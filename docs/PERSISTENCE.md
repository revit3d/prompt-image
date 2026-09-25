# Step 4.2: persistent local photo index

`PhotoIndexStore` is an actor-owned SQLite store for derived photo data. [Step 4.3](INDEXING.md) connects it to foreground indexing through **Подготовка к поиску** in the gallery. The viewer's separate OCR results remain temporary, and the public-sample search screen is unchanged.

## Stored data and contracts

The database contains asset identifiers, creation/modification dates, dimensions, an asset-generation UUID, and independent embedding/OCR stages. Each stage records its processing version, status, safe failure code, current attempt token, and completed payload. It stores no source image bytes, thumbnails, local file paths, raw exception messages, or query history.

- **Photo snapshots:** `upsert` preserves an unchanged snapshot and completed work. Changed metadata invalidates both stages and creates a new generation. Dates use Foundation's reference epoch to preserve exact `Date` equality. Deleting and re-adding the same identifier also produces a new generation.
- **Versions:** a changed embedding model ID invalidates only embeddings; a changed OCR version invalidates only OCR and its full-text entries. `PhotoIndexPipeline.currentOCRVersion` includes the application pipeline version, Vision revision, languages, recognition/tiling settings, and OS version. Bump the pipeline version when recognition or merging behavior changes. The caller must pass the version of the actual producing pipeline.
- **Work:** `beginWork` returns a ticket containing asset ID/generation, stage, version, and a unique attempt. Successful writes, failure reports, and cancellation require that exact current ticket and `processing` status. Old attempts cannot overwrite a retry, edited photo, changed pipeline, deleted/re-added photo, or cleared index.
- **Progress:** stages are `pending`, `processing`, `complete`, `requiresDownload`, or `failed`. Embedding and OCR complete independently; one failure does not discard the other. An OCR result with no text is a completed result, not an unprocessed image. Pending work is returned in bounded pages. Failed stages require explicit retry; the coordinator resets cloud-only stages once per enabled foreground/start cycle.
- **Restart:** opening the database resets interrupted `processing` stages to `pending` and clears their attempt tokens. Completed payloads remain. Keep one store owner per app: opening a second owner would reset another owner's processing tickets. `cancel` deliberately performs its small cleanup in a fresh cancellation context, so it can be called from an already-cancelled work task. All other transactions respect task cancellation and roll back unfinished writes.
- **Encoding:** embeddings use 512 little-endian Float32 values (2,048 bytes), with dimension, finite-value, unit-norm, and model-ID validation on loading. OCR uses a bounded, versioned JSON envelope containing original lines, confidence, image bounds, Vision revision, and languages. Invalid payloads surface an error rather than being silently repaired.

Completed embeddings can be read in model-filtered pages; completed OCR can be fetched by asset ID and OCR version. Schema version 1 uses `photos`, `stages`, `ocr_text`, and an external-content `ocr_fts` table. Payload, status, and full-text updates commit together. Foreign-key cascades and triggers remove full-text entries with their photos. A failed transaction preserves the previous state, including its valid work ticket.

## Text lookup

SQLite [FTS5](https://www.sqlite.org/fts5.html) supplies `unicode61` tokenization for Russian and English. `searchOCR` accepts up to 4,096 UTF-8 bytes and 32 literal word/number terms, combines them with AND, and filters to completed results of the requested OCR version. Punctuation is treated as a separator; user input never becomes SQL or FTS operator syntax. Empty/punctuation-only input returns no matches. Pages are limited to 1–1,000 items.

Results include asset ID, original text, and SQLite's BM25 rank; lower ranks sort first, with asset ID breaking ties. This is word lookup, not semantic ranking or a probability. There is no Russian stemming, prefix matching, or combined visual/text ranking in this step. Milestone 5 will supply the query experience and ranking combination.

## Files, privacy, and recovery

`openDefault()` uses `Library/Application Support/PhotoIndex/index.sqlite` inside the app container. The directory is marked [excluded from backup](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup) before creation of the database, has mode 0700 and complete iOS file protection, and gives the database/known SQLite sidecars mode 0600 and complete protection. Symlink database/directory leaves are rejected. SQLite opens with the complete-protection flag; no weaker protection fallback is used. Open the store when protected data is available; locked-device or storage errors surface to its caller.

The store uses rollback journals in DELETE mode, synchronous FULL commits, foreign keys, memory-only temporary tables, a two-second busy timeout, and SQLite secure-delete. FTS secure-delete is also enabled where the runtime supports it (SQLite 3.42+). Completed transactions do not retain WAL/SHM files. Removing records or `clear()` removes derived records and searchable content, without touching Photos. These choices do not promise forensic erasure of flash storage or OS snapshots.

Schema creation and `user_version` changes are transactional. Existing databases receive SQLite quick/foreign-key checks. A future or invalid schema, malformed payload, or database error is reported without automatically deleting or rebuilding user data. Errors exposed by this layer contain safe categories/SQLite numeric codes, never SQL, OCR text, asset IDs, or file paths. The layer emits no content logs and uses no network APIs.

Steps 4.3–4.4 reconcile complete permitted snapshots on library refresh and clear derived data after revocation. `pruneStaleRecords` removes absent assets, changed metadata, explicit content-invalidations, or all records for a rebuild before models load. A replacement receives a new generation even when its metadata is identical. `synchronize` atomically updates snapshots/versions; never pass either operation an incomplete page. `retryDownloads` resets only cloud stages for the coordinator's bounded foreground policy; `retryIncomplete` also resets failed stages for explicit retry. `recoverInterruptedWork` repairs interrupted claims after the sole worker drains. Summary counts report photos: pending, cloud, and failed categories may overlap when their two stages differ. This storage layer deliberately does not call PhotoKit; future search callers must also validate current access rather than treating the database as permission authority. See [library-change handling](LIBRARY_CHANGES.md) for observer behavior and the rebuild fallback.

## Validation

Prepare the existing app model/reference resources using the [README](../README.md). Storage tests use generated records and temporary databases in the test app's sandbox, not personal photos or the default persistent index.

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:PromptImageTests/PhotoIndexStoreTests \
  -only-testing:PromptImageTests/PhotoIndexCodecTests \
  -only-testing:PromptImageTests/SQLiteConnectionTests \
  -only-testing:PromptImageTests/CLIPEmbeddingTests test
```

The tests exercise real SQLite persistence/reopening, interruption recovery, stale attempts, independent stage versions, Russian/English full-text lookup, invalidation/deletion, rollback, invalid payloads/schema versions, and storage attributes. Building the test bundle alone does not exercise these behaviors. The simulator does not report the iOS file-protection class: its suite checks permissions/backup exclusion and explicitly skips the dedicated protection-class test. Run the same suites on the paired iPhone (choose its destination and omit `CODE_SIGNING_ALLOWED=NO`) to check complete protection on the directory, database, and a journal during an active transaction. Actual locked-device access behavior and sustained library-scale performance remain phone checks for the indexing coordinator.

Validated on 2026-09-25 with Xcode 27.0 in Release: all 37 tests in four suites passed on the paired iPhone, including the complete-protection directory/database/journal assertions. The iPhone 18 Pro / iOS 27.0 simulator run also passed, executing 36 tests and explicitly skipping that one hardware-only test. No personal images or default index data were used. These are storage and codec checks, not end-to-end library indexing or locked-device access tests.
