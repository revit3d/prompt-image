#!/usr/bin/env python3
"""Download a reproducible, local-only 400-image public evaluation sample."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import random
import re
import tempfile
import urllib.error
import urllib.request
import zipfile


COCO_BASE = "https://s3.us-east-1.amazonaws.com/images.cocodataset.org"
COCO_ARCHIVE = COCO_BASE + "/annotations/annotations_trainval2017.zip"
COCO_MEMBER = "annotations/captions_val2017.json"
TEXTVQA_METADATA = "https://dl.fbaipublicfiles.com/textvqa/data/TextVQA_0.5.1_val.json"
SEED = 173
METADATA_LIMIT = 300 * 1024 * 1024
IMAGE_LIMIT = 5 * 1024 * 1024
USER_AGENT = "PromptImage-Evaluation/1.0 (public-dataset subset downloader)"
PROVENANCE_FIELDS = [
    "dataset", "source_image_id", "relative_path", "download_url",
    "original_url", "license_name", "license_url", "sha256", "bytes",
]


def request(url, headers=None):
    if not url.startswith("https://"):
        raise ValueError("Only HTTPS downloads are allowed")
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})}),
        timeout=20,
    )


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_cached(path, expected_hash=None):
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Expected a regular cached file: {path}")
    if expected_hash and sha256(path) != expected_hash:
        raise ValueError(f"Cached file changed; inspect it before retrying: {path}")


def download(url, destination, limit, expected_hash=None):
    if destination.exists():
        verify_cached(destination, expected_hash)
        if destination.stat().st_size > limit:
            raise ValueError(f"Cached file exceeds size limit: {destination}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with request(url) as response, tempfile.NamedTemporaryFile(
            dir=destination.parent, prefix=destination.name + ".", suffix=".partial", delete=False
        ) as output:
            temporary = Path(output.name)
            if int(response.headers.get("Content-Length", "0")) > limit:
                raise ValueError(f"Download exceeds {limit} bytes: {url}")
            count = 0
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                count += len(chunk)
                if count > limit:
                    raise ValueError(f"Download exceeds {limit} bytes: {url}")
                output.write(chunk)
        verify_cached(temporary, expected_hash)
        # Never replace a file that appeared while this download was running.
        os.link(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class RangeUnavailable(Exception):
    pass


class RemoteZip(io.RawIOBase):
    """Seekable HTTP Range reader; avoids downloading the full COCO archive."""

    def __init__(self, url):
        super().__init__()
        self.url = url
        self.position = 0
        with request(url, {"Range": "bytes=0-0"}) as response:
            match = re.fullmatch(r"bytes 0-0/(\d+)", response.headers.get("Content-Range", ""))
            if response.status != 206 or not match:
                raise RangeUnavailable("COCO host did not support HTTP Range requests")
            self.length = int(match.group(1))
            response.read(1)

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        bases = {io.SEEK_SET: 0, io.SEEK_CUR: self.position, io.SEEK_END: self.length}
        if whence not in bases or bases[whence] + offset < 0:
            raise ValueError("Invalid seek")
        self.position = bases[whence] + offset
        return self.position

    def read(self, size=-1):
        count = min(self.length - self.position, size if size >= 0 else self.length)
        if count <= 0:
            return b""
        if count > METADATA_LIMIT:
            raise ValueError("Remote ZIP read exceeds metadata limit")
        start, end = self.position, self.position + count - 1
        with request(self.url, {"Range": f"bytes={start}-{end}"}) as response:
            expected = f"bytes {start}-{end}/{self.length}"
            if response.status != 206 or response.headers.get("Content-Range") != expected:
                raise RangeUnavailable("COCO host stopped honoring HTTP Range requests")
            data = response.read(count + 1)
            if len(data) != count:
                raise ValueError("Truncated or oversized COCO Range response")
        self.position += count
        return data


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def save_fixed_json(path, value):
    payload = json_bytes(value)
    if path.exists():
        if path.read_bytes() != payload:
            raise ValueError(f"Existing metadata differs; inspect it before retrying: {path}")
    else:
        path.write_bytes(payload)


def load_metadata(sources, previous_hashes, allow_full_archive):
    coco_path = sources / "captions_val2017.json"
    if coco_path.exists():
        verify_cached(coco_path, previous_hashes.get(coco_path.name))
        if coco_path.stat().st_size > METADATA_LIMIT:
            raise ValueError("Cached COCO metadata exceeds size limit")
    else:
        try:
            archive_source = RemoteZip(COCO_ARCHIVE)
        except RangeUnavailable:
            if not allow_full_archive:
                raise ValueError(
                    "HTTP Range is unavailable. Retry with --allow-full-coco-archive "
                    "to permit downloading the approximately 241 MB annotation archive."
                )
            archive_path = sources / "annotations_trainval2017.zip"
            download(COCO_ARCHIVE, archive_path, METADATA_LIMIT)
            archive_source = archive_path
        with zipfile.ZipFile(archive_source) as archive:
            if archive.getinfo(COCO_MEMBER).file_size > METADATA_LIMIT:
                raise ValueError("COCO captions metadata exceeds size limit")
            payload = archive.read(COCO_MEMBER)
            # Validate before writing; no general archive extraction or path traversal.
            json.loads(payload)
            coco_path.write_bytes(payload)
    text_path = sources / "TextVQA_0.5.1_val.json"
    download(TEXTVQA_METADATA, text_path, METADATA_LIMIT, previous_hashes.get(text_path.name))
    return json.loads(coco_path.read_text()), json.loads(text_path.read_text()), [coco_path, text_path]


def choose_images(coco, textvqa):
    licenses = {entry["id"]: entry for entry in coco["licenses"]}
    eligible = [
        image for image in coco["images"]
        if "/licenses/by/" in licenses[image["license"]]["url"]
    ]
    if len(eligible) < 320:
        raise ValueError("Fewer than 320 COCO images with the requested CC BY license")
    captions = {}
    for annotation in coco["annotations"]:
        captions.setdefault(annotation["image_id"], []).append(annotation["caption"])
    chosen_coco = sorted(random.Random(SEED).sample(sorted(eligible, key=lambda row: row["id"]), 320), key=lambda row: row["id"])
    choices = []
    for image in chosen_coco:
        if not isinstance(image["file_name"], str) or not re.fullmatch(r"[0-9]{12}\.jpg", image["file_name"]):
            raise ValueError("COCO metadata contains an unexpected image filename")
        license_info = licenses[image["license"]]
        choices.append({
            "dataset": "coco2017_val", "source_image_id": str(image["id"]),
            "relative_path": "coco/" + image["file_name"],
            "download_url": COCO_BASE + "/val2017/" + image["file_name"],
            "original_url": image.get("flickr_url", ""),
            "license_name": license_info["name"], "license_url": license_info["url"],
            "captions": captions.get(image["id"], []),
        })
    excluded = {
        "yes", "no", "none", "unknown", "unanswerable", "nothing", "unreadable",
        "black", "white", "red", "blue", "green", "yellow", "orange", "pink",
        "purple", "brown", "gray", "grey", "silver", "gold", "left", "right",
        "top", "bottom", "up", "down", "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine", "ten",
    }
    candidates = {}
    for row in sorted(textvqa["data"], key=lambda item: item["question_id"]):
        if not isinstance(row["image_id"], str) or not re.fullmatch(r"[0-9a-f]{16}", row["image_id"]):
            raise ValueError("TextVQA metadata contains an unexpected image identifier")
        if not row["answers"]:
            continue
        answer, consensus = Counter(a.strip().lower() for a in row["answers"]).most_common(1)[0]
        if consensus < 8 or len(answer) < 3 or answer in excluded or not any(c.isalpha() for c in answer):
            continue
        candidates.setdefault(row["image_id"], {**row, "consensus_answer": answer, "consensus_count": consensus})
    if len(candidates) < 80:
        raise ValueError("Fewer than 80 unique TextVQA images pass the consensus filter")
    chosen_text = random.Random(SEED).sample(sorted(candidates), 80)
    for image_id in sorted(chosen_text):
        row = candidates[image_id]
        choices.append({
            "dataset": "textvqa_0.5.1_val", "source_image_id": image_id,
            "relative_path": f"textvqa/{image_id}.jpg",
            "download_url": f"https://open-images-dataset.s3.amazonaws.com/train/{image_id}.jpg",
            "original_url": row.get("flickr_original_url", ""),
            "license_name": "CC BY 2.0 (Open Images source listing; see source page)",
            "license_url": "https://creativecommons.org/licenses/by/2.0/",
            "question": row["question"], "question_id": row["question_id"],
            "answers": row["answers"], "consensus_answer": row["consensus_answer"],
            "consensus_count": row["consensus_count"],
        })
    return choices


def fetch_image(root, choice, previous_hashes):
    destination = root / "images" / choice["relative_path"]
    download(choice["download_url"], destination, IMAGE_LIMIT, previous_hashes.get(choice["relative_path"]))
    if destination.stat().st_size < 5:
        raise ValueError(f"Image is too small to be a JPEG: {destination}")
    with destination.open("rb") as stream:
        beginning = stream.read(3)
        stream.seek(-2, io.SEEK_END)
        ending = stream.read(2)
    if beginning != b"\xff\xd8\xff" or ending != b"\xff\xd9":
        raise ValueError(f"Invalid or truncated JPEG markers: {destination}")
    return {
        **{field: choice[field] for field in PROVENANCE_FIELDS if field not in ("sha256", "bytes")},
        "sha256": sha256(destination), "bytes": destination.stat().st_size,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1] / "PrivateData" / "Evaluation")
    parser.add_argument("--allow-full-coco-archive", action="store_true", help="Allow a ~241 MB archive if HTTP Range is unsupported")
    args = parser.parse_args()
    root = args.root.resolve()
    sources = root / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    info_path = sources / "SOURCE_INFO.json"
    previous = json.loads(info_path.read_text()) if info_path.exists() else {}
    provenance_path = root / "provenance.csv"
    image_hashes = {}
    if provenance_path.exists():
        with provenance_path.open(newline="", encoding="utf-8") as stream:
            image_hashes = {row["relative_path"]: row["sha256"] for row in csv.DictReader(stream)}
    coco, textvqa, metadata_paths = load_metadata(sources, previous.get("metadata_sha256", {}), args.allow_full_coco_archive)
    choices = choose_images(coco, textvqa)
    save_fixed_json(sources / "selection.json", choices)
    info = {
        "seed": SEED, "counts": {"coco2017_val": 320, "textvqa_0.5.1_val": 80},
        "metadata_urls": {"captions_val2017.json": COCO_ARCHIVE + "#" + COCO_MEMBER, "TextVQA_0.5.1_val.json": TEXTVQA_METADATA},
        "metadata_sha256": {path.name: sha256(path) for path in metadata_paths},
        "selection_sha256": sha256(sources / "selection.json"),
        "source_pages": ["https://cocodataset.org/#termsofuse", "https://textvqa.org/dataset/", "https://github.com/openimages/dataset", "https://github.com/cvdfoundation/open-images-dataset"],
        "license_notes": [
            "COCO image licenses come from its per-image license table; only CC BY entries are selected.",
            "TextVQA annotations are published under CC BY 4.0. Open Images lists source images as CC BY 2.0 without warranting each image's current license.",
            "Original image URLs are retained. This manifest does not contain verified individual photographer credits and is not a redistribution license clearance.",
        ],
    }
    save_fixed_json(info_path, info)
    rows = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        pending = [pool.submit(fetch_image, root, choice, image_hashes) for choice in choices]
        try:
            for future in as_completed(pending):
                rows.append(future.result())
                if len(rows) % 50 == 0:
                    print(f"Downloaded or verified {len(rows)}/400 images", flush=True)
        except BaseException:
            for future in pending:
                future.cancel()
            raise
    rows.sort(key=lambda row: row["relative_path"])
    with provenance_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=PROVENANCE_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    size = sum(row["bytes"] for row in rows)
    print(f"Ready: {len(rows)} images, {size / 1024 / 1024:.1f} MiB in {root / 'images'}")
    print("Run tools/evaluation.py inventory, then prepare and review the query labels.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, urllib.error.URLError, RangeUnavailable) as error:
        raise SystemExit(f"Evaluation download failed: {error}") from error
