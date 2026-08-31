# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The Marketplace is a built-in GameBanana browser on Linux and Windows: search, browse, filter by category or character, sort, and open a mod for its screenshots, description and file list.
  - A carousel above the grid shows GameBanana's top mods across seven periods, from today to all time.
  - Adult content can be shown, blurred until you click it, or hidden entirely.
  - Cards show when each mod was released and last updated.
  - A mod's page shows its author, category (which links back to the grid), tags, dates, and every file with its size, upload date and virus-scan result.
  - The Marketplace marks which mods and which files you have already installed.
  - Marketplace installs arrive with their description, screenshots and character tag filled in from the mod page.
- Downloads run in the background, two at a time, and install themselves as they land.
  - Downloads resume where they left off and survive the app closing.
  - Downloads can be cancelled while running.
  - A title-bar button opens the list of downloads, where a failed one can be retried and finished ones cleared.
  - One notification shows overall download progress until the last one finishes.
- Mods record where they came from, so they can be checked for updates.
  - Existing mods are linked back to their GameBanana page from the source URL they already carry.
  - Mod cards show a mark for how well each mod is set up for update checking, and a toolbar button filters the library to the ones that need attention.
  - "Update tracking…" in a mod's right-click menu links it to its GameBanana page and records which file you have.
  - That dialog can settle for the install date instead, or stop asking if the mod isn't from GameBanana.
  - "Mark all as current" settles every tracked mod with no known version, using each mod's install date.
  - "Sort out mod tracking…" turns a library check into one pass for confirming mod pages, filling in versions and recording dead links.
- Mods can be checked for updates, one at a time or the whole library, and only when you press it. A blue mark shows what has something newer.
  - Update checks say whether they are sure or guessing.
  - The library check reports mods it couldn't reach separately from mods with nothing new.
  - Files an author published together count as one release, so another variant isn't read as an update.
  - An update can be ignored from its dialog, and one click undoes it.
  - A toolbar filter narrows the library to mods with updates.
  - Settings can check for updates at startup. Off by default, and it never installs anything.
- Updates can be installed from the update dialog. The mod keeps its name, character tag, favourite star and on/off state.
  - The dialog lists every newer file and marks the one it would pick.
  - Updating writes over the files the new version replaces and leaves anything you added yourself alone.
  - Every update saves a copy of the mod first, and "Restore a previous version…" puts it back.
  - The dialog shows the author's release notes for anything published since your version.
  - Hotkeys the new version moved are listed after an update.
  - You're told what an update will do before it runs.
  - When a new version renames its .ini, the old one is offered for deletion.
  - An update whose archive layout no longer matches the mod stops and says so rather than guessing.
- An install that turns out to be a patch says so, and remembers it for later.
  - Installing a patch asks where it goes: its own folder with the mod it patches fetched in for you, or straight into a mod you already have, picked from a searchable list with cover images.
  - That list puts the folders holding the files the patch replaces first, and each one says how many it holds.
  - When the patch's page names a mod you already have, that mod goes to the top of the list.
  - A patch whose files don't belong in the mod you picked installs as its own mod instead, and says which of the two reasons it was.
  - A folder holding a patch plus the mod it patches can be told about both, and both are checked for updates.
  - An update to either mod in such a folder can be installed: the base mod goes in and the patch is put back over the top. Folders you merged by hand say so first, since the app can't tell which files are which.
- Installing an archive you have installed before asks first.
- The Mods toolbar is search plus a **Library** menu, with the filters on their own row.
- The Mods tab sorts by **Recently added** by default.
- Settings has an **Updates** section for the startup check, and a **Marketplace** section for the adult-content filter.
- RAR and 7z mods install with no setup: 7-Zip ships with the app, and the Arch package installs it.
- The Arch package pulls in what "open mod page" and "open mod folder" need, and lists xdotool and ydotool as optional.

### Changed

- The "which mod is this?" search starts with the mod's name read as words, so `Ellen_Joe_Cheongsam` searches for "Ellen Joe Cheongsam".
- Notifications are small cards in the bottom-right corner. Several can show at once, any can be closed, and hovering pauses their countdowns.
- Every notification says what happened and what it happened to, led by the character's portrait.
- Enabling, favouriting, renaming, retagging, refreshing and deleting report only when they fail.
- Notifications are drawn above dialogs instead of behind them.
- Install confirmations name the mod that arrived, and anything you need to act on comes as its own warning beside it.
- Mod descriptions are larger, better spaced, and consistently styled everywhere they're shown.
- Descriptions keep the paragraph spacing their author gave them.
- Downloaded archives land in the app's own downloads folder and are deleted once installed. Anything left over is cleared when you next start the app.

### Removed

- The embedded webview (Windows) and the Downloads-folder watcher (Linux), replaced by the built-in browser.

### Fixed

- A missing 7-Zip is reported as a missing tool rather than a broken archive.
- Importing a folder no longer follows symbolic links out of it.
- A mod whose folder can't be written to is named instead of failing quietly.
- Editing a mod's hotkey updates the library straight away instead of after a tab switch.
- Ukrainian counted messages use the right form of the noun.
- Importing or deleting a mod no longer replays the "switched character" animation across the grid.
- Turning a mod on or off no longer rebuilds its card, so it keeps its hover lift.
- "Detect tags for all mods" no longer blanks the Settings page behind a blocking dialog.
- Collapsing the sidebar no longer throws an exception across the navigation buttons.
- Cover images are decoded at the size they're shown, cutting the app's image memory.
- Certificate validation is no longer disabled when downloading mods.
- Installing a mod no longer risks deleting the folder its archive was sitting in.
- Metadata written by a newer version of the app is no longer erased when you edit a mod's description, tags or character.
- Saving a mod with no character no longer records "unknown" as its character.

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
