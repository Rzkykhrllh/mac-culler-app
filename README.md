# PhotoCuller

A native macOS app for **culling photos fast**: open a folder, review images (including RAW), mark them
(flag / rating / color label / note), filter and sort, compare shots side by side, then rename / move / copy.
It is a culling tool, not a photo manager or editor. The full spec is in [docs/SPEC.md](docs/SPEC.md).

- macOS 14+, Swift 6, SwiftUI + AppKit (`NSCollectionView` grid, `NSScrollView` zoom views)
- ImageIO / Core Image only (no LibRaw); GRDB.swift is the only dependency
- App Sandbox on (user-selected read/write + app-scoped bookmarks)

## Build & run

```bash
brew install xcodegen      # only needed if you change project.yml
xcodegen generate          # regenerates PhotoCuller.xcodeproj (committed, so optional)
open PhotoCuller.xcodeproj # ⌘R to run, ⌘U to run the tests
```

From the command line:

```bash
xcodebuild -project PhotoCuller.xcodeproj -scheme PhotoCuller -derivedDataPath build/DD build
cd Packages/CullerKit && swift test
```

The app is signed to run locally (ad-hoc). For Mac App Store / Developer ID distribution set a team and
signing identity in `project.yml`.

## Layout

```
PhotoCuller/                 App target
  App/                       entry point, menus, keyboard routing, app-wide services
  Model/                     FolderSession (items, stacks, display list, marking, undo, file ops), settings
  Features/                  Grid, Loupe, Compare, Filter, Info, Rename, MoveCopy, Settings, History
  Shared/                    key map (single table of shortcuts), formatting, logging
Packages/CullerKit/          Core library, fully unit-tested (`swift test`)
  Constants.swift            app name, bundle ID, XMP namespace: rename the app here (+ project.yml)
  Model/                     FileRef/ItemFiles, PhotoMetadata, ExifInfo, FilterState, SortOrder
  Services/                  FolderScanner, StackBuilder, ExifReader, XMPCodec, MetadataStore,
                             MetadataWriteQueue, IndexStore (GRDB), ImageDecoder/ImagePipeline,
                             RenameTemplate, FileOperations, OperationLog, Bookmarks, FolderWatcher
```

## How marks are stored

| Field | Where |
|---|---|
| Rating | `xmp:Rating` |
| Color label | `xmp:Label` (`Red`, `Yellow`, `Green`, `Blue`, `Purple`) |
| Flag | `culler:Flag` = `pick` / `reject` |
| Note | `culler:Note` |

- JPEG / HEIC / TIFF: embedded XMP, written with `CGImageDestinationCopyImageSource`, so pixels are never re-encoded.
- RAW (incl. **DNG**) and PNG: `<basename>.xmp` sidecar. ImageIO cannot write DNG (it is not in
  `CGImageDestinationCopyTypeIdentifiers()`), which settles spec open item §17.
- RAW+JPEG pairs: the sidecar and the JPEG's embedded XMP are kept in sync.
- Every write is merge-only (other tools' XMP is preserved), atomic (temp file + replace) and debounced
  in a background queue. A compact JSON backup goes into the `com.byairu.photoculler.meta` xattr; a
  missing RAW sidecar is regenerated from it when the folder is reopened.
- Two ImageIO quirks are handled: `kCFNull` tag removal is ignored for HEIC/TIFF (clears are written as
  empty values instead), and ImageIO cannot parse an XMP packet with no properties (written by hand
  and recognized with an XML parser).

## Folders, tabs, RAW+JPEG modes, selection

- **Finder-like sidebar**: Favorites (Home, Desktop, Documents, Downloads, Pictures), pinned folders and
  Locations (internal / external / SD-card volumes). Every folder expands lazily with a photo count.
  The sandbox only lets the app read what you granted: a locked folder asks once (“Grant Access”, opened
  right at that folder) and the security-scoped bookmark is kept, so everything below it is browsable from then on.
  A path bar above the photos shows where you are and the subfolders of the current folder.
- **Tabs** like a web browser (⌘T, ⌘W, ⇧⌘T, ⌃Tab, ⌘1–9, ⌘-click a folder): each tab keeps its own folder,
  selection, filters, view mode and compare state; tabs are restored on the next launch.
- **RAW + JPEG** (segmented control above the photos, ⌥⌘1–4): *as one photo* (marks apply to both files),
  *separately*, *JPEG only*, *RAW only*. In the separate modes each file is its own photo.
- **True RAW vs camera preview** (⌥⌘R): RAW files are rendered from the sensor data with Core Image by default,
  so they look different from the camera JPEG (no film simulation). “Camera Preview” uses the JPEG embedded in
  the RAW instead (faster, camera look). In “as one photo” mode the pair shows the JPEG, also at 100%.
- **Stacks: Off · Bursts · Similar** (above the photos; ⇧S on/off, ⌥S bursts ↔ similar). *Bursts* groups frames
  ≤ 1 s apart (spec §4.4). *Similar* groups consecutive photos that look alike using on-device Vision feature prints
  (≈130 photos/s, cached in the index), so a scene shot over several seconds stays together; a strict ↔ loose
  slider (⌥[ / ⌥]) regroups instantly. Different cameras, or photos more than 10 minutes apart, never stack.
- **Selection**: ⇧/⌘-click, drag, ⇧+arrows. `S` expands/collapses every selected stack. Marks apply to the whole selection.
- **Right-click** any photo (grid, filmstrip, loupe, compare) for all photo actions, with their shortcuts shown.
- **Compare**: drag photos from the filmstrip onto the left / right slot; ⌥A switches the filmstrip between the
  candidates and all photos.

## Keyboard

Lightroom-compatible: `P`/`X`/`U` flag, `0`–`5` rating, `6`–`9` labels, `⇧`+key marks and advances,
Caps Lock auto-advance, `←`/`→`, `⌥←`/`⌥→` unflagged, `G`/`E`/`C` views, `Z`/Space 100%, `Tab` compare slot,
`S` stack, `I` info, `H` histogram, `M` note, `⌥9` purple, `⌥0` clear label, `F2` rename, `⌘⇧M`/`⌘⇧C` move/copy.
Every menu command has a shortcut; **Help ▸ Keyboard Shortcuts** (⌘/) lists them all. While typing in a text
field, plain keys go straight to the field, so single-key shortcuts never fire by accident.

## Performance (Apple M2, 820 RAF + 820 JPG, 54 GB)

Measured with the read-only benchmark (`swift run -c release culler-bench <folder>` in `Packages/CullerKit`):

| | |
|---|---|
| Scan 1,640 files → 820 items | 0.1 s |
| EXIF + XMP index (first open; cached afterwards) | 0.7–1.4 s |
| RAW+JPG grid: placeholders / first screen sharp / all 820 | 0.13 s / 1.4 s / 12 s |
| RAW only, camera preview: first screen / all | 0.5 s / 11 s |
| RAW only, True RAW: camera preview shown / first screen True RAW / all | 0.3 s / 11 s / ~3.5 min (background, disk-cached) |
| Loupe preview 2560 px: JPG / RAW camera / True RAW | 170 / 175 / 300 ms (next 3 prefetched) |
| 100% zoom: RAW / JPG | 50 / 330 ms |

The first RAW a process touches costs ≈5 s (ImageIO RAW support) and the first Core Image RAW render ≈7 s;
both are warmed up in the background as soon as a folder opens, and RAW+JPG thumbnails use the JPEG until then.
Pairs take their thumbnail from the RAW's embedded preview (same camera look, ~6× faster than decoding a 26 MP JPEG),
with the 1 ms embedded EXIF thumbnail shown first.

Real-camera-file tests (copied to a temp folder, never modified in place):

```bash
CULLER_REAL_RAW_DIR=/path/to/copy/of/a/shoot swift test --filter RealCameraFileTests
```

Use a copy outside protected folders (Documents, Desktop…): the `xctest` helper has no permission to read them.

Similar-photo grouping on a folder from the command line: `swift run -c release culler-similar <folder>` —
prints the groups found at several thresholds (useful for tuning).

## Development aids (Debug builds only)

```bash
# Opens a folder the sandbox can already read (e.g. inside the app container) and runs an in-app smoke test.
open -n build/DD/Build/Products/Debug/PhotoCuller.app --args \
  -openFolder ~/Library/Containers/com.byairu.photoculler/Data/Documents/TestShoot -selfTest
log stream --predicate 'subsystem == "com.byairu.photoculler"' --level info
```

Note: inside the container, `Data/Pictures` etc. are symlinks to your real folders. Use `Data/Documents`.

The **Debug** menu has an overlay with load times and cache hit rates.

## Before real-world use

Finalize the app name, bundle ID and XMP namespace URI in `Packages/CullerKit/Sources/CullerKit/Constants.swift`
(and `project.yml`). Notes and flags are written into your files under that namespace.
