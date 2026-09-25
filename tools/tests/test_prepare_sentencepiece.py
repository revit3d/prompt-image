from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "prepare_sentencepiece", Path(__file__).parents[1] / "prepare_sentencepiece.py"
)
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


class PrepareSentencePieceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "SentencePieceRuntime"
        self.config = self.root / "source.json"
        self.pin = {"runtime_id": "test-runtime", "source_commit": "pinned-commit"}
        self.config.write_text(json.dumps(self.pin))
        contexts = ExitStack()
        self.addCleanup(contexts.close)
        contexts.enter_context(patch.object(preparer, "CONFIG", self.config))
        contexts.enter_context(patch.object(preparer, "OUTPUT", self.output))
        contexts.enter_context(patch.object(preparer, "recipe_hash", return_value="test-recipe"))
        self.network = contexts.enter_context(patch.object(
            preparer.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")
        ))

    def write_bundle(self, directory, marker="original"):
        for name in preparer.REQUIRED_FILES:
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(marker)
        manifest = {
            "schema_version": 1, "runtime_id": self.pin["runtime_id"],
            "source": self.pin, "recipe_sha256": "test-recipe",
            "files": {name: preparer.sha256(directory / name) for name in preparer.REQUIRED_FILES},
        }
        self.save_manifest(directory, manifest)
        return manifest

    def save_manifest(self, directory, manifest):
        (directory / "runtime-manifest.json").write_text(json.dumps(manifest))

    def test_offline_reuse_checks_cached_bytes_without_network(self):
        archive = self.root / "source.tar.gz"
        archive.write_bytes(b"pinned archive")
        pin = {"url": "https://example.invalid/source", "sha256": hashlib.sha256(b"pinned archive").hexdigest()}
        preparer.fetch(pin, archive, offline=True)
        archive.write_bytes(b"modified archive")
        with self.assertRaisesRegex(ValueError, "checksum"):
            preparer.fetch(pin, archive, offline=True)
        with self.assertRaisesRegex(ValueError, "absent"):
            preparer.fetch(pin, self.root / "missing.tar.gz", offline=True)
        self.network.assert_not_called()

    def test_download_checksum_failure_removes_partial_file(self):
        self.network.side_effect = None
        self.network.return_value = io.BytesIO(b"incorrect bytes")
        destination = self.root / "archive.tar.gz"
        with self.assertRaisesRegex(ValueError, "checksum"):
            preparer.fetch({"url": "https://example.invalid/source", "sha256": "0" * 64}, destination, offline=False)
        self.assertFalse(destination.exists())
        self.assertFalse(destination.with_suffix(".download").exists())

    def test_extraction_rejects_traversal_absolute_paths_and_links(self):
        for kind in ("traversal", "absolute", "symlink", "hardlink"):
            with self.subTest(kind=kind):
                archive = self.root / f"{kind}.tar.gz"
                name = "sentencepiece-pinned-commit/safe"
                if kind == "traversal":
                    name = "sentencepiece-pinned-commit/../../escaped"
                elif kind == "absolute":
                    name = "/escaped"
                member = tarfile.TarInfo(name)
                if kind in ("symlink", "hardlink"):
                    member.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
                    member.linkname = "../../escaped"
                with tarfile.open(archive, "w:gz") as target:
                    target.addfile(member, io.BytesIO())
                with self.assertRaises(ValueError):
                    preparer.unpack(archive, self.root / kind, "pinned-commit")
                self.assertFalse((self.root / "escaped").exists())

    def test_verification_requires_schema_and_exact_source_provenance(self):
        manifest = self.write_bundle(self.output)
        preparer.verify(announce=False)
        for mutation in ("schema", "source", "recipe"):
            changed = dict(manifest)
            if mutation == "schema":
                changed["schema_version"] = 2
            elif mutation == "source":
                changed["source"] = {**self.pin, "source_commit": "different"}
            else:
                changed["recipe_sha256"] = "old-recipe"
            with self.subTest(mutation=mutation):
                self.save_manifest(self.output, changed)
                with self.assertRaises(ValueError):
                    preparer.verify(announce=False)

    def test_verification_rejects_empty_or_missing_required_inventory(self):
        manifest = self.write_bundle(self.output)
        manifest["files"] = {}
        self.save_manifest(self.output, manifest)
        with self.assertRaisesRegex(ValueError, "required"):
            preparer.verify(announce=False)
        manifest = self.write_bundle(self.output)
        license_name = "SentencePiece-LICENSE.txt"
        (self.output / license_name).unlink()
        del manifest["files"][license_name]
        self.save_manifest(self.output, manifest)
        with self.assertRaisesRegex(ValueError, "required"):
            preparer.verify(announce=False)

    def test_verification_detects_tampering_and_empty_required_files(self):
        self.write_bundle(self.output)
        license_path = self.output / "SentencePiece-LICENSE.txt"
        license_path.write_text("tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            preparer.verify(announce=False)
        license_path.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "nonempty"):
            preparer.verify(announce=False)

    def test_failed_publish_restores_the_previous_runtime(self):
        self.write_bundle(self.output, marker="original")
        package = self.root / "staged"
        self.write_bundle(package, marker="replacement")
        original_rename = Path.rename

        def fail_replacement(path, destination):
            if path == package:
                raise OSError("publish interrupted")
            return original_rename(path, destination)

        with patch.object(Path, "rename", fail_replacement):
            with self.assertRaisesRegex(OSError, "interrupted"):
                preparer.publish(package)
        self.assertEqual((self.output / "SentencePiece-LICENSE.txt").read_text(), "original")
        preparer.verify(announce=False)
        self.assertTrue(package.exists())
        self.assertEqual(list(self.root.glob(".SentencePieceRuntime.previous-*")), [])

    def test_failed_post_publish_validation_rolls_back(self):
        self.write_bundle(self.output, marker="original")
        package = self.root / "staged"
        self.write_bundle(package, marker="replacement")
        original_verify = preparer.verify

        def fail_after_publish(directory=None, announce=True):
            if directory is None:
                raise ValueError("published verification failed")
            return original_verify(directory, announce=announce)

        with patch.object(preparer, "verify", side_effect=fail_after_publish):
            with self.assertRaisesRegex(ValueError, "verification failed"):
                preparer.publish(package)
        self.assertEqual((self.output / "SentencePiece-LICENSE.txt").read_text(), "original")
        preparer.verify(announce=False)


if __name__ == "__main__":
    unittest.main()
