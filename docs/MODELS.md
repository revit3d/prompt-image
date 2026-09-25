# Preparing the CLIP model bundle

Step 3.1 prepares and bundles the two encoders from OpenAI CLIP ViT-B/32. The app exposes resource lookup and explicit model loading; the photo gallery does not run inference yet. Image preprocessing in Swift, tokenization, Russian translation, retrieval evaluation, and device performance are step 3.2 and later.

## First preparation

Run from the repository root on a native Apple Silicon Mac with Python 3.11 installed. The M3 Pro development machine meets the hardware requirement. The commands below use Homebrew's Python 3.11 path; do not use the older system Python for conversion.

```sh
/opt/homebrew/bin/python3.11 -m venv ModelArtifacts/.venv
ModelArtifacts/.venv/bin/python -m pip install -r tools/models/requirements.txt
ModelArtifacts/.venv/bin/python tools/prepare_clip.py prepare
```

Dependency installation requires network access. The first preparation also downloads about 4 MiB of pinned CLIP source and a 338 MiB checkpoint. Allow additional disk space for Python dependencies, conversion staging, the model pair, and Xcode build products. No personal photos are read or sent anywhere during preparation.

Preparation verifies the source archive and checkpoint SHA-256 values before importing the source or loading the checkpoint. It requires the dependency versions in `tools/models/requirements.txt`, exports both encoders in a temporary directory, and runs the CPU conversion checks described below. It publishes `ModelArtifacts/CLIP/` only after every check passes. During a rebuild, the previous complete bundle remains in place until the replacement is ready.

**Prepare the models before any Xcode app build, test build, or run on a fresh checkout.** The project explicitly references the two model packages, tokenizer, manifest, and license. Missing resources produce an Xcode build error. Xcode does not run preparation or download models automatically. Once preparation succeeds, the regular build commands in [README.md](../README.md#build-verification) apply.

## Reuse, verification, and rebuilding

Run `prepare` again to reuse an existing bundle whose recipe and file checksums still match. No conversion or network request is needed for that path.

Verify the prepared bundle without model dependencies, network access, or inference:

```sh
python3 tools/prepare_clip.py verify
```

This checks the manifest, current preparation recipe, complete file inventory, checksums, and the presence of a passing stored smoke report. It does not rerun the report's numerical checks.

Use cached source and checkpoint downloads when preparing offline:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_clip.py prepare --offline
```

If the exporter, source lock, or dependency lock changes, or verification reports modified generated files, explicitly rebuild:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_clip.py prepare --rebuild --offline
```

Offline rebuilding still requires the installed dependencies and both valid cached downloads. Omit `--offline` to allow a missing download. A checksum mismatch in a cached download fails rather than trusting it; remove only the named invalid cached file before retrying online. A conversion or numerical-check failure leaves the previously published bundle unchanged and requires investigation before proceeding.

## Provenance and generated files

The model identifier is `openai-clip-vit-b32-fp16-v1`. `tools/models/clip-source.json` pins the [official CLIP source](https://github.com/openai/CLIP/tree/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6), source archive checksum, and official ViT-B/32 checkpoint URL/checksum. The source commit is `d05afc436d78f1c48dc0dbf8e5980a9d471f35f6`; the checkpoint SHA-256 is `40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af`.

The downloaded source includes the [MIT license](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/LICENSE) and [model card](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/model-card.md). Keep these with distributed model artifacts. The model card describes limitations relevant to evaluating this prototype; conversion alone does not establish suitability or retrieval quality. This is the English baseline; Russian queries will require the planned on-device translation stage.

The preparation follows Apple's [PyTorch-to-Core-ML workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html), with separately traced encoders and ML Program export using FP16 compute. The model format's minimum target is iOS 16; this does not change the app's deployment target.

```text
ModelArtifacts/
  .venv/                        Local Python conversion environment
  Downloads/                    Checksum-verified source and checkpoint cache
  CLIP/
    CLIPImageEncoder.mlpackage  Image encoder, compiled by Xcode
    CLIPTextEncoder.mlpackage   Text encoder, compiled by Xcode
    tokenizer.json             Vocabulary, merges, rules, and reference tokens
    model-manifest.json        Version, provenance, contracts, and file checksums
    LICENSE.txt                Original OpenAI MIT license
    model-card.md              Original model card
    smoke-report.json          Mac CPU conversion comparison results
```

All of `ModelArtifacts/` is Git-ignored. Commit the preparation code and locks, never the generated weights or environment. The manifest records dependency versions, Python/macOS/architecture, preprocessing, tokenizer source hash, tensor interfaces, recipe hash, and hashes for generated files. The manifest itself is excluded from its file inventory.

Xcode includes only the explicitly listed model packages, tokenizer, manifest, and license. It compiles `.mlpackage` files into `.mlmodelc` resources. The download cache, Python environment, model card, and smoke report are not copied into the app. `CLIPModelResources` validates the supported manifest and locates the compiled resources; loading weights is a separate explicit call and does not happen at app startup.

## Input and output contract

| Encoder | Input name | Type and fixed shape | Output |
| --- | --- | --- | --- |
| Image | `image` | Float32 `[1, 3, 224, 224]`, normalized RGB in NCHW order | `embedding`, Float32 `[1, 512]` |
| Text | `tokens` | Int32 `[1, 77]`, CLIP token IDs | `embedding`, Float32 `[1, 512]` |

Both outputs are **raw embeddings**. The caller must check for finite values and a nonzero norm, then divide each embedding by its L2 norm before calculating cosine similarity. The exported encoders do not include this postprocessing, a similarity score, or ranking.

The image tensor must be prepared before model inference:

1. Apply the photo's orientation before resizing.
2. Resize with bicubic interpolation so the shorter side is 224 pixels, preserving aspect ratio; center-crop to 224 × 224.
3. Use RGB channel order and scale byte values to `[0, 1]` by dividing by 255.
4. Normalize each channel with `(value - mean) / std`. Means are `[0.48145466, 0.4578275, 0.40821073]`; standard deviations are `[0.26862954, 0.26130258, 0.27577711]`.
5. Arrange Float32 values as one NCHW tensor: batch, RGB channels, height, width.

The reference for resize/crop/color conversion is the pinned CLIP `_transform` using torchvision/PIL. Matching Swift image decoding, interpolation, crop rounding, and orientation to this reference must be tested on real images in step 3.2. Supplying unnormalized pixels or a BGRA image buffer directly does not meet this contract.

`tokenizer.json` records the complete 49,408-entry vocabulary, ordered BPE merges, byte encoder, token-splitting pattern, cleaning rules, and truncation policy. Cleaning follows the pinned tokenizer: `ftfy.fix_text`, two HTML-unescape passes, strip/collapse Unicode whitespace, and lowercase. The start token is 49406, end token 49407, and padding token 0. A sequence contains a start token, at most 75 content tokens, an end token, and padding to 77 positions; truncation preserves an end token at position 76. A Swift tokenizer must reproduce these rules rather than substitute another CLIP tokenizer or approximate Unicode cleaning.

Six stored golden token arrays cover empty input, ordinary English, punctuation/HTML entities, combining Unicode characters/emoji, and long-input truncation. They provide reference outputs for implementing Swift tokenization later. Bundling them does not implement tokenization in the app.

## Validation boundaries

Preparation compares PyTorch eager output with the traced encoders, then compares the saved Core ML models with PyTorch using CPU inference. It uses three synthetic image tensors and six text token arrays. It requires finite, nonzero 512-element outputs, cosine agreement of at least 0.999 per sample, and maximum image/text similarity drift of 0.01. The report records the measured values.

The iOS test suite checks bundled manifest/tokenizer/license contents, golden token IDs, and CPU-only loading of both compiled encoders with the expected input/output names, shapes, and data types. `build-for-testing` only compiles this test bundle; run `test` to execute these checks.

These checks establish conversion and packaging integrity. They do not establish photo preprocessing parity, semantic-search accuracy, Russian query quality, iPhone inference speed, memory/battery behavior, or Neural Engine compatibility. Those measurements belong to the next roadmap steps. The current gallery remains the same, and no photo is processed by CLIP yet.

## Step 3.1 validation record

Validated on 2026-09-25 using this pinned recipe, Python 3.11.16, and Xcode 27.0:

- Both saved Core ML encoders passed Mac CPU prediction checks. Minimum cosine agreement was 0.999604 for images and 0.999968 for text; maximum cross-modal similarity drift was 0.001835.
- Offline rebuilding, existing-bundle reuse, and the dependency-free integrity check succeeded. The packages occupy approximately 168 MiB (image) and 121 MiB (text) before app packaging.
- All 33 Python tests passed, including interrupted downloads, checksum failures, stale recipes, and failed-rebuild preservation.
- Debug app/test-bundle compilation and the Release Simulator build passed. All 55 Swift tests passed on the iPhone 18 Pro / iOS 27.0 Simulator, including actual CPU loading of both compiled encoders, not just test-bundle compilation.

Physical iPhone execution and performance have not been measured for these encoders. Generated per-run evidence remains under ignored `ModelArtifacts/CLIP/smoke-report.json` and `build/`; changing the preparation recipe requires new validation.
