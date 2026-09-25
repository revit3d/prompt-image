from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location(
    "prepare_clip", Path(__file__).parents[1] / "prepare_clip.py"
)
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


class InterruptedResponse(io.BytesIO):
    def read(self, size=-1):
        if self.tell():
            raise OSError("connection interrupted")
        return super().read(size)


class PrepareCLIPTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.root = Path(temporary.name)
        self.artifacts = self.root / "ModelArtifacts"
        self.artifacts.mkdir()
        self.lock = {
            "model_id": "test-clip-model",
            "source_commit": "test-commit",
        }
        self.config = self.root / "clip-source.json"
        self.save_config()
        for name, value in (("CONFIG", self.config), ("ARTIFACTS", self.artifacts)):
            self.contexts.enter_context(patch.object(preparer, name, value))
        self.network = self.contexts.enter_context(patch.object(
            preparer.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")
        ))

    def save_config(self):
        self.config.write_text(json.dumps(self.lock), encoding="utf-8")

    def download_spec(self, content):
        return {
            "url": "https://example.test/model",
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    def write_source_archive(self, path, extra=None):
        with zipfile.ZipFile(path, "w") as archive:
            for name in preparer.SOURCE_FILES:
                archive.writestr(f"CLIP-{self.lock['source_commit']}/{name}", name.encode())
            for name, content in (extra or {}).items():
                archive.writestr(name, content)

    def write_bundle(self, directory, recipe="current-recipe", marker="original"):
        # Tiny opaque package stand-ins exercise integrity, not Core ML behavior.
        files = {
            "tokenizer.json": json.dumps({"fixture": marker}),
            "LICENSE.txt": "Test license",
            "model-card.md": "Test model card",
            "smoke-report.json": json.dumps({"passed": True}),
            "CLIPImageEncoder.mlpackage/Data/weights.bin": "image fixture",
            "CLIPTextEncoder.mlpackage/Data/weights.bin": "text fixture",
        }
        for name, content in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        manifest = {
            "schema_version": 1,
            "model_id": self.lock["model_id"],
            "recipe_sha256": recipe,
            "files": preparer.file_inventory(directory),
        }
        preparer.write_json(directory / "model-manifest.json", manifest)
        return manifest

    def prepare_environment(self):
        cache = self.artifacts / "Downloads"
        cache.mkdir()
        archive = cache / "CLIP-source.zip"
        self.write_source_archive(archive)
        checkpoint = cache / "ViT-B-32.pt"
        checkpoint.write_bytes(b"test checkpoint; never deserialized")
        self.lock.update({
            "source_archive": self.download_spec(archive.read_bytes()),
            "checkpoint": self.download_spec(checkpoint.read_bytes()),
        })
        self.save_config()
        self.contexts.enter_context(patch.object(preparer.platform, "system", return_value="Darwin"))
        self.contexts.enter_context(patch.object(preparer.platform, "machine", return_value="arm64"))
        self.contexts.enter_context(patch.object(preparer.sys, "version_info", (3, 11, 16)))
        self.contexts.enter_context(patch.object(preparer, "installed_versions", return_value={}))
        self.contexts.enter_context(patch.object(preparer, "recipe_sha256", return_value="current-recipe"))

    def test_download_checksum_failure_never_publishes_or_keeps_partial_file(self):
        destination = self.root / "Downloads" / "checkpoint.pt"
        self.network.side_effect = None
        self.network.return_value = io.BytesIO(b"incorrect bytes")
        with self.assertRaisesRegex(ValueError, "Download checksum mismatch"):
            preparer.fetch_verified(self.download_spec(b"expected bytes"), destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(destination.parent.iterdir()), [])

    def test_interrupted_download_cleans_partial_file(self):
        destination = self.root / "Downloads" / "checkpoint.pt"
        self.network.side_effect = None
        self.network.return_value = InterruptedResponse(b"partial contents")
        with self.assertRaisesRegex(OSError, "connection interrupted"):
            preparer.fetch_verified(self.download_spec(b"complete contents"), destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(destination.parent.iterdir()), [])

    def test_successful_download_publishes_verified_bytes_and_reuses_offline(self):
        destination = self.root / "checkpoint.pt"
        content = b"verified checkpoint"
        self.network.side_effect = None
        self.network.return_value = io.BytesIO(content)
        self.assertEqual(preparer.fetch_verified(self.download_spec(content), destination), destination)
        self.assertEqual(destination.read_bytes(), content)
        self.network.reset_mock()
        self.network.side_effect = AssertionError("Offline cache reuse attempted network access")
        self.assertEqual(preparer.fetch_verified(self.download_spec(content), destination, offline=True), destination)
        self.network.assert_not_called()

    def test_modified_cached_file_is_rejected_and_preserved(self):
        destination = self.root / "checkpoint.pt"
        destination.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            preparer.fetch_verified(self.download_spec(b"original"), destination, offline=True)
        self.network.assert_not_called()
        self.assertEqual(destination.read_bytes(), b"modified")

    def test_missing_offline_download_does_not_access_network(self):
        destination = self.root / "absent" / "checkpoint.pt"
        with self.assertRaisesRegex(ValueError, "Missing cached download"):
            preparer.fetch_verified(self.download_spec(b"original"), destination, offline=True)
        self.network.assert_not_called()
        self.assertFalse(destination.parent.exists())

    def test_bundle_verification_rejects_missing_modified_and_unexpected_files(self):
        for mutation in ("missing", "modified", "unexpected", "nested_manifest"):
            with self.subTest(mutation=mutation):
                output = self.root / mutation
                self.write_bundle(output)
                path = output / "CLIPImageEncoder.mlpackage/Data/weights.bin"
                if mutation == "missing":
                    path.unlink()
                elif mutation == "modified":
                    path.write_bytes(b"changed weights")
                elif mutation == "unexpected":
                    (output / "unexpected.bin").write_bytes(b"unexpected file")
                else:
                    (output / "CLIPImageEncoder.mlpackage/model-manifest.json").write_text("{}")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    preparer.verify_bundle(output, "current-recipe")

    def test_incomplete_bundle_is_rejected_even_with_matching_inventory(self):
        output = self.root / "bundle"
        manifest = self.write_bundle(output)
        for name in tuple(manifest["files"]):
            if name.startswith("CLIPTextEncoder.mlpackage/"):
                (output / name).unlink()
        manifest["files"] = preparer.file_inventory(output)
        preparer.write_json(output / "model-manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            preparer.verify_bundle(output, "current-recipe")

    def test_current_manifest_with_failed_smoke_check_is_rejected(self):
        output = self.root / "bundle"
        manifest = self.write_bundle(output)
        preparer.write_json(output / "smoke-report.json", {"passed": False})
        manifest["files"] = preparer.file_inventory(output)
        preparer.write_json(output / "model-manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "did not pass"):
            preparer.verify_bundle(output, "current-recipe")

    def test_stale_recipe_requires_explicit_rebuild(self):
        output = self.artifacts / "CLIP"
        self.write_bundle(output, recipe="older-recipe")
        with patch.object(preparer, "recipe_sha256", return_value="current-recipe"):
            with patch.object(preparer, "export_models") as exporter:
                with self.assertRaisesRegex(ValueError, "recipe changed"):
                    preparer.prepare(offline=True)
        exporter.assert_not_called()
        self.network.assert_not_called()
        self.assertEqual(preparer.verify_bundle(output)["recipe_sha256"], "older-recipe")

    def test_current_bundle_reuse_needs_neither_dependencies_nor_network(self):
        output = self.artifacts / "CLIP"
        self.write_bundle(output)
        with patch.object(preparer, "recipe_sha256", return_value="current-recipe"):
            with patch.object(preparer, "installed_versions") as dependencies:
                with patch.object(preparer, "export_models") as exporter:
                    preparer.prepare(offline=True)
        dependencies.assert_not_called()
        exporter.assert_not_called()
        self.network.assert_not_called()

    def test_source_extraction_only_copies_exact_allowlisted_members(self):
        archive = self.root / "source.zip"
        self.write_source_archive(archive, {
            "../../escaped.txt": b"outside destination",
            f"CLIP-{self.lock['source_commit']}/clip/../../escaped.txt": b"traversal",
            f"CLIP-{self.lock['source_commit']}/setup.py": b"unneeded executable",
            "/absolute.txt": b"absolute path",
        })
        output = self.root / "extracted"
        preparer.unpack_source(archive, output, self.lock["source_commit"])
        extracted = {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()}
        self.assertEqual(extracted, set(preparer.SOURCE_FILES))
        for name in preparer.SOURCE_FILES:
            self.assertEqual((output / name).read_bytes(), name.encode())
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_conversion_failure_never_publishes_partial_bundle(self):
        self.prepare_environment()
        output = self.artifacts / "CLIP"

        def fail_export(source, checkpoint, staging, versions, lock):
            (staging / "partial-model").write_bytes(b"partial")
            raise ValueError("conversion failed")

        with patch.object(preparer, "export_models", side_effect=fail_export):
            with self.assertRaisesRegex(ValueError, "conversion failed"):
                preparer.prepare(offline=True)
        self.assertFalse(output.exists())
        self.assertEqual({path.name for path in self.artifacts.iterdir()}, {"Downloads"})
        self.network.assert_not_called()

    def test_failed_rebuild_preserves_previous_verified_bundle(self):
        self.prepare_environment()
        output = self.artifacts / "CLIP"
        previous = self.write_bundle(output, recipe="older-recipe")

        def invalid_export(source, checkpoint, staging, versions, lock):
            self.assertEqual(preparer.verify_bundle(output), previous)
            self.write_bundle(staging, marker="replacement")
            (staging / "CLIPTextEncoder.mlpackage/Data/weights.bin").write_bytes(b"tampered")

        with patch.object(preparer, "export_models", side_effect=invalid_export):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                preparer.prepare(offline=True, rebuild=True)
        self.assertEqual(preparer.verify_bundle(output), previous)
        self.assertEqual({path.name for path in self.artifacts.iterdir()}, {"Downloads", "CLIP"})
        self.network.assert_not_called()

    def test_rebuild_publishes_only_after_replacement_passes_validation(self):
        self.prepare_environment()
        output = self.artifacts / "CLIP"
        previous = self.write_bundle(output, recipe="older-recipe")

        def successful_export(source, checkpoint, staging, versions, lock):
            self.assertEqual(preparer.verify_bundle(output), previous)
            self.write_bundle(staging, marker="replacement")

        with patch.object(preparer, "export_models", side_effect=successful_export):
            preparer.prepare(offline=True, rebuild=True)
        preparer.verify_bundle(output, "current-recipe")
        self.assertEqual(json.loads((output / "tokenizer.json").read_text()), {"fixture": "replacement"})
        self.assertEqual({path.name for path in self.artifacts.iterdir()}, {"Downloads", "CLIP"})
        self.network.assert_not_called()


if __name__ == "__main__":
    unittest.main()
