# PromptImage

An iOS prototype for searching a personal photo library with natural-language descriptions. The first release is intended for Russia, with a Russian interface and Russian and English search.

The current app implements milestone 2: a Russian photo-permission flow, a grid of permitted photos ordered newest first, a full-screen still-image viewer, and a foreground check of local image-data availability. Users can open iOS Settings to change access. The gallery refreshes when the library changes or the app becomes active again. Steps 3.1–3.2 add repeatable CLIP preparation, preprocessing, and local embeddings with independent Python-reference tests. Step 3.3 adds a **Язык поиска** screen and bundled Russian-to-English translation before query encoding. Step 3.4 connects these models in **Тест поиска**, a minimal interface that searches a separately copied public sample using an in-memory index. Indexing the user's Photos library, persistent storage, and OCR remain future work.

Step 1.3 adds a local evaluation dataset and bilingual query protocol. See [the evaluation guide](docs/EVALUATION.md) for the public sample, development/holdout split, and coverage limitations. Dataset images, annotations, and query labels stay under the Git-ignored `PrivateData/Evaluation/` directory.

## Requirements

- Xcode 27 with its iOS platform support, selected as the active developer environment.
- An installed iOS Simulator runtime to launch the app in Simulator.
- For phone testing: a paired iPhone with Developer Mode enabled and an Apple Account configured in Xcode. The initial test device is an iPhone 17 Pro.
- Russian query translation uses bundled Core ML models and supports the existing iOS 17 deployment target. It is independent of device region/system language, Apple Intelligence, and Apple language packs. See [translation preparation and limits](docs/TRANSLATION.md).
- For model preparation: a native Apple Silicon Mac, Python 3.11, and network access for initial dependency/model downloads. Subsequent app builds and model loading use local artifacts.

The project retains the working signing and deployment settings from the first successful device run. The app's deployment target currently uses Xcode's `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)` setting; a fixed minimum iOS version has not been chosen yet.

## Open and run

On a fresh checkout, prepare the models first using the commands below. They are required resources for every Xcode build.

1. Open `PromptImage.xcodeproj` in the repository root. If Xcode still has the earlier nested project open, close that window and reopen this root project after the move.
2. Select the shared **PromptImage** scheme.
3. Choose an installed iPhone simulator or your paired physical iPhone in the run destination selector.
4. For a physical phone, open the app target's **Signing & Capabilities**, keep **Automatically manage signing** enabled, and select your team. The existing bundle identifier is `com.revited.promptimage`; another developer may need a unique identifier for their own team.
5. Press **⌘R** to build and run.

## Prepare the model bundle

Run from the repository root:

```sh
/opt/homebrew/bin/python3.11 -m venv ModelArtifacts/.venv
ModelArtifacts/.venv/bin/python -m pip install -r tools/models/requirements.txt
ModelArtifacts/.venv/bin/python tools/prepare_clip.py prepare
```

The tool downloads pinned, checksum-verified CLIP source and weights, exports Core ML encoders using mostly FP16 with a Float32 image convolution, and publishes the bundle only after conversion checks pass. All downloaded/generated files stay in Git-ignored `ModelArtifacts/`. Xcode compiles the explicitly referenced model packages and bundles the tokenizer, manifest, and license; it does not download models during a build. Missing model artifacts are a build error.

Repeating `prepare` reuses a matching bundle. `prepare --offline` requires cached downloads; `prepare --rebuild --offline` explicitly rebuilds after preparation-code or dependency changes. Run `python3 tools/prepare_clip.py verify` for a dependency-free integrity check without inference. See [the model guide](docs/MODELS.md) for requirements, tensor/preprocessing contracts, provenance, failure recovery, and validation limits.

Prepare the bundled translator and native tokenizer runtime before building the app too:

```sh
ModelArtifacts/.venv/bin/python -m pip install -r tools/models/translation-requirements.txt cmake==3.31.6
ModelArtifacts/.venv/bin/python tools/prepare_translation.py prepare
ModelArtifacts/.venv/bin/python tools/prepare_sentencepiece.py
```

This adds approximately 211 MiB of prepared translation resources. The models ship inside the app; users do not download separate language packs. See [TRANSLATION.md](docs/TRANSLATION.md) for pinned provenance, licenses, offline rebuilding, generation limits, and phone measurements.

## Build verification

Prepare the model bundle before running these commands from the repository root. They compile for Simulator without development signing; the generic destination does not launch a simulator.

Before **test builds or test runs**, generate the independent reference fixtures too:

```sh
ModelArtifacts/.venv/bin/python tools/prepare_clip_validation.py prepare --offline
```

These synthetic fixtures belong only to the test target. See [the inference guide](docs/INFERENCE.md) for preprocessing contracts, Mac comparisons, iPhone benchmarking, and format limits.

Debug app build:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Release app build:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Compile the unit-test target and its app host:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
```

`build-for-testing` checks that the test target compiles; it does not exercise app behavior. `PromptImageTests` contains Swift Testing behavioral tests for permissions, gallery refreshes and selection, image-request lifetimes, and local availability. They cover revocation during a fetch or availability check, changes to limited access, coalesced refreshes, deleted/edited photos, cancellation, stale callbacks, synchronous responses, no-network request options, degraded/empty/error responses, timeouts, serial scanning, and foreground pause/resume. These tests use injected providers; they do not exercise real iCloud storage behavior, PhotoKit image decoding, or the system permission dialog.

The model tests verify resources and tensor interfaces, exact token IDs, orientation/cropping/normalization, normalized embeddings, cancellation/unloading, and agreement with independent Python references. A separate benchmark reports inference time and sampled process memory; run it alone in Release on the physical iPhone for useful numbers. Debug preprocessing of the large fixture is substantially slower. These checks do not measure retrieval quality.

Query tests cover language routing, English bypass, translation failure and missing-model states, cancellation, and stale results. Simulator tests also run the real bundled translation model against independent Python outputs. The [physical-device benchmark](docs/TRANSLATION.md#validate-and-try-the-app) checks accelerated inference and records timing/memory; compilation alone does not establish those results.

Retrieval tests cover cosine ranking, model compatibility, deterministic ties, corpus integrity, cancellation, and screen-state lifetimes. A separate [development retrieval evaluation](docs/RETRIEVAL.md#run-the-development-evaluation) runs the real models over the manually transferred sample. It is enabled only when the sample exists in the app's data container; a skipped test is not retrieval validation.

Run the behavioral tests on an installed simulator using Release optimization for the large image fixtures. `ENABLE_TESTABILITY=YES` enables the test target's imports:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Release -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -parallel-testing-enabled NO test
```

Use `xcrun simctl list devices available` to choose another installed destination if needed. Xcode's **Product → Test** also runs the tests on the selected destination.

## Verify Russian query setup

Open **Язык поиска** inside the app, from the gallery's **Поиск** menu or the initial permission screen. Translation is ready from the bundled model without a separate setup/download. Enter a Russian description, then an English one, and use **Проверить описание** to run local query encoding. This diagnostic screen displays the English processing text. Short or mixed-language descriptions can use an explicit language choice.

See [TRANSLATION.md](docs/TRANSLATION.md) for offline checks, tests under another system language/region, and comparison against manually written English descriptions. Queries never download models or fall back to a server. No Apple Translation session or regional setting is involved.

## Try semantic search on the development sample

Prepare and verify the exact frozen public corpus:

```sh
python3 tools/prepare_retrieval_demo.py prepare
python3 tools/prepare_retrieval_demo.py verify
```

Follow [RETRIEVAL.md](docs/RETRIEVAL.md) to copy `PrivateData/RetrievalDemo/` into the installed app's data container while the app is closed. Open **Тест поиска**, tap **Подготовить 400 изображений**, enter a Russian/English description, and tap **Найти изображения**. The screen shows the ten closest sample images; tapping one opens a larger view. It is available before granting Photos permission because this development sample is separate from the photo library.

The demo uses an in-memory index, prepared again after reopening its screen. The copied images are outside the app bundle and never imported into Photos. The guide includes the isolated device evaluation and scoring commands for 28 development visual queries; held-out and OCR evaluation remain separate.

## Verify photo permissions on iPhone

1. Build and run. If access has not been requested, the Russian explanation appears without a system prompt. Tap **Продолжить** to request access.
2. Choose selected photos in the system dialog. Confirm the app shows **Доступ к выбранным фотографиям**, without requiring full access.
3. In the gallery, tap **Доступ**, then **Изменить доступ** to open the app's iOS Settings. Change the selected photos or allow full access, then return. Full access should show **Полный доступ разрешён**.
4. In Settings, set Photos access to none and return. Confirm **Доступ к фотографиям закрыт** and an **Открыть настройки** button. Reopening the app must not request permission again automatically.
5. Restore access in Settings, return, and confirm the screen updates. Also verify after closing and reopening the app.
6. Where a device policy restricts Photos access, expect **Доступ ограничен системой**, with no repeated request or promise that the app can override the restriction. This state is also covered by the injected-provider tests.

For a fresh first-request test in Simulator, reset only this app's Photos permission:

```sh
xcrun simctl privacy booted reset photos com.revited.promptimage
```

Settings controls selection changes; an in-app limited-library picker is not implemented. `Configuration/Info.plist` suppresses PhotoKit's automatic limited-selection reminder so browsing does not cause an unsolicited picker. The permission adapter uses PhotoKit's `.readWrite` access level because PhotoKit provides no read-only level for reading existing images; the app performs no library writes. Both build configurations include a Russian `NSPhotoLibraryUsageDescription` for the system dialog.

## Verify photo browsing on iPhone

1. With full access, confirm the grid shows recent photos and screenshots first. Videos and hidden photos are excluded. Live Photos appear as still images.
2. Scroll quickly in both directions through a large library. Thumbnails should fill without showing another cell's photo, and scrolling should remain responsive. Off-screen requests are cancelled and the views release their decoded images.
3. Tap portrait and landscape images, then rotate the phone. The full-screen viewer should preserve image proportions; **Закрыть** returns to the existing grid position. This step does not yet add zoom, video playback, or swiping between photos.
4. Use **Доступ → Изменить доступ** to grant limited access. Confirm only the selected photos remain. Change that selection while keeping limited access, then return and confirm the grid refreshes. An empty selection shows guidance instead of an empty grid.
5. While the viewer is open, switch to Photos or Settings and remove the displayed photo or revoke its permission. Return: the viewer should close if its photo is no longer available. Restore access and check that browsing works again. Edit a photo in Photos and confirm the app refreshes its image.
6. Check a photo whose larger image is only in iCloud. A cached thumbnail may appear, but the viewer must show an unavailable/cloud message if it cannot obtain the larger image locally. It must not start a download. Open the photo in Apple's Photos app to download it, then use **Повторить** in the viewer.

The grid count is the number of permitted image assets reported by PhotoKit, including assets whose image data may only be in iCloud. The separate **Доступность на iPhone** check reports source-data availability across those permitted photos. It does not hide skipped photos from the gallery.

The app fetches metadata off the main thread and decodes images only for visible views. Thumbnails and the viewer use their display size in pixels, rather than original-size image requests. Every PhotoKit image request explicitly disables network access. A local thumbnail is not evidence that the full image is available for later indexing.

## Verify local availability on iPhone

1. Start with a limited selection containing a recent local photo, a screenshot, a Live Photo, and an older iCloud-optimized photo if available. In **Доступность на iPhone**, tap **Проверить**. Browsing alone must not start a source-data scan.
2. Watch **Проверено**, **На iPhone**, **Пропущено**, and **Не проверено**. Checked equals local + requires-download + failed; checked + unchecked equals the permitted photo count. Skipped equals requires-download + failed. A cached thumbnail must not turn an iCloud-only source into a local result. Tile badges show a checkmark, cloud, or warning for completed checks.
3. Tap **Пауза**, browse some photos, and tap **Продолжить**. Finished results remain; the interrupted photo is checked again. Switch to another app or lock the phone during a scan: it pauses and resumes when active again. A manually paused scan must remain paused after returning.
4. Change the limited selection, delete/edit a photo, or revoke access while scanning. Removed/edited results must be discarded, counts must follow the current library, and revocation must clear the check and cancel its request. Narrowing full access to limited access also clears the check; tap **Проверить** again for the new selection.
5. Complete the scan, open an iCloud-only photo in Apple's Photos app to download its full image data, return, and tap **Перепроверить**. Its status may now become local. Rechecking is explicit because downloads or cache eviction need not change photo metadata.
6. Repeat with airplane mode enabled. Local data should remain readable, while photos requiring downloads remain skipped. If available, include edited images and a large ProRAW image and observe responsiveness/memory; Simulator tests do not substitute for these device checks.

Availability checks use [`requestImageDataAndOrientation`](https://developer.apple.com/documentation/photos/phimagemanager/requestimagedataandorientation(for:options:resulthandler:)) with `.current`, asynchronous delivery, and `isNetworkAccessAllowed = false`. This requests the largest current representation, including edits, rather than a thumbnail. A successful nonempty, non-degraded response with no error counts as local. An explicit iCloud/network-required result is skipped; other errors, missing/empty data, degraded responses, and a 30-second timeout count as failed checks rather than being assumed to be cloud-only.

Only one source-data request is active at a time. The app reads the compressed data only to check its presence, then discards it without decoding, saving, or logging it. This limits concurrency, not the absolute byte size of one large asset. The scan retains IDs/statuses in memory for the current app session; it is not a persistent index and does not prove successful OCR/model decoding. Availability can change after a check and must be checked again when later processing begins. An initiated scan picks up added or edited photos while active; manual pause disables automatic continuation.

## Repository layout

```text
PromptImage.xcodeproj/          Xcode project and shared PromptImage scheme
PromptImage/
  PromptImageApp.swift          SwiftUI app entry point
  ContentView.swift             Permission and gallery routing
  PhotoLibrary/                Authorization, gallery, image requests, and availability checks
  Models/                      CLIP resources, preprocessing, tokenization, and embeddings
  Query/                       Language setup, local translation, and query embeddings
  Retrieval/                   In-memory sample index, ranking, and test-search interface
  Assets.xcassets/              Bundled app assets
Configuration/Info.plist        Typed PhotoKit privacy configuration
PromptImageTests/
  *.swift                      Permission, gallery, image-loader, and availability tests
docs/EVALUATION.md              Dataset preparation and evaluation protocol
docs/MODELS.md                  Pinned CLIP preparation and tensor contracts
docs/INFERENCE.md               Swift inference validation and phone benchmarking
docs/TRANSLATION.md             Russian query setup and translation validation
docs/RETRIEVAL.md               Development sample transfer, search, and evaluation
tools/                         Dataset utilities and model/runtime preparation
PrivateData/                   Local-only sample photos, labels, and indexes
ModelArtifacts/                Local-only downloaded and converted models
build/                         Local build products and results
```

`PrivateData`, `ModelArtifacts`, and `build` are ignored by Git and are created only when needed. Keep private data and model artifacts outside the synchronized `PromptImage/` source directory. Xcode includes only the explicitly referenced CLIP/translation resources and SentencePiece runtime; download caches and the Python environment are excluded. Reference fixtures belong only to the test target.

As features are added, keep these responsibilities separate within the app:

- **UI:** screens, user actions, and presentation state.
- **Photo library:** PhotoKit permissions, asset access, and library changes.
- **Indexing:** resumable work scheduling and coordination of image embeddings and OCR.
- **Persistence:** the local index, processing status, and model versions.
- **Search:** query processing and ranking visual and OCR matches.

The permission and gallery UI, PhotoKit providers, availability scan, and observable models follow these boundaries today. Sample retrieval adds separate ranking, corpus loading, and screen-state coordination; persistent photo-library indexing and combined OCR search remain later work.

The evaluation utilities use Python 3.9 or later and its standard library. Run their offline integrity tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -v
```

## Development workflow

Use a focused `codex/` branch, make small commits with simple messages after each validated roadmap step, and open a pull request to `main` after each completed milestone. See [AGENTS.md](AGENTS.md) for the repository workflow.

## Prototype privacy and data handling

The planned prototype processes images on the phone, indexes only locally available photos while the app is open, and combines visual search with Russian and English OCR. It will not require a backend or upload the user's images for inference. The current app browses permitted photos and checks local source availability without uploading, downloading from iCloud, or modifying them. **Тест поиска** searches a separately copied public sample with local models; personal-library indexing and OCR are not implemented yet. Permission is re-read from iOS rather than saved as an independent source of truth. Revocation clears the gallery, viewer, and availability results and cancels pending requests.

- Keep personal photos, screenshots, evaluation queries and labels, and generated indexes in `PrivateData/` or outside the repository.
- Keep downloaded weights and converted models in `ModelArtifacts/`. Step 3.1 provides pinned versions, license records, checksums, and [repeatable preparation instructions](docs/MODELS.md). Model preparation never reads private evaluation photos or the photo library.
- Do not commit exported signing keys, provisioning profiles, credentials, device backups, or private logs.
- Track project configuration, source code, asset catalogs, and shared schemes. Xcode user settings, build products, and signing exports are ignored.
- The team identifier and bundle identifier in the Xcode project are configuration values; they do not contain the signing private key.
