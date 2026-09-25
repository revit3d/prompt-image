# Step 3.4: semantic retrieval on the development sample

**Тест поиска** connects image embeddings, Russian-to-English query translation, text embeddings, and cosine ranking in a minimal iPhone interface. It searches the existing public evaluation sample: **400 images** and **28 development visual queries**, comprising 14 paired Russian/English scenarios. The separate **Язык поиска** screen remains available for checking translation and query encoding alone.

The sample is copied into the app's data container by a developer. It is not included in the app bundle or imported into Photos. Searching this sample requires no Photos permission and does not index the user's library. [Step 4.3](INDEXING.md) separately adds persistent, resumable photo-library indexing with CLIP and OCR. Opening **Тест поиска** pauses and drains that work before preparing the sample. The combined personal-library search interface remains milestone 5; this sample demo's ranking is unchanged.

## Prepare the exact frozen corpus

Prepare the CLIP, translation, and tokenizer artifacts using the [README](../README.md#prepare-the-model-bundle), then use the frozen dataset from [EVALUATION.md](EVALUATION.md). Run from the repository root:

```sh
python3 tools/prepare_retrieval_demo.py prepare
python3 tools/prepare_retrieval_demo.py verify
```

The standard-library tool reads `PrivateData/Evaluation/benchmark.json`, verifies the frozen hashes of `images.csv` and `queries.development.csv`, and checks every referenced image's bytes. It copies all 400 images without resizing, decoding, or re-encoding them into ignored `PrivateData/RetrievalDemo/`. Only development queries with `kind=visual` enter the demo. The tool does not read `queries.csv` or `queries.holdout.csv`.

The output contains `demo-manifest.json` and `images/`. Manifest schema 1 records model ID `openai-clip-vit-b32-fp16-v2`, source hashes, a corpus fingerprint, image IDs/paths/hashes, and development query IDs/groups/languages/text/known positives. The fingerprint is SHA-256 of compact, key-sorted JSON containing `benchmark_sha256`, `images_csv_sha256`, and `development_queries_csv_sha256`, without a trailing newline. Reading the benchmark's recorded holdout hash does not expose held-out query text.

Both preparation and verification reject unsafe paths, symlinks, duplicate IDs, incompatible model contracts, and changed image bytes. The demo accepts at most 500 images, 5 MiB per image, 100 queries, and 1 MiB of manifest metadata. A new local output replaces the previous demo only after verification; failed publication restores the previous copy, or preserves a recoverable backup if restoration also fails. `--dataset` and `--output` permit isolated test fixtures; output cannot overlap the source, replace unrelated existing directories, or overwrite repository source/model directories.

## Transfer and try the iPhone interface

Build and install PromptImage first. Find the paired phone using `xcrun devicectl list devices`, then replace `YOUR_DEVICE_ID` below. Keep the phone unlocked with Developer Mode enabled.

**Stop the app in Xcode or close it from the app switcher before copying.** Do not replace the sample while indexing, searching, or viewing a result. Copy into the app's data container:

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_ID --source PrivateData/RetrievalDemo --destination Documents/RetrievalDemo --domain-type appDataContainer --domain-identifier com.revited.promptimage
```

The expected device layout is `Documents/RetrievalDemo/demo-manifest.json` and `Documents/RetrievalDemo/images/…`. Use your configured bundle identifier if it differs. This developer transfer creates a separate copy and leaves the Mac dataset and the phone's Photos library unchanged. The app marks the demo directory as excluded from backup when it loads it. Removing/reinstalling the app may require transferring the sample again.

1. Open **Тест поиска** from the initial permission screen or the gallery's **Поиск** menu. A missing or incompatible sample produces a message instead of silently searching another collection.
2. Tap **Подготовить 400 изображений**. Progress counts images whose embeddings have finished. The app verifies each image's hash before preprocessing and processes one image at a time.
3. Select a development description through **Примеры описаний**, or enter your own Russian/English description. Short or mixed descriptions can use an explicit language choice. Tap **Найти изображения**.
4. Inspect the ten closest images in ranked order. Tap a result to open a larger view. The interface shows the English processing text when it differs from the entered description. A closest image is not necessarily a relevant match; the corpus may contain no suitable image.
5. Check cancellation, changing a pending description, closing the screen, and switching away from the app. Unfinished preparation is discarded and must restart. A completed in-memory index can continue to serve the same open screen after returning to the foreground; reopening the screen requires preparing again.
6. Repeat a search with network access disabled. Inference uses bundled models and the copied local files; it does not fetch iCloud images or call a server.

Image preprocessing follows [INFERENCE.md](INFERENCE.md). The index retains normalized 512-element vectors and file references in memory. For 400 Float32 vectors, the vector payload alone is 819,200 bytes; arrays, identifiers, model/runtime allocations, and displayed images add overhead. It is not a persistent index or a measurement of total memory. The image model is released after preparation, before loading the query models. Ranking scores each image with cosine similarity and retains the top ten; equal scores use ascending image IDs for deterministic order. Cosine is not a probability or confidence percentage.

Cancellation is checked between expensive operations. A synchronous prediction or decode already running may finish before cancellation takes effect; its stale result must not replace a newer screen state. Closing the screen waits for outstanding work before releasing models. Normal interactive searches do not save embeddings, query text, or result reports.

## Run the development evaluation

Compile/run the ordinary behavioral tests using the [README commands](../README.md#build-verification). Ranking and screen-state tests use small injected examples; they do not establish real-photo quality. The following separate test uses the copied 400-image corpus and the real bundled models. It is enabled only when the demo manifest exists in the test host's data container, so confirm that the test actually executed rather than being skipped.

Run it alone in Release on the physical iPhone, after transferring the sample:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'platform=iOS,id=YOUR_DEVICE_ID' -derivedDataPath build/DeviceDerivedData ENABLE_TESTABILITY=YES -parallel-testing-enabled NO '-only-testing:PromptImageTests/RetrievalEvaluationTests/evaluatesDevelopmentRetrievalOnCurrentHardware()' test
```

This indexes all 400 images and executes each of the 28 development visual queries with its declared language. It uses Core ML `.all` compute units; that permits acceleration but does not prove every operation runs on the Neural Engine. The first query includes lazy translation/text model loading. Subsequent queries reuse loaded models. The explicit test writes `Documents/retrieval-evaluation.json`, containing public example IDs, English processing text, top-ten image IDs, per-query errors/timing, corpus/model provenance, indexing time, and sampled whole-process memory. The report is excluded from backup.

Fetch and score the report locally:

```sh
mkdir -p build
xcrun devicectl device copy from --device YOUR_DEVICE_ID --source Documents/retrieval-evaluation.json --destination build/retrieval-evaluation.json --domain-type appDataContainer --domain-identifier com.revited.promptimage
python3 tools/prepare_retrieval_demo.py score --results build/retrieval-evaluation.json
```

Scoring re-verifies the frozen dataset and prepared demo and requires matching corpus/model IDs and `ranking_limit=10`. Each successful case must contain ten unique known image IDs. Unknown or duplicate result/query IDs are errors. Missing or failed queries remain in the denominator and score zero.

Results are separated by language, with 14 queries in each denominator:

- **Success@1:** at least one known positive is the first result.
- **Success@5:** at least one known positive is among the first five results.
- **MRR@10:** reciprocal rank of the first known positive within the first ten, or zero if none appears. This is truncated MRR, not full-corpus MRR.

The report's memory samples occur every 10 ms and may miss transient peaks. They include the app and runtime, and unloading does not force all system caches to release immediately. Indexing/search times describe this run on this hardware; no battery, thermal, or older-device conclusion follows from them.

## Coverage and validation record

The evaluation is **development visual retrieval only**. The 80 TextVQA images remain in the searchable corpus as distractors, but their text queries are excluded. No OCR, held-out query score, personal-library recall, screenshot/recipe/meme quality, or production readiness is established by this run. Russian and English versions of a scenario are paired observations. Known positives can be incomplete, and public images may overlap model pretraining. Preserve the original labels when reviewing apparent misses; document legitimate label corrections separately.

On 2026-09-25, the Release evaluation executed on the physical iPhone 17 Pro using all **400 unchanged images** and all **28 development visual queries**. No images or failed queries were removed, and there were no query execution errors. The corpus fingerprint was `da4e969e9f380e3a6ca9202e2722362852e5f0638712d60ab1316dbb31255d8b`.

| Language | Success@1 | Success@5 | MRR@10 |
| --- | --- | --- | --- |
| Russian | 8/14 (57.1%) | 13/14 (92.9%) | 0.7245 |
| English | 9/14 (64.3%) | 13/14 (92.9%) | 0.7643 |

The same living-room scenario missed the first five in both languages: its known positive ranked seventh in Russian and sixth in English. Labels were preserved. This does not establish the held-out target, and unlisted images may also be relevant.

| Phone measurement | Observation |
| --- | --- |
| Prepare all 400 image embeddings | 11.06 seconds |
| First search, Russian, including query model loading | 5.26 seconds |
| Subsequent Russian searches, median of 13 | 72.8 ms |
| English searches, median of 14 | 11.7 ms |
| Sampled whole-process peak RSS | 697.5 MiB |

The first complete corpus run exposed one CMYK JPEG that the previous preprocessor rejected. Step 3.4 adds four-channel resizing followed by Pillow-compatible RGB conversion, including inverted JPEG decode mappings. Two independent synthetic CMYK references and the original corpus image passed Mac tensor comparisons; Simulator and phone CMYK checks also passed. The original image bytes and benchmark labels were not changed.

Validation also passed the full Release Simulator suite under French language/France region settings: **142 reported tests in 20 suites**, with the optional corpus evaluation skipped there because the sample was installed only on the phone. The subsequent direct JPEG diagnostic and reference comparison passed as two focused Simulator tests; three focused physical-phone tests passed, covering JPEG/TIFF CMYK, all 19 image/12 text references, and raw JPEG decoder comparison. All **81 Python integrity/scoring tests** passed. Debug app/test-bundle compilation passed. [INFERENCE.md](INFERENCE.md#generate-independent-reference-fixtures) explains the independently measured native JPEG differences and their bounded acceptance criteria.

Generated reports remain in ignored `build/retrieval-evaluation.json`, `build/retrieval-scores.json`, and `build/step-3.4-*.log`. The ordinary UI does not write these reports. Earlier model-only measurements remain in their respective guides and must not be presented as complete retrieval timings.
