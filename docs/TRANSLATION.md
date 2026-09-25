# Step 3.3: bundled Russian-to-English translation

The app bundles a separate translation model, like its CLIP models. Russian descriptions are translated locally into English before CLIP encoding; English descriptions bypass translation. No Apple Translation API, language-pack download, account, or server is involved. The feature compiles for the project's existing iOS 17 deployment target and does not require Apple Intelligence or Russian regional settings.

`QueryEmbeddingPipeline` returns the unchanged original query (for future OCR search), the English processing text, source language, and normalized CLIP embedding. The **Язык поиска** screen in the app lets you test this pipeline. It does not rank photos yet; retrieval is step 3.4.

## Models and provenance

The baseline is [Helsinki-NLP/opus-mt-ru-en](https://huggingface.co/Helsinki-NLP/opus-mt-ru-en), pinned to commit `fbd6dc73284f95536648512cc21d57f19191961a`. The source checkpoint SHA-256 is `535450eb5613f3cc912f9ca3e54cfef6c14d201b319c24a88faf776a65538b5d`. `tools/models/translation-source.json` pins every downloaded file and the license text. The model's license is **CC BY 4.0**; the app includes its license, attribution, source revision, and conversion/generation modification notice.

The model ID is `helsinki-opus-mt-ru-en-fp16-v1`. Two FP16 Core ML programs implement its encoder and decoder. The prepared translation bundle occupies approximately **211 MiB**, in addition to CLIP. Separate graphs duplicate some shared weights. Quantization and decoder caching are potential later optimizations, not properties of this version.

Tokenization uses the official [SentencePiece](https://github.com/google/sentencepiece) **0.2.1** C++ processor, commit `31646a467d2051eb904e0b45de3a73e91fe1c1e3`, behind a small C interface. Its source archive checksum, CMake version, and deployment targets are pinned in `tools/models/sentencepiece-source.json`. The generated static XCFramework supports iPhone arm64, Simulator arm64/x86_64, and Mac arm64; the iPhone archive is about 1.6 MiB before final linking. The app includes SentencePiece and vendored dependency license notices.

The model manifest declares source languages, target language, tokenizer assets, generation limits, and model version. The translation interface takes explicit source/target languages. Adding a language requires a compatible model, tokenizer validation, routing/UI support, and quality testing; the current Russian model does not acquire new languages automatically. A multilingual replacement is possible, but its Russian quality, size, and performance must be measured. The CLIP interface stays English regardless of the translation provider.

## Prepare a fresh checkout

First create the model environment and prepare CLIP using [MODELS.md](MODELS.md). Then run from the repository root:

```sh
ModelArtifacts/.venv/bin/python -m pip install -r tools/models/translation-requirements.txt cmake==3.31.6
ModelArtifacts/.venv/bin/python tools/prepare_translation.py prepare
ModelArtifacts/.venv/bin/python tools/prepare_sentencepiece.py
```

The first run downloads the pinned source checkpoint (about 307 MB), tokenizer/configuration/license files, and SentencePiece source. All downloads, converted models, native libraries, fixtures, and build intermediates stay in ignored `ModelArtifacts/`. They are development-time preparation, not downloads performed by the app. The conversion uses only fixed public example text; it does not read photos or evaluation holdout queries.

Xcode explicitly compiles the model packages and links the static tokenizer runtime. It bundles only the listed model/tokenizer/license resources. Translation reference JSON and tokenizer goldens belong to the **test target only**. Normal users receive the models with the app and do not install Python, CMake, or any language packs.

Both tools reuse a matching prepared bundle. Cached offline rebuilding is explicit:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_translation.py prepare --offline --rebuild
ModelArtifacts/.venv/bin/python tools/prepare_sentencepiece.py --offline --rebuild
```

Dependency-free integrity checks:

```sh
python3 tools/prepare_translation.py verify
python3 tools/prepare_sentencepiece.py --verify
```

Recipe changes, corrupted files, and incompatible contracts fail verification. The translation bundle is published only after conversion/reference checks pass. Downloads are checked before model loading, and the previously prepared bundle is preserved if rebuilding fails. The native runtime uses vendored dependencies rather than fetching dependencies during CMake compilation.

## Processing contract

The reference is pinned Transformers 4.51.3 `MarianTokenizer(text)` and `MarianMTModel.generate()` with **greedy generation** (`num_beams=1`, no sampling). This deliberately differs from the checkpoint's six-beam generation default. The tokenizer's separate optional Moses `normalize()` function is not invoked by `tokenizer(text)`; SentencePiece's embedded normalizer supplies the actual normalization here.

SentencePiece pieces are mapped through Marian's `vocab.json`; raw SentencePiece IDs are not model IDs. Source and target SentencePiece models differ. The vocabulary has 62,518 entries: EOS `0`, unknown `1`, PAD/start `62517`. Source encoding appends EOS. Target decoding skips special tokens with tokenization-space cleanup disabled.

| Component | Fixed input/output contract |
| --- | --- |
| Encoder | Int32 `source_tokens` and `source_mask`, both `[1,64]`; Float32 `source_hidden` `[1,64,512]` |
| Decoder | Int32 `decoder_tokens` and `decoder_mask` `[1,64]`, Float32 `source_hidden` `[1,64,512]`, Int32 `source_mask` `[1,64]`, Int32 `last_index` `[1]` |
| Decoder output | Float32 `logits` `[1,62518]` for the last active prefix position |

Generation starts with PAD, chooses the largest finite logit excluding PAD, and stops at EOS. The source budget is **63 content tokens plus EOS**, and the output budget is **63 generated tokens including EOS**. Overlong source text and outputs that fail to terminate are errors, never silently truncated successful translations. Both input and translated strings also have a 16,384-byte UTF-8 limit. CLIP's separate 77-token limit still applies after translation.

`BundledTranslationEngine` is a serial actor. It loads models/tokenizers lazily, checks cancellation between tokenization, predictions, and generation steps, and releases cached resources with `unload()`. A synchronous Core ML prediction already running finishes before cancellation is observed. No query cache, query logs, disk writes, or network requests are added.

Language detection uses `NLLanguageRecognizer` without system-locale language hints. Automatic routing requires at least four letters, a single Latin/Cyrillic script, confidence of at least 0.8, and a margin of 0.2. Short, uncertain, or mixed-script descriptions ask for an explicit Russian/English choice; other detected languages are rejected. Original input remains intact for later OCR. Model failure does not prevent English queries or cause Russian to be silently encoded as English.

## Validate and try the app

The standard [README tests](../README.md#build-verification) run real bundled translation in Simulator alongside routing/state/cancellation tests. No system language downloads are needed. To verify independence from regional settings:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -parallel-testing-enabled NO -testLanguage fr -testRegion FR test
```

Run the performance/quality diagnostic alone on a paired physical iPhone, replacing `YOUR_DEVICE_ID`:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'platform=iOS,id=YOUR_DEVICE_ID' -derivedDataPath build/DeviceDerivedData ENABLE_TESTABILITY=YES -parallel-testing-enabled NO '-only-testing:PromptImageTests/BundledTranslationTests/measuresBundledTranslationOnCurrentHardware()' test
```

It checks ten public phrases against the independent Python translations and reports latency, sampled process memory, and CLIP similarity to manually written English equivalents. Only those fixed public phrases are printed. Cosine is not a percentage accuracy score, and the test does not measure photo retrieval.

In **the PromptImage app**, open **Язык поиска** from the gallery toolbar or the initial permission screen. The model is ready without setup. Enter Russian/English descriptions and tap **Проверить описание**; the result shows the English text after translation and CLIP encoding. Test with airplane mode/Wi-Fi off, a short ambiguous word, an explicit language choice, an overlong description, and editing/canceling while processing. Region, system language, and downloaded Apple language packs do not choose the translation direction.

## Validation observations

Debug and Release app/test-bundle compilation passed. All **116 Swift tests in 16 suites** passed on the iPhone 18 Pro / iOS 27.0 Simulator with French as the preferred language and France as the region. A subsequent cancellation fix passed all **13 query-store tests**, including a new regression ensuring an already-cancelled old request cannot clear a newer result or supersede its availability refresh. All **65 offline Python tests** passed, including model/runtime integrity and failed-publication recovery. Prepared CLIP, translation, and SentencePiece runtime checksums and recipes verify successfully.

The ten initial descriptions produce identical token sequences in upstream PyTorch greedy generation, fixed-shape PyTorch export wrappers, and saved Core ML CPU inference. Native Swift tokenization matches all **30 source-encoding** and **16 target-decoding** references, including Unicode, punctuation, literal special tokens, and language-tag handling.

On the iPhone 17 Pro, the bundled `.all` compute path matched all ten reference translations. First-call translation took **3.44 seconds**, including lazy loading; warm translations across the ten phrases had a **32.1 ms median**, ranging from **19.9 to 43.7 ms**. The benchmark's sampled whole-process peak RSS was approximately **681 MiB**, including translation and CLIP text inference. Sampling is every 10 ms, so it may miss transient peaks; these are observations on one device, not guarantees for older phones or long-running indexing.

The comparison identifies real translation limitations: `чек` became “Check” rather than “receipt,” `рыжий кот` became “Red cat” rather than “orange cat,” and `ребёнок` became “The baby” rather than “a child.” These occur in the original model too, so they are not Core ML conversion errors. Keep them visible in retrieval evaluation rather than patching the ten phrases. Wider query coverage and image retrieval quality remain step 3.4/later evaluation work.

Generated numerical evidence remains under ignored `ModelArtifacts/Translation/translation-smoke-report.json` and `build/step-3.3-bundled-*.log`. Model, runtime, and preparation versions are reproducible, but this validation does not replace execution on an older physical iPhone running iOS 17.
