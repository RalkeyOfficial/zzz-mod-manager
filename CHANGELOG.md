# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The Marketplace is now a built-in GameBanana browser, working the same way on Linux and Windows: search or browse ZZZ mods, filter by category or character, sort, then open a mod to see its screenshots, description and full file list and download from there. Linux no longer has to send you to an external browser.
- A "best of" carousel above the Marketplace grid cycles through GameBanana's top three mods for each of seven periods — today, this week, this month, 3 and 6 months, this year, and all time. Each card shows the mod's cover full-width with its title over the top; click it to open the mod. It advances on its own and pauses while your cursor is over it.
- Mods flagged as adult content on GameBanana are blurred until you click to reveal them, with a Marketplace toolbar setting to show them unblurred or hide them entirely. Your choice is remembered between sessions, as is the Marketplace sort order.
- Marketplace mod cards show how long ago each mod was first released and last updated, with the exact dates on hover.
- The mod detail view shows each file's name, size, upload date and GameBanana's own virus-scan result, and can list older superseded versions. When a mod offers more than one file, you choose which to download.
- Marketplace downloads now resume where they left off instead of starting over, survive the app being closed mid-download, and show a transfer rate and estimated time remaining.
- Marketplace downloads can now be cancelled while in progress.
- Mods now record where they came from, so a future release can tell you when an update is available. A Marketplace download records exactly which mod and which file it was; an archive or folder you import yourself records how it arrived and, for archives, its checksum.
- Mods you already have are now linked back to their GameBanana page automatically, using the source URL already stored on them, so update checking will work for your existing library and not just for new installs. No new files appear in mods that have no source URL.
- The Marketplace now marks mods you already have. Cards and the mod page show which of your mod folders came from that page — several, when you have installed more than one variant — and the file list marks the exact file you installed, or notes when a file is byte-identical to an archive you installed.
- Installing an archive you have installed before now asks first, naming the mods it produced, instead of quietly making a second copy. Applies to Marketplace downloads and to archives you import yourself. It can only recognise archives this version installed, and never a re-packed copy of the same mod.
- Mods installed from the Marketplace arrive with their description and screenshots (up to ten) already filled in from their GameBanana page, and are tagged with the character the mod is filed under there — which catches mods whose folder name gives nothing away. Anything the mod folder already carried is kept, including a preview image shipped inside the archive, which stays the cover.

### Changed

- Mod descriptions are easier to read: body text is larger, lines are more generously spaced, and headings, lists, quotes, code, tables and horizontal rules now follow one consistent style everywhere a description is shown. A `---` divider is a hairline instead of a thick bar.
- Descriptions keep the spacing their author gave them: blank lines between paragraphs are a full line tall rather than a hairline gap, and a run of several stays as tall as it was written instead of collapsing into a single break.
- Downloaded archives now always land in the app's own downloads folder and are deleted once installed; an archive that fails to extract is kept, and the app tells you where to find it.

### Removed

- The embedded webview (Windows) and the Downloads-folder watcher (Linux) are gone, replaced by the built-in browser above. The watcher could only notice a file appearing and had to guess when your browser had finished writing it, so it also picked up unrelated downloads and could never tell which mod a file belonged to.

### Fixed

- Mod cover images are decoded at the size they are shown rather than their full resolution, cutting the app's image memory dramatically — a 49-cover library previously held over 200 MB of decoded image data, enough that scrolling the library could push other images out of memory and force them to reload.
- Certificate validation is no longer disabled when downloading mods.
- Installing a mod no longer risks deleting the folder its archive was sitting in.
- A failed or interrupted marketplace download no longer leaves a partial file and an open file handle behind.

- Metadata written into a mod's `.zzz-mod-manager/metadata.json` by a newer version of the app (or another tool) is no longer erased when you edit that mod's description, tags or character.
- Saving the edit dialog for a mod with no character assigned no longer records the placeholder "unknown" as its character, and mods carrying that placeholder from an older version are now treated as untagged.

## [2.2.2] - 2026-07-19

### Fixed

- Importing a single-folder mod no longer fails with a false "Mods already exist or an error occurred" and installs nothing. A list-aliasing bug in the shared import resolver emptied the folder list before the copy, breaking the common single-folder import on both the mod import button/drag-drop and the Marketplace.

## [2.2.1] - 2026-07-19

### Changed

- The multi-folder selection flow and the "no `.ini`" check are now shared between the Marketplace and the mod import button/drag-drop, so both paths always behave identically (the Marketplace previously lacked the selection dialog).

### Fixed

- Auto-installing a multi-folder download from the Marketplace now opens the same folder-selection dialog as the upload button and drag/drop, instead of silently installing every folder (e.g. `previews`) as its own mod.
- An archive whose root holds a `.ini` next to resource folders (e.g. `res/`, `buffer/`, `name.ini`) now installs as one mod instead of treating each folder as separate and dropping the `.ini`. Applies to both the Marketplace and the mod import button/drag-drop.
- Imports now warn when a resulting mod contains no `.ini` at all, catching incomplete/broken mods early.

## [2.2.0] - 2026-07-18

### Added

- Importing an archive (or dropping) with multiple folders now opens a selection dialog: pick which folders to install, and choose whether each becomes its own mod or they combine into one mod (for a mod plus a dependency folder). Real mods (folders with a `.ini`) are pre-selected over auxiliary folders like `previews`, fixing multi-folder zips installing junk as separate mods.
- Right-click → "Open in file explorer" opens a mod's folder in the system file manager.
- Right-click → "Delete" permanently removes a mod (folder, active link, and saved state) after a confirmation dialog.
- The mod details dialog lets you edit the description inline (pencil → edit → save) without opening the full Edit dialog.
- Pasting rich text into either description editor (Ctrl+V) converts it to markdown, preserving bold, italic, inline code, headers, links, and lists. Falls back to plain-text paste when the clipboard has no HTML.
- Markdown formatting shortcuts in both description editors: Ctrl+B/I/E wrap the selection in bold/italic/inline-code (toggling off if already wrapped, or inserting a selected placeholder with no selection), Ctrl+K makes a link, and Ctrl+1/2/3 toggle a heading on the current line.

### Changed

- Slimmed the mod right-click menu: removed the "Add image" and "Activate/Deactivate" entries (still available via the Edit dialog and the card's toggle switch respectively).
- Refactored the mods screen: split the 4500-line `mods_screen.dart` into focused component, dialog, and util files (no behaviour change) for readability and maintenance.
- Editorial actions (rename, edit, favorite, delete) now update the list in place instead of rescanning every mod, so they stay fast no matter how many mods you have.

### Fixed

- `> [!INFO]` in mod descriptions now renders as an info callout (a note-style alias) instead of a plain blockquote — `INFO` isn't a real GitHub alert, but people commonly reach for it over `NOTE`.
- Soldier 0 Anby auto-categorises from the community nicknames "sanby" and "anbys".
- Saving the Edit dialog after the mod was renamed (or deleted) no longer recreates a ghost folder containing only metadata; it now reports that the mod no longer exists and skips the save.

## [2.1.0] - 2026-06-27

### Added

- Mod descriptions render as markdown in the details dialog, with embedded links that open in the browser and GitHub-style alert callouts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`).

### Changed

- The description editor in the mod Edit dialog is now a much taller, fixed-height text box.

### Fixed

- Qingyi's misspelled character id (`quinqiy` → `qingyi`) is corrected, so Qingyi mods auto-categorise instead of landing in Unknown; existing tags are remapped automatically.
- Auto-categorisation recognises characters whose folder name differs from their id (e.g. "Zhu Yuan" vs `zhuyuan`) via the shared name/alias detector, instead of a raw id substring match.
- Downloaded mods persist their detected character to disk like folder imports, so the category survives a rename (the download path previously only showed it in a notification).
- Character auto-detection no longer scans `.ini` contents, which mis-tagged mods (e.g. "norma" inside "NormalMap"); it now uses the mod folder name and the source archive name.

## [2.0.0] - 2026-06-27

### Added

- Rename mods from within the app (right-click → Rename); the folder moves and its active link, favorite, and category state are preserved.
- Non-character categories (UI, Texture, Audio, Misc) alongside the character roster, assignable via a searchable picker with a character-portrait grid.
- The ALL tab groups mods into collapsible per-character and per-category sections in roster order; other tabs stay a flat grid.
- A toolbar to search, sort (Default / Name A–Z / Z–A), filter by tags (Any/All match), and show favorites only; the sort choice persists across launches.
- Multiple images per mod, managed in the Edit dialog (paste or add files, pick the cover, staged until Save); the details dialog shows the full gallery.
- A read-only mod details dialog (right-click → Details) with the gallery, character, description, tags, source link, and keybinds in one place.
- Editable description and tags in the mod Edit dialog, persisted to the in-folder metadata (description previously could not be saved at all).
- A per-mod source link (GameBanana or any URL); when set, right-click → "Open source page" opens it in the browser.
- Per-mod metadata is stored inside each mod's folder (`.zzz-mod-manager/metadata.json`), so it travels with the mod and survives renames; legacy data migrates on first scan.
- `CLAUDE.md`, `TODO.md`, and `CHANGELOG.md` added to the repository.

### Changed

- Character roster updated to the current game version: corrected names (e.g. Lycaon, Soldier 0 - Anby, Ju Fufu) plus 18 new characters, all driven by a single list with brief and real names.
- Redesigned mod cards: an on/off toggle switch (replacing the ✓/✕ badge that misread as "delete"), info and source-link buttons, and a name + tag-chip footer; deeper metadata moved to the details dialog.
- Mod cards scale from their centre with a straight-up lift on hover, and the grid gained top padding so the top row is no longer clipped.
- The right-click "Keybinds" action is now "Edit keybinds" (localized) and shows key combos in their exact `.ini` form for editing accuracy.

### Fixed

- The window opens at its proper size from the first frame on Linux, instead of appearing as a tiny square and then growing (which mis-centered content).
- Character portraits resolve by asset filename, so characters whose image differs from their id (e.g. Billy) show the real portrait instead of a placeholder.
- Scrollbar crash when switching mods tabs — two lists briefly shared one `ScrollController`; each list now owns its own.
- Saving a mod edit is near-instant: keybinds are cached per mod instead of re-parsing every mod's `.ini` files on each save.
- The "Add mods" and keybinds dialogs now respect the EN/UK language toggle (they were hardcoded to one language).
- The keybinds modal lists every bind: capitalised `Key =` sections were dropped, so lookup is now case-insensitive and the count badge counts actual binds.

### Removed

- The Favorites sidebar tab — the toolbar's favorites-only filter covers the same need (the per-mod star and the filter are unchanged).

## [1.0.0] - 2025-10-01

- Initial release.
