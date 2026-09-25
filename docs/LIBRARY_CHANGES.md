# Step 4.4: keeping the index current

After **Начать/Продолжить**, the index follows the permitted library for the current app session, including after its queue finishes. New photos are added, edited photos are reprocessed, and removed/hidden/inaccessible photos lose their derived records. **Пауза**, opening an inference diagnostic, starting the separate availability scan, revoking/narrowing access, or a storage/model-setup error disables automatic processing. App relaunch restores progress but requires an explicit start again.

The app still processes one local source at a time in the foreground. It never asks PhotoKit to download an original. Previously cloud-only stages are retried once when enabled indexing returns to the foreground or the user taps Start/Continue. A library notification alone does not reset them, and processing failures remain on explicit **Повторить пропущенные**. Completed stages are preserved. This catches originals downloaded separately in Photos even when asset metadata stays unchanged.

## Reconciliation contract

`PhotoKitLibraryProvider` retains a `PHFetchResult` baseline and forwards value-only `PhotoLibraryChange` notifications. Object-level `assetContentChanged` flags invalidate both CLIP and OCR, including full-text entries, even if dates/dimensions are unchanged. Removed identifiers are invalidated immediately too. Changes lacking incremental detail conservatively request a rebuild of the currently permitted set. Ordinary notifications still trigger a complete permission-aware metadata fetch.

The baseline is initialized by a generation-checked fetch and then advanced by PhotoKit changes. Later metadata fetches do not replace it: installing a fetched after-state could otherwise hide an equal-metadata edit whose notification was delayed. A cancelled/late fetch cannot overwrite newer observer history. Stopping observation resets the baseline.

`PhotoLibraryStore` stops indexing immediately when a refresh begins and publishes only the latest complete fetch. Content notifications also cancel image requests, refresh gallery/viewer identities, clear the temporary availability check, and dismiss an affected viewer so its temporary OCR cannot remain visible. Unchanged notifications preserve those display results.

The coordinator accumulates content invalidations across coalesced fetches and inactive periods. Each identifier/full-rebuild request has a token. Before loading model resources, `pruneStaleRecords` transactionally removes stale rows and their vectors/OCR/FTS entries. Only the tokens included in that successful commit are acknowledged; a newer notification for the same ID survives. Failure or transaction cancellation keeps invalidations pending. `synchronize` then queues new snapshots and invalidates only the stage whose pipeline version changed. Old generation/attempt tickets cannot publish into replacements.

Full metadata reconciliation remains proportional to library size, while expensive inference runs only for pending stages. Unchanged refreshes do not request image sources or recompute completed work. Session update intent is separate from worker activity, so finishing an empty queue does not cause repeated worker runs.

## Rebuild fallback and limits

Use **Подготовка к поиску → ⋯ → Перестроить индекс** if results appear stale after an edit made while the app was closed. Confirming rebuild removes derived results and processes the currently permitted local photos again. It does not modify or delete photos and does not weaken file protection. It may take as long as the initial index.

Normal relaunch reconciliation detects additions, removals, and metadata changes. This prototype does not persist PhotoKit change-history tokens. An edit with identical stored metadata that happens while the app is terminated, or a process termination before an observed invalidation can be committed, can therefore require the explicit rebuild fallback. In-memory notifications are not claimed to survive termination. Persistent change-history integration and faster large-library metadata reconciliation remain possible later improvements.

## Phone checks

1. Index a small selected library and let the queue finish. Add a screenshot in Photos, return, and confirm it is processed without another Start. Existing completed images should not be reprocessed.
2. Crop or annotate an indexed photo, then return. Its old derived results should be replaced. Repeat while the index is busy and while its viewer/OCR sheet is open; the affected viewer should close.
3. Delete a photo, hide one, and change the limited selection while its authorization status remains limited. After refresh, counts and derived rows must reflect only permitted visible images. Revoke all access, then restore a small selection: old data must not reappear.
4. Tap **Пауза**, add/edit a photo, and return. Metadata/status updates may occur, but image processing must wait for **Продолжить**. Reopening the app also requires Start/Continue.
5. Include an iCloud-only image. Finish a run, download that original with Photos, and return while indexing remains enabled. Only previously cloud-only/pending stages should be revisited. A still-cloud-only image stays skipped rather than retrying continuously. Repeat without downloading and with airplane mode.
6. Exercise **Перестроить индекс** and cancel its confirmation once, then confirm it. Original photos must remain intact; completed-stage counts should be rebuilt. If testing a new model/pipeline version, confirm only that stage is invalidated.

## Validation

Run the [focused command](INDEXING.md#automated-validation). The baseline tests model ordering/cancellation/history retention without creating real `PHChange` objects. Library tests inject content notifications, and coordinator/storage tests use synthetic sources and real temporary SQLite databases. They cover equal-metadata edits, repeated notifications, late inference, session updates, pause, foreground cloud rechecks, version-specific invalidation, pruning with unavailable models, transaction rollback, and rebuilds. The existing integration test still exercises real CLIP/Vision inference and SQLite using generated images.

These checks do not establish actual PhotoKit notification timing or iCloud download/cache behavior. The manual checks above, lock/protection timing, and sustained memory/battery measurements on a large personal library remain device validation tasks.

Validated on 2026-09-26 with Xcode 27.0 in Release: all 118 tests in the ten-suite focused selection passed on both the iPhone 18 Pro / iOS 27.0 simulator and the paired physical iPhone, with no skipped tests. Both runs executed the synthetic real-CLIP/Vision/SQLite integration test alongside the library-change and lifecycle cases.
