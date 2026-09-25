# Step 4.1: recognize text in photos

The photo viewer's **Распознать текст** action opens an explicit, single-photo OCR check. It recognizes Russian and English together and displays the original text. It does not translate text, index the library, save results, or change sample-search ranking. Persistent storage and resumable indexing belong to later milestone 4 steps.

## Recognition and image handling

- A separate PhotoKit source provider requests the current image data and orientation with `isNetworkAccessAllowed = false`. A previous availability result or cached display thumbnail is insufficient. Authorization, selection, and asset metadata are checked before requesting and before delivering the bytes. Cloud-only, degraded, empty, erroneous, and timed-out responses are not recognized.
- `PhotoOCREngine` serializes work on its own actor. Apple's [`VNRecognizeTextRequest`](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) uses revision 3, `.accurate`, language correction, explicit `ru-RU` and `en-US`, and zero minimum text height. Both languages must be reported as supported at runtime; there is no server or English-only fallback.
- OCR has its own ImageIO/Core Image preprocessing. It keeps the whole image, uses PhotoKit orientation exactly once (including mirrored orientations), flattens transparency against white, and limits the decoded short edge to 1,600 pixels. It never uses CLIP's 224-pixel center crop.
- Long images retain their aspect ratio and useful text size, subject to the decoded-pixel cap. Recognition runs serially on sections no larger than 2,048 × 2,048 pixels, overlapping by 256 pixels. Detections from overlapping sections are merged using position and text, favoring complete and reliable lines. A detection seen in only one section is retained; repeated text at different positions survives. Bounding boxes map to the upright whole image, normalized with a bottom-left origin.
- The reusable result contains original lines, confidence, normalized bounds, Vision revision, and requested languages. Display text joins lines top-to-bottom. This is not document-layout, table, handwriting, or multi-column reconstruction. Vision revisions can still change behavior between OS releases.

Limits are 64 MiB of encoded input, 100 million source pixels, 65,536 pixels per source dimension, and 24 million decoded pixels. Pixel limits are checked before thumbnail decoding; a decoded image that exceeds the cap is rejected. The decoded-pixel cap can further reduce the short edge on extremely long images. Oversized PhotoKit responses are reported as unavailable; engine dimension/decode limits have a specific error. Unsupported formats fail explicitly.

PhotoKit materializes compressed data before the byte limit can be applied, and ImageIO/Vision have their own temporary allocations. These limits and serial sections constrain work; they do not establish a measured peak-memory guarantee. Very large ProRAW files can be skipped. Recognition of tiny, blurry, stylized, or low-contrast text remains imperfect, and unusually large text crossing a section boundary may be missed.

## Lifetimes and privacy

Recognition starts only after tapping **Начать распознавание**. The source request times out after 30 seconds. Closing the OCR screen, leaving the app, dismissing the photo viewer, or receiving a changed photo snapshot invalidates work and clears displayed text. Deleting the selected photo or removing permission closes its viewer through the existing library refresh flow. Returning to the app does not automatically restart OCR.

Cancellation cancels PhotoKit requests and active Vision requests. Synchronous image decoding or Vision cleanup may take time to return; the screen stays busy until submitted recognition finishes. Generation checks reject late results, and the same viewer cannot start another recognition while cancellation is still completing. Source bytes, lines, and errors containing private content are never written or logged. No clipboard write is automatic; text selection is a user action. Clearing references is not a secure-memory-erasure guarantee.

## Run focused behavioral tests

Prepare the existing model/reference bundles as described in the [README](../README.md). They remain required by the app's test host even though OCR uses the system Vision framework.

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:PromptImageTests/PhotoOCREngineTests \
  -only-testing:PromptImageTests/PhotoOCRLineMergerTests \
  -only-testing:PromptImageTests/PhotoOCRSourceProviderTests \
  -only-testing:PromptImageTests/PhotoOCRStoreTests \
  -only-testing:PromptImageTests/PhotoLibraryStoreTests \
  -only-testing:PromptImageTests/PhotoImageLoaderTests test
```

Real Vision tests use synthetic, high-contrast text drawn in memory. Other tests use injected sources to exercise no-network options, orientation forwarding, bad/cloud/oversized data, changed access/version, request timeout, cancellation, synchronous callbacks, and late results. Compilation alone does not run these checks. These tests do not establish personal-library OCR recall, actual iCloud behavior, battery consumption, or physical-phone peak memory.

Validated on 2026-09-25 with Xcode 27.0 and the iPhone 18 Pro / iOS 27.0 simulator in Release: the app/test bundle built, and all 67 selected behavioral tests in these six suites passed. This includes actual Vision recognition and the existing gallery/image-loader regressions. Phone checks below have not been performed as part of this step.

## Manual phone checks

1. Open a local Russian recipe screenshot, an English screenshot, and a mixed Russian/English image. Run OCR and compare the text with the original, including ingredients, numbers, and punctuation. Add a meme or photographed sign to expose stylized/small-text limits.
2. Try a long screenshot with text near the top, middle, and bottom. Look for missing or duplicated lines at section boundaries. Check a rotated image and an image with no text.
3. Start recognition, then cancel, close the screen, switch apps, or lock the phone. Confirm no late result appears; on returning, explicitly start again. Reopen the OCR screen during cancellation and confirm it waits instead of starting another request.
4. While OCR is visible, edit/delete its photo in Photos or remove its permission/limited selection in Settings. Return and confirm stale text is gone and the viewer follows the refreshed selection.
5. Try an iCloud-only image in airplane mode. A cached preview must not become an OCR source. It should report a required download or unavailable source. Download in Apple's Photos app, return, and explicitly retry.
6. Repeat local-image OCR in airplane mode. Record failures and compare actual text locally; keep screenshots, extracted text, and private annotations outside Git. Use Instruments on the physical iPhone for memory/latency measurements before batch indexing.
