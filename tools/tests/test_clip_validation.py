from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


with patch.object(sys, "path", [str(Path(__file__).parents[1]), *sys.path]):
    spec = importlib.util.spec_from_file_location(
        "prepare_clip_validation", Path(__file__).parents[1] / "prepare_clip_validation.py"
    )
    validation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validation)


class CLIPValidationIntegrityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.artifacts = self.root / "ModelArtifacts"
        self.artifacts.mkdir()
        self.config = self.root / "clip-source.json"
        self.lock = {"model_id": "test-model", "source_commit": "pinned-source"}
        self.config.write_text(json.dumps(self.lock))
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.contexts.enter_context(patch.object(validation, "ARTIFACTS", self.artifacts))
        self.contexts.enter_context(patch.object(validation.preparation, "CONFIG", self.config))
        self.contexts.enter_context(patch.object(validation, "recipe_sha256", return_value="current-recipe"))
        self.network = self.contexts.enter_context(patch.object(
            validation.preparation.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")
        ))

    def bundle(self, directory=None, recipe="current-recipe"):
        directory = directory or self.artifacts / "CLIPValidation"
        directory.mkdir(parents=True)
        for name, size in (("image.png", 8), ("tensor.bin", 3 * 224 * 224 * 4),
                           ("raw.bin", 512 * 4), ("normalized.bin", 512 * 4)):
            (directory / name).write_bytes(bytes(size))
        embeddings = {"raw_embedding_file": "raw.bin", "embedding_file": "normalized.bin"}
        manifest = {
            "schema_version": 1, "model_id": self.lock["model_id"], "source": self.lock,
            "recipe_sha256": recipe,
            "images": [{"name": "image", "image_file": "image.png", "tensor_file": "tensor.bin",
                        "exif_orientation": 1, **embeddings}],
            "texts": [{"name": "text", "text": "", "tokens": [49406, 49407] + [0] * 75, **embeddings}],
            "input_sources": [],
        }
        self.save(directory, manifest)
        return directory, manifest

    def save(self, directory, manifest):
        manifest["files"] = validation.file_inventory(directory)
        validation.preparation.write_json(directory / validation.MANIFEST, manifest)

    def test_verified_reference_bundle_needs_no_ml_dependencies_or_network(self):
        directory, manifest = self.bundle()
        self.assertEqual(validation.verify_bundle(directory, "current-recipe"), manifest)
        self.network.assert_not_called()

    def test_missing_modified_and_extra_files_fail_inventory_check(self):
        for mutation in ("missing", "modified", "extra", "nested-manifest"):
            with self.subTest(mutation=mutation):
                directory, _ = self.bundle(self.artifacts / mutation)
                if mutation == "missing":
                    (directory / "raw.bin").unlink()
                elif mutation == "modified":
                    (directory / "raw.bin").write_bytes(b"changed")
                elif mutation == "extra":
                    (directory / "extra.bin").write_bytes(b"unexpected")
                else:
                    (directory / "nested").mkdir()
                    (directory / "nested" / validation.MANIFEST).write_text("{}")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    validation.verify_bundle(directory)

    def test_wrong_tensor_size_rejected_even_if_checksums_updated(self):
        for name in ("tensor.bin", "raw.bin", "normalized.bin"):
            with self.subTest(name=name):
                directory, manifest = self.bundle(self.artifacts / name)
                (directory / name).write_bytes(b"short")
                self.save(directory, manifest)
                with self.assertRaisesRegex(ValueError, "tensor size"):
                    validation.verify_bundle(directory)

    def test_model_identity_and_source_pin_must_match(self):
        for field, value in (("schema_version", 2), ("model_id", "other-model"), ("source", {})):
            with self.subTest(field=field):
                directory, manifest = self.bundle(self.artifacts / field)
                manifest[field] = value
                self.save(directory, manifest)
                with self.assertRaisesRegex(ValueError, "mismatched model source"):
                    validation.verify_bundle(directory)

    def test_reference_case_cannot_escape_bundle(self):
        directory, manifest = self.bundle()
        manifest["images"][0]["tensor_file"] = "../outside.bin"
        self.save(directory, manifest)
        with self.assertRaisesRegex(ValueError, "unsafe file"):
            validation.verify_bundle(directory)

    def test_incomplete_cases_and_invalid_token_contract_are_rejected(self):
        for mutation in ("empty-images", "empty-texts", "duplicates", "orientation", "tokens", "float-tokens", "eot"):
            with self.subTest(mutation=mutation):
                directory, manifest = self.bundle(self.artifacts / mutation)
                if mutation == "empty-images":
                    manifest["images"] = []
                elif mutation == "empty-texts":
                    manifest["texts"] = []
                elif mutation == "duplicates":
                    manifest["texts"][0]["name"] = "image"
                elif mutation == "orientation":
                    manifest["images"][0]["exif_orientation"] = 9
                elif mutation == "tokens":
                    manifest["texts"][0]["tokens"].pop()
                elif mutation == "float-tokens":
                    manifest["texts"][0]["tokens"][2] = 1.5
                else:
                    manifest["texts"][0]["tokens"][1] = 1
                self.save(directory, manifest)
                with self.assertRaises(ValueError):
                    validation.verify_bundle(directory)

    def test_matching_bundle_reuse_does_not_import_or_run_ml(self):
        self.bundle()
        with patch.object(validation.preparation, "installed_versions") as versions:
            with patch.object(validation, "generate") as generator:
                validation.prepare(offline=True)
        versions.assert_not_called()
        generator.assert_not_called()
        self.network.assert_not_called()

    def test_recipe_change_requires_explicit_rebuild_and_keeps_old_bundle(self):
        directory, manifest = self.bundle(recipe="old-recipe")
        with self.assertRaisesRegex(ValueError, "recipe changed"):
            validation.prepare(offline=True)
        self.assertEqual(validation.verify_bundle(directory), manifest)

    def test_explicit_photos_cannot_enter_test_bundle_or_outside_artifacts(self):
        with self.assertRaisesRegex(ValueError, "separate --output"):
            validation.prepare(photos=[self.root / "photo.jpg"])
        for directory in (self.artifacts / "CLIPValidation" / "private",
                          self.artifacts / "CLIPValidation" / "nested" / "private"):
            with self.subTest(directory=directory):
                with self.assertRaisesRegex(ValueError, "separate --output"):
                    validation.prepare(photos=[self.root / "photo.jpg"], output=directory, rebuild=True)
        for directory in (self.root, self.artifacts):
            with self.subTest(directory=directory):
                with self.assertRaisesRegex(ValueError, "subdirectory of ignored ModelArtifacts"):
                    validation.prepare(output=directory)

    def test_reserved_artifact_directories_cannot_be_replaced_or_modified(self):
        for reserved in ("CLIP", "Downloads", ".venv"):
            for suffix in ("", "nested/fixtures"):
                directory = self.artifacts / reserved / suffix
                with self.subTest(directory=directory):
                    with self.assertRaisesRegex(ValueError, "reserved"):
                        validation.prepare(output=directory, offline=True, rebuild=True)
                    self.assertFalse(directory.exists())
        self.network.assert_not_called()

    def test_symlinks_cannot_bypass_photo_bundle_or_reserved_directory_checks(self):
        for destination in ("CLIPValidation", "CLIP", "Downloads", ".venv"):
            actual = self.artifacts / destination
            actual.mkdir()
            alias = self.artifacts / f"alias-{destination}"
            alias.symlink_to(actual, target_is_directory=True)
            with self.subTest(destination=destination):
                with self.assertRaisesRegex(ValueError, "separate --output|reserved"):
                    validation.prepare(output=alias / "nested", photos=[self.root / "photo.jpg"], rebuild=True)
                self.assertEqual(list(actual.iterdir()), [])

    def test_case_variants_cannot_bypass_output_boundaries_on_macos(self):
        for name in ("clipvalidation", "clip", "downloads", ".VENV"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "separate --output|reserved"):
                    validation.prepare(output=self.artifacts / name / "nested",
                                       photos=[self.root / "photo.jpg"], rebuild=True)

    def test_different_photo_inputs_are_not_silently_reused(self):
        directory, manifest = self.bundle(self.artifacts / "PhotoValidation")
        manifest["input_sources"] = [{"name": "photo-1", "source_filename": "old.jpg", "sha256": "old"}]
        self.save(directory, manifest)
        with self.assertRaisesRegex(ValueError, "photo inputs changed"):
            validation.prepare(offline=True, output=directory)

    def test_failed_rebuild_preserves_old_bundle(self):
        directory, previous = self.bundle(recipe="old-recipe")
        lock = {**self.lock, "source_archive": {}, "checkpoint": {}}
        self.config.write_text(json.dumps(lock))
        previous["source"] = lock
        self.save(directory, previous)
        with ExitStack() as stack:
            stack.enter_context(patch.object(validation.preparation, "installed_versions", return_value={}))
            stack.enter_context(patch.object(validation.preparation, "fetch_verified", return_value=self.root / "unused"))
            stack.enter_context(patch.object(validation.preparation, "unpack_source"))
            stack.enter_context(patch.object(validation, "generate", side_effect=ValueError("reference generation failed")))
            with self.assertRaisesRegex(ValueError, "reference generation failed"):
                validation.prepare(offline=True, rebuild=True)
        self.assertEqual(validation.verify_bundle(directory), previous)
        self.assertEqual([entry.name for entry in self.artifacts.iterdir()], ["CLIPValidation"])


if __name__ == "__main__":
    unittest.main()
