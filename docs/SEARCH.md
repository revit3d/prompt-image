# Step 5.1: combined photo-library search pipeline

The internal `PhotoSearchPipeline` searches the persistent personal-library index with a Russian or English query. It preserves the original input for OCR lookup, uses the bundled on-device translator for Russian visual queries, and encodes the English description with CLIP. It makes no image requests, downloads, or uploads, and does not save queries or log private content.

This step implements the pipeline and its tests. The app's **Тест поиска** screen still searches the separate public sample. The personal-library search screen, text-only mode, cancellation on query edits, and user-facing search states belong to step 5.2; snippets and viewer improvements belong to 5.3.

## Retrieval and ranking

- Visual retrieval considers every completed embedding in the query's exact model space. It scans pages of 200 vectors, keeping the best 100 cosine matches with ascending photo IDs breaking ties. The sample demo's 10,000-image bound does not limit this scan.
- OCR retrieval searches the original Russian/English input, including when visual input was translated. It uses the existing literal whole-word AND query and current OCR version, taking the best 100 BM25 matches. Punctuation separates words; user input cannot become FTS operators. There is no stemming, substring matching, or exact-phrase guarantee.
- Equal-weight reciprocal-rank fusion adds `1 / (60 + rank)` for each channel containing an asset, with ranks starting at one. This uses rank positions rather than mixing cosine and BM25 scores. See the [original RRF paper](https://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf). The constant and candidate counts are prototype defaults, not parameters tuned on held-out queries.
- Results are deduplicated by photo identifier and ordered by fusion score, then ascending identifier. The default result count is 50, with an allowed range of 1–100. Each result retains its source metadata, optional visual similarity, and the recognized text only when it matched OCR. These scores do not represent certainty.
- Either completed stage can contribute while the other remains pending, failed, or unavailable. An empty index returns no matches. A visual query can still return nearest neighbors without any OCR match.

Combined input is limited to 4,096 UTF-8 bytes and 32 letter/number terms, matching the existing OCR lookup contract. These limits and blank input are checked before model work. The existing automatic language detection and explicit Russian/English choices remain available. Translation, inference, and storage failures propagate; there is no silent cloud or alternate-model fallback.

## Ownership and access

Construct the pipeline with the library's existing `PhotoIndexingStore`. That owner captures an active, synchronized library revision before query preparation and checks it after inference and retrieval. It also requires the text encoder's model ID to equal the synchronized image model ID. Unready access/index state reports `PhotoSearchError.indexNotReady`; a changed library revision or cancellation discards the in-flight search.

Both rankings and result metadata are read in one uninterrupted turn of the existing SQLite actor. There is no second connection or recovery of another worker's tickets. Completed stages remain searchable while indexing runs; vector scanning is off the UI actor and checks cancellation between records/pages. A search briefly occupies the storage actor, so throughput and latency at large-library scale still need measurement.

Before delivery, every result is checked against current PhotoKit accessibility and source metadata. Removed or changed assets are filtered even when the observer notification has not arrived yet. This can yield fewer results than requested. The later search screen must also cancel its task and clear already-displayed results when the query, library, permissions, or activity changes; an already-returned value cannot revoke itself. Call `unload()` after outstanding query work has drained to release translation/text models.

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
  -only-testing:PromptImageTests/PhotoIndexProcessorTests \
  -only-testing:PromptImageTests/PhotoIndexStoreTests \
  -only-testing:PromptImageTests/PhotoIndexingStoreTests \
  -only-testing:PromptImageTests/QueryEmbeddingPipelineTests \
  -only-testing:PromptImageTests/SemanticImageIndexTests test
```

The new tests use synthetic vectors/text and real temporary SQLite databases. They cover fusion, deduplication, model/OCR versions, paged rankings, persistence, Russian/English routing, query bounds, partial indexes, cancellation, and access changes. The processor integration test also runs real CLIP/Vision indexing plus bundled translation/CLIP text encoding and verifies that both channels contribute to the persisted result. It does not access personal photos.

For a physical device, select the paired iPhone, use `build/DeviceDerivedData`, and omit `CODE_SIGNING_ALLOWED=NO`. Test-bundle compilation alone is not behavioral validation. Synthetic retrieval checks do not establish real-world ranking quality, PhotoKit notification timing, thousands-of-images latency, battery use, or thermal behavior.

Validated on 2026-09-26 with Xcode 27.0 in Release on both the iPhone 18 Pro / iOS 27.0 simulator and the paired iPhone 17 Pro / iOS 27.0. All 82 test functions in the eight selected suites passed on each destination (118 executions including parameterized cases), with no failures or skips. Both runs executed the real-model integration test, including combined Russian/English retrieval. An independent SQLite query-plan check also confirmed that vector pages seek through the photo-ID index without repeatedly sorting the full library; this is not an on-device search-latency benchmark.
