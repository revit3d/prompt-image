#!/usr/bin/env python3
"""Prepare the pinned CLIP model pair locally; never reads the photo library."""

import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "tools/models/clip-source.json"
REQUIREMENTS = ROOT / "tools/models/requirements.txt"
ARTIFACTS = ROOT / "ModelArtifacts"
SOURCE_FILES = (
    "clip/__init__.py", "clip/clip.py", "clip/model.py", "clip/simple_tokenizer.py",
    "clip/bpe_simple_vocab_16e6.txt.gz", "LICENSE", "model-card.md",
)
PROMPTS = [
    "", "a photo of a cat", "a red car beside a tree",
    "Recipe: eggs, milk &amp; flour!", "a cafe\u0301 by the sea — summer ☀️",
    "a photo " * 100,
]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def recipe_sha256():
    digest = hashlib.sha256()
    for path in (CONFIG, REQUIREMENTS, Path(__file__)):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def fetch_verified(spec, destination, offline=False):
    """Never deserialize an unchecked checkpoint or publish a partial download."""
    destination = Path(destination)
    if destination.exists():
        if sha256(destination) != spec["sha256"]:
            raise ValueError(f"Checksum mismatch: {destination}. Remove this cached file and retry.")
        return destination
    if offline:
        raise ValueError(f"Missing cached download in offline mode: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as target:
            temporary = Path(target.name)
            print(f"Downloading {destination.name}", flush=True)
            with urllib.request.urlopen(spec["url"], timeout=60) as response:
                shutil.copyfileobj(response, target)
        if sha256(temporary) != spec["sha256"]:
            raise ValueError(f"Download checksum mismatch: {destination.name}")
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination


def unpack_source(archive, destination, commit):
    # Copy only known members; archive paths never become arbitrary filesystem paths.
    with zipfile.ZipFile(archive) as source:
        for name in SOURCE_FILES:
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(source.read(f"CLIP-{commit}/{name}"))


def installed_versions():
    versions = {}
    for line in REQUIREMENTS.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, expected = line.split("==")
        actual = metadata.version(name)
        if actual != expected:
            raise ValueError(f"Expected {name}=={expected}, found {actual}; install tools/models/requirements.txt")
        versions[name] = actual
    return versions


def file_inventory(directory):
    return {
        path.relative_to(directory).as_posix(): sha256(path)
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path != directory / "model-manifest.json"
    }


def verify_bundle(directory, expected_recipe=None):
    manifest = json.loads((directory / "model-manifest.json").read_text())
    lock = json.loads(CONFIG.read_text())
    if manifest.get("schema_version") != 1 or manifest.get("model_id") != lock["model_id"]:
        raise ValueError("Unsupported model manifest")
    if expected_recipe is not None and manifest.get("recipe_sha256") != expected_recipe:
        raise ValueError("Model preparation recipe changed; run prepare --rebuild")
    required = {"tokenizer.json", "LICENSE.txt", "model-card.md", "smoke-report.json"}
    files = manifest.get("files", {})
    if not required.issubset(files) or not all(
        any(name.startswith(encoder + ".mlpackage/") for name in files)
        for encoder in ("CLIPImageEncoder", "CLIPTextEncoder")
    ):
        raise ValueError("Model bundle is incomplete")
    # Compare full inventories, catching absent, modified, and unexpected package files.
    if files != file_inventory(directory):
        raise ValueError("Model bundle checksum mismatch; run prepare --rebuild")
    report = json.loads((directory / "smoke-report.json").read_text())
    if report.get("passed") is not True:
        raise ValueError("Model conversion did not pass its smoke check")
    return manifest


def normalized(array, np):
    if array.shape != (1, 512) or not np.isfinite(array).all():
        raise ValueError("Encoder returned a non-finite or incorrectly shaped embedding")
    norm = np.linalg.norm(array)
    if norm <= 0:
        raise ValueError("Encoder returned a zero embedding")
    return array.astype(np.float32) / norm


def export_models(source, checkpoint, output, versions, lock):
    import coremltools as ct
    import numpy as np
    import torch

    sys.path.insert(0, str(source))
    import clip
    from clip.simple_tokenizer import SimpleTokenizer

    torch.set_num_threads(4)
    torch.manual_seed(0)
    # Keep the trace stable instead of switching to the inference-only MHA fast path.
    torch.backends.mha.set_fastpath_enabled(False)
    model, _ = clip.load(str(checkpoint), device="cpu", jit=False)
    model.eval().float()

    class ImageEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.visual = model.visual

        def forward(self, image):
            return self.visual(image)

    class TextEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.clip = model

        def forward(self, tokens):
            return self.clip.encode_text(tokens)

    tokenizer = SimpleTokenizer()
    tokens = clip.tokenize(PROMPTS, truncate=True).numpy().astype(np.int32)
    write_json(output / "tokenizer.json", {
        "schema_version": 1,
        "model_id": lock["model_id"],
        "context_length": 77,
        "start_token": 49406, "end_token": 49407, "padding_token": 0,
        "vocabulary": tokenizer.encoder,
        "merges": [list(pair) for pair, _ in sorted(tokenizer.bpe_ranks.items(), key=lambda item: item[1])],
        "byte_encoder": {str(key): value for key, value in tokenizer.byte_encoder.items()},
        "pattern": tokenizer.pat.pattern,
        "cleaning": ["ftfy.fix_text", "html.unescape twice", "strip", "collapse Unicode whitespace", "lowercase"],
        "golden_tokens": [{"text": text, "tokens": row.tolist()} for text, row in zip(PROMPTS, tokens)],
        "truncation": "At most 75 content tokens; append EOT then pad to 77. Truncation replaces position 76 with EOT.",
    })
    shutil.copyfile(source / "LICENSE", output / "LICENSE.txt")
    shutil.copyfile(source / "model-card.md", output / "model-card.md")

    rng = np.random.default_rng(0)
    images = [
        np.zeros((1, 3, 224, 224), dtype=np.float32),
        np.ones((1, 3, 224, 224), dtype=np.float32),
        rng.standard_normal((1, 3, 224, 224)).astype(np.float32),
    ]
    cases = [
        ("CLIPImageEncoder", "image", ImageEncoder().eval(), images, np.float32),
        ("CLIPTextEncoder", "tokens", TextEncoder().eval(), [row[None, :] for row in tokens], np.int32),
    ]
    comparisons, reference_vectors, converted_vectors = {}, {}, {}
    with torch.no_grad():
        for name, input_name, wrapper, samples, dtype in cases:
            print(f"Tracing and converting {name}", flush=True)
            example = torch.from_numpy(samples[0])
            traced = torch.jit.trace(wrapper, example)
            # The patch convolution loses measurable accuracy in FP16 on Mac CPU.
            # Keeping that one operation in FP32 adds 4.5 MiB while the transformer
            # and text encoder retain FP16 weights and computation.
            precision = (
                ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type != "conv")
                if name == "CLIPImageEncoder" else ct.precision.FLOAT16
            )
            converted = ct.convert(
                traced, source="pytorch", convert_to="mlprogram",
                inputs=[ct.TensorType(name=input_name, shape=example.shape, dtype=dtype)],
                outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                minimum_deployment_target=ct.target.iOS16,
                compute_precision=precision,
                compute_units=ct.ComputeUnit.CPU_ONLY,
            )
            converted.author = "OpenAI; Core ML conversion by PromptImage"
            converted.license = "MIT (see bundled LICENSE.txt)"
            converted.short_description = f"{lock['model_id']} / {name}; raw 512-dimensional embeddings"
            converted.version = lock["model_id"]
            converted.user_defined_metadata["source_commit"] = lock["source_commit"]
            converted.user_defined_metadata["checkpoint_sha256"] = lock["checkpoint"]["sha256"]
            converted.user_defined_metadata["compute_precision"] = (
                "FLOAT16 with conv operations in FLOAT32" if name == "CLIPImageEncoder" else "FLOAT16"
            )
            converted.save(str(output / f"{name}.mlpackage"))
            # Exercise the serialized model, not just the in-memory conversion result.
            predictor = ct.models.MLModel(str(output / f"{name}.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
            agreement, trace_errors, absolute_errors = [], [], []
            reference_vectors[name], converted_vectors[name] = [], []
            for sample in samples:
                reference = wrapper(torch.from_numpy(sample)).numpy()
                trace = traced(torch.from_numpy(sample)).numpy()
                np.testing.assert_allclose(reference, trace, rtol=1e-5, atol=1e-5)
                prediction = predictor.predict({input_name: sample})["embedding"]
                left, right = normalized(reference, np), normalized(prediction, np)
                agreement.append(float(np.sum(left * right)))
                trace_errors.append(float(np.max(np.abs(reference - trace))))
                absolute_errors.append(float(np.max(np.abs(left - right))))
                reference_vectors[name].append(left[0])
                converted_vectors[name].append(right[0])
            comparisons[name] = {
                "sample_count": len(samples), "minimum_cosine_agreement": min(agreement),
                "maximum_normalized_absolute_error": max(absolute_errors),
                "maximum_trace_absolute_error": max(trace_errors),
            }
            if min(agreement) < 0.999:
                raise ValueError(f"{name}: Core ML/PyTorch cosine agreement below 0.999: {min(agreement)}")
            del predictor, converted, traced

    original_scores = np.array(reference_vectors["CLIPImageEncoder"]) @ np.array(reference_vectors["CLIPTextEncoder"]).T
    converted_scores = np.array(converted_vectors["CLIPImageEncoder"]) @ np.array(converted_vectors["CLIPTextEncoder"]).T
    drift = float(np.max(np.abs(original_scores - converted_scores)))
    if drift > 0.01:
        raise ValueError(f"Cross-modal similarity drift exceeds 0.01: {drift}")
    report = {
        "passed": True, "compute_units": "CPU_ONLY", "encoders": comparisons,
        "maximum_similarity_drift": drift,
        "thresholds": {"minimum_cosine_agreement": 0.999, "maximum_similarity_drift": 0.01},
        "limitations": "Synthetic tensor conversion smoke check only; real photo preprocessing, retrieval quality, and iPhone performance are step 3.2 and later.",
    }
    write_json(output / "smoke-report.json", report)
    manifest = {
        "schema_version": 1, "model_id": lock["model_id"],
        "embedding_dimension": 512, "context_length": 77, "image_size": 224,
        "embedding_normalized": False,
        "recipe_sha256": recipe_sha256(), "source": lock,
        "tokenizer_bpe_sha256": sha256(source / "clip/bpe_simple_vocab_16e6.txt.gz"),
        "license": "MIT", "dependencies": versions,
        "environment": {"python": platform.python_version(), "macos": platform.mac_ver()[0], "architecture": platform.machine()},
        "conversion": {
            "format": "mlprogram", "precision": "MIXED", "minimum_target": "iOS16", "batch_size": 1,
            "image_precision": {"default": "FLOAT16", "overrides": {"conv": "FLOAT32"}},
            "text_precision": "FLOAT16",
        },
        "image_input": {"name": "image", "dtype": "float32", "shape": [1, 3, 224, 224]},
        "text_input": {"name": "tokens", "dtype": "int32", "shape": [1, 77]},
        "output": {"name": "embedding", "dtype": "float32", "shape": [1, 512], "postprocessing": "L2 normalize before cosine similarity"},
        "image_preprocessing": {
            "orientation": "Apply EXIF orientation before resize (caller responsibility)",
            "resize": "Bicubic, shorter side 224, preserve aspect ratio", "crop": "Center crop 224x224",
            "color": "RGB", "layout": "NCHW", "pixel_scale": 1 / 255,
            "mean": [0.48145466, 0.4578275, 0.40821073], "std": [0.26862954, 0.26130258, 0.27577711],
            "reference": "Pinned clip.clip._transform / torchvision PIL transforms",
        },
        "files": file_inventory(output),
    }
    write_json(output / "model-manifest.json", manifest)
    print(json.dumps(report, indent=2), flush=True)


def prepare(offline=False, rebuild=False):
    output = ARTIFACTS / "CLIP"
    recipe = recipe_sha256()
    if output.exists() and not rebuild:
        verify_bundle(output, recipe)
        print("Prepared CLIP bundle is current and all checksums match.")
        return
    if platform.system() != "Darwin" or platform.machine() != "arm64" or sys.version_info[:2] != (3, 11):
        raise ValueError("Preparation requires native Apple Silicon macOS with Python 3.11")
    versions = installed_versions()
    lock = json.loads(CONFIG.read_text())
    cache = ARTIFACTS / "Downloads"
    archive = fetch_verified(lock["source_archive"], cache / "CLIP-source.zip", offline)
    checkpoint = fetch_verified(lock["checkpoint"], cache / "ViT-B-32.pt", offline)
    with tempfile.TemporaryDirectory(prefix="clip-preparation-", dir=ARTIFACTS) as temporary:
        temporary = Path(temporary)
        source, staging = temporary / "source", temporary / "CLIP"
        unpack_source(archive, source, lock["source_commit"])
        staging.mkdir()
        export_models(source, checkpoint, staging, versions, lock)
        verify_bundle(staging, recipe)
        # Keep the previous bundle until a complete replacement has passed validation.
        backup = temporary / "previous-CLIP"
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
    parser.add_argument("--offline", action="store_true", help="Require already-cached, checksum-verified downloads")
    parser.add_argument("--rebuild", action="store_true", help="Replace generated bundle only after conversion checks pass")
    args = parser.parse_args()
    try:
        if args.command == "verify":
            verify_bundle(ARTIFACTS / "CLIP", recipe_sha256())
            print("CLIP bundle recipe and all file checksums match. No network or inference was used.")
        else:
            prepare(args.offline, args.rebuild)
    except (OSError, ValueError, metadata.PackageNotFoundError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
