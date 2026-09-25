#!/usr/bin/env python3
"""Copy the frozen development corpus into an ignored, developer-only iPhone demo.

Uses only the standard library. No Photos access, image conversion, networking,
or held-out query reads. The output is development data, never an app resource.
"""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATASET = ROOT / "PrivateData/Evaluation"
DEFAULT_OUTPUT = ROOT / "PrivateData/RetrievalDemo"
MODEL_ID = "openai-clip-vit-b32-fp16-v2"
MANIFEST = "demo-manifest.json"
IMAGE_FIELDS = ["image_id", "relative_path", "sha256"]
QUERY_FIELDS = ["query_id", "group_id", "split", "language", "kind", "query",
                "expected_image_ids", "notes"]
HASH = re.compile(r"[0-9a-f]{64}\Z")
IDENTIFIER = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
MAX_METADATA_BYTES = 1024 * 1024
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_CORPUS_BYTES = 500 * MAX_IMAGE_BYTES


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def reject_symlinks(path):
    path = Path(os.path.abspath(path))
    if any(item.is_symlink() for item in [path, *path.parents]):
        raise ValueError("Symlink paths are not allowed")
    return path


def safe_path(directory, relative):
    if (not isinstance(relative, str) or not relative or "\\" in relative
            or "\x00" in relative):
        raise ValueError("Unsafe relative path")
    parts = PurePosixPath(relative).parts
    if (relative.startswith("/") or not parts or any(part in {".", ".."} for part in relative.split("/"))
            or "/".join(parts) != relative):
        raise ValueError("Unsafe relative path")
    return reject_symlinks(Path(directory).joinpath(*parts))


def require_file(path, maximum):
    path = reject_symlinks(path)
    if not path.is_file() or not 0 < path.stat().st_size <= maximum:
        raise ValueError("Missing, empty, or oversized input file")
    return path


def read_json(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result

    with require_file(path, MAX_METADATA_BYTES).open(encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=unique_keys)


def read_csv(path, fields):
    with require_file(path, MAX_METADATA_BYTES).open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != fields:
            raise ValueError("Unexpected CSV columns")
        rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise ValueError("Malformed CSV row")
    return rows


def fingerprint(source):
    encoded = json.dumps(source, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_manifest(manifest):
    """Check the complete schema before any image path is opened."""
    if (not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int
            or manifest["schema_version"] != 1 or manifest.get("model_id") != MODEL_ID):
        raise ValueError("Unsupported demo schema or incompatible model")
    source = manifest.get("source")
    fields = {"benchmark_sha256", "images_csv_sha256", "development_queries_csv_sha256"}
    if (not isinstance(source, dict) or set(source) != fields
            or any(not isinstance(value, str) or not HASH.fullmatch(value) for value in source.values())
            or manifest.get("corpus_fingerprint") != fingerprint(source)):
        raise ValueError("Invalid corpus fingerprint or source hashes")
    images, queries = manifest.get("images"), manifest.get("queries")
    if not isinstance(images, list) or not 1 <= len(images) <= 500:
        raise ValueError("Demo needs between 1 and 500 images")
    if not isinstance(queries, list) or not 1 <= len(queries) <= 100:
        raise ValueError("Demo needs development visual queries")
    ids, paths = set(), set()
    for item in images:
        if not isinstance(item, dict) or set(item) != {"id", "relative_path", "sha256"}:
            raise ValueError("Invalid image record")
        digest, name, relative = item["sha256"], item["id"], item["relative_path"]
        if (not isinstance(digest, str) or not HASH.fullmatch(digest)
                or name != "img_" + digest[:12] or name in ids):
            raise ValueError("Duplicate or invalid image ID/hash")
        if (not isinstance(relative, str) or not relative.startswith("images/")
                or relative.casefold() in paths):
            raise ValueError("Duplicate or invalid image path")
        # Validate lexical paths without depending on a real directory.
        if ("\\" in relative or "\x00" in relative or
                any(part in {"", ".", ".."} for part in relative.split("/"))):
            raise ValueError("Unsafe image path")
        ids.add(name)
        paths.add(relative.casefold())
    groups, query_ids = defaultdict(list), set()
    for item in queries:
        if not isinstance(item, dict) or set(item) != {"id", "group_id", "language", "text", "expected_image_ids"}:
            raise ValueError("Invalid query record")
        for field in ("id", "group_id"):
            if not isinstance(item[field], str) or not IDENTIFIER.fullmatch(item[field]):
                raise ValueError("Invalid query or group ID")
        if item["id"] in query_ids:
            raise ValueError("Duplicate query ID")
        query_ids.add(item["id"])
        text, expected = item["text"], item["expected_image_ids"]
        if (item["language"] not in {"ru", "en"} or not isinstance(text, str)
                or not text.strip() or len(text.encode("utf-8")) > 16384):
            raise ValueError("Invalid query language or text")
        if (not isinstance(expected, list) or not expected or any(not isinstance(value, str) for value in expected)
                or len(set(expected)) != len(expected) or set(expected) - ids):
            raise ValueError("Missing, duplicate, or unknown expected image IDs")
        groups[item["group_id"]].append(item)
    for group in groups.values():
        if Counter(item["language"] for item in group) != Counter({"ru": 1, "en": 1}):
            raise ValueError("Each development group needs one Russian and one English query")
        if len({frozenset(item["expected_image_ids"]) for item in group}) != 1:
            raise ValueError("Language pair has different expected image IDs")
    return manifest


def dataset_manifest(dataset):
    """Verify frozen metadata and image bytes without opening any holdout query file."""
    dataset = reject_symlinks(dataset)
    benchmark_path = dataset / "benchmark.json"
    benchmark = read_json(benchmark_path)
    if (not isinstance(benchmark, dict) or benchmark.get("schema_version") != 1
            or benchmark.get("errors") != [] or not isinstance(benchmark.get("file_sha256"), dict)):
        raise ValueError("Dataset must have a valid frozen benchmark.json")
    source = {"benchmark_sha256": sha256(benchmark_path)}
    for filename, field in (("images.csv", "images_csv_sha256"),
                            ("queries.development.csv", "development_queries_csv_sha256")):
        actual = sha256(require_file(dataset / filename, MAX_METADATA_BYTES))
        if actual != benchmark["file_sha256"].get(filename):
            raise ValueError("Frozen dataset CSV checksum mismatch")
        source[field] = actual
    image_rows = read_csv(dataset / "images.csv", IMAGE_FIELDS)
    query_rows = read_csv(dataset / "queries.development.csv", QUERY_FIELDS)
    if type(benchmark.get("images")) is not int or len(image_rows) != benchmark["images"]:
        raise ValueError("Frozen image count mismatch")
    if any(row["split"] != "development" or row["kind"] not in {"visual", "text"} for row in query_rows):
        raise ValueError("Development CSV contains an invalid split or kind")
    if len({row["query_id"] for row in query_rows}) != len(query_rows):
        raise ValueError("Duplicate query ID in development CSV")
    counts = Counter(f'{row["kind"]}/{row["language"]}/development' for row in query_rows)
    frozen_counts = {key: value for key, value in benchmark.get("query_counts", {}).items()
                     if key.endswith("/development")}
    if dict(counts) != frozen_counts:
        raise ValueError("Frozen development query counts mismatch")
    manifest = {
        "schema_version": 1, "model_id": MODEL_ID, "corpus_fingerprint": fingerprint(source),
        "source": source,
        "images": [{"id": row["image_id"], "relative_path": "images/" + row["relative_path"],
                    "sha256": row["sha256"]} for row in image_rows],
        "queries": [{"id": row["query_id"], "group_id": row["group_id"], "language": row["language"],
                     "text": row["query"], "expected_image_ids": row["expected_image_ids"].split("|")}
                    for row in query_rows if row["kind"] == "visual"],
    }
    validate_manifest(manifest)
    verify_images(dataset, manifest)
    return manifest


def verify_images(directory, manifest):
    total_bytes = 0
    for item in manifest["images"]:
        path = require_file(safe_path(directory, item["relative_path"]), MAX_IMAGE_BYTES)
        total_bytes += path.stat().st_size
        if total_bytes > MAX_CORPUS_BYTES:
            raise ValueError("Demo corpus exceeds the byte limit")
        if sha256(path) != item["sha256"]:
            raise ValueError("Image checksum mismatch")


def verify_bundle(directory, expected_manifest=None):
    """Verify a transferred bundle locally; optionally bind it to the frozen source."""
    directory = reject_symlinks(directory)
    manifest = validate_manifest(read_json(directory / MANIFEST))
    if expected_manifest is not None and manifest != expected_manifest:
        raise ValueError("Demo differs from the frozen development corpus")
    verify_images(directory, manifest)
    expected_files = {MANIFEST, *(item["relative_path"] for item in manifest["images"])}
    actual_files = set()
    for base, directories, names in os.walk(directory, followlinks=False):
        for name in directories + names:
            reject_symlinks(Path(base) / name)
        actual_files.update((Path(base) / name).relative_to(directory).as_posix() for name in names)
    if actual_files != expected_files:
        raise ValueError("Unexpected or missing demo files")
    return manifest


def validate_output(dataset, output):
    dataset, output = reject_symlinks(dataset), reject_symlinks(output)
    # Casefold prevents bypassing these guards on the usual macOS filesystem.
    normalized = lambda path: Path(str(path.resolve()).casefold())
    source, destination, root = normalized(dataset), normalized(output), normalized(ROOT)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Demo output cannot overlap the source dataset")
    allowed = normalized(ROOT / "PrivateData/RetrievalDemo")
    if (destination == root or destination in root.parents
            or (root in destination.parents and destination != allowed and allowed not in destination.parents)):
        raise ValueError("Repository demo output must be inside PrivateData/RetrievalDemo")
    if output.exists():
        # Never replace an arbitrary folder, even when a caller supplies --output.
        verify_bundle(output)
    return output


def publish(staging, output, backup):
    if output.exists():
        output.rename(backup)
    try:
        staging.rename(output)
    except BaseException:
        if backup.exists():
            try:
                backup.rename(output)
            except OSError as error:
                raise OSError(f"Could not restore previous demo; it is preserved at {backup}") from error
        raise


def prepare(dataset=DEFAULT_DATASET, output=DEFAULT_OUTPUT):
    output = validate_output(dataset, output)
    manifest = dataset_manifest(dataset)
    output.parent.mkdir(parents=True, exist_ok=True)
    # The temporary directory is on the same filesystem as the final folder.
    temporary = Path(tempfile.mkdtemp(prefix=".retrieval-demo-", dir=output.parent))
    backup, published = temporary / "previous", False
    try:
        staging = temporary / "staging"
        staging.mkdir()
        for item in manifest["images"]:
            source = safe_path(dataset, item["relative_path"])
            destination = staging / item["relative_path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        (staging / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        verify_bundle(staging, manifest)
        # Recheck metadata after copying; mutation during preparation cannot publish.
        if dataset_manifest(dataset) != manifest:
            raise ValueError("Frozen corpus changed during preparation")
        publish(staging, output, backup)
        published = True
    finally:
        # A failed restore must not cause temporary-directory cleanup to erase
        # the only surviving copy of the previous demo.
        if published or not backup.exists():
            shutil.rmtree(temporary)
    return manifest


def score_results(manifest, report):
    """Score the first ten ranks against known positives; missing/failed queries score zero."""
    validate_manifest(manifest)
    if (not isinstance(report, dict) or report.get("schema_version") != 1
            or report.get("model_id") != manifest["model_id"]
            or report.get("corpus_fingerprint") != manifest["corpus_fingerprint"]
            or type(report.get("ranking_limit")) is not int or report["ranking_limit"] != 10
            or not isinstance(report.get("cases"), list)):
        raise ValueError("Results have incompatible corpus or model provenance")
    image_ids = {item["id"] for item in manifest["images"]}
    queries = {item["id"]: item for item in manifest["queries"]}
    results = {}
    for case in report["cases"]:
        if not isinstance(case, dict) or case.get("query_id") not in queries:
            raise ValueError("Results contain an unknown query")
        query_id, ranked_ids = case["query_id"], case.get("ranked_ids")
        if query_id in results:
            raise ValueError("Results contain a duplicate query")
        if (not isinstance(ranked_ids, list) or any(not isinstance(value, str) for value in ranked_ids)
                or len(set(ranked_ids)) != len(ranked_ids) or set(ranked_ids) - image_ids):
            raise ValueError("Results contain duplicate or unknown ranked images")
        error = case.get("error")
        if error is not None and (not isinstance(error, str) or not error.strip()):
            raise ValueError("Result error must be a nonempty string when present")
        if error is None and len(ranked_ids) != min(10, len(image_ids)):
            raise ValueError("Successful queries must contain the first ten corpus ranks")
        results[query_id] = case
    scores = {}
    for language in ("ru", "en"):
        language_queries = [query for query in queries.values() if query["language"] == language]
        first_ranks, failed = [], 0
        for query in language_queries:
            case = results.get(query["id"])
            if case is None or case.get("error") is not None:
                failed += 1
                first_ranks.append(None)
                continue
            first_ranks.append(next((rank for rank, image_id in enumerate(case["ranked_ids"], 1)
                                     if image_id in query["expected_image_ids"]), None))
        count = len(language_queries)
        top1 = sum(rank == 1 for rank in first_ranks)
        top5 = sum(rank is not None and rank <= 5 for rank in first_ranks)
        scores[language] = {"queries": count, "failed_queries": failed,
                            "success_at_1_count": top1, "success_at_1": top1 / count,
                            "success_at_5_count": top5, "success_at_5": top5 / count,
                            "mrr_at_10": sum(1 / rank for rank in first_ranks if rank) / count}
    return {"schema_version": 1, "model_id": manifest["model_id"],
            "corpus_fingerprint": manifest["corpus_fingerprint"], "split": "development", "kind": "visual", "ranking_limit": 10,
            "languages": scores,
            "limitations": "Known positives may be incomplete. RU/EN versions of a scenario are paired observations. Development results do not establish held-out or personal-photo quality."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify", "score"])
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--results", type=Path, help="Developer result JSON; required for score")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            manifest = prepare(args.dataset, args.output)
        else:
            manifest = verify_bundle(args.output, dataset_manifest(args.dataset))
        if args.command == "score":
            if args.results is None:
                raise ValueError("score requires --results")
            print(json.dumps(score_results(manifest, read_json(args.results)), indent=2))
            return
        print(f'{args.command.capitalize()} verified {len(manifest["images"])} unchanged images and '
              f'{len(manifest["queries"])} development visual queries. '
              f'Corpus: {manifest["corpus_fingerprint"]}')
    except (OSError, ValueError, csv.Error, TypeError, KeyError) as error:
        parser.exit(1, f"Retrieval demo error: {error}\n")


if __name__ == "__main__":
    main()
