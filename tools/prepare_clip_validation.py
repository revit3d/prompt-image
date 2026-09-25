#!/usr/bin/env python3
"""Generate independent CLIP golden fixtures from synthetic images, never private photos."""

import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile

import prepare_clip as preparation


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "ModelArtifacts"
MANIFEST = "validation-manifest.json"
TEXT_CASES = [
    ("empty", ""),
    ("cat", "a photo of a cat"),
    ("car", "a red car beside a tree"),
    ("recipe", "Recipe: eggs, milk &amp; flour!"),
    ("unicode", "a cafe\u0301 by the sea — summer ☀️"),
    ("truncated", "a photo " * 100),
    ("quotes", "‘Quoted’ “summer photos” — isn't it beautiful?"),
    ("russian", "Красная машина рядом с деревом. Рецепт блинов"),
    ("html", "Fish &amp;amp; chips &quot;today&quot; &#x1F41F;"),
    ("whitespace", "  CAFÉ\t\nbeach\u00a0sunset\u2003vacation  "),
    ("width-ligatures", "ＦＵＬＬＷＩＤＴＨ ﬁsh ﬂour ﬃ ﬄ ﬅ ﬆ"),
    ("contractions-entities", "We've 2 cats, 3.5 dogs &copy; &eacute; &NotEqualTilde;"),
]


def recipe_sha256():
    digest = hashlib.sha256()
    for path in (Path(__file__), Path(preparation.__file__), preparation.CONFIG, preparation.REQUIREMENTS):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def file_inventory(directory):
    return {
        path.relative_to(directory).as_posix(): preparation.sha256(path)
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path != directory / MANIFEST
    }


def verify_bundle(directory, expected_recipe=None):
    """Verify bytes, provenance, and referenced vector sizes without ML dependencies."""
    directory = Path(directory)
    manifest = json.loads((directory / MANIFEST).read_text())
    lock = json.loads(preparation.CONFIG.read_text())
    if (manifest.get("schema_version") != 1 or manifest.get("model_id") != lock["model_id"]
            or manifest.get("source") != lock):
        raise ValueError("Unsupported validation manifest or mismatched model source")
    if expected_recipe is not None and manifest.get("recipe_sha256") != expected_recipe:
        raise ValueError("Validation recipe changed; run prepare --rebuild")
    if manifest.get("files") != file_inventory(directory):
        raise ValueError("Validation fixture checksum mismatch; run prepare --rebuild")
    files = manifest["files"]

    def require_file(name, byte_count=None):
        if not isinstance(name, str) or name not in files or Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Validation manifest references an absent or unsafe file")
        if byte_count is not None and (directory / name).stat().st_size != byte_count:
            raise ValueError(f"Wrong validation tensor size: {name}")

    images, texts = manifest.get("images", []), manifest.get("texts", [])
    if not images or not texts:
        raise ValueError("Validation fixture bundle is incomplete")
    names = [case.get("name") for case in images + texts]
    if not all(isinstance(name, str) and name for name in names) or len(set(names)) != len(names):
        raise ValueError("Validation case names must be nonempty and unique")
    for case in images:
        require_file(case.get("image_file"))
        require_file(case.get("tensor_file"), 3 * 224 * 224 * 4)
        if case.get("exif_orientation") not in range(1, 9):
            raise ValueError("Invalid fixture orientation")
    for case in texts:
        tokens = case.get("tokens", [])
        if (len(tokens) != 77 or any(type(token) is not int or not 0 <= token <= 49407 for token in tokens)
                or tokens[0] != 49406 or 49407 not in tokens):
            raise ValueError("Invalid validation token sequence")
    for case in images + texts:
        require_file(case.get("raw_embedding_file"), 512 * 4)
        require_file(case.get("embedding_file"), 512 * 4)
    return manifest


def make_images(directory):
    """Integer-valued asymmetric patterns reveal crop, interpolation, channel, and rotation errors."""
    import numpy as np
    from PIL import Image

    directory.mkdir(parents=True, exist_ok=True)

    def rgb(width, height):
        y, x = np.indices((height, width))
        pixels = np.stack(((x * 255 // max(1, width - 1)),
                           (y * 255 // max(1, height - 1)),
                           ((x // 13 + y // 19) % 2) * 255), axis=2).astype(np.uint8)
        pixels[height // 9:height // 3, width // 8:width // 2] = [239, 31, 81]
        pixels[height * 2 // 3:height * 8 // 9, width * 3 // 4:] = [7, 199, 53]
        return pixels

    cases = []
    for name, width, height in (("landscape", 321, 241), ("portrait", 241, 321),
                                ("upscale", 109, 157), ("large", 1031, 777),
                                ("extreme-aspect", 4096, 32)):
        path = directory / f"{name}.png"
        Image.fromarray(rgb(width, height)).save(path)
        cases.append((name, path, 1))
    path = directory / "high-resolution.jpg"
    Image.fromarray(rgb(4032, 3024)).save(path, quality=95, subsampling=0)
    cases.append(("high-resolution", path, 1))
    width, height = 319, 243
    y, x = np.indices((height, width))
    alpha = ((x + 3 * y) % 256).astype(np.uint8)
    alpha[:height // 3, :width // 3] = 0
    rgba = np.concatenate((rgb(width, height), alpha[:, :, None]), axis=2)
    path = directory / "alpha.png"
    Image.fromarray(rgba).save(path)
    cases.append(("alpha", path, 1))
    path = directory / "alpha-no-resize.png"
    no_resize_rgb = rgb(320, 224)
    no_resize_alpha = np.full((224, 320, 1), 127, dtype=np.uint8)
    no_resize_alpha[:100, :100] = 0
    Image.fromarray(np.concatenate((no_resize_rgb, no_resize_alpha), axis=2)).save(path)
    cases.append(("alpha-no-resize", path, 1))
    path = directory / "grayscale.png"
    Image.fromarray(((x * 3 + y * 7) % 256).astype(np.uint8)).save(path)
    cases.append(("grayscale", path, 1))
    # The same compressed RGB content with each EXIF tag isolates orientation handling.
    image = Image.fromarray(rgb(321, 241))
    for orientation in range(1, 9):
        path = directory / f"orientation-{orientation}.jpg"
        exif = Image.Exif()
        exif[274] = orientation
        image.save(path, quality=95, subsampling=0, exif=exif)
        cases.append((f"orientation-{orientation}", path, orientation))
    return cases


def write_floats(path, values):
    import numpy as np
    values = np.asarray(values, dtype="<f4")
    if not np.isfinite(values).all():
        raise ValueError("Reference tensor contains non-finite values")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(values.tobytes(order="C"))


def generate(source, checkpoint, output, versions, lock, photos=()):
    import numpy as np
    from PIL import Image, ImageOps
    import torch

    sys.path.insert(0, str(source))
    import clip

    torch.set_num_threads(4)
    torch.manual_seed(0)
    torch.backends.mha.set_fastpath_enabled(False)
    model, preprocess = clip.load(str(checkpoint), device="cpu", jit=False)
    model.eval().float()
    images, texts = [], []

    def embeddings(name, tensor, encoder):
        raw = encoder(tensor).numpy()
        normal = preparation.normalized(raw, np)
        raw_name = f"references/{name}-raw.bin"
        normal_name = f"references/{name}-normalized.bin"
        write_floats(output / raw_name, raw)
        write_floats(output / normal_name, normal)
        return {"raw_embedding_file": raw_name, "embedding_file": normal_name}

    image_cases = make_images(output / "images")
    input_sources = []
    for index, photo in enumerate(photos):
        photo = Path(photo)
        name = f"photo-{index + 1}"
        destination = output / "images" / f"{name}{photo.suffix.lower()}"
        shutil.copyfile(photo, destination)
        with Image.open(destination) as image:
            orientation = image.getexif().get(274, 1)
        image_cases.append((name, destination, orientation))
        input_sources.append({"name": name, "source_filename": photo.name, "sha256": preparation.sha256(photo)})

    with torch.inference_mode():
        for name, path, orientation in image_cases:
            with Image.open(path) as image:
                oriented = ImageOps.exif_transpose(image)
                tensor = preprocess(oriented).unsqueeze(0)
                tensor_name = f"references/{name}-tensor.bin"
                write_floats(output / tensor_name, tensor.numpy())
                images.append({
                    "name": name, "image_file": path.relative_to(output).as_posix(),
                    "mode": image.mode, "exif_orientation": orientation,
                    "raw_size": list(image.size), "oriented_size": list(oriented.size),
                    "tensor_file": tensor_name,
                    **embeddings(name, tensor, model.encode_image),
                })
            print(f"Reference image: {name}", flush=True)
        for name, text in TEXT_CASES:
            tokens = clip.tokenize([text], truncate=True)
            texts.append({
                "name": f"text-{name}", "text": text, "tokens": tokens[0].tolist(),
                **embeddings(f"text-{name}", tokens, model.encode_text),
            })
            print(f"Reference text: {name}", flush=True)

    manifest = {
        "schema_version": 1, "model_id": lock["model_id"], "source": lock,
        "recipe_sha256": recipe_sha256(), "dependencies": versions,
        "environment": {"python": platform.python_version(), "architecture": platform.machine()},
        "reference": "Pinned official OpenAI CLIP, PyTorch float32, CPU; no Core ML conversion",
        "image_preprocessing": "Pillow ImageOps.exif_transpose, then unmodified official CLIP preprocess (bicubic resize, center crop, RGB conversion, normalization)",
        "binary_format": {"dtype": "float32", "byte_order": "little", "tensor_shape": [1, 3, 224, 224], "embedding_shape": [1, 512]},
        "limitations": "Deterministic synthetic images verify numerical contracts, not real-photo retrieval quality or iPhone performance.",
        "input_sources": input_sources,
        "images": images, "texts": texts, "files": file_inventory(output),
    }
    preparation.write_json(output / MANIFEST, manifest)


def prepare(offline=False, rebuild=False, output=None, photos=()):
    output = Path(output) if output is not None else ARTIFACTS / "CLIPValidation"
    # macOS commonly uses a case-insensitive volume: resolve() alone preserves
    # letter case and would let "clipvalidation/private" bypass the bundle guard.
    def normalized(path):
        return Path(str(path.resolve()).casefold())

    resolved_output = normalized(output)
    if normalized(ARTIFACTS) not in resolved_output.parents:
        raise ValueError("Validation output must be a subdirectory of ignored ModelArtifacts")
    for name in ("CLIP", "Downloads", ".venv"):
        reserved = normalized(ARTIFACTS / name)
        if resolved_output == reserved or reserved in resolved_output.parents:
            raise ValueError("Validation output cannot replace reserved model, download, or environment directories")
    test_bundle = normalized(ARTIFACTS / "CLIPValidation")
    if photos and (resolved_output == test_bundle or test_bundle in resolved_output.parents):
        raise ValueError("Explicit photo references require a separate --output directory, outside the test-bundled CLIPValidation directory")
    recipe = recipe_sha256()
    if output.exists() and not rebuild:
        manifest = verify_bundle(output, recipe)
        inputs = [{"name": f"photo-{index + 1}", "source_filename": Path(photo).name,
                   "sha256": preparation.sha256(photo)} for index, photo in enumerate(photos)]
        if manifest.get("input_sources", []) != inputs:
            raise ValueError("Validation photo inputs changed; run prepare --rebuild")
        print("CLIP validation fixtures are current and all checksums match.")
        return
    versions = preparation.installed_versions()
    lock = json.loads(preparation.CONFIG.read_text())
    cache = ARTIFACTS / "Downloads"
    archive = preparation.fetch_verified(lock["source_archive"], cache / "CLIP-source.zip", offline)
    checkpoint = preparation.fetch_verified(lock["checkpoint"], cache / "ViT-B-32.pt", offline)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="clip-validation-", dir=ARTIFACTS) as temporary:
        temporary = Path(temporary)
        source, staging = temporary / "source", temporary / "CLIPValidation"
        preparation.unpack_source(archive, source, lock["source_commit"])
        staging.mkdir()
        generate(source, checkpoint, staging, versions, lock, photos)
        verify_bundle(staging, recipe)
        backup = temporary / "previous-CLIPValidation"
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            output.rename(backup)
        try:
            staging.rename(output)
        except BaseException:
            if backup.exists():
                backup.rename(output)
            raise
    print(f"Prepared and verified {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify"])
    parser.add_argument("--offline", action="store_true", help="Use only the pinned downloads already cached by prepare_clip.py")
    parser.add_argument("--rebuild", action="store_true", help="Replace fixtures only after the new reference bundle verifies")
    parser.add_argument("--output", type=Path, default=ARTIFACTS / "CLIPValidation", help="Generated fixture directory (keep ignored local data outside source directories)")
    parser.add_argument("--photo", type=Path, action="append", default=[], help="Explicit optional reference photo; requires a separate --output directory; no private data is read by default")
    args = parser.parse_args()
    try:
        if args.command == "verify":
            verify_bundle(args.output, recipe_sha256())
            print("Validation recipe and all checksums match. No network or inference was used.")
        else:
            prepare(args.offline, args.rebuild, args.output, args.photo)
    except (OSError, ValueError, metadata.PackageNotFoundError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
