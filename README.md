<p align="center"><img src="Resources/AppIcon-1024.png" width="160" alt="Roomy icon"></p>

# Roomy

A macOS app that shows what is using space on your disk and helps you free it up safely.

- **Scan** your home folder, any folder or a whole disk. Folders are read in parallel and hard links are counted once.
- **See** it as a list, a list of the biggest files (filter by kind and age) or a treemap.
- **Clean up** by ticking items and choosing **Review and Clean…**. Items go to the Trash, so Put Back still works.
- **Compress and Clean…** zips items next to themselves, checks that each zip reads back, and only then moves the originals to the Trash. If an item would shrink by less than 10%, it is left alone.
- **Safety rules** (`Sources/RoomyCore/SafetyPolicy.swift`) block system folders, your home folder, Keychains, iCloud Drive, cloud drives and Photos libraries, and warn about Library, Git repositories and running apps.

## Requirements

macOS 14 or later, and Swift 5.10 or later (Xcode or the Command Line Tools).

## Build

```sh
./scripts/build-app.sh            # builds build/Roomy.app and build/Roomy.zip
./scripts/build-app.sh --install  # also copies it to /Applications
open build/Roomy.app
```

The app is signed for local use only, without a developer certificate. On another Mac, right-click the app and choose **Open** the first time.

For complete sizes, give Roomy Full Disk Access in System Settings → Privacy & Security → Full Disk Access.

There is also a command-line scanner:

```sh
swift run roomy-scan ~ --top 20
```

## Releases

Each push to `main` and each pull request is built by the **Build** workflow; the app zip is attached to the run.

To publish a version, open **Actions → Release → Run workflow** on GitHub and pick `patch`, `minor` or `major`.
The workflow takes the latest `vX.Y.Z` tag, bumps it, stamps the number into the app, builds it and publishes a
GitHub Release with `Roomy-X.Y.Z.zip` and its SHA-256 checksum. Pushing a tag works too:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

Locally, `VERSION=1.0.0 BUILD_NUMBER=7 ./scripts/build-app.sh` builds with a version number.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/RoomyCore` | Scanner, scan tree, safety policy, cleanup and compression. No UI. |
| `Sources/Roomy` | The SwiftUI app. |
| `Sources/roomy-scan` | Command-line scanner. |
| `scripts/build-app.sh` | Builds and signs the app bundle. |
| `scripts/make-icon.swift` | Draws the app icon and writes `Resources/AppIcon.icns`. |
| `.github/workflows` | Build on every push, and versioned releases. |
