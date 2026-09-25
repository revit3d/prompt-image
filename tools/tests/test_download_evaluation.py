import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "download_evaluation", Path(__file__).parents[1] / "download_evaluation.py"
)
downloader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(downloader)


class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class DownloaderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def metadata(self):
        # Public metadata shapes only; these are not real images or benchmark labels.
        coco = {
            "licenses": [
                {"id": 4, "name": "Attribution", "url": "http://creativecommons.org/licenses/by/2.0/"},
                {"id": 1, "name": "Noncommercial", "url": "http://creativecommons.org/licenses/by-nc-sa/2.0/"},
            ],
            "images": [
                {"id": index, "file_name": f"{index:012}.jpg", "license": 4 if index < 330 else 1}
                for index in range(400)
            ],
            "annotations": [],
        }
        textvqa = {
            "data": [
                {
                    "question_id": index,
                    "image_id": f"{index:016x}",
                    "question": "What word appears on the sign?",
                    "answers": [f"word{index}"] * 10,
                }
                for index in range(90)
            ]
        }
        return coco, textvqa

    def test_selection_reproducible_when_metadata_order_changes_and_excludes_nc(self):
        coco, textvqa = self.metadata()
        initial = downloader.choose_images(coco, textvqa)
        coco["images"].reverse()
        textvqa["data"].reverse()
        repeated = downloader.choose_images(coco, textvqa)
        self.assertEqual(initial, repeated)
        self.assertEqual(len(initial), 400)
        selected_coco = [row for row in initial if row["dataset"] == "coco2017_val"]
        self.assertEqual(len(selected_coco), 320)
        self.assertTrue(all(int(row["source_image_id"]) < 330 for row in selected_coco))
        self.assertEqual(len({row["relative_path"] for row in initial}), 400)

    def test_remote_metadata_cannot_escape_image_directory(self):
        for unsafe_name in ("../outside.jpg", "/tmp/outside.jpg", "nested/image.jpg", "000000000000.jpg?x=1"):
            with self.subTest(filename=unsafe_name):
                coco, textvqa = self.metadata()
                for image in coco["images"]:
                    image["file_name"] = unsafe_name
                with self.assertRaisesRegex(ValueError, "filename"):
                    downloader.choose_images(coco, textvqa)
        coco, textvqa = self.metadata()
        textvqa["data"][0]["image_id"] = "../../outside"
        with self.assertRaisesRegex(ValueError, "identifier"):
            downloader.choose_images(coco, textvqa)

    def test_insufficient_licensed_sample_fails_instead_of_relaxing_filter(self):
        coco, textvqa = self.metadata()
        coco["images"] = coco["images"][:319]
        with self.assertRaisesRegex(ValueError, "Fewer than 320"):
            downloader.choose_images(coco, textvqa)

    def test_modified_cached_file_is_preserved_and_rejected(self):
        path = self.root / "cached.jpg"
        path.write_bytes(b"modified")
        expected = hashlib.sha256(b"original").hexdigest()
        with patch.object(downloader, "request") as network:
            with self.assertRaisesRegex(ValueError, "Cached file changed"):
                downloader.download("https://example.test/image.jpg", path, 100, expected)
        network.assert_not_called()
        self.assertEqual(path.read_bytes(), b"modified")

    def test_cached_symlink_is_not_followed(self):
        original = self.root / "original.jpg"
        original.write_bytes(b"content")
        link = self.root / "linked.jpg"
        link.symlink_to(original)
        with patch.object(downloader, "request") as network:
            with self.assertRaisesRegex(ValueError, "regular cached file"):
                downloader.download("https://example.test/image.jpg", link, 100)
        network.assert_not_called()
        self.assertEqual(original.read_bytes(), b"content")

    def test_response_without_content_length_cannot_exceed_download_limit(self):
        destination = self.root / "large.jpg"
        with patch.object(downloader, "request", return_value=Response(b"too much data")):
            with self.assertRaisesRegex(ValueError, "exceeds"):
                downloader.download("https://example.test/large.jpg", destination, 5)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_truncated_range_response_is_rejected(self):
        responses = [
            Response(b"x", 206, {"Content-Range": "bytes 0-0/100"}),
            Response(b"short", 206, {"Content-Range": "bytes 0-9/100"}),
        ]
        with patch.object(downloader, "request", side_effect=responses):
            remote = downloader.RemoteZip("https://example.test/archive.zip")
            with self.assertRaisesRegex(ValueError, "Truncated"):
                remote.read(10)

    def test_range_ignored_by_server_does_not_trigger_full_download(self):
        with patch.object(downloader, "request", return_value=Response(b"whole archive", 200)):
            with self.assertRaises(downloader.RangeUnavailable):
                downloader.RemoteZip("https://example.test/archive.zip")

    def test_two_byte_file_produces_a_clear_image_error(self):
        path = self.root / "images" / "coco" / "000000000000.jpg"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"\xff\xd8")
        choice = {"relative_path": "coco/000000000000.jpg", "download_url": "https://example.test/image.jpg"}
        with self.assertRaisesRegex(ValueError, "too small"):
            downloader.fetch_image(self.root, choice, {})


if __name__ == "__main__":
    unittest.main()
