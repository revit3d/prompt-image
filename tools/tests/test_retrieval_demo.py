from collections import Counter
from copy import deepcopy
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "prepare_retrieval_demo", Path(__file__).parents[1] / "prepare_retrieval_demo.py"
)
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class RetrievalDemoTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.dataset = self.root / "source"
        self.output = self.root / "demo"
        self.dataset.mkdir()
        self.images, self.queries = [], []
        for index in range(3):
            relative = f"coco/image-{index}.jpg"
            image = self.dataset / "images" / relative
            image.parent.mkdir(parents=True, exist_ok=True)
            # Opaque bytes prove the transfer neither decodes nor re-encodes files.
            image.write_bytes(f"original image fixture {index}".encode())
            digest = demo.sha256(image)
            self.images.append({"image_id": "img_" + digest[:12], "relative_path": relative, "sha256": digest})
        for index, kind in enumerate(("visual", "visual", "text")):
            for language in ("ru", "en"):
                self.queries.append({"query_id": f"q{index}-{language}", "group_id": f"q{index}",
                                     "split": "development", "language": language, "kind": kind,
                                     "query": "кот" if language == "ru" else "cat",
                                     "expected_image_ids": self.images[index]["image_id"], "notes": "source evidence"})
        self.freeze()

    def write_csv(self, name, fields, rows):
        with (self.dataset / name).open("w", encoding="utf-8", newline="") as target:
            writer = csv.DictWriter(target, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def freeze(self):
        self.write_csv("images.csv", demo.IMAGE_FIELDS, self.images)
        self.write_csv("queries.development.csv", demo.QUERY_FIELDS, self.queries)
        benchmark = {"schema_version": 1, "errors": [], "images": len(self.images),
                     "query_counts": dict(Counter(f'{row["kind"]}/{row["language"]}/development' for row in self.queries)),
                     "file_sha256": {name: demo.sha256(self.dataset / name)
                                     for name in ("images.csv", "queries.development.csv")}}
        (self.dataset / "benchmark.json").write_text(json.dumps(benchmark))

    def write_manifest(self, manifest):
        (self.output / demo.MANIFEST).write_text(json.dumps(manifest))

    def report(self, manifest):
        ids = [image["id"] for image in manifest["images"]]
        return {"schema_version": 1, "model_id": demo.MODEL_ID,
                "corpus_fingerprint": manifest["corpus_fingerprint"], "ranking_limit": 10,
                "cases": [{"query_id": query["id"], "ranked_ids": ids[:]} for query in manifest["queries"]]}

    def test_prepare_copies_exact_bytes_and_only_development_visual_queries(self):
        # No all-query or holdout file is needed or read. Poison files make accidental reads fail.
        for name in ("queries.csv", "queries.holdout.csv"):
            (self.dataset / name).mkdir()
        manifest = demo.prepare(self.dataset, self.output)
        self.assertEqual(len(manifest["images"]), 3)
        self.assertEqual(len(manifest["queries"]), 4)
        self.assertEqual({query["group_id"] for query in manifest["queries"]}, {"q0", "q1"})
        self.assertEqual(demo.verify_bundle(self.output, demo.dataset_manifest(self.dataset)), manifest)
        for image in manifest["images"]:
            self.assertEqual((self.output / image["relative_path"]).read_bytes(),
                             (self.dataset / image["relative_path"]).read_bytes())
        self.assertEqual(demo.prepare(self.dataset, self.output), manifest)

    def test_fingerprint_has_deterministic_compact_sorted_encoding(self):
        source = {"z": "1", "a": "2"}
        self.assertEqual(demo.fingerprint(source), hashlib.sha256(b'{"a":"2","z":"1"}').hexdigest())
        self.assertEqual(demo.fingerprint(source), demo.fingerprint(dict(reversed(list(source.items())))))

    def test_changed_frozen_metadata_is_rejected(self):
        for filename in ("images.csv", "queries.development.csv"):
            with self.subTest(filename=filename):
                self.freeze()
                with (self.dataset / filename).open("a") as target:
                    target.write("\n")
                with self.assertRaisesRegex(ValueError, "CSV checksum mismatch"):
                    demo.prepare(self.dataset, self.output)
                self.assertFalse(self.output.exists())

    def test_changed_image_keeps_previous_demo(self):
        previous = demo.prepare(self.dataset, self.output)
        (self.dataset / previous["images"][0]["relative_path"]).write_bytes(b"changed source")
        with self.assertRaisesRegex(ValueError, "Image checksum mismatch"):
            demo.prepare(self.dataset, self.output)
        self.assertEqual(demo.verify_bundle(self.output), previous)

    def test_duplicate_ids_queries_or_paths_are_rejected(self):
        original_images, original_queries = deepcopy(self.images), deepcopy(self.queries)
        for mutation in ("image", "query", "path"):
            with self.subTest(mutation=mutation):
                self.images, self.queries = deepcopy(original_images), deepcopy(original_queries)
                if mutation == "image":
                    self.images.append(self.images[0])
                elif mutation == "query":
                    self.queries.append(self.queries[0])
                else:
                    self.images[1]["relative_path"] = self.images[0]["relative_path"]
                self.freeze()
                with self.assertRaisesRegex(ValueError, "[Dd]uplicate"):
                    demo.prepare(self.dataset, self.output)

    def test_query_schema_and_frozen_counts_are_checked(self):
        original = deepcopy(self.queries)
        for mutation in ("holdout", "unknown_positive", "unpaired", "mismatched_pair"):
            with self.subTest(mutation=mutation):
                self.queries = deepcopy(original)
                if mutation == "holdout":
                    self.queries[0]["split"] = "holdout"
                elif mutation == "unknown_positive":
                    self.queries[0]["expected_image_ids"] = "missing"
                elif mutation == "unpaired":
                    del self.queries[0]
                else:
                    self.queries[0]["expected_image_ids"] = self.images[2]["image_id"]
                self.freeze()
                with self.assertRaises(ValueError):
                    demo.dataset_manifest(self.dataset)

    def test_path_escape_and_symlink_source_are_rejected(self):
        original = deepcopy(self.images)
        for relative in ("../outside.jpg", "/outside.jpg", "coco//image-0.jpg", "coco/./image-0.jpg", "coco\\image-0.jpg"):
            with self.subTest(relative=relative):
                self.images = deepcopy(original)
                self.images[0]["relative_path"] = relative
                self.freeze()
                with self.assertRaises(ValueError):
                    demo.dataset_manifest(self.dataset)
        self.images = original
        self.freeze()
        path = self.dataset / "images" / self.images[0]["relative_path"]
        external = self.root / "external.jpg"
        path.rename(external)
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            demo.prepare(self.dataset, self.output)

    def test_output_guard_protects_source_repository_and_unrelated_folders(self):
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        marker = unrelated / "keep.txt"
        marker.write_text("preserve")
        for output in (self.dataset, self.dataset / "child", self.root, demo.ROOT,
                       demo.ROOT / "ModelArtifacts/danger", demo.ROOT / "PromptImage/danger", unrelated):
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    demo.prepare(self.dataset, output)
        self.assertEqual(marker.read_text(), "preserve")
        link = self.root / "linked-output"
        link.symlink_to(unrelated, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            demo.prepare(self.dataset, link)

    def test_bundle_tampering_and_unexpected_files_are_rejected(self):
        manifest = demo.prepare(self.dataset, self.output)
        for mutation in ("model", "fingerprint", "query"):
            with self.subTest(mutation=mutation):
                changed = deepcopy(manifest)
                if mutation == "model":
                    changed["model_id"] = "other-model"
                elif mutation == "fingerprint":
                    changed["corpus_fingerprint"] = "0" * 64
                else:
                    changed["queries"][0]["text"] = "changed query"
                self.write_manifest(changed)
                with self.assertRaises(ValueError):
                    demo.verify_bundle(self.output, manifest)
        self.write_manifest(manifest)
        extra = self.output / "extra.bin"
        extra.write_bytes(b"not in manifest")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            demo.verify_bundle(self.output)
        extra.unlink()
        (self.output / manifest["images"][0]["relative_path"]).unlink()
        with self.assertRaisesRegex(ValueError, "Missing"):
            demo.verify_bundle(self.output)

    def test_failed_copy_and_publish_preserve_previous_bundle(self):
        previous = demo.prepare(self.dataset, self.output)
        with patch.object(demo.shutil, "copyfile", side_effect=OSError("copy interrupted")):
            with self.assertRaisesRegex(OSError, "copy interrupted"):
                demo.prepare(self.dataset, self.output)
        self.assertEqual(demo.verify_bundle(self.output), previous)
        original_rename = Path.rename

        def failed_publish(path, target):
            if path.name == "staging":
                raise OSError("publish interrupted")
            return original_rename(path, target)

        with patch.object(Path, "rename", failed_publish):
            with self.assertRaisesRegex(OSError, "publish interrupted"):
                demo.prepare(self.dataset, self.output)
        self.assertEqual(demo.verify_bundle(self.output), previous)
        self.assertFalse(any(path.name.startswith(".retrieval-demo-") for path in self.root.iterdir()))

    def test_mutation_during_copy_is_not_published(self):
        previous = demo.prepare(self.dataset, self.output)
        original_copy = demo.shutil.copyfile

        def mutate_after_copy(source, destination):
            result = original_copy(source, destination)
            self.queries[0]["query"] += " changed"
            self.freeze()
            return result

        with patch.object(demo.shutil, "copyfile", side_effect=mutate_after_copy):
            with self.assertRaisesRegex(ValueError, "changed during preparation"):
                demo.prepare(self.dataset, self.output)
        self.assertEqual(demo.verify_bundle(self.output), previous)

    def test_failed_rollback_preserves_recoverable_backup(self):
        previous = demo.prepare(self.dataset, self.output)
        original_rename = Path.rename

        def failed_publish_and_restore(path, target):
            if path.name in {"staging", "previous"}:
                raise OSError("filesystem unavailable")
            return original_rename(path, target)

        with patch.object(Path, "rename", failed_publish_and_restore):
            with self.assertRaisesRegex(OSError, "preserved at"):
                demo.prepare(self.dataset, self.output)
        backups = list(self.root.glob(".retrieval-demo-*/previous"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(demo.verify_bundle(backups[0]), previous)

    def test_size_limits_reject_oversized_metadata_and_image_files(self):
        with patch.object(demo, "MAX_METADATA_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "oversized"):
                demo.dataset_manifest(self.dataset)
        with patch.object(demo, "MAX_IMAGE_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "oversized"):
                demo.dataset_manifest(self.dataset)

    def test_scoring_keeps_failed_and_missing_queries_in_each_language_denominator(self):
        manifest = demo.dataset_manifest(self.dataset)
        report = self.report(manifest)
        score = demo.score_results(manifest, report)
        for language in ("ru", "en"):
            self.assertEqual(score["languages"][language]["queries"], 2)
            self.assertEqual(score["languages"][language]["success_at_1"], 0.5)
            self.assertEqual(score["languages"][language]["success_at_5"], 1)
            self.assertEqual(score["languages"][language]["mrr_at_10"], 0.75)
        report["cases"][0] = {"query_id": "q0-ru", "ranked_ids": [], "error": "Translation failed"}
        report["cases"] = [case for case in report["cases"] if case["query_id"] != "q1-en"]
        score = demo.score_results(manifest, report)
        self.assertEqual(score["languages"]["ru"]["failed_queries"], 1)
        self.assertEqual(score["languages"]["ru"]["success_at_5"], 0.5)
        self.assertEqual(score["languages"]["ru"]["mrr_at_10"], 0.25)
        self.assertEqual(score["languages"]["en"]["mrr_at_10"], 0.5)

    def test_scoring_rejects_unknown_duplicate_or_truncated_results_and_wrong_provenance(self):
        manifest = demo.dataset_manifest(self.dataset)
        for mutation in ("model", "corpus", "duplicate_query", "unknown_query", "duplicate_rank", "unknown_rank", "truncated", "ranking_limit"):
            with self.subTest(mutation=mutation):
                report = self.report(manifest)
                if mutation == "model":
                    report["model_id"] = "other-model"
                elif mutation == "corpus":
                    report["corpus_fingerprint"] = "0" * 64
                elif mutation == "duplicate_query":
                    report["cases"].append(report["cases"][0])
                elif mutation == "unknown_query":
                    report["cases"][0]["query_id"] = "unknown"
                elif mutation == "duplicate_rank":
                    report["cases"][0]["ranked_ids"].append(report["cases"][0]["ranked_ids"][0])
                elif mutation == "unknown_rank":
                    report["cases"][0]["ranked_ids"][0] = "unknown"
                elif mutation == "truncated":
                    report["cases"][0]["ranked_ids"].pop()
                else:
                    report["ranking_limit"] = 5
                with self.assertRaises(ValueError):
                    demo.score_results(manifest, report)

    def test_scoring_distinguishes_top_five_from_top_ten_and_missing_positive(self):
        manifest = demo.dataset_manifest(self.dataset)
        for index in range(3, 12):
            digest = hashlib.sha256(f"extra-{index}".encode()).hexdigest()
            manifest["images"].append({"id": "img_" + digest[:12], "relative_path": f"images/{index}.jpg", "sha256": digest})
        report = self.report(manifest)
        for case in report["cases"]:
            # q0's positive occurs at rank6; q1's occurs at rank12, outside top10.
            ids = case["ranked_ids"]
            ids[0], ids[5] = ids[5], ids[0]
            ids[1], ids[11] = ids[11], ids[1]
            case["ranked_ids"] = ids[:10]
        score = demo.score_results(manifest, report)
        for language in ("ru", "en"):
            result = score["languages"][language]
            self.assertEqual(result["success_at_1"], 0)
            self.assertEqual(result["success_at_5"], 0)
            self.assertAlmostEqual(result["mrr_at_10"], 1 / 12)
            self.assertEqual(result["failed_queries"], 0)


if __name__ == "__main__":
    unittest.main()
