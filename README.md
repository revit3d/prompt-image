# PromptImage

An iOS prototype for searching a personal photo library with natural-language descriptions. The first release is intended for Russia, with a Russian interface and Russian and English search.

The current app implements steps 2.1–2.2: a Russian photo-permission flow, a grid of permitted photos ordered newest first, and a full-screen still-image viewer. Users can open iOS Settings to change access. The gallery refreshes when the library changes or the app becomes active again. Indexing, OCR, model inference, and search are future work.

Step 1.3 adds a local evaluation dataset and bilingual query protocol. See [the evaluation guide](docs/EVALUATION.md) for the public sample, development/holdout split, and coverage limitations. Dataset images, annotations, and query labels stay under the Git-ignored `PrivateData/Evaluation/` directory.

## Requirements

- Xcode 27 with its iOS platform support, selected as the active developer environment.
- An installed iOS Simulator runtime to launch the app in Simulator.
- For phone testing: a paired iPhone with Developer Mode enabled and an Apple Account configured in Xcode. The initial test device is an iPhone 17 Pro.

The project retains the working signing and deployment settings from the first successful device run. The app's deployment target currently uses Xcode's `$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)` setting; a fixed minimum iOS version has not been chosen yet.

## Open and run

1. Open `PromptImage.xcodeproj` in the repository root. If Xcode still has the earlier nested project open, close that window and reopen this root project after the move.
2. Select the shared **PromptImage** scheme.
3. Choose an installed iPhone simulator or your paired physical iPhone in the run destination selector.
4. For a physical phone, open the app target's **Signing & Capabilities**, keep **Automatically manage signing** enabled, and select your team. The existing bundle identifier is `com.revited.promptimage`; another developer may need a unique identifier for their own team.
5. Press **⌘R** to build and run.

## Build verification

Run these commands from the repository root. They compile for Simulator without development signing; the generic destination does not launch a simulator.

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

`build-for-testing` checks that the test target compiles; it does not exercise app behavior. `PromptImageTests` contains Swift Testing behavioral tests for permissions, gallery refreshes and selection, and image-request lifetimes. They cover revocation during a fetch, changes to limited access, coalesced refreshes, deleted/edited photos, cancellation, stale callbacks, and synchronous image responses. These tests use injected providers; they do not exercise real PhotoKit image decoding or the system permission dialog.

Run the behavioral tests on an installed simulator:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test
```

Use `xcrun simctl list devices available` to choose another installed destination if needed. Xcode's **Product → Test** also runs the tests on the selected destination.

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

The grid count is the number of permitted image assets reported by PhotoKit, including assets whose image data may only be in iCloud. It is not a local-image or indexing count. Step 2.3 will address library-wide local availability and skipped-photo reporting.

The app fetches metadata off the main thread and decodes images only for visible views. Thumbnails and the viewer use their display size in pixels, rather than original-size image requests. Every PhotoKit image request explicitly disables network access. A local thumbnail is not evidence that the full image is available for later indexing.

## Repository layout

```text
PromptImage.xcodeproj/          Xcode project and shared PromptImage scheme
PromptImage/
  PromptImageApp.swift          SwiftUI app entry point
  ContentView.swift             Permission and gallery routing
  PhotoLibrary/                Authorization, metadata, image requests, grid, and viewer
  Assets.xcassets/              Bundled app assets
Configuration/Info.plist        Typed PhotoKit privacy configuration
PromptImageTests/
  *.swift                      Permission, gallery, and image-loader tests
docs/EVALUATION.md              Dataset preparation and evaluation protocol
tools/                         Dataset download, inventory, and validation utilities
PrivateData/                   Local-only sample photos, labels, and indexes
ModelArtifacts/                Local-only downloaded and converted models
build/                         Local build products and results
```

`PrivateData`, `ModelArtifacts`, and `build` are ignored by Git and are created only when needed. Keep private data and model artifacts outside the synchronized `PromptImage/` source directory so Xcode does not accidentally bundle them.

As features are added, keep these responsibilities separate within the app:

- **UI:** screens, user actions, and presentation state.
- **Photo library:** PhotoKit permissions, asset access, and library changes.
- **Indexing:** resumable work scheduling and coordination of image embeddings and OCR.
- **Persistence:** the local index, processing status, and model versions.
- **Search:** query processing and ranking visual and OCR matches.

The permission and gallery UI, PhotoKit providers, and observable models follow these boundaries today; indexing, persistence, and search are not implemented yet.

The evaluation utilities use Python 3.9 or later and its standard library. Run their offline integrity tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -v
```

## Development workflow

Use a focused `codex/` branch, make small commits with simple messages after each validated roadmap step, and open a pull request to `main` after each completed milestone. See [AGENTS.md](AGENTS.md) for the repository workflow.

## Prototype privacy and data handling

The planned prototype processes images on the phone, indexes only locally available photos while the app is open, and combines visual search with Russian and English OCR. It will not require a backend or upload the user's images for inference. The current app browses permitted photos without uploading or modifying them; processing and search are not implemented yet. Permission is re-read from iOS rather than saved as an independent source of truth. Revocation clears the gallery and viewer and cancels pending image requests.

- Keep personal photos, screenshots, evaluation queries and labels, and generated indexes in `PrivateData/` or outside the repository.
- Keep downloaded weights and converted models in `ModelArtifacts/`. A later milestone will provide pinned model versions, license records, and repeatable preparation instructions.
- Do not commit exported signing keys, provisioning profiles, credentials, device backups, or private logs.
- Track project configuration, source code, asset catalogs, and shared schemes. Xcode user settings, build products, and signing exports are ignored.
- The team identifier and bundle identifier in the Xcode project are configuration values; they do not contain the signing private key.
