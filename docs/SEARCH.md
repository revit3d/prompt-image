# Steps 5.1–5.2: photo-library search

The internal `PhotoSearchPipeline` searches the persistent personal-library index with a Russian or English query. It preserves the original input for OCR lookup, uses the bundled on-device translator for Russian visual queries, and encodes the English description with CLIP. It makes no image requests, downloads, or uploads, and does not save queries or log private content.

Step 5.2 adds **Поиск → Поиск по фотографиям** to the gallery. Combined search is selected initially; **Текст на фото** searches the original OCR words directly without translation, language detection, or CLIP query inference. **Тест поиска** remains a separate diagnostic for the public sample. OCR snippets and zoom remain step 5.3.

## Try the search screen

1. Prepare some local photos using **Подготовка к поиску**, then open **Поиск → Поиск по фотографиям**. Opening search pauses and drains indexing; the completed portion stays searchable. Resume indexing explicitly after returning to the gallery.
2. Enter a Russian or English description and tap **Найти фотографии**. For a short or mixed-language description, choose a language manually. Combined results are labeled **Ближайшие совпадения**, with no confidence percentages.
3. Switch to **Текст на фото** and enter words visible in a screenshot or recipe. The language picker is unnecessary in this mode. All words must appear in recognized text; this is word lookup, not an exact-phrase or substring guarantee. If nothing matches, **Текст не найден** explains how to refine the query.
4. Edit the query, language, or mode while a search runs. Results clear immediately. Searches run only on explicit submission, not on every keystroke. If you submit again while an old native call is finishing, only the latest submitted query waits to run. **Отмена** drops that request too.
5. With no completed analysis, expect **Пока нечего искать** (or **Текст ещё не подготовлен**). **К подготовке фотографий** returns to the gallery. A partially prepared index remains searchable; unavailable storage/library state displays guidance and disables submission. A translation error offers English or text-only search without a server fallback.
6. Tap a result to view it, then close it and confirm the query/results remain. Switch apps or lock the phone with results or a viewer open: both must clear. On return, wait for the permitted library to refresh and submit again. Repeat after editing/deleting a result or changing selected-photo access in Settings.

The screen returns at most 50 results and suggests refining the query when that limit is reached. Photo display uses the existing local-only image provider. Queries remain in memory for the app session and are not saved as history. Zoom, OCR snippets, detailed result coverage, and broader navigation polish are later work.

## Retrieval and ranking

- Visual retrieval considers every completed embedding in the query's exact model space. It scans pages of 200 vectors, keeping the best 100 cosine matches with ascending photo IDs breaking ties. The sample demo's 10,000-image bound does not limit this scan.
- OCR retrieval searches the original Russian/English input, including when visual input was translated. It uses the existing literal whole-word AND query and current OCR version, taking the best 100 BM25 matches. Punctuation separates words; user input cannot become FTS operators. There is no stemming, substring matching, or exact-phrase guarantee.
- Equal-weight reciprocal-rank fusion adds `1 / (60 + rank)` for each channel containing an asset, with ranks starting at one. This uses rank positions rather than mixing cosine and BM25 scores. See the [original RRF paper](https://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf). The constant and candidate counts are prototype defaults, not parameters tuned on held-out queries.
- Results are deduplicated by photo identifier and ordered by fusion score, then ascending identifier. The default result count is 50, with an allowed range of 1–100. Each result retains its source metadata, optional visual similarity, and the recognized text only when it matched OCR. These scores do not represent certainty.
- Either completed stage can contribute while the other remains pending, failed, or unavailable. An empty index returns no matches. A visual query can still return nearest neighbors without any OCR match.

Input in both modes is limited to 4,096 UTF-8 bytes and 32 letter/number terms, matching the existing OCR lookup contract. These limits and blank input are checked before model work. Combined search retains automatic language detection and explicit Russian/English choices. Text-only search keeps SQLite's BM25 order and filters the current OCR version independently of saved visual embeddings. Translation, inference, and storage failures receive safe messages; there is no silent cloud or alternate-model fallback. Reading the index still requires successful library reconciliation and the app's bundled model metadata.

## Ownership and access

Construct the pipeline with the library's existing `PhotoIndexingStore`. That owner captures an active, synchronized library revision before query preparation and checks it after inference and retrieval. It also requires the text encoder's model ID to equal the synchronized image model ID. Unready access/index state reports `PhotoSearchError.indexNotReady`; a changed library revision or cancellation discards the in-flight search.

Both rankings and result metadata are read in one uninterrupted turn of the existing SQLite actor. There is no second connection or recovery of another worker's tickets. Completed stages remain searchable while indexing runs; vector scanning is off the UI actor and checks cancellation between records/pages. A search briefly occupies the storage actor, so throughput and latency at large-library scale still need measurement.

Before delivery, every result is checked against current PhotoKit accessibility and source metadata. Removed or changed assets are filtered even when the observer notification has not arrived yet. This can yield fewer results than requested. The library owns one `PhotoSearchStore`; synchronous index-invalidation callbacks discard already-displayed results and the selected photo as well as in-flight work. Query, language, and mode edits also invalidate delivery immediately.

The screen keeps one operation slot until a cancelled native prediction actually returns. A replacement waits for that slot and rechecks index readiness before dispatch. Deactivation and invalidation unload query models only after inference drains; reopening waits for that cleanup too. Successful repeated queries reuse warm models. Other diagnostics wait for search cleanup, and gallery indexing controls are disabled while it drains. Opening search pauses image indexing explicitly to avoid concurrent image/query model loading in the UI flow.

## Validation

Prepare models and reference fixtures as described in the [README](../README.md), then run actual behavioral tests:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:PromptImageTests/ReciprocalRankFusionTests \
  -only-testing:PromptImageTests/PhotoIndexSearchTests \
  -only-testing:PromptImageTests/PhotoSearchPipelineTests \
  -only-testing:PromptImageTests/PhotoSearchStoreTests \
  -only-testing:PromptImageTests/PhotoLibrarySearchTests \
  -only-testing:PromptImageTests/PhotoLibraryStoreTests \
  -only-testing:PromptImageTests/PhotoIndexProcessorTests \
  -only-testing:PromptImageTests/PhotoIndexStoreTests \
  -only-testing:PromptImageTests/PhotoIndexingStoreTests \
  -only-testing:PromptImageTests/QueryEmbeddingPipelineTests \
  -only-testing:PromptImageTests/SemanticImageIndexTests test
```

The tests use synthetic vectors/text and real temporary SQLite databases. They cover fusion, deduplication, model/OCR versions, paged rankings, persistence, Russian/English routing, query bounds, partial indexes, cancellation, and access changes. Step 5.2 adds text-only model bypass, empty/no-match states, queued replacement queries, delayed native completion, serialized unloading, safe errors, and production library-to-search invalidation wiring. The processor integration test also runs real CLIP/Vision indexing plus bundled translation/CLIP text encoding and verifies that both channels contribute to the persisted result. It does not access personal photos.

For a physical device, select the paired iPhone, use `build/DeviceDerivedData`, and omit `CODE_SIGNING_ALLOWED=NO`. Test-bundle compilation alone is not behavioral validation. Synthetic retrieval checks do not establish real-world ranking quality, PhotoKit notification timing, thousands-of-images latency, battery use, or thermal behavior.

Validated on 2026-09-26 with Xcode 27.0 in Release on both the iPhone 18 Pro / iOS 27.0 simulator and the paired iPhone 17 Pro / iOS 27.0. All 82 test functions in the eight selected suites passed on each destination (118 executions including parameterized cases), with no failures or skips. Both runs executed the real-model integration test, including combined Russian/English retrieval. An independent SQLite query-plan check also confirmed that vector pages seek through the photo-ID index without repeatedly sorting the full library; this is not an on-device search-latency benchmark.

Step 5.2 was validated on the same date/devices with the expanded eleven-suite command above: all 129 test functions passed on each destination (184 executions including parameterized cases), with no failures, skips, or reported runtime warnings. This includes the production library/search wiring and real-model integration. These automated checks exercise state, retrieval, and lifecycle coordination; the SwiftUI viewer transitions and real Photos changes still need the manual screen checks listed above.
