# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Right-click → "Open in file explorer" opens a mod's folder in the system file manager.
- Right-click → "Delete" permanently removes a mod (folder, active link, and saved state) after a confirmation dialog.
- The mod details dialog lets you edit the description inline (pencil → edit → save) without opening the full Edit dialog.
- Pasting rich text into either description editor (Ctrl+V) converts it to markdown, preserving bold, italic, inline code, headers, links, and lists. Falls back to plain-text paste when the clipboard has no HTML.
- Markdown formatting shortcuts in both description editors: Ctrl+B/I/E wrap the selection in bold/italic/inline-code (toggling off if already wrapped, or inserting a selected placeholder with no selection), Ctrl+K makes a link, and Ctrl+1/2/3 toggle a heading on the current line.

### Changed

- Slimmed the mod right-click menu: removed the "Add image" and "Activate/Deactivate" entries (still available via the Edit dialog and the card's toggle switch respectively).
- Refactored the mods screen: split the 4500-line `mods_screen.dart` into focused component, dialog, and util files (no behaviour change) for readability and maintenance.

### Fixed

- `> [!INFO]` in mod descriptions now renders as an info callout (a note-style alias) instead of a plain blockquote — `INFO` isn't a real GitHub alert, but people commonly reach for it over `NOTE`.
- Soldier 0 Anby auto-categorises from the community nicknames "sanby" and "anbys".

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
