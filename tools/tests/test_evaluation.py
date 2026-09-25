import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("evaluation", Path(__file__).parents[1] / "evaluation.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class EvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        evaluation.initialize(self.root)

    def fixture(self):
        # These bytes test metadata integrity, not image decoding or model quality.
        for index in range(400):
            (self.root / "images" / f"{index:03}.jpg").write_bytes(f"fixture-{index}".encode())
        images, _ = evaluation.image_inventory(self.root / "images")
        evaluation.write_csv(self.root / "images.csv", evaluation.IMAGE_FIELDS, images)
        queries = evaluation.query_template()
        for index, row in enumerate(queries):
            row["query"] = "тест" if row["language"] == "ru" else "test"
            row["expected_image_ids"] = images[index // 2]["image_id"]
        evaluation.write_csv(self.root / "queries.csv", evaluation.QUERY_FIELDS, queries)
        return images, queries

    def test_complete_benchmark_passes(self):
        self.fixture()
        report = evaluation.validate(self.root)
        self.assertEqual(report["errors"], [])
        self.assertEqual((report["images"], report["queries"], report["groups"]), (400, 80, 40))

    def test_init_preserves_labels(self):
        labels = self.root / "queries.csv"
        labels.write_text("my private labels", encoding="utf-8")
        evaluation.initialize(self.root)
        self.assertEqual(labels.read_text(), "my private labels")

    def test_duplicate_content_and_rename_keep_id(self):
        first = self.root / "images" / "a.jpg"
        first.write_bytes(b"same content")
        original, _ = evaluation.image_inventory(self.root / "images")
        first.rename(self.root / "images" / "b.jpg")
        (self.root / "images" / "c.jpg").write_bytes(b"same content")
        current, duplicates = evaluation.image_inventory(self.root / "images")
        self.assertEqual(duplicates, 1)
        self.assertEqual(original[0]["image_id"], current[0]["image_id"])

    def test_tampered_image_rejected(self):
        images, _ = self.fixture()
        (self.root / "images" / images[0]["relative_path"]).write_bytes(b"changed")
        self.assertTrue(any("integrity" in error for error in evaluation.validate(self.root)["errors"]))

    def test_path_traversal_rejected(self):
        images, _ = self.fixture()
        images[0]["relative_path"] = "../outside.jpg"
        evaluation.write_csv(self.root / "images.csv", evaluation.IMAGE_FIELDS, images)
        self.assertTrue(any("Unsafe" in error for error in evaluation.validate(self.root)["errors"]))

    def test_symlink_not_indexed_or_accepted(self):
        images, _ = self.fixture()
        victim = self.root / "images" / images[0]["relative_path"]
        original = victim.read_bytes()
        victim.unlink()
        outside = self.root / "outside.jpg"
        outside.write_bytes(original)
        victim.symlink_to(outside)
        self.assertEqual(len(evaluation.image_inventory(self.root / "images")[0]), 399)
        self.assertTrue(any("Symlink" in error for error in evaluation.validate(self.root)["errors"]))

    def test_unknown_and_leaking_labels_rejected(self):
        images, queries = self.fixture()
        queries[28]["expected_image_ids"] = images[0]["image_id"]
        queries[29]["expected_image_ids"] = images[0]["image_id"]
        queries[0]["expected_image_ids"] += "|img_unknown"
        evaluation.write_csv(self.root / "queries.csv", evaluation.QUERY_FIELDS, queries)
        errors = evaluation.validate(self.root)["errors"]
        self.assertTrue(any("Unknown" in error for error in errors))
        self.assertTrue(any("reused" in error for error in errors))

    def test_incomplete_template_rejected(self):
        errors = evaluation.validate(self.root)["errors"]
        self.assertTrue(any("300–500" in error for error in errors))
        self.assertTrue(any("Missing query" in error for error in errors))

    def test_freeze_exports_separate_splits_and_fingerprints_labels(self):
        self.fixture()
        snapshot = evaluation.freeze(self.root)
        development = evaluation.read_csv(self.root / "queries.development.csv", evaluation.QUERY_FIELDS)
        holdout = evaluation.read_csv(self.root / "queries.holdout.csv", evaluation.QUERY_FIELDS)
        self.assertEqual((len(development), len(holdout)), (56, 24))
        self.assertEqual({row["split"] for row in holdout}, {"holdout"})
        self.assertEqual(snapshot["file_sha256"]["queries.csv"], evaluation.sha256(self.root / "queries.csv"))

    def test_freeze_refuses_unlabeled_data(self):
        with self.assertRaisesRegex(ValueError, "invalid benchmark"):
            evaluation.freeze(self.root)
        self.assertFalse((self.root / "benchmark.json").exists())


if __name__ == "__main__":
    unittest.main()
