# PhotoCuller — Product & Technical Specification (v1)

> Working name: **PhotoCuller** (final name TBD). All user-visible names, the bundle ID and the XMP namespace must come from a single constants file so renaming is a one-line change.

## 1. Overview

A native macOS app for **culling photos fast**: open a folder, review images (including RAW), mark them (flag / rating / color label / comment), filter and sort, compare 2+ shots side by side to pick the keeper, then rename / move / copy files.

It is a **culling tool, not a photo manager or editor**. Speed, keyboard-driven flow and never losing data are the top priorities.

### Primary user
A photographer who shoots a lot of **bursts** and keeps only 1–2 frames per burst, works mainly from the keyboard, and may later bring picks into Lightroom.

### Guiding principles
1. **The UI never waits for disk or decoding.** All heavy work is async/background; always show the fastest available representation (cached thumbnail → embedded preview → full RAW decode).
2. **Never lose or corrupt user data.** Original image pixels are never re-encoded. Metadata writes are merge-only and atomic. No destructive action happens automatically.
3. **Keyboard first.** Every culling action is reachable with a single key (Lightroom-compatible).
4. **Interoperable.** Rating and color label are stored in standard XMP so other apps can read them.

---

## 2. Platform & stack

| Item | Decision |
|---|---|
| Language / UI | Swift, SwiftUI for app structure, panels and settings; **AppKit (via `NSViewRepresentable`) for performance-critical views**: the thumbnail grid (`NSCollectionView`) and zoomable image views (`NSScrollView`-based) |
| State | Swift Observation (`@Observable`), Swift Concurrency (actors, `async/await`) |
| Image I/O | ImageIO (`CGImageSource`, `CGImageDestination`, `CGImageMetadata`) and Core Image (`CIRAWFilter`) — no LibRaw |
| Local index/cache DB | SQLite via **GRDB.swift** (only third-party dependency allowed without asking) |
| Minimum OS | **macOS 14 (Sonoma)** |
| Architecture | **Universal binary** (Apple Silicon primary target; Intel best-effort) |
| Sandbox | **App Sandbox ON from day one** (see §11) |

---

## 3. Supported formats

- **RAW:** everything macOS ImageIO/Core Image supports (CR2, CR3, NEF, ARW, RAF, ORF, RW2, DNG, …). New camera models depend on macOS updates — show a clear "unsupported RAW" placeholder when decoding fails.
- **Raster:** JPEG, HEIC/HEIF, TIFF, PNG.
- Unknown/unsupported files are ignored (not shown).

### Image representation pipeline (per item)
1. **Thumbnail** (~400 px long edge): from disk cache, else generated via `CGImageSourceCreateThumbnailAtIndex` (prefer embedded thumbnail/preview, do not force full decode).
2. **Screen preview** (fit to display): for RAW, use the **embedded full-size JPEG preview**; for raster, a downsampled decode.
3. **Full resolution** (100% zoom only): RAW decoded via `CIRAWFilter`; raster decoded at native size. While decoding, keep showing the preview, then swap in.

---

## 4. Data model

### 4.1 Folder session
- User opens one folder (via `NSOpenPanel`).
- **Include subfolders**: toggle, default **off**. When on and the scan exceeds a threshold (default 5,000 files), warn before continuing.
- Recent folders list (persisted with security-scoped bookmarks).
- No global catalog. The folder on disk is the source of truth.

### 4.2 Item (`PhotoItem`)
A logical photo, made of one or more files:
- `primaryFile` (the file used for display), optional `pairedFiles` (e.g. JPEG paired with RAW), optional `sidecarURL` (`.xmp`).
- Metadata: `flag` (pick / reject / none), `rating` (0–5), `colorLabel` (none / red / yellow / green / blue / purple), `note` (free text).
- EXIF snapshot: capture date+subseconds, camera make/model, body serial (if present), lens, focal length, aperture, shutter, ISO, exposure compensation, dimensions, file size, file modification date.

### 4.3 RAW+JPEG pairing
- Files with the **same base name in the same folder**, one RAW + one raster, form **one item** (default ON, setting: "Treat RAW+JPEG as one photo").
- Display uses the JPEG for speed; 100% zoom decodes the RAW.
- Every metadata change and every file operation applies to **all files of the pair**.
- Edge cases: `IMG_001.CR3` + `IMG_001.JPG` + `IMG_001-edit.JPG` → only exact base-name matches pair; `IMG_001-edit.JPG` is its own item.
- When the setting is off, each file is its own item.

### 4.4 Burst stacks
- Sort items by capture time (`DateTimeOriginal` + `SubSecTimeOriginal`, honoring `OffsetTimeOriginal` when present).
- Consecutive items are in the same stack when the gap is **≤ threshold (default 1.0 s, configurable)** **and** they come from the same camera body (serial number if available, else make+model). This prevents mixing two bodies shot simultaneously.
- Stacks of size 1 are plain items.
- Stack cover = first item in the stack; if any item is flagged **pick**, the first pick becomes the cover.
- Stacks are display-only groupings (not persisted to XMP).

---

## 5. Metadata storage (critical)

### 5.1 Fields

| Field | Storage | Notes |
|---|---|---|
| Rating 0–5 | `xmp:Rating` | Standard; readable by Lightroom/Bridge/Capture One |
| Color label | `xmp:Label` with values `Red`, `Yellow`, `Green`, `Blue`, `Purple` | Matches Lightroom's default label set names |
| Flag | Custom namespace `culler:Flag` = `pick` / `reject` (absent = none) | Lightroom does **not** read pick/reject flags from XMP; do not overload `xmp:Rating = -1` |
| Note | Custom namespace `culler:Note` | Intentionally separate from `dc:description` (caption) |

Custom namespace: prefix `culler`, URI defined in one constant (e.g. `https://byairu.com/ns/culler/1.0/`), registered with `CGImageMetadataRegisterNamespaceForPrefix`.

### 5.2 Where metadata is written

| File type | Primary storage | Backup |
|---|---|---|
| JPEG, HEIC, TIFF | **Embedded XMP** in the file | xattr |
| DNG | Embedded XMP **if** ImageIO supports lossless metadata update for DNG (verify in milestone 2); otherwise sidecar | xattr |
| Proprietary RAW (CR3, NEF, ARW, RAF, …) | **XMP sidecar** `<basename>.xmp` (Lightroom convention) | xattr |
| PNG | Sidecar | xattr |

For a RAW+JPEG pair: write the RAW's sidecar **and** the JPEG's embedded XMP (keep both in sync).

### 5.3 Write rules (non-negotiable)
1. **Merge only (PATCH, never PUT).** Read existing XMP (embedded or sidecar), change only the fields this app owns (`xmp:Rating`, `xmp:Label`, `culler:*`), preserve every other field (Lightroom develop settings, keywords, etc.). Use `CGImageMetadataCreateFromXMPData` / `CGImageMetadataSetValueWithPath` / `CGImageMetadataCreateXMPData`.
2. **Never re-encode pixels.** For embedded XMP use `CGImageDestinationCopyImageSource` (lossless metadata update).
3. **Atomic writes.** Write to a temp file in the same directory, then replace (`FileManager.replaceItemAt`). On any failure, the original must be untouched.
4. **Background write queue.** Writes are serialized per file in a background actor and never block UI. Coalesce rapid changes to the same item (debounce ~300 ms). Flush the queue on app quit / folder close.
5. Show a non-blocking error indicator if a write fails (e.g. read-only volume), and keep the pending value in the index so it is not lost.

### 5.4 xattr backup
- After each successful write, store a compact JSON copy (`{rating, label, flag, note, updatedAt}`) in xattr `<bundle-id>.meta` on the primary file (and paired files).
- On folder open: if a RAW has the xattr but **no sidecar**, regenerate the sidecar from the xattr. If both exist and disagree, the XMP wins (it may have been edited by another app).

### 5.5 Finder tags (optional)
- Setting "Sync color labels to Finder tags", default **off**. Maps label → Finder tag of the same color via `URLResourceValues.tagNames`. Only adds/removes the app's own color tags; never touches other user tags.

### 5.6 Index & cache
- **SQLite index** (GRDB) caches per-file EXIF + metadata keyed by path + file size + modification date, to make reopen and filtering instant. It is a cache, **never the source of truth**; it can be deleted at any time.
- **Thumbnail/preview disk cache** in `~/Library/Caches/<bundle-id>/`, keyed by a hash of (path, size, mtime). Size limit configurable (default 5 GB), LRU eviction.

---

## 6. Views

### 6.1 Grid
- Virtualized `NSCollectionView`; adjustable thumbnail size (slider / ⌘+ ⌘−).
- Each cell shows: thumbnail, flag badge, rating stars, color label strip, note indicator, pair badge (e.g. "RAW+JPG"), stack badge.
- Stacks are **collapsed by default** (cover + badge "×12"); expand/collapse inline.
- Multi-select (click, ⇧-click, ⌘-click, ⌘A).

### 6.2 Loupe
- Single large image, fit to window, with a **filmstrip at the bottom**.
- Zoom to 100% (toggle) centered on the cursor position / last click; pan by drag or trackpad.
- Native macOS full screen (⌃⌘F) hides all chrome except a minimal status overlay.

### 6.3 Compare
- **Default:** two slots side by side (left / right). Both slots are chosen freely from a filmstrip at the bottom.
  - One slot is "active" (highlighted). Clicking a filmstrip item puts it into the active slot. Tab switches the active slot.
  - All marking actions apply to the active slot's item.
- **Optional grid mode:** 3 or 4 slots (2×2) via toggle.
- **Optional "Pin current best" mode** (Settings, default off): left slot holds the current best; ←/→ cycles the right slot through candidates; Return promotes the right image to the left.
- **Zoom/pan sync:** toggle, default **on**. Holding ⌥ while panning moves only the image under the cursor (temporary independent pan). Sync uses normalized coordinates (relative to image size) so images of different resolutions align.
- Entry points: select ≥2 items in grid → C; or select a stack → C (filmstrip = stack contents); or C with nothing selected → compare mode with an empty slot and filmstrip of the current filtered list.

### 6.4 Status / info overlay (all views)
- **Always visible status** for the current item: flag, rating, color label, note indicator — updates immediately on keypress.
- **EXIF overlay, minimal by default:** shutter, aperture, ISO, focal length, lens. Press I to expand into a full info panel (date/time, camera, exposure mode, exposure compensation, dimensions, file names of all files in the item, file size).
- **Histogram:** toggle (H), default off, computed lazily from the screen preview only when visible.

---

## 7. Filtering & sorting

### Filters (combined with AND)
- Flag: pick / reject / unflagged (multi-select)
- Rating: operator `≥`, `=`, `≤` + value 0–5
- Color label (multi-select, incl. "none")
- File type: RAW / JPEG / HEIC / TIFF / PNG / paired
- Has note
- EXIF: camera (list from current folder), lens (list), ISO range, focal length range, aperture range, capture date range

**Filter + stacks:** stacks stay intact. A stack is shown if ≥1 member matches; badge shows `matching/total` (e.g. "1/12"); when expanded, only matching members are shown.

EXIF data is indexed in the background after folder open; EXIF filters become available progressively (show indexing progress).

### Sorting
Capture time (**default**), file name, rating, file modification date, file size — ascending/descending.

---

## 8. File operations

### 8.1 Rename
- Scope: **selected items** (default) or all items in the current filtered view.
- **Token template**, e.g. `{date:yyyyMMdd}_{seq:4}_{original}`. Tokens: `{original}`, `{date:<format>}` (capture date), `{time:<format>}`, `{seq:<digits>}` with configurable start, `{camera}`, `{lens}`, `{rating}`, literal text.
- Saved templates (named presets).
- **Mandatory preview** table "old → new" before executing.
- Renames all files of an item (RAW, paired JPEG, sidecar `.xmp`) consistently.
- Name collisions (with existing files or within the batch): auto-suffix `-1`, `-2`, … and show them in the preview.
- Extensions keep their original case.

### 8.2 Move & copy
- Single dialog with Move / Copy choice and destination folder (`NSOpenPanel`; destination stored as security-scoped bookmark). Recent destinations list.
- Always moves/copies **all files of an item** (including sidecar and xattr).
- **Same volume move:** atomic `moveItem`. **Cross-volume move:** copy → verify (size + checksum) → delete source only after successful verification. Never leave a half-moved item.
- Collisions: auto-suffix (same as rename), listed in a confirmation summary.
- Progress UI for large batches; cancellable (already-completed items stay done and are logged).

### 8.3 Reject handling
- Reject is **only a mark**. The app never moves or deletes rejected files automatically. (User can filter flag = reject and use Move manually.)

### 8.4 Undo / redo
- Covers **metadata changes and file operations** (rename, move, copy).
- ⌘Z / ⇧⌘Z. Batch operations undo as one step.
- File operations are recorded in a **persistent operation log** (JSON lines in Application Support), so they can be undone after an app restart (via an "Operation History" window).
- Before undoing a file operation, verify the files are still where/what the log expects (path + size + mtime). If not, refuse that step with a clear explanation; never guess.
- Undoing a copy = moving the copied files to Trash (the only Trash use in v1, and only via explicit undo).

---

## 9. Keyboard (Lightroom-compatible defaults)

| Key | Action |
|---|---|
| P / X / U | Pick / Reject / Unflag |
| 0–5 | Set rating |
| 6 / 7 / 8 / 9 | Red / Yellow / Green / Blue label (toggle). Purple: menu only (as in Lightroom) |
| Caps Lock | Auto-advance on/off (default off). When on, any flag/rating/label key also moves to the next item |
| ⇧ + P/X/U/0–9 | Apply and advance once (regardless of auto-advance) |
| ← / → | Previous / next item (in compare: change the active slot's item) |
| ⌥ → / ⌥ ← | Next / previous **unflagged** item |
| S | Expand / collapse the selected stack |
| G / E / C | Grid / Loupe / Compare |
| Tab | Compare: switch active slot |
| Return | Grid: open in loupe. Pin mode: promote candidate |
| Z or Space | Toggle 100% zoom |
| I | Toggle full info panel |
| H | Toggle histogram |
| M | Edit note for current item (inline text field; Esc cancels, ⌘Return saves) |
| F2 | Rename… |
| ⌘⇧M / ⌘⇧C | Move… / Copy… |
| ⌘F | Focus filter bar |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌃⌘F | Full screen |

Shortcuts are hardcoded in v1 but defined in one table so v2 customization is easy.

---

## 10. Performance requirements

Reference workload: **5,000 files in a folder, RAW up to ~60 MB each**, on an Apple Silicon laptop.

| Metric | Target |
|---|---|
| Next/previous image in loupe (prefetched) | < 50 ms to display |
| Next/previous image (not prefetched) | < 150 ms to show embedded preview |
| Folder open → grid visible | < 1 s (placeholders first, thumbnails stream in progressively) |
| Main thread | Never blocked by disk I/O, decoding or metadata writes (no beach balls) |
| 100% zoom on RAW | Preview shown instantly; full decode < 1 s |
| Marking key → status update | Immediate (same frame); disk write async |
| Memory | Bounded: LRU cache for decoded previews (e.g. ~current ±5 items), thumbnails downsampled; memory must not grow with folder size beyond thumbnails |

Implementation requirements:
- Prefetch the next 3 and previous 1 previews in the direction of navigation; cancel stale prefetch tasks.
- Thumbnail generation with bounded concurrency (≈ CPU core count), prioritizing visible cells.
- Use the SQLite index so reopening a folder skips re-reading EXIF/XMP for unchanged files.
- Watch the folder (FSEvents / `DispatchSource`) and update items when files change externally.

Add a simple debug overlay (toggle in a Debug menu) showing load times and cache hit rates.

---

## 11. Sandbox & distribution

- **App Sandbox ON** with entitlements:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.files.user-selected.read-write`
  - `com.apple.security.files.bookmarks.app-scope`
- Because the user opens a folder via `NSOpenPanel`, the app gets read/write access to the whole folder tree → sidecars, renames and xattrs inside it work without extra prompts.
- Move/copy destinations are also chosen via `NSOpenPanel` and bookmarked.
- Persist security-scoped bookmarks for recent folders and destinations; handle stale bookmarks by asking the user to reselect.
- v1 distribution: run/build locally from Xcode. Architecture must remain compatible with later Mac App Store or Developer ID + notarization distribution.

---

## 12. Settings

- Treat RAW+JPEG as one photo (on)
- Burst threshold seconds (1.0)
- Include subfolders by default (off)
- Compare: default slot count (2), Pin current best mode (off), sync zoom/pan default (on)
- Sync color labels to Finder tags (off)
- Cache size limit (5 GB) + "Clear cache" button
- Rename templates management

---

## 13. Scope

### In v1
Everything above.

### v2 (do NOT build in v1, but don't block)
- Grouping by visual similarity (Vision feature prints)
- Keywords / tags
- AF focus point display (maker notes, per-brand)
- Highlight/shadow clipping overlay, focus peaking
- AND/OR smart filters
- Customizable shortcuts
- Favorite destination folders with shortcuts
- "Process rejects" action (to `_rejected/` or Trash)
- Copy note to caption (`dc:description`)

### Out of scope
Photo editing, export with resize/format conversion, AI auto-culling, video, cloud sync, cross-folder catalog/library.

---

## 14. Suggested project structure

```
PhotoCuller/
  App/                 // App entry, commands/menus, constants (name, bundle ID, XMP namespace)
  Model/               // PhotoItem, FileRef, Metadata, ExifInfo, Stack, FilterState, SortOrder
  Services/
    FolderScanner      // enumerate files, pairing, watching
    StackBuilder       // burst grouping
    ImagePipeline      // actor: thumbnails, previews, full decode, caches, prefetch
    MetadataStore      // actor: XMP read/merge/write (embedded + sidecar), xattr, Finder tags, write queue
    Index              // GRDB SQLite cache
    FileOperations     // rename, move, copy, collision handling
    OperationLog       // persistent log + undo/redo
    Bookmarks          // security-scoped bookmark handling
  Features/
    Grid/  Loupe/  Compare/  Filter/  Info/  Rename/  MoveCopy/  Settings/  History/
  Shared/              // keyboard map, formatting, utilities
Tests/
  Fixtures/            // small sample JPEG, HEIC, DNG, a few real RAWs, existing Lightroom-style .xmp
```

---

## 15. Milestones

Each milestone ends with a working, runnable app and passing tests.

1. **Browse:** open folder, scan, pairing, grid with thumbnails, loupe with filmstrip, keyboard navigation, prefetch, caches, sandbox + bookmarks.
2. **Mark & persist:** flag/rating/label/note, status overlay, XMP merge read/write (embedded + sidecar), write queue, xattr backup, auto-advance, undo/redo for metadata. Verify DNG embedded-write support.
3. **Stacks, filter & sort:** burst stacks (collapse/expand), background EXIF indexing, filter bar, sorting, filter+stack behaviour, EXIF overlay + info panel, histogram.
4. **Compare:** two-slot compare with filmstrip, active slot, synced zoom/pan with ⌥ override, 3–4 slot grid, pin current best mode.
5. **File operations:** rename with templates + preview, move/copy with verification, collision handling, persistent operation log, undo of file ops, history window.
6. **Polish:** settings window, Finder tag sync, performance pass against §10 targets, error states (unsupported RAW, read-only volume, missing files).

---

## 16. Acceptance tests (must exist as automated tests where possible)

- **XMP merge:** given a sidecar containing Lightroom develop settings + keywords, changing the rating preserves all other content byte-for-meaning (parse before/after and compare all non-owned properties).
- **Lossless embed:** after writing metadata to a JPEG/HEIC, decoded pixel data is identical to before.
- **Atomicity:** a simulated failure mid-write leaves the original file unchanged.
- **Pairing:** exact base-name match only; pairing toggle off yields separate items.
- **Stacks:** threshold boundary (exactly 1.0 s in, 1.01 s out), two camera bodies interleaved in time produce separate stacks.
- **Rename:** template rendering, sequence padding, collision suffixing, sidecar + pair renamed together.
- **Move cross-volume:** source removed only after verified copy; cancellation leaves no partial items.
- **Undo:** metadata undo, rename undo, move undo after app restart; undo refused when the file changed externally.
- **xattr recovery:** delete a RAW's sidecar → reopen folder → sidecar regenerated from xattr.
- **Performance:** scripted test folder of ≥2,000 files measuring folder-open time and navigation latency (manual or XCTest `measure`).

---

## 17. Open items

- Final app name, bundle ID and XMP namespace URI — **must be finalized before real-world use**, since notes are written into users' files.
- Confirm ImageIO lossless metadata write support for DNG (milestone 2).
