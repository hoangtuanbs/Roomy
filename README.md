<p align="center"><img src="Resources/AppIcon-1024.png" width="160" alt="Roomy icon"></p>

# Roomy

A macOS app that shows what is using space on your disk and helps you free it up safely.

![Roomy main view](docs/screenshot.png)

*Folders sorted by size on the left and a treemap of the same folder on the right, with two items ticked for cleanup.*

- **Scan** your home folder, any folder or a whole disk. Folders are read in parallel and hard links are counted once.
- **See** it as a list, a list of the biggest files (filter by kind and age) or a treemap.
- **See it as rings**: switch the map between **Treemap** and **Rings**. The rings chart shows four levels around the
  open folder, each item's angle by its size and coloured like the treemap; hover for its name and size, click a folder
  to zoom in and click the centre to go up.
- **Quick Look**: select an item in a list, the treemap or the rings and press Space (or ⌘Y). The arrow keys move the
  preview through the list.
- **Collect** items in the **tray** at the bottom of the window: drag them there from any list, the treemap or the
  rings, choose **Add to Tray** in the context menu, or tick them. The tray shows each item with its size and the total,
  and **Review and Clean…** moves them to the Trash after you review them, so Put Back still works.
- **Fast reopening**: each scan is cached in `~/Library/Caches/io.github.hoangtuanbs.Roomy/Scans`, so the last scan of
  a folder shows at once, with a "Scanned 2 hours ago · Rescan" note, while a fresh scan runs behind it. **Rescan This
  Folder** in the context menu scans just that folder again and updates the totals around it.
- **Smart Clean** (top of the sidebar, the toolbar, or ⇧⌘K) finds junk that is safe to remove: app caches, logs,
  Xcode build data, device support files and simulator caches, package manager caches (npm, Yarn, pnpm, pip, Homebrew,
  CocoaPods, Gradle, Cargo) and installers in Downloads older than 30 days. Xcode archives, simulators unused for
  6 months and `node_modules` folders untouched for 30 days in the scanned folder are listed too, but start unticked
  so you can review them. Each card says what the files are and what happens if you remove them; open a card to untick
  single items. **Clean** moves the ticked items to the Trash. Caches of macOS and of apps that are open are left alone.
  The Trash is shown on its own card, and emptying it, the one thing that cannot be undone, asks first.
- **Disk overview** above the results shows where the disk's space goes, like DaisyDisk: a bar with what the scan
  found, **hidden** space (used, but not found: files Roomy cannot read without Full Disk Access, macOS system files and
  snapshots), **purgeable** space (local snapshots, iCloud files and caches macOS frees on its own) and free space.
  Click a part to learn what it is. It also lists the disk's **local snapshots** with their dates; a Time Machine
  snapshot can be deleted after a confirmation (`tmutil deletelocalsnapshots`, no admin rights). **Free Purgeable
  Space…** asks Time Machine to thin its snapshots (`tmutil thinlocalsnapshots`), or open Storage Settings instead.
  Neither can be undone, so both ask first.
- **Duplicates** (below Smart Clean in the sidebar, the toolbar, or ⇧⌘D) finds identical files of 1 MB or more in
  the current scan, or in a folder you choose. Files of the same size are compared by their first and last 64 KB, and
  only those that still match are read in full (SHA-256). Hard links, symbolic links, empty files, packages such as
  apps and Photos libraries, Git folders and protected places are left out. Each set of copies is a card, largest
  waste first, with thumbnails; one copy is kept (the oldest one with the plainest path, not one in Downloads or the
  Trash or named like "photo copy.jpg"), and you can pick another with its **Keep** button. **Move Duplicates to
  Trash** moves the rest to the Trash, never every copy.
- **Uninstaller** (below Duplicates in the sidebar, the toolbar, or ⇧⌘U) lists the apps in `/Applications` and
  `~/Applications` with their icons, sizes and when you last used them; search them and sort by size, name or last
  use. Choose an app to see its bundle and the files it left in your Library, grouped (app data, caches, settings,
  saved window state, sandbox and shared containers, web storage, WebKit data, cookies, logs and launch agents).
  Only items named exactly by the app's bundle identifier or exact name count, never another app's files or a name
  shared by a maker's apps. Items named by a longer, related identifier (such as `com.google.Chrome.canary` for Chrome)
  may belong to another app, so they start unticked with a **Review first** badge. **Uninstall** moves the ticked
  items to the Trash. Apps of macOS are not listed, and an app
  that is open has to be quit first. Apps from the App Store or installed for all users may need an administrator;
  Roomy says so and never asks for one. **Leftovers of removed apps** lists Library items named after apps that are
  no longer installed. They are guesses, so nothing there is ticked until you review it.
- **Menu bar** (on by default, turn it off in Settings, ⌘,): an icon in the menu bar shows the startup disk and any
  external disks with a bar for how full they are and their free space, refreshed every minute and when you open it.
  **Open Roomy**, **Smart Clean…** and **Quit** are a click away. Roomy keeps running in the menu bar after its window closes.
- **Low-space alert** (Settings): when the startup disk has less than 10 GB free (you choose 5 to 100 GB), Roomy sends one
  notification a day, "Your disk is almost full". Clicking it opens Roomy. Roomy asks for notification permission only
  when you turn the alert on, and it does nothing if you say no.
- **Export as CSV…** (File menu, ⇧⌘E, or the toolbar's CSV button) saves the current folder as a CSV file: path, name,
  kind, category, size in bytes and as text, modified date (ISO 8601) and item count for folders. Choose to include the
  folders inside it down to 2, 3 or 5 levels.
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

`build/Roomy.app/Contents/MacOS/Roomy --scan <folder>` opens Roomy already scanning a folder. Adding
`--snapshot <file.png>` saves the window as an image and quits, which is how `docs/screenshot.png` is made.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/RoomyCore` | Scanner, scan tree, safety policy, cleanup, compression, the Smart Clean junk finder, the low-space alert rule and CSV export. No UI. |
| `Tests/RoomyCoreTests` | Unit tests, run with `swift test`. They only use temporary folders. |
| `Sources/Roomy` | The SwiftUI app. |
| `Sources/roomy-scan` | Command-line scanner. |
| `scripts/build-app.sh` | Builds and signs the app bundle. |
| `scripts/make-icon.swift` | Draws the app icon and writes `Resources/AppIcon.icns`. |
| `.github/workflows` | Build on every push, and versioned releases. |

## Help

Choose **Help → Email Us…** in the app, or write to [hoangtuanbs@proton.me](mailto:hoangtuanbs@proton.me).
Bugs and ideas are also welcome as [GitHub issues](https://github.com/hoangtuanbs/Roomy/issues).

## Support the project

Roomy is free. If it helped you, you can donate in Ethereum (also in the app under **Help → Donate…**):

<img src="docs/donate-qr.png" width="180" alt="QR code for the Ethereum donation address">

`0xF8352b493e7750C03bde4bdA94A203B010933735`

Ethereum (ETH) address. Please double-check the address in your wallet before sending.

## License

MIT, see [LICENSE](LICENSE).

## Author

- hoangtuanbs
- DanaExperts Co. Ltd.
- DanaExperts Finland Oy
