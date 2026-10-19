# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Mods that include shader fixes install with them: switching the mod on copies its shader files into ZZMI's ShaderFixes folder, and switching it off takes them back out, including a copy the XXMI Launcher renamed to `DISABLED_…`. A shader file already there with the same contents is used as it is and left in place if the app didn't put it there, while one with different contents keeps the mod off and says which. Mods in one archive that share a ShaderFixes folder each get a copy and can be on together.
- Shader fixes shipped in a folder with another name, such as "PUT THESE IN SHADERFIXES", are recognised on import and installed with the mod, and the import picker says which folder they came from.
- "Sort out where these mods came from" lists the mods with no mod page, folded under their count, each with a button to identify it.
- Mod covers load faster: a card-sized copy is saved beside each newly imported cover, and the mod cards read that instead of decoding the full screenshot every time. Covers added by an older version keep loading as before until they are added again through the edit dialog.
- The Marketplace is a built-in GameBanana browser on Linux and Windows: search by mod name or paste a mod link or id, browse, filter by category or character, sort, and open a mod for its screenshots, description and file list. A search keeps the category and sort you have set.
  - A carousel above the grid shows GameBanana's top mods across seven periods, from today to all time.
  - Adult content can be shown, blurred until you click it, or hidden entirely.
  - Cards show when each mod was released and last updated.
  - A mod's page shows its author, category (which links back to the grid), tags, dates, and every file with its size, upload date and virus-scan result.
  - The Marketplace marks which mods and which files you have already installed.
  - Marketplace installs arrive with their description, screenshots and character tag filled in from the mod page.
- Downloads run in the background, two at a time, and install themselves as they land.
  - Downloads resume where they left off and survive the app closing.
  - A download that won't fit is refused before it starts, saying how much is needed and how much is free.
  - Downloads can be cancelled while running.
  - Downloads in the sidebar opens the list of downloads, where a failed one can be retried and finished ones cleared.
  - One notification shows overall download progress until the last one finishes.
  - A download that has landed says it's unpacking, rather than going quiet between finishing and asking where the mod goes.
- An archive that won't fit when unpacked is refused before unpacking, saying how much is needed and how much is free. The archive is kept, so clearing space and installing again is all it takes.
- A mod that won't fit in your mods folder is refused before anything is copied there, saying how much is needed and how much is free.
- A Storage tab shows what the app is keeping on disk, as a chart broken down by kind: mods, saved versions, downloads, covers and metadata, logs, and leftovers.
  - Each category opens to list its biggest items, and free space is shown for every disk the app writes to.
  - "Free up space" deletes installed archives, abandoned downloads, leftover extraction folders, old logs, and the saved versions of mods that are no longer in your library. It never touches your mods, or the saved versions of mods you still have.
  - It leaves your downloads alone while a transfer or install is running, and says so rather than doing it quietly.
- Mods record where they came from, so they can be checked for updates.
  - Existing mods are linked back to their GameBanana page from the source URL they already carry.
  - Mod cards show how well each mod is set up for update checking: "Which file?" or "Base unknown" in blue when there is something to sort out, "Dated only", "Guessed file" or "Not tracked" in grey, and "Local" for a mod you marked as your own. A Needs attention filter narrows a character's mods to the ones to sort out.
  - A reminder above the mods says how many mods aren't set up for update checking, with a button to sort them out. Close it once and it stays away; a switch in Settings brings it back.
  - "Update tracking…" in a mod's right-click menu links it to its GameBanana page and records which file you have.
  - That dialog can settle for the install date instead, or stop asking if the mod isn't from GameBanana.
  - "Mark all as current" settles the tracked mods with no known version among the character on screen's mods, using each mod's install date.
  - "Sort out mod tracking…" turns a library check into one pass for confirming mod pages and filling in versions.
- Mods can be checked for updates, one at a time or the whole library, and only when you press it. An amber "Newer file" badge shows what has something newer, or "Maybe newer" when that rests on a guess.
  - Update checks say whether they are sure or guessing.
  - The library check reports mods it couldn't reach separately from mods with nothing new.
  - Files an author published together count as one release, so another variant isn't read as an update.
  - An update can be ignored from its dialog, and one click undoes it, there or on the mod's History tab.
  - Updates filters narrow the character list, and a character's mods, to those with updates.
  - Settings can check for updates at startup. Off by default, and it never installs anything.
- Updates can be installed from the update dialog. The mod keeps its name, character tag, favourite star and on/off state.
  - The dialog lists every newer file and marks the one it would pick.
  - Updating replaces the mod's files with the new version's. Old files are removed.
  - An update empties the mod folder before writing the new version, so nothing of the old one is left loading. Anything you added to the folder by hand goes with it, and the saved copy still has all of it.
  - Every update saves a copy of the mod first, and "Restore a previous version…" or Restore on the mod's History tab puts it back. The confirmation says that anything added to the folder since is removed.
  - Saved versions survive renaming a mod, including renaming its folder outside the app.
  - Deleting a mod deletes every saved version of it too, and the confirmation says how many.
  - "Reinstall this version…" in a mod's right-click menu, or Reinstall on its History tab, empties the folder and puts the author's files back, without changing which version you have. It is offered once the file you have is confirmed, and not for a mod marked Local.
  - A mod whose file has been taken off GameBanana says so instead of quietly reinstalling a different version.
  - The dialog shows the author's release notes for anything published since your version.
  - Hotkeys the new version moved are listed after an update.
  - You're told what an update will do before it runs.
  - An update whose archive has several folders, with no record of which is the mod or a record that no longer matches, asks which folders are the mod and remembers the answer.
  - Updating a mod that came bundled with others offers all of them and downloads the archive once, instead of once per mod.
  - The update dialog says how many other mods came from the same archive before you start.
  - Each of those mods has its own tick box, and the ones the app can't place are listed with the reason.
  - A mod that already has a newer file, or whose updates you're ignoring, is offered but not ticked, and the row says which.
  - A progress bar counts through the folders as they're written, and the result names each one.
  - The window you wait in stays up from pressing Update until you're asked, saying whether it's unpacking the download or checking what it changes, instead of vanishing for a few seconds first.
- An install that turns out to be a patch says so, and remembers it for later.
  - Installing a patch asks where it goes: its own folder with the mod it patches fetched in for you, or straight into a mod you already have, picked from a searchable list with cover images.
  - That list puts the folders holding the files the patch replaces first, and each one says how many it holds.
  - When the patch's page names a mod you already have, that mod goes to the top of the list.
  - A patch whose files don't belong in the mod you picked installs as its own mod instead, and says which of the two reasons it was.
  - A folder holding a patch plus the mod it patches can be told about both, and both are checked for updates.
  - Checking such a folder for updates reports on both mods in full — each with its own verdict, its own before-and-after, its own release notes and its own Update button.
  - Its details panel lists the mods it is made of by name, base first and patches on top, with each one's file, author and upload date once the app has its page. The tracking dialog lists both side by side, each marked as the mod or the patch. Which one you installed first makes no difference to how any of it reads.
  - A patch can be taken back out, from "Remove patch…" in the mod's right-click menu, from its row in the tracking dialog, or with Take out on the mod's History tab: the files it added are deleted and the mod's own files come back. It saves a copy of the mod first, tells you what it will do before it does it, and says so when one of your mod's files was never saved.
  - Updating a patch takes its old version back out: your mod's own files return wherever the new patch no longer replaces them, and anything the old patch added and the new one doesn't goes.
  - A patch you dragged in yourself is remembered too, so it survives an update to the mod under it — even though it has no page to check for updates and can't be taken out from the menu.
- Every install records the files it wrote, with their sizes.
  - An update to either mod in such a folder can be installed: the base mod goes in and the patch is put back over the top. Folders you merged by hand say so first, since the app can't tell which files are which.
- The app writes a log file for each run, keeping the last seven, with your username removed and file paths shortened.
  - Each log opens with your system details: OS, distro, display server, and which required tools are installed and at what version.
  - Settings has a **Diagnostics** section to turn the log file off, open its folder, or copy a summary to the clipboard for a bug report.
- Installing an archive you have installed before asks first.
- The library's bulk actions (check for updates, sort out tracking, mark all as current) are in one menu above a character's mods, each with the number of mods it would act on.
- The Library lists every agent with their portrait on their element's colour, and how many mods they have and how many are on. Rows with no mods yet are dimmed, and the UI, Texture, Audio and Misc categories and unassigned mods sit above the agents. A filter field and chips narrow the list, and "Hide empty" hides the rows with no mods, remembered between runs.
- A character's page opens with their portrait, element, faction and role, and how many mods they have, how many are on and how much space they take.
- A character's mods can be filtered to the active ones.
- Each mod has a Note in its details panel, saved as you type and kept only on this computer.
- Each mod has a page in the Library, opened from its details panel: its pictures one at a time, its buttons, and Overview, In-game keys, History and Note tabs, with where it is stored and linked beside them. History lists the file in use and each saved version with Reinstall and Restore, the author's latest update post, the patches on top with what each changed, and an ignored update. Opening the page looks the mod up on GameBanana, so its file, author and dates show without an update check.
- A mod dropped or pasted onto a character you picked by clicking it in the list is filed under that character; elsewhere its character is worked out from its name.
- Settings has an **Updates** section for the startup check, and a **Marketplace** section for the adult-content filter.
- Settings › Appearance has an **Accent** choice: violet, paper, lime or teal. Paper colours the main button and selected chips and keeps violet for links and switches.
- **Launch game** in the sidebar starts the XXMI Launcher beside your ZZMI folder with `--nogui --xxmi ZZMI`.
- Settings › **Launch game with** picks another file, and **Launch arguments** changes what it passes.
- On Linux, Settings › **Wine or Proton** lists the builds installed by Steam, Heroic, Lutris and Bottles by name, and **Wine prefix** picks the prefix. Proton runs through umu-launcher, or directly when that is switched off.
- On Plasma, GNOME and Hyprland with hypridle, while a game started with **Launch game** runs, the screen stays on and the computer doesn't go to sleep on its own, even after the app is closed.
- The sidebar shows whether ZZMI is where Settings says, how many mods are on, and a reminder to press F10 in game after changes.
- RAR and 7z mods install with no setup: 7-Zip ships with the app, and the Arch package installs it.
- The Arch package pulls in what "open mod page" and "open mod folder" need, and lists xdotool and ydotool as optional.
- Claret, Phoenix, Roxy and Severian are in the character list, with portraits, and mods named after them are sorted to them on import.

### Changed

- The app has a new look: a dark ink background with a violet accent, or a light paper theme, set in the Geist and Unbounded typefaces, with a new app and window icon.
- The same kind of text is the same size on every screen.
- The "which mod is this?" search starts with the mod's name read as words, so `Ellen_Joe_Cheongsam` searches for "Ellen Joe Cheongsam".
- A mod with no character saved for it is listed under Unassigned, instead of being sorted to a character guessed from its folder name every time the library is read.
- The Default sort is **Recently added**: a character's mods are listed newest first, with mods that have no install date last.
- Ctrl+V on the Library imports .zip, .7z and .rar archives whose paths are on the clipboard, as well as folders.
- Notifications are small cards in the bottom-right corner. Several can show at once, any can be closed, and hovering pauses their countdowns.
- Every notification says what happened and what it happened to, led by the character's portrait.
- Enabling, favouriting, renaming, retagging, reading the library again and deleting report only when they fail.
- Notifications are drawn above dialogs instead of behind them.
- Install confirmations name the mod that arrived, and anything you need to act on comes as its own warning beside it.
- Mod descriptions are better spaced, and consistently styled everywhere they're shown.
- Descriptions keep the paragraph spacing their author gave them.
- Downloaded archives land in the app's own downloads folder and are deleted once installed. Anything left over is cleared when you next start the app.
- The title bar shows the Zenith logo and its own window buttons. Dragging it moves the window, a double-click maximises it, and a right-click opens the window menu.
- The sidebar is laid out in Library and GameBanana sections. Characters shows how many agents there are, and Updates opens the characters and mods with an update.
- Pressing a mod card selects it and opens its details; the switch on the card turns it on and off.
- A mod's details are a panel beside the mods instead of a dialog, showing its pictures, description, tags, in-game keys, where it came from, when it was added, its size and its folder, with Open folder, Check for updates and Delete.
- The Single/Multi switch is **One at a time**, a switch per character: with it on, turning a mod on turns that character's other mods off. It starts on for agents and off for the UI, Texture, Audio and Misc categories, and is remembered.
- The favourites filter is a Favorites chip beside the other filters above a character's mods, and one filter applies at a time.
- Refresh is **Read the library again** in the ⋯ menu above a character's mods.
- A status bar along the bottom shows the ZZMI folder, how many links are active, and the version.
- Settings offers Light, System or Dark in place of the dark-mode switch. System is what the app starts on, and it follows your desktop's own light or dark setting for as long as you leave it there.
- A mod's right-click "Open source page" and the GameBanana link in its details panel open the page it's tracked against, so a mod you linked through "Update tracking…" has them without you typing a link.
- Settings and first-run setup ask for the ZZMI folder instead of the links folder, and show where links and shader fixes go.
- The "Mods folder" setting is called "Mod library".
- A links folder that isn't ZZMI's Mods folder gives way to the Mods folder beside it, so mods linked there show as off until they are switched on again.

### Removed

- The embedded webview (Windows) and the Downloads-folder watcher (Linux), replaced by the built-in browser.
- F10 auto-reload — the F10 button, the auto-reload toggle and the "Automatic mod reload" settings section — because a keypress the app sends never reaches a game running under Proton, so it only ever claimed to work. Press F10 in the game; xdotool is no longer needed.
- The Source link box in a mod's Edit dialog. Which mod page a mod belongs to is set by "Update tracking…" now, which is also what decides where updates are checked.
- Collapsing the sidebar.
- The ALL tab. Every mod is under its character, and mods with no character have a row of their own.
- The search box and tag filter above the mods.
- The ↗ button on mod cards. A mod's page opens from its right-click menu and its details panel.
- Editing a description from a mod's details. Edit info edits it.
- Tags on mod cards. A mod's tags are in its details panel.

### Fixed

- Zip archives whose paths were written with Windows separators now extract into their folders instead of as files with `\` in their names.
- Enabled mods are no longer switched off when the mods folder is missing at launch, for example on a drive that is not mounted yet.
- Mod images left in the app's own data folder by versions before 2.0.0 are cleared once they're inside the mod they belong to, instead of being kept twice forever. A library upgraded long ago can get hundreds of megabytes back.
- The app shows its own icon and name in the taskbar and window switcher instead of a blank placeholder.
  - On Wayland the window no longer carries two stacked title bars.
  - The portable build gets its icon on Wayland by running `packaging/install-desktop-entry.sh` once. It stays out of your application launcher unless you pass `--menu`.
- A missing 7-Zip is reported as a missing tool rather than a broken archive.
- Importing a folder no longer follows symbolic links out of it.
- A mod whose folder can't be written to is named instead of failing quietly.
- An import that fails says what went wrong — no mods folder set, the copy failed, no room — instead of reporting that the mods are already in your library.
- Editing a mod's hotkey updates the library straight away instead of after a tab switch.
- Ukrainian counted messages use the right form of the noun.
- Importing or deleting a mod no longer replays the "switched character" animation across the grid.
- Turning a mod on or off no longer rebuilds its card, so it keeps its hover lift.
- "Detect tags for all mods" no longer blanks the Settings page behind a blocking dialog.
- Cover images are decoded at the size they're shown, cutting the app's image memory.
- Certificate validation is no longer disabled when downloading mods.
- Installing a mod no longer risks deleting the folder its archive was sitting in.
- Metadata written by a newer version of the app is no longer erased when you edit a mod's description, tags or character.
- Saving a mod with no character no longer records "unknown" as its character.
- The theme you pick is still there the next time you start the app.
- A saved version's size is measured past a file the app can't read, instead of stopping there and reporting the short total as the whole.

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
