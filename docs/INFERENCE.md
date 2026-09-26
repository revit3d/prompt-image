# Step 3.2: local embeddings and reference validation

Step 3.2 supplies a Swift pipeline for turning encoded still images and text into normalized 512-element CLIP embeddings. It runs inside a serial actor, loads each model lazily, checks cancellation between expensive operations, and can release cached models with `unload()`. The engine itself does not fetch Photos assets, build an index, or translate queries. [Step 3.3](TRANSLATION.md) adds translation, and [step 3.4](RETRIEVAL.md) connects the models to an in-memory public-sample search interface.

`CLIPEmbeddingEngine.imageEmbedding(data:orientation:)` accepts encoded image bytes. The optional orientation overrides embedded EXIF; the [foreground indexing pipeline](INDEXING.md) supplies PhotoKit's orientation without applying it twice. `textEmbedding(_:)` accepts text for the English CLIP baseline. Both return `CLIPEmbedding`, which validates dimension, finite values, and nonzero norm; cosine comparisons reject different model versions.

The engine itself performs no network requests, logs no images or user queries, and writes no embeddings to disk. The separate [step 4.3 coordinator](INDEXING.md) persists successful photo-library results and resumes incomplete stages. Queued/cancelled work is checked before preprocessing and prediction. A synchronous Core ML prediction already in progress finishes before cancellation is observed. Both indexing flows stop new work when the app becomes inactive: the step 3.4 sample demo discards unfinished preparation, while photo-library indexing retains completed stages.

## Preprocessing contracts

Images follow the pinned Pillow/torchvision reference: apply orientation, resize the shorter side to 224 with antialiased bicubic filtering, center-crop with the reference rounding, convert to RGB, and produce normalized Float32 NCHW values. The resampler computes only columns retained by the crop, which avoids allocating enormous resized panoramas. All eight EXIF orientations are supported.

PNG transparency requires particular care: Pillow resizes RGBA in premultiplied form, then discards alpha after cropping. Hidden RGB must remain intact when resizing is unnecessary. Apple's decoded pixel representation can differ between Mac and iOS, so a bounded PNG decoder preserves the original channels for 8-bit grayscale/truecolor PNGs with explicit alpha, including Adam7 interlacing. PNG palette/color-key transparency (`tRNS`) and sampled nonopaque premultiplied alpha from other decoders are rejected. The validation suite checks transparency with and without resizing. JPEG decode rounding can differ between ImageIO and Pillow even when resizing matches.

The prototype interprets decoded color channels without an ICC transform, matching Pillow's reference behavior. It supports decoded 8-bit RGB, grayscale, and CMYK layouts, with a basic HEIC smoke test. CMYK retains four channels through resizing and cropping before applying [Pillow's integer RGB conversion](https://github.com/python-pillow/Pillow/blob/11.3.0/src/libImaging/Convert.c#L552); identity and inverted channel decode mappings are supported. Unsupported mappings, floating-point, and high-bit-depth pixels fail explicitly. ImageIO may convert source formats while decoding; this does not guarantee rejection of every RAW/HDR source, and RAW, wide-gamut, and HDR equivalence is not established. Inputs are bounded to 100 MiB encoded, 50 million pixels, 32,768 pixels per side, and 256 MiB for decoded row storage. These are rejection limits, not a promise that peak process memory stays below 256 MiB.

Text uses the pinned CLIP byte vocabulary and ranked BPE merges, preserving EOT when truncating to 77 tokens. Swift operates on byte symbols rather than grapheme clusters. Cleanup includes HTML entities, standard Unicode normalization, width/ligature conversion, whitespace and quote normalization. Known corrupted Latin-1/Windows-1252 sequences and replacement characters fail explicitly: this is not a complete port of ftfy's legacy-encoding repair heuristics. Queries over 16,384 UTF-8 bytes fail before tokenization. The tokenizer keeps no query cache between calls.

Russian token-ID parity tests check the implementation, not Russian search quality. Step 3.3 now wraps this English encoder with [on-device query translation](TRANSLATION.md). Model preprocessing and text-cleaning licenses are bundled as `Pillow-LICENSE.txt` and `TextCleaning-LICENSE.txt`.

## Generate independent reference fixtures

First prepare the models as described in [MODELS.md](MODELS.md). Then run:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_clip_validation.py prepare --offline
python3 tools/prepare_clip_validation.py verify
```

The generator uses the pinned upstream PyTorch model and tokenizer, not the Swift implementation or converted Core ML outputs. It creates 19 deterministic synthetic images and 12 text cases under ignored `ModelArtifacts/CLIPValidation/`. Cases cover portrait/landscape and odd dimensions, upscaling, extreme aspect ratio, transparency with and without resizing, grayscale, orientations 1–8, a 4032 × 3024 JPEG, and CMYK JPEGs with and without resizing. References include exact token IDs, preprocessed tensors, and raw/normalized embeddings.

This directory is a resource of the **test target only**. Generate it before building/running tests on a fresh checkout; normal app builds require only the model bundle. No personal photos or evaluation corpus files enter the default fixture bundle. Generated files have recipe, provenance, and checksum verification; use `prepare --offline --rebuild` if the fixture recipe changes.

The standard [README test command](../README.md#build-verification) runs tokenizer, preprocessing, embedding validation, cancellation/unloading, model-loading, and Python-reference comparisons along with existing photo-library tests. Debug image preprocessing is much slower than optimized code, especially for the 12-megapixel fixture; use Release for performance measurements. The physical-device benchmark is excluded from Simulator builds.

Reference checks require exact token IDs, PNG tensor errors at most 0.00001, and embedding cosine agreement of at least 0.999. Mac/Simulator JPEG decoding and physical CMYK JPEG decoding use a mean tensor-error limit of 0.004 in normalized channel units. Physical RGB JPEGs use a mean limit of **one 8-bit RGB code value**, computed by undoing each channel's normalization. All JPEGs retain the normalized maximum-error limit of 0.06, and image/text similarity drift must remain at most 0.01 across all reference pairs. Version 2 retains the image convolution in Float32 to meet these checks; the remaining image operations and text encoder use FP16.

Step 3.4's broader phone validation exposed approximately half a code value of average difference in existing RGB JPEG fixtures, exceeding the Mac-derived 0.004 normalized mean limit while preserving embedding and similarity agreement. A separate reference now compares ImageIO's raw decoded RGB bytes with Pillow **before** resizing, isolating decoder differences from the Swift resize/crop/normalization path. The phone-specific bound is expressed in quantization units rather than fitted to one normalized error value. PNG, CMYK, maximum pixel error, embedding, and ranking-drift limits were not relaxed, and production RGB preprocessing did not change.

The direct 4:4:4 JPEG diagnostic measured a mean difference of **0.4916 RGB code values on the iPhone** and **0.1611 in Simulator**. On the phone, CMYK reference embedding cosine exceeded 0.99994 and the maximum image/text similarity drift across the complete reference set was 0.00282, below the unchanged 0.01 limit. These observations describe the tested decoder/hardware combination, not a claim about Apple's decoder algorithm or every iPhone.

Run the offline Python checks:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -v
```

## Compare the same Swift code on the Mac

Build the command-line validator directly from the app's model source files:

```sh
xcrun swiftc -O -parse-as-library -module-cache-path build/SwiftModuleCache PromptImage/Models/*.swift tools/validate_clip.swift -o build/validate-clip
build/validate-clip ModelArtifacts/CLIP ModelArtifacts/CLIPValidation build/clip-mac-parity.json
```

The tool compiles the prepared models locally, runs CPU inference, and writes a numerical report. A failed comparison exits unsuccessfully and leaves the report for diagnosis. Temporary compiled models are removed when the run finishes.

For explicitly chosen photos, generate a separate local fixture directory and validate it on the Mac:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_clip_validation.py prepare --offline --output ModelArtifacts/CLIPPhotoValidation --photo PrivateData/Evaluation/images/coco/000000000285.jpg --photo PrivateData/Evaluation/images/coco/000000000785.jpg
build/validate-clip ModelArtifacts/CLIP ModelArtifacts/CLIPPhotoValidation build/clip-photo-parity.json
```

Those examples are existing public COCO samples from step 1.3. This command reads only explicitly supplied photos, preserves source hashes, and does not upload them or bundle them in the iOS tests. Optional photo inputs are forbidden in the default test fixture directory and its descendants, including symlink/case aliases. Outputs must stay under ignored `ModelArtifacts/` and cannot replace the model bundle, downloads, or Python environment.

## Measure the iPhone

Use `xcrun devicectl list devices` or Xcode to find the connected phone. Run the benchmark alone in Release, replacing `YOUR_DEVICE_ID`:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'platform=iOS,id=YOUR_DEVICE_ID' -derivedDataPath build/DeviceDerivedData ENABLE_TESTABILITY=YES -parallel-testing-enabled NO '-only-testing:PromptImageTests/CLIPInferenceTests/measuresColdAndWarmInferenceOnCurrentHardware()' test
```

This uses the project's configured development signing. The phone must be paired, unlocked, and have Developer Mode enabled. `ENABLE_TESTABILITY=YES` permits the test target's imports while retaining Release optimization.

The `CLIP_BENCHMARK` JSON line reports first-call time and five subsequent times for image and text. Image time includes decoding/preprocessing of the 12-megapixel fixture; first calls also include lazy model/tokenizer loading. Core ML may reuse OS compilation caches, so “cold” means first call in this engine instance. The benchmark uses `.all` compute units and checks results against Python references; allowing the Neural Engine does not guarantee Core ML schedules every operation there.

Memory figures are whole-process resident bytes sampled every 10 ms, including the test app and Core ML runtime. They are not an allocation budget or a guaranteed capture of every transient peak; releasing models does not force Apple runtime caches to release immediately. No library scan, battery test, or retrieval-quality measurement is implied by these timings.

## Step 3.2 validation record

Validated on 2026-09-25 with Xcode 27.0, Python 3.11.16, and model `openai-clip-vit-b32-fp16-v2`:

- All 47 offline Python tests passed; model and both fixture bundles passed recipe/checksum verification.
- Debug app/test-bundle compilation passed. All 77 behavioral tests passed in Release on the iPhone 18 Pro / iOS 27.0 Simulator, including the independent reference comparisons.
- The M3 Pro Mac CPU validator passed 19 image cases (17 synthetic plus two public COCO photos) and 12 text cases. Minimum embedding cosine agreement was 0.999742 for images and 0.999925 for text; maximum image/text similarity drift was 0.002214. All PNG tensors and token IDs matched exactly.
- The isolated Release benchmark executed and passed on the physical iPhone 17 Pro with `.all` compute units, including numerical checks against Python. Results below describe one run with five warm repetitions.

| Measurement | Result |
| --- | --- |
| 4032 × 3024 JPEG, first image call | 2,461 ms |
| Same image, warm median (range) | 457 ms (457–465 ms) |
| Short English text, first text call | 1,961 ms |
| Same text, warm median (range) | 4.17 ms (4.03–10.04 ms) |
| Process RSS before model loading | 154.6 MiB |
| Sampled peak process RSS | 542.0 MiB |
| Process RSS after unloading | 231.2 MiB |

These results support the prototype's next step, but sustained indexing throughput, heating, battery use, and lower-memory phones still need measurement. The current memory footprint is material for future scheduling. Local evidence is in `build/step-3.2-mac-parity.json`, `build/step-3.2-release-tests.log`, `build/step-3.2-device-benchmark.log`, and the corresponding Xcode result bundles; generated evidence stays out of Git.
