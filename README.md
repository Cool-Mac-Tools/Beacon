# Beacon

A fast, native macOS search launcher. Press a hotkey anywhere, type, and find
the thing you were actually looking for: a file, app, recent download, image,
PDF, note, message, browser-history page, or System Settings pane.

Beacon is a lightweight menu-bar app with a keyboard-driven overlay, in the
spirit of Spotlight / Raycast / Alfred, but tuned for local, high-signal Mac
search. It uses the system Spotlight index where it is strong (file name and
document-content search), then fills the gaps with direct local scanners for the
places Apple's tools often miss: Recents, installed apps, Messages, Notes,
Clipboard, browser history, and System Settings shortcuts.

## Features

- Global hotkey overlay: summon the search bar from any app.
- Live results as you type, with smart ranking (exact name matches and your
  own files first; folders surface reliably).
- Searches by name **and by text inside documents** (PDFs, text, Office/iWork,
  etc.); content matches are flagged with a "text match" badge and kick in
  once the query is 3+ characters (name search is instant from the first).
- **Recents** filter: a clean Finder-style timeline of files you've opened,
  saved, or added recently (including fresh images/videos/downloads), powered by
  Beacon's own filesystem scanner so it is not blocked by Finder/Spotlight
  recency quirks. Type to narrow within recent files.
- File rows show Quick Look thumbnails, and History rows show site favicons
  where available.
- Apps are scanned directly from application folders, so downloaded/third-party
  apps show up even when Spotlight misses them.
- **System Settings** filter: jump straight to Wi-Fi, Displays, Privacy,
  Full Disk Access, Keyboard, Battery, and other settings panes.
- All matching is case- and accent-insensitive across every source
  ("jose" finds "José" in files, messages, notes, and history alike).
- **Search your text messages** (iMessage & SMS) under the Messages filter:
  find by word, phrase, or **contact name** across your whole history
  (typing "Mom" surfaces Mom's messages, not just texts containing the word);
  results show the
  **contact's name**, a snippet centered on the match, and when it was sent.
  `return` opens the conversation in Messages and `⌘C` copies the text.
  (Requires Full Disk Access; sender names use Contacts — see below.)
- **Search your Apple Notes** under the Notes filter: full-text search across
  every note (title + body), with the matched word shown and bolded; `return`
  opens Notes. (Uses the same Full Disk Access as Messages.)
- Matched words are **bolded** in result titles and message/note snippets.
- Type filters: All, Recents, Apps, Messages, Notes, History, Docs, PDFs,
  Audio, Folders, Photos, Videos, Clipboard, Settings.
- Fully keyboard-driven (no mouse needed).
- Quick Look previews, reveal in Finder, copy path.
- Native Swift/SwiftUI, zero third-party dependencies.

## Download (for users)

1. Go to the [latest release](https://github.com/Cool-Mac-Tools/Beacon/releases/latest).
2. Download `Beacon-<version>.dmg` and open it.
3. **Double-click Beacon** - it installs itself into Applications, relaunches
   from there, and opens the search bar with a first-run hotkey tip.
   (Dragging it to Applications works too.)
4. Press **Option + S** anywhere to search. Beacon lives in the menu bar.

The app is signed with a Developer ID and notarized by Apple, so it opens
without security warnings.

## Website

An Apple-style marketing site lives in [`docs/`](docs/). Preview locally:

```bash
bash docs/serve.sh
```

Then open [http://localhost:8080](http://localhost:8080). To publish on GitHub Pages,
set the source to the `/docs` folder on the `main` branch in repo Settings → Pages.

## Why Beacon?

macOS already has Spotlight and Finder search, but both have sharp edges when
you are trying to find local things quickly.

**Spotlight became a cluttered kitchen.** It started as a fast file finder, then
grew into a universal assistant. Searching for a PDF or app can mix local files
with web suggestions, Siri knowledge, dictionary cards, Maps results, and other
noise. Results can also shift while you type, so pressing Return quickly can
open the wrong thing.

**Spotlight depends on a hidden index.** When that index lags or corrupts,
Spotlight may miss a file sitting on your Desktop. Fixing it usually means
finding the right System Settings panel, excluding/re-including folders, or
waiting for a rebuild.

**Finder search is unpredictable.** Finder often searches "This Mac" when you
expected the current folder, hides package/system internals, and its Recents
view is especially confusing: a newly downloaded or exported file can be missing
because it has not been opened yet.

Beacon's answer is not "replace everything with one giant assistant." It keeps
the launcher small and local:

- `All` gives a blended, ranked view of files, apps, messages, and notes.
- `Recents` is built from the filesystem so fresh downloads, images, exports,
  and screenshots appear immediately.
- `Apps` scans `.app` bundles directly, including downloaded apps outside
  Apple's built-in set.
- `Messages`, `Notes`, `Clipboard`, and `History` each have focused filters, so
  those sources do not drown out file search.
- `Settings` jumps straight to common System Settings panes.

Beacon does **not** search cloud-only files that have not been downloaded to the
Mac yet. If a provider keeps a file only in the cloud and does not expose it on
disk, Beacon will not see it until it exists locally.

## Requirements (to build from source)

- macOS 13 or newer.
- Xcode command-line tools / Swift toolchain (`swift --version`).

## Build & run

From the project root:

```bash
bash scripts/run.sh
```

This builds the app, assembles `Beacon.app`, ad-hoc signs it, quits any running
copy, and launches the new build. Look for the Beacon lens icon in your menu
bar.

To build a debug variant, set `CONFIG=debug bash scripts/run.sh`.

## Using Beacon

- **Open / close:** `Option + S` (toggles the search bar). Also available by
  clicking the menu-bar icon. (`Cmd + S` is left alone for Save, and
  `Cmd + Space` for Spotlight.)
- **Type** to search by name. Multiple words narrow the results (all words must
  appear in the name).
- **Filter by type:** click a chip, or press `Tab` / `Shift + Tab` to cycle.

### Keyboard shortcuts

| Key            | Action                          |
| -------------- | ------------------------------- |
| `↑` / `↓`      | Move selection                  |
| `return`       | Open the selected item          |
| `⌘ return`     | Reveal in Finder                |
| `⌘ Y`          | Quick Look preview              |
| `⌘ C`          | Copy the file's path            |
| `Tab` / `⇧Tab` | Cycle type filter               |
| `esc`          | Dismiss the search bar          |

> Note: Quick Look is mapped to `⌘ Y` (instead of the Finder-style `Space`)
> because `Space` is needed for typing multi-word searches.

## Full Disk Access

Spotlight already indexes most user locations, so **file search works out of the
box** with no permissions. Full Disk Access unlocks the extras:

- **Message search** (reading `~/Library/Messages/chat.db`),
- **Notes search** (reading the Apple Notes database), and
- complete coverage of every folder, including some protected locations.

Beacon touches the Messages database once at launch, so it automatically appears
in the Full Disk Access list — you don't need the `+` button. To grant it:

1. In Beacon, select the **Messages** filter and click **Open Settings**
   (or open **System Settings → Privacy & Security → Full Disk Access**).
2. Find **Beacon** in the list and turn its switch **on**.
3. When prompted, choose **Quit & Reopen** (or relaunch Beacon).

> If Beacon isn't listed yet, launch it once first, then reopen the list — or
> drag `Beacon.app` from Applications into the list.

The first time you search Messages, macOS also asks for **Contacts** access —
allow it to see sender names instead of raw phone numbers. If you decline,
message search still works; it just shows the number/email.

## How It Works

```
Hotkey / menu bar  ->  floating NSPanel  ->  SwiftUI SearchView
                                                   |
                                               SearchEngine
                                                   |
      Spotlight file search + local stores/scanners (Recents, Apps, Messages,
      Notes, Clipboard, History, Settings)
```

- `Sources/Beacon/HotKey.swift` registers the global hotkey via the Carbon
  Hot Key API (no Accessibility permission required).
- `Sources/Beacon/SearchPanel.swift` is a borderless, floating, non-activating
  panel that hosts the SwiftUI UI.
- `Sources/Beacon/SearchEngine.swift` coordinates all sources, cancels stale
  work as the user types, merges the "All" view, and publishes ranked results.
- `Sources/Beacon/FileType.swift` defines the filter chips and which source
  backs each chip.
- `Sources/Beacon/RecentsStore.swift` scans visible user folders directly so
  newly saved/downloaded files show up without waiting on Spotlight Recents.
- `Sources/Beacon/AppStore.swift` scans installed `.app` bundles in
  `/Applications`, `~/Applications`, and system app folders.
- `Sources/Beacon/MessageStore.swift` powers the Messages filter: it opens the
  Messages SQLite database read-only, decodes message text (including the binary
  `attributedBody` blobs newer macOS uses), caches recent messages in memory,
  and filters them as you type.
- `Sources/Beacon/NotesStore.swift` powers the Notes filter: it opens the Apple
  Notes SQLite database read-only and decodes each note body (gzip-compressed
  protobuf) to enable full-text search across your notes.
- `Sources/Beacon/BrowserHistoryStore.swift` reads Safari and Chromium history
  databases; `Sources/Beacon/FaviconStore.swift` loads same-site favicons for
  history rows.
- `Sources/Beacon/ThumbnailStore.swift` uses Quick Look thumbnails for file
  previews in Recents and file search.
- `Sources/Beacon/SettingsStore.swift` maps common System Settings panes to
  searchable deep links.

## Roadmap

- Settings UI with a customizable hotkey recorder and result limits.
- Optional cloud-provider integrations for files that are visible remotely but
  not downloaded locally.
- Richer content snippets for text matches inside PDFs/documents.
- Expand semantic indexing to additional local folders and cloud providers.

## License

Beacon's source is available under the
[PolyForm Internal Use License 1.0.0](LICENSE.md): read it, build it, modify
it, and use it for yourself (or internally at your company) for free. You may
**not** redistribute Beacon or works based on it.

Want the signed, notarized build with automatic updates — and to support
development? [Buy a license at beaconmac.com](https://beaconmac.com) ($15/year).

By submitting a contribution (pull request, patch, or suggestion) you agree it
may be incorporated into Beacon under the same license.

## Semantic search development

AI search now combines file search, bounded document excerpts, and an optional
local image index. In AI → Manage, enable image indexing and connect Photos if
wanted. It ranks older images by their content before asking your provider to
verify at most 40 candidates. Date constraints apply before ranking. Source text
is treated as untrusted data, and cancelling a query cancels active HTTP requests.

`python3 scripts/prepare-models.py` downloads and verifies Apple's MobileCLIP-S0
encoders (about 108 MB) and compiles them using the installed Swift/Core ML tools.
Run/release packaging prepares and bundles them automatically. See
[the model notes](Resources/CLIP-MODEL.md) for coverage, cache location, and limits.

Validation:

- `bash scripts/test.sh`: XCTest with full Xcode, or portable checks with CLT.
- `bash scripts/test-semantic.sh`: date ranking, excerpts, and media classification.
- `bash scripts/test-semantic.sh --models`: real tokenizer and both image/text encoders,
  including a generated red/blue image retrieval check. No personal data or paid API calls.
- `bash scripts/test-semantic.sh --text-models`: text-only model checks when the
  execution environment blocks IOSurface/image inference.

GitHub Actions builds the app, runs XCTest, and exercises the actual pinned models
on macOS 26. Local tool sandboxes can block process/graphics services needed by Core ML;
that is reported as a test failure, never silently marked successful.
