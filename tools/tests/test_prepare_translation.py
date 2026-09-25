from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "prepare_translation", Path(__file__).parents[1] / "prepare_translation.py"
)
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


class InterruptedResponse(io.BytesIO):
    def read(self, size=-1):
        if self.tell():
            raise OSError("connection interrupted")
        return super().read(size)


class PrepareTranslationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        self.root = Path(temporary.name)
        self.artifacts = self.root / "ModelArtifacts"
        self.artifacts.mkdir()
        self.lock = {"model_id": "test-translator", "source_commit": "pinned-revision", "license": "CC-BY-4.0"}
        self.config = self.root / "translation-source.json"
        self.save_config()
        for name, value in (("ROOT", self.root), ("CONFIG", self.config), ("ARTIFACTS", self.artifacts)):
            self.contexts.enter_context(patch.object(preparer, name, value))
        self.network = self.contexts.enter_context(patch.object(
            preparer.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")
        ))

    def save_config(self):
        preparer.write_json(self.config, self.lock)

    def download_spec(self, content):
        return {"url": "https://example.test/weights", "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}

    def write_bundle(self, directory, recipe="current-recipe"):
        # Small opaque weights exercise publication/integrity only, never inference.
        report = {"schema_version": 1, "model_id": self.lock["model_id"],
                  "source_commit": self.lock["source_commit"], "recipe_sha256": recipe,
                  "passed": True, "exact_greedy_sequences": 10}
        reference = {"schema_version": 1, "model_id": self.lock["model_id"], "cases": []}
        files = {
            "source.spm": "source tokenizer", "target.spm": "target tokenizer", "vocab.json": "{}",
            "Translation-LICENSE.txt": "test license", "Translation-ATTRIBUTION.txt": "test attribution",
            "translation-model-card.md": "test card", "tokenizer-golden.json": json.dumps(reference),
            "translation-reference.json": json.dumps(reference), "translation-smoke-report.json": json.dumps(report),
            "TranslationEncoder.mlpackage/Data/weights.bin": "encoder fixture",
            "TranslationDecoder.mlpackage/Data/weights.bin": "decoder fixture",
        }
        for name, content in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        manifest = {
            "schema_version": 1, "model_id": self.lock["model_id"], "recipe_sha256": recipe,
            "source": self.lock.copy(), "license": "CC-BY-4.0",
            "source_languages": ["ru"], "target_language": "en", "max_source_tokens": 64,
            "max_decoder_tokens": 64, "vocab_size": 62518, "hidden_size": 512,
            "eos_token_id": 0, "pad_token_id": 62517, "decoder_start_token_id": 62517,
            "files": preparer.file_inventory(directory),
        }
        preparer.write_json(directory / "translation-manifest.json", manifest)
        return manifest

    def prepare_environment(self):
        cache = self.artifacts / "TranslationDownloads"
        cache.mkdir()
        (cache / "pytorch_model.bin").write_bytes(b"opaque fixture; never deserialized")
        self.lock["files"] = {"pytorch_model.bin": self.download_spec((cache / "pytorch_model.bin").read_bytes())}
        self.save_config()
        self.contexts.enter_context(patch.object(preparer.platform, "system", return_value="Darwin"))
        self.contexts.enter_context(patch.object(preparer.platform, "machine", return_value="arm64"))
        self.contexts.enter_context(patch.object(preparer.sys, "version_info", (3, 11, 16)))
        self.contexts.enter_context(patch.object(preparer, "installed_versions", return_value={}))
        self.contexts.enter_context(patch.object(preparer, "recipe_sha256", return_value="current-recipe"))

    def rewrite_manifest(self, output, manifest):
        manifest["files"] = preparer.file_inventory(output)
        preparer.write_json(output / "translation-manifest.json", manifest)

    def test_unverified_download_is_never_published(self):
        for content in (b"x", b"wrong bytes"):
            with self.subTest(content=content):
                target = self.root / "Downloads" / "weights.bin"
                self.network.side_effect = None
                self.network.return_value = io.BytesIO(content)
                with self.assertRaisesRegex(ValueError, "Downloaded source checksum mismatch"):
                    preparer.fetch_verified(self.download_spec(b"right bytes"), target)
                self.assertFalse(target.exists())
                self.assertEqual(list(target.parent.iterdir()), [])

    def test_interrupted_download_cleans_partial_file(self):
        target = self.root / "Downloads" / "weights.bin"
        self.network.side_effect = None
        self.network.return_value = InterruptedResponse(b"partial")
        with self.assertRaisesRegex(OSError, "connection interrupted"):
            preparer.fetch_verified(self.download_spec(b"complete weights"), target)
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.iterdir()), [])

    def test_verified_cache_reuse_and_offline_failures_never_access_network(self):
        target = self.root / "weights.bin"
        target.write_bytes(b"verified weights")
        self.assertEqual(preparer.fetch_verified(self.download_spec(target.read_bytes()), target, offline=True), target)
        with self.assertRaisesRegex(ValueError, "Cached source checksum mismatch"):
            preparer.fetch_verified(self.download_spec(b"different weight"), target, offline=True)
        with self.assertRaisesRegex(ValueError, "Missing cached source"):
            preparer.fetch_verified(self.download_spec(b"missing"), self.root / "missing.bin", offline=True)
        self.network.assert_not_called()
        self.assertEqual(target.read_bytes(), b"verified weights")

    def test_file_mutations_are_rejected(self):
        for mutation in ("missing", "changed", "extra"):
            with self.subTest(mutation=mutation):
                output = self.root / mutation
                self.write_bundle(output)
                weights = output / "TranslationEncoder.mlpackage/Data/weights.bin"
                if mutation == "missing":
                    weights.unlink()
                elif mutation == "changed":
                    weights.write_bytes(b"changed")
                else:
                    (output / "extra.bin").write_bytes(b"unexpected")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    preparer.verify_bundle(output, "current-recipe")

    def test_stale_recipe_and_wrong_contract_are_rejected(self):
        output = self.root / "bundle"
        manifest = self.write_bundle(output)
        with self.assertRaisesRegex(ValueError, "recipe changed"):
            preparer.verify_bundle(output, "new-recipe")
        for key, value in (("target_language", "fr"), ("max_source_tokens", 128), ("decoder_start_token_id", 0)):
            with self.subTest(field=key):
                modified = {**manifest, key: value}
                preparer.write_json(output / "translation-manifest.json", modified)
                with self.assertRaisesRegex(ValueError, "Unsupported translation contract"):
                    preparer.verify_bundle(output, "current-recipe")

    def test_changed_source_provenance_is_rejected_without_inference(self):
        output = self.root / "bundle"
        manifest = self.write_bundle(output)
        manifest["source"] = {**self.lock, "source_commit": "unreviewed-revision"}
        preparer.write_json(output / "translation-manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "source provenance"):
            preparer.verify_bundle(output, "current-recipe")
        self.network.assert_not_called()

    def test_report_and_reference_provenance_rejected_even_with_matching_inventory(self):
        for name, key in (("translation-smoke-report.json", "source_commit"),
                          ("translation-smoke-report.json", "recipe_sha256"),
                          ("translation-reference.json", "model_id"),
                          ("tokenizer-golden.json", "model_id")):
            with self.subTest(file=name, field=key):
                output = self.root / (name + key)
                manifest = self.write_bundle(output)
                report = json.loads((output / name).read_text())
                report[key] = "wrong provenance"
                preparer.write_json(output / name, report)
                self.rewrite_manifest(output, manifest)
                with self.assertRaisesRegex(ValueError, "provenance mismatch"):
                    preparer.verify_bundle(output, "current-recipe")

    def test_incomplete_or_failed_conversion_cannot_pass_matching_checksums(self):
        for mutation in ("package", "report"):
            with self.subTest(mutation=mutation):
                output = self.root / mutation
                manifest = self.write_bundle(output)
                if mutation == "package":
                    (output / "TranslationDecoder.mlpackage/Data/weights.bin").unlink()
                else:
                    report = json.loads((output / "translation-smoke-report.json").read_text())
                    report["passed"] = False
                    preparer.write_json(output / "translation-smoke-report.json", report)
                self.rewrite_manifest(output, manifest)
                with self.assertRaises(ValueError):
                    preparer.verify_bundle(output, "current-recipe")

    def test_current_bundle_reuse_requires_neither_network_nor_conversion_dependencies(self):
        self.write_bundle(self.artifacts / "Translation")
        with patch.object(preparer, "recipe_sha256", return_value="current-recipe"):
            with patch.object(preparer, "installed_versions") as dependencies:
                with patch.object(preparer, "export_models") as exporter:
                    preparer.prepare(offline=True)
        dependencies.assert_not_called()
        exporter.assert_not_called()
        self.network.assert_not_called()

    def test_failed_rebuild_keeps_previous_bundle(self):
        self.prepare_environment()
        output = self.artifacts / "Translation"
        previous = self.write_bundle(output, recipe="previous-recipe")

        def failed_export(cache, staging, versions, lock):
            self.assertEqual(preparer.verify_bundle(output), previous)
            self.write_bundle(staging)
            (staging / "TranslationDecoder.mlpackage/Data/weights.bin").write_bytes(b"broken replacement")

        with patch.object(preparer, "export_models", side_effect=failed_export):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                preparer.prepare(offline=True, rebuild=True)
        self.assertEqual(preparer.verify_bundle(output), previous)
        self.assertEqual({path.name for path in self.artifacts.iterdir()}, {"Translation", "TranslationDownloads"})
        self.network.assert_not_called()


if __name__ == "__main__":
    unittest.main()
