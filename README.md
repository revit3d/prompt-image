# PromptImage

An iOS prototype for searching a personal photo library with natural-language descriptions. The first release is intended for Russia, with a Russian interface and Russian and English search.

The current app implements step 2.1: a Russian photo-access explanation, a user-triggered permission request, and separate states for full, limited, denied, and system-restricted access. Users can open iOS Settings to change access; the app refreshes permission when it becomes active again. Photo browsing, indexing, OCR, model inference, and search are future work.

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

`build-for-testing` checks that the test target compiles; it does not exercise app behavior. `PromptImageTests` contains Swift Testing behavioral tests for the permission model: no automatic prompts, permission results, refresh after changes, avoiding repeat prompts, and overlapping requests. They use an injected provider and do not interact with the system permission dialog.

Run the behavioral tests on an installed simulator:

```sh
xcodebuild -project PromptImage.xcodeproj -scheme PromptImage -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test
```

Use `xcrun simctl list devices available` to choose another installed destination if needed. Xcode's **Product → Test** also runs the tests on the selected destination.

## Verify photo permissions on iPhone

1. Build and run. If access has not been requested, the Russian explanation appears without a system prompt. Tap **Продолжить** to request access.
2. Choose selected photos in the system dialog. Confirm the app shows **Доступ к выбранным фотографиям**, without requiring full access.
3. Tap **Изменить доступ** to open the app's iOS Settings. Change the selected photos or allow full access, then return. Full access should show **Полный доступ разрешён**.
4. In Settings, set Photos access to none and return. Confirm **Доступ к фотографиям закрыт** and an **Открыть настройки** button. Reopening the app must not request permission again automatically.
5. Restore access in Settings, return, and confirm the screen updates. Also verify after closing and reopening the app.
6. Where a device policy restricts Photos access, expect **Доступ ограничен системой**, with no repeated request or promise that the app can override the restriction. This state is also covered by the injected-provider tests.

For a fresh first-request test in Simulator, reset only this app's Photos permission:

```sh
xcrun simctl privacy booted reset photos com.revited.promptimage
```

Settings controls selection changes in step 2.1; an in-app limited-library picker is not implemented. The app does not fetch photo assets yet. The permission adapter uses PhotoKit's `.readWrite` access level because PhotoKit provides no read-only level for reading existing images; the app performs no library writes. Both build configurations include a Russian `NSPhotoLibraryUsageDescription` for the system dialog.

## Repository layout

```text
PromptImage.xcodeproj/          Xcode project and shared PromptImage scheme
PromptImage/
  PromptImageApp.swift          SwiftUI app entry point
  ContentView.swift             Photo-permission screen
  PhotoLibrary/                PhotoKit authorization adapter and permission state
  Assets.xcassets/              Bundled app assets
PromptImageTests/
  PromptImageTests.swift        Permission-model behavioral tests
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

The permission UI and photo-authorization model follow these boundaries today; indexing, persistence, and search are not implemented yet.

The evaluation utilities use Python 3.9 or later and its standard library. Run their offline integrity tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -v
```

## Development workflow

Use a focused `codex/` branch, make small commits with simple messages after each validated roadmap step, and open a pull request to `main` after each completed milestone. See [AGENTS.md](AGENTS.md) for the repository workflow.

## Prototype privacy and data handling

The planned prototype processes images on the phone, indexes only locally available photos while the app is open, and combines visual search with Russian and English OCR. It will not require a backend or upload the user's images for inference. The current app requests photo permission only; processing and search are not implemented yet. Permission is re-read from iOS rather than saved as an independent source of truth.

- Keep personal photos, screenshots, evaluation queries and labels, and generated indexes in `PrivateData/` or outside the repository.
- Keep downloaded weights and converted models in `ModelArtifacts/`. A later milestone will provide pinned model versions, license records, and repeatable preparation instructions.
- Do not commit exported signing keys, provisioning profiles, credentials, device backups, or private logs.
- Track project configuration, source code, asset catalogs, and shared schemes. Xcode user settings, build products, and signing exports are ignored.
- The team identifier and bundle identifier in the Xcode project are configuration values; they do not contain the signing private key.
