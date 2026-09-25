#!/usr/bin/env python3
"""Prepare and validate a local retrieval benchmark; never uploads data."""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


DEFAULT_DATASET = Path(__file__).resolve().parents[1] / "PrivateData/Evaluation"
IMAGE_FIELDS = ["image_id", "relative_path", "sha256"]
QUERY_FIELDS = ["query_id", "group_id", "split", "language", "kind", "query",
                "expected_image_ids", "notes"]
EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_csv(path, fields, rows):
    """Replace generated metadata atomically, preserving images and other CSVs."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="",
                                     dir=path.parent, delete=False) as target:
        temporary = Path(target.name)
        writer = csv.DictWriter(target, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def read_csv(path, fields):
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != fields:
            raise ValueError(f"{path.name}: expected columns {', '.join(fields)}")
        rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise ValueError(f"{path.name}: malformed CSV row")
    return rows


def query_template():
    rows = []
    for kind, prefix in [("visual", "v"), ("text", "t")]:
        for index in range(1, 21):
            group = f"{prefix}{index:02}"
            for language in ["ru", "en"]:
                rows.append(dict(query_id=f"{group}-{language}", group_id=group,
                                 split="development" if index <= 14 else "holdout",
                                 language=language, kind=kind, query="",
                                 expected_image_ids="", notes=""))
    return rows


def initialize(dataset):
    (dataset / "images").mkdir(parents=True, exist_ok=True)
    for filename, fields, rows in [("images.csv", IMAGE_FIELDS, []),
                                   ("queries.csv", QUERY_FIELDS, query_template())]:
        if not (dataset / filename).exists():
            write_csv(dataset / filename, fields, rows)


def image_inventory(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("images must be an existing directory, not a symlink")
    files = []
    for base, directories, names in os.walk(directory, followlinks=False):
        directories[:] = sorted(name for name in directories
                                if not (Path(base) / name).is_symlink())
        files.extend(Path(base) / name for name in sorted(names)
                     if Path(name).suffix.lower() in EXTENSIONS
                     and not (Path(base) / name).is_symlink())
    rows, known, duplicates = [], {}, 0
    for path in sorted(files):
        digest = sha256(path)
        image_id = "img_" + digest[:12]
        if image_id in known:
            if known[image_id] != digest:
                raise ValueError("Short image ID collision; increase ID length before proceeding")
            duplicates += 1
            continue
        known[image_id] = digest
        rows.append(dict(image_id=image_id,
                         relative_path=path.relative_to(directory).as_posix(), sha256=digest))
    return rows, duplicates


def validate(dataset):
    images = read_csv(dataset / "images.csv", IMAGE_FIELDS)
    queries = read_csv(dataset / "queries.csv", QUERY_FIELDS)
    errors = []
    if not 300 <= len(images) <= 500:
        errors.append(f"Expected 300–500 unique images; found {len(images)}")
    ids, paths = set(), set()
    image_root = dataset / "images"
    for row in images:
        image_id, relative = row["image_id"], Path(row["relative_path"])
        if image_id in ids or row["relative_path"] in paths:
            errors.append("Duplicate image ID or path in images.csv")
        ids.add(image_id)
        paths.add(row["relative_path"])
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            errors.append(f"Unsafe image path for {image_id}")
            continue
        path = image_root / relative
        if any(parent.is_symlink() for parent in [image_root, path, *path.parents]
               if parent == image_root or image_root in parent.parents):
            errors.append(f"Symlink image path for {image_id}")
            continue
        if not path.is_file():
            errors.append(f"Missing image for {image_id}")
            continue
        digest = sha256(path)
        if digest != row["sha256"] or image_id != "img_" + digest[:12]:
            errors.append(f"Image integrity mismatch for {image_id}")
    actual, duplicates = image_inventory(image_root)
    if images != actual:
        errors.append("Image inventory is stale; run inventory and review any label changes")

    groups, seen_queries, positives = defaultdict(list), set(), defaultdict(set)
    for row in queries:
        query_id = row["query_id"]
        if not query_id or query_id in seen_queries:
            errors.append("Blank or duplicate query_id")
        seen_queries.add(query_id)
        if not row["group_id"]:
            errors.append(f"Missing group_id for {query_id}")
        for key, options in [("split", {"development", "holdout"}),
                             ("language", {"ru", "en"}), ("kind", {"visual", "text"})]:
            if row[key] not in options:
                errors.append(f"Invalid {key} for {query_id}")
        if not row["query"].strip():
            errors.append(f"Missing query text for {query_id}")
        expected = row["expected_image_ids"].split("|")
        if not all(expected) or len(expected) != len(set(expected)):
            errors.append(f"Missing or duplicate expected image IDs for {query_id}")
        if set(expected) - ids:
            errors.append(f"Unknown expected image ID for {query_id}")
        for image_id in expected:
            if image_id:
                positives[image_id].add(row["split"])
        groups[row["group_id"]].append(row)
    group_counts = Counter()
    for group_id, rows in groups.items():
        if Counter(row["language"] for row in rows) != Counter({"ru": 1, "en": 1}):
            errors.append(f"Group {group_id} needs exactly one Russian and one English query")
        for key in ["split", "kind"]:
            if len({row[key] for row in rows}) != 1:
                errors.append(f"Group {group_id} crosses {key} boundaries")
        if len({frozenset(row["expected_image_ids"].split("|")) for row in rows}) != 1:
            errors.append(f"Language pair in {group_id} has different expected images")
        group_counts[(rows[0]["kind"], rows[0]["split"])] += 1
    if any(len(splits) > 1 for splits in positives.values()):
        errors.append("Expected image reused across development and holdout queries")
    for kind in ["visual", "text"]:
        for split, minimum in [("development", 14), ("holdout", 6)]:
            if group_counts[(kind, split)] < minimum:
                errors.append(f"Need at least {minimum} {split} {kind} query groups")
    counts = Counter(f'{row["kind"]}/{row["language"]}/{row["split"]}' for row in queries)
    return dict(images=len(images), queries=len(queries), groups=len(groups),
                duplicate_image_files=duplicates, query_counts=dict(sorted(counts.items())),
                errors=errors)


def freeze(dataset):
    """Export the reviewed split and record the exact benchmark revision."""
    report = validate(dataset)
    if report["errors"]:
        raise ValueError("Cannot freeze an invalid benchmark; run validate for details")
    queries = read_csv(dataset / "queries.csv", QUERY_FIELDS)
    paths = ["images.csv", "queries.csv"]
    for split in ["development", "holdout"]:
        filename = f"queries.{split}.csv"
        write_csv(dataset / filename, QUERY_FIELDS,
                  [row for row in queries if row["split"] == split])
        paths.append(filename)
    paths.extend(name for name in ["provenance.csv", "sources/SOURCE_INFO.json"]
                 if (dataset / name).is_file())
    snapshot = dict(schema_version=1, **report,
                    file_sha256={name: sha256(dataset / name) for name in paths})
    (dataset / "benchmark.json").write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("command", choices=["init", "inventory", "validate", "freeze"])
    args = parser.parse_args()
    try:
        if args.command == "init":
            initialize(args.dataset)
            print("Evaluation directories and missing CSV templates created; existing labels preserved.")
        elif args.command == "inventory":
            rows, duplicates = image_inventory(args.dataset / "images")
            write_csv(args.dataset / "images.csv", IMAGE_FIELDS, rows)
            print(f"Inventoried {len(rows)} unique images; {duplicates} exact duplicates retained on disk.")
        elif args.command == "freeze":
            report = freeze(args.dataset)
            print(f'Frozen {report["images"]} images and {report["queries"]} queries; benchmark.json records their hashes.')
        else:
            report = validate(args.dataset)
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 1 if report["errors"] else 0
    except (OSError, ValueError, csv.Error) as error:
        print(f"Evaluation error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
