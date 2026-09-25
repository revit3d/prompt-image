# Steps 4.3–4.4: foreground indexing and library updates

The gallery's **Подготовка к поиску** card builds a persistent index of permitted, locally available still images. Tap **Начать** to produce a CLIP image embedding and Russian/English Vision OCR for each photo. Opening the app refreshes metadata and saved progress, but does not start image processing. There are no server requests or iCloud downloads.

## Try it on the iPhone

1. Build/run from Xcode and grant a small selected library containing photos, screenshots, and, if available, an iCloud-only image. Find **Подготовка к поиску** above the gallery. Confirm no image processing starts before **Начать**.
2. Tap **Начать**. **Готово** counts photos with both stages complete; **Изображения** and **Текст** count their independently completed stages. Blank OCR is complete. Cloud-only and failed photos are reported separately; those categories can overlap when different stages have different outcomes.
3. Tap **Пауза** during processing. The current native operation may need to return before the pause finishes. Tap **Продолжить**: completed stages remain saved, including an embedding whose OCR was interrupted.
4. Switch apps or lock/unlock the phone during a run. No new image jobs start while inactive. On return, the library is refreshed before an enabled index resumes. After the queue finishes, indexing stays enabled for new/edited photos in this app session. **Пауза** disables these automatic updates too. Close/relaunch the app: saved results return, and processing requires **Продолжить** again.
5. Download a skipped photo using Apple's Photos app and return. If indexing is enabled, previously cloud-only stages are checked once per return; **Начать/Продолжить** also rechecks them. Ordinary library notifications do not repeat these attempts. **Повторить пропущенные** explicitly retries both failed and cloud stages while preserving successful stages. Repeat with airplane mode enabled to check the local-only behavior.
6. During processing, remove a selected photo, edit/delete a photo in Photos, narrow access, or revoke permission in Settings. Return and verify progress follows the new selection. Revocation clears derived data once protected storage is available. Original photos are never modified.
7. Open **Тест поиска**, **Язык поиска**, or **Распознать текст** in the viewer while indexing. The index pauses and drains before the diagnostic opens. Resume indexing explicitly afterward. The separate availability check is disabled during indexing; starting that diagnostic also disables automatic index updates.
8. Follow the [library-change checks](LIBRARY_CHANGES.md) for additions, edits, deletions, limited access, and the **⋯ → Перестроить индекс** fallback.

Saved vectors and OCR become available to the storage lookup APIs after each stage, even before the rest of the library finishes. This step does not add the combined personal-library search screen: **Тест поиска** still searches the public development sample. Milestone 5 supplies the personal-library query interface and visual/OCR ranking.

## Execution and recovery

`PhotoIndexingStore` owns one database connection and one worker. It requests pending records in pages of 20, processes one source at a time, and reuses its compressed bytes sequentially for the incomplete embedding/OCR stages. CLIP and Vision run off the UI actor. Completed stages commit independently. Progress uses row-level changes between exact start/stop summaries, avoiding repeated whole-index scans per photo.

Source loading reuses the existing bounded, cancellable PhotoKit provider with network access disabled and a 30-second timeout. The callback bridge handles synchronous delivery, cancellation with no provider completion, and late callbacks. Encoded sources are limited to 64 MiB after PhotoKit delivery; CLIP/OCR retain their existing decoding limits. These bounds do not promise a fixed process-memory ceiling: PhotoKit initially materializes a response, and models/decoded images also consume memory.

Pause cancels the source/worker immediately, rejects late outputs, and keeps the worker slot occupied until native inference returns and the image model unloads. Interrupted tickets return to pending; completed stages remain intact. If a device lock prevents cleanup, a later foreground pass repairs processing states only after the previous worker has drained. Process termination uses the database's existing reopen recovery. Storage errors stop the run and surface a safe message instead of failing every remaining photo.

Every library refresh invalidates the current indexing snapshot. A complete fresh snapshot prunes inaccessible and changed rows before model initialization, then synchronizes photo and pipeline versions. PhotoKit content notifications also invalidate results when metadata is unchanged. Source access/version is checked again after inference and around persistence; a changed/inaccessible asset loses its derived records. Revocation also clears a prior index when the app launches without Photos permission. Permission cleanup is independent of model availability and is deferred when protected storage cannot be opened. Counts are hidden until a valid snapshot has been synchronized. Future search clients must apply the same access checks; the storage APIs themselves are not authorization gates.

## Automated validation

Prepare resources as described in the [README](../README.md), then run:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:PromptImageTests/PhotoIndexingStoreTests \
  -only-testing:PromptImageTests/PhotoIndexReconciliationTests \
  -only-testing:PromptImageTests/PhotoLibraryFetchBaselineTests \
  -only-testing:PromptImageTests/PhotoIndexSchedulingTests \
  -only-testing:PromptImageTests/PhotoIndexProcessorTests \
  -only-testing:PromptImageTests/PhotoIndexStoreTests \
  -only-testing:PromptImageTests/PhotoLibraryStoreTests \
  -only-testing:PromptImageTests/PhotoOCRSourceProviderTests \
  -only-testing:PromptImageTests/PhotoOCRStoreTests \
  -only-testing:PromptImageTests/PhotoAvailabilityScanTests test
```

The new coordinator/storage tests use injected synthetic sources and temporary databases. The processor integration test uses generated Russian/English text, real bundled CLIP, real Vision OCR, and real SQLite; it checks persisted vectors/text, lookup, pause/resume, and model reload. It makes no PhotoKit image requests. The normal app test host may still refresh permitted metadata and the default index, but image processing requires an explicit start.

For hardware validation choose the paired iPhone as the destination, use `build/DeviceDerivedData`, and omit `CODE_SIGNING_ALLOWED=NO`. Compilation alone is not behavioral validation. Real PhotoKit notification delivery, iCloud behavior, locked-device timing, OCR accuracy on personal images, battery/thermal impact, and sustained performance across thousands of photos remain manual phone checks. No background scheduling or parallel inference is introduced. Automatic retry is limited to cloud-only stages once per enabled foreground/start cycle.

Step 4.3 was validated on 2026-09-26 with Xcode 27.0 in Release: all 92 tests in its eight-suite selection passed on both the iPhone 18 Pro / iOS 27.0 simulator and the paired physical iPhone. Both runs executed the real CLIP/Vision/SQLite integration test, including pause/resume and model reload; none were skipped. Step 4.4 expands this selection with reconciliation and observer-baseline tests; see [its validation record](LIBRARY_CHANGES.md#validation).
