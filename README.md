# PromptImage

An iOS prototype for searching a personal photo library with natural-language descriptions. The first release is intended for Russia, with a Russian interface and Russian and English search.

The current app displays Hello World. Step 1.2 establishes the repository layout, shared Xcode scheme, and a Swift Testing unit-test target. Photo access, indexing, OCR, model inference, and search are future work.

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

`PromptImageTests` currently imports Swift Testing and the app module, but contains no behavioral tests. `build-for-testing` checks that the test target compiles; it does not exercise app behavior. Add focused tests as features gain meaningful behavior. Running those tests will require a specific installed simulator or physical device instead of the generic destination.

## Repository layout

```text
PromptImage.xcodeproj/          Xcode project and shared PromptImage scheme
PromptImage/
  PromptImageApp.swift          SwiftUI app entry point
  ContentView.swift             Initial screen
  Assets.xcassets/              Bundled app assets
PromptImageTests/
  PromptImageTests.swift        Swift Testing target
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

These are implementation boundaries for later milestones, not separate packages or implemented services today.

## Development workflow

Use a focused `codex/` branch, make small commits with simple messages after each validated roadmap step, and open a pull request to `main` after each completed milestone. See [AGENTS.md](AGENTS.md) for the repository workflow.

## Prototype privacy and data handling

The planned prototype processes images on the phone, indexes only locally available photos while the app is open, and combines visual search with Russian and English OCR. It will not require a backend or upload the user's images for inference. These capabilities are not implemented yet.

- Keep personal photos, screenshots, evaluation queries and labels, and generated indexes in `PrivateData/` or outside the repository.
- Keep downloaded weights and converted models in `ModelArtifacts/`. A later milestone will provide pinned model versions, license records, and repeatable preparation instructions.
- Do not commit exported signing keys, provisioning profiles, credentials, device backups, or private logs.
- Track project configuration, source code, asset catalogs, and shared schemes. Xcode user settings, build products, and signing exports are ignored.
- The team identifier and bundle identifier in the Xcode project are configuration values; they do not contain the signing private key.
