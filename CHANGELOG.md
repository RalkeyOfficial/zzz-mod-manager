# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The Marketplace is now a built-in GameBanana browser, working the same way on Linux and Windows: search or browse ZZZ mods, filter by category or character, sort, then open a mod to see its screenshots, description and full file list and download from there. Opening a mod and coming back leaves the results exactly where you had scrolled to. Linux no longer has to send you to an external browser.
- A "best of" carousel above the Marketplace grid cycles through GameBanana's top three mods for each of seven periods — today, this week, this month, 3 and 6 months, this year, and all time. Each card shows the mod's cover full-width with its title over the top; click it to open the mod. It advances on its own, and pauses while your cursor is over it or while you have a mod open, so you come back to the card you left.
- Mods flagged as adult content on GameBanana are blurred until you click to reveal them, with a Marketplace toolbar setting to show them unblurred or hide them entirely. Your choice is remembered between sessions, as is the Marketplace sort order.
- Marketplace mod cards show how long ago each mod was first released and last updated, with the exact dates on hover.
- The mod detail view shows the author, category, when the mod was first released and when it was last updated, and each file's name, size, upload date and GameBanana's own virus-scan result, and can list older superseded versions. When a mod offers more than one file, you choose which to download.
- Marketplace downloads now resume where they left off instead of starting over, survive the app being closed mid-download, and show a transfer rate and estimated time remaining.
- Marketplace downloads can now be cancelled while in progress.
- Mods now record where they came from, so a future release can tell you when an update is available. A Marketplace download records exactly which mod and which file it was; an archive or folder you import yourself records how it arrived and, for archives, its checksum.
- Mods you already have are now linked back to their GameBanana page automatically, using the source URL already stored on them, so update checking will work for your existing library and not just for new installs. No new files appear in mods that have no source URL.
- The Marketplace now marks mods you already have. Cards and the mod page show which of your mod folders came from that page — several, when you have installed more than one variant — and the file list marks the exact file you installed, or notes when a file is byte-identical to an archive you installed.
- Installing an archive you have installed before now asks first, naming the mods it produced, instead of quietly making a second copy. Applies to Marketplace downloads and to archives you import yourself. It can only recognise archives this version installed, and never a re-packed copy of the same mod.
- Mods installed from the Marketplace arrive with their description and screenshots (up to ten) already filled in from their GameBanana page, and are tagged with the character the mod is filed under there rather than with whatever the folder name reads as — so a Zhao skin called "Zhao Nicole" lands under Zhao. Mods not filed under a character still fall back to the name. Anything the mod folder already carried is kept, including a preview image shipped inside the archive, which stays the cover.
- Mod cards now show how well each mod is set up for update checking, in one mark at the corner of the cover: amber when we know which GameBanana mod it is but not which version you have, a quiet clock when only the install date is recorded, a quiet broken link when its GameBanana page has been taken down, and a quiet dot when it isn't linked to a mod page at all. Nothing is shown once the exact file is known. A new toolbar button lists how many mods still need attention — the amber and the unlinked ones — and filters the library down to them.
- Clicking that mark — or "Update tracking…" in a mod's right-click menu — opens a dialog to link a mod to its GameBanana page and say which file you have. It states what it already has on record first: which mod page, whether that came from a download, from you confirming it or from a link you pasted, and which file and version — or that only a date is recorded, and which date. Then it searches for the folder name or takes a pasted mod page link, marks the file you already chose, and says *why* it thinks a particular file is yours rather than just guessing.
- If you don't know which file you have, the same dialog will settle for remembering the date and telling you about anything published after it; if the mod isn't from GameBanana at all, one click stops it asking. It can also fill in a description, screenshots and tags the mod is missing.
- That same answer can be given to a whole library at once: "Mark all as current" in the Mods toolbar's Library menu settles every mod that is linked to a mod page but has no known version, using each mod's install date. It filters the library down to exactly those mods before asking, makes no network requests, invents no version numbers, and says up front how many mods it will change and how many it can't touch.
- The app can now check your mods for updates — one mod at a time from its right-click menu, or the whole library from the Library menu, and only ever when you press it. Mods with something newer published get a blue mark at the corner of their cover; clicking it says what you have, what has been published since, and when.
- Update checks say how sure they are. "An update is available" is only used when the file you installed has actually been superseded, or when a newer file carries the same variant label; anything resting on a guessed link or a guessed version is reported as "possibly outdated" instead, with the reason spelled out. GameBanana publishes no comparable version numbers, so this is a best guess by design and never claims otherwise.
- The whole-library check reports mods it could not reach separately from mods it found nothing for, so a connection problem can never read as "everything is up to date". A mod page that has been removed is reported as such, and one mod with a bad link no longer spoils the check for the rest.
- Update checks read the mod's release history, so a *different variant* of a mod is no longer mistaken for a newer version of yours: files the author published together — an SFW and an NSFW build, or four proportion variants in one post — are treated as one release. Two files the author stamped with the same version number are too, even when they were posted weeks apart.
- An update you don't want can be ignored from its dialog. The mark disappears from the mod's card, the mod stays tracked, and anything the author publishes afterwards shows up again on its own. One click undoes it.
- Once the update check has found something, a toolbar filter narrows the library down to just those mods — so three updates among a hundred and twenty-eight mods are one click away rather than something to scroll for. Once you've dealt with the last update the filter switches itself off rather than leaving you looking at an empty library.
- When a mod has published more than one file since the one you have — an SFW and an NSFW build, say — the update dialog lists them all rather than picking for you, and marks the one it would choose along with why: because it matches your variant's label, or merely because it's the newest. Where the labels match, your variant wins even if the other one is newer.
- Found an update? You can now install it. The update dialog's "Update" button downloads the file and writes it over the mod's own folder — the mod keeps its name, its place in your library, its character tag, its favourite star and its on/off state. Where a mod offers several files, click the one you want first.
- Updating never empties a mod folder, only writes over the files the new version replaces. Anything you added yourself — a patch you applied on top, a second mod you merged in, your own textures — stays where it is.
- Every update saves a copy of the mod first, and "Restore a previous version…" in a mod's right-click menu puts it back. Restoring saves a copy too, so it can be undone. Copies are kept for at least a month, up to three per mod, within an overall size budget.
- The update dialog shows the author's release notes for anything published since the version you have — their changelog and their write-up — so you can see what you're getting before you install it. They sit in a collapsible section you open when you want them and close when you're done.
- After an update, any hotkey the new version moved is listed as "Skin — F7 → F9", with an explanation of why nothing was carried over and where to set it again. Keys the update left alone aren't listed, so the section only appears when something actually changed.
- Before an update is applied you're told what will happen: that a copy is being saved, that keys you rebound inside the mod's .ini will go back to the author's, and — if the download turns out to be a patch rather than a whole mod — that only its .ini files are being replaced.
- If a new version renames its .ini file, the old one is offered up for deletion — leaving both means two are loaded at once, which usually shows up as broken hotkeys. An .ini belonging to a *different* mod merged into the same folder is never offered, and is named so you know why.
- Installing something that turns out to be a patch — .ini files with none of the content they need — now says so straight away, instead of leaving you to work it out when the game shows nothing. Mods that only replace part of a character, which is most of them, are not mistaken for patches.
- When the app can't tell where a downloaded archive's folders should go — because the mod predates this version, or the archive is laid out differently now — it stops and says so rather than guessing. Download it as a new mod instead.
- Checking the whole library now doubles as a way to sort out where your mods came from, in one pass: mods whose link to a mod page was only worked out from a URL are listed side by side with the page they point at for you to confirm, mods with no known version get theirs filled in where the answer is obvious or a file picker where it isn't, and mod pages that have been taken down are recorded as gone so nothing keeps asking about them. It uses the check's own results, so it costs no extra requests, and nothing is saved until you press Save. Reachable at any time from "Sort out mod tracking…" in the Mods toolbar's Library menu, not only right after a check.
- The Mods toolbar is search plus a **Library** menu on one row, with every filter on the row below. The three things that act on the whole library — check for updates, sort out mod tracking, mark all as current — live in that menu with a count each.
- Downloads now run in the background, so you can keep browsing — or queue up several mods — instead of watching one archive arrive. Two run at a time and the rest wait their turn; each one installs itself as it lands, and only stops to ask you something when it has to. A button appears in the title bar while anything is in flight, listing every download with its size, rate and time remaining, and a button to cancel, retry a failed one, or clear the finished.
- A download still reports itself while it runs: one notification in the corner shows how far along everything is, how fast, and how long is left, and stays until the last one is done. It doesn't block anything, it names the mod when there's only one, and you can close it if you'd rather watch the list instead.
- Settings can now check for updates when the app starts, so the blue marks are already on your mods instead of waiting for you to find the button. It's off until you turn it on, it only speaks up when it actually found something, and it never downloads or installs anything — updates are always applied by you.
- The Settings tab has an **Updates** section for that, and a **Marketplace** section holding the adult-content setting that until now only existed in the Marketplace toolbar. Both places change the same setting, so it reads the same wherever you look.
- RAR and 7z mods now install without you setting anything up first. The Windows and Linux portable builds ship with 7-Zip included, and the Arch package installs it for you — previously the app needed one you had already installed yourself, and most mods on GameBanana come as .rar or .7z.
- The Arch package also pulls in the tool behind "open mod page" and "open mod folder", and lists xdotool and ydotool as optional extras for F10 auto-reload, so a fresh install has what it needs.
- The Mods tab's default sort is now **Recently added** and sorts by when each mod was installed, newest first. Mods with no known install date stay at the end in the order they were already in, rather than being shuffled into a guess.
- A mod's page in the Marketplace now shows the author's tags, in the same form they get stored under when you install it — so a mod reads the same whether you're browsing it or looking at the folder it became.
- The category on a mod's page is now a link. Clicking "Ellen Joe" — or "Bangboo Skins", or whatever it's filed under — takes you back to the grid showing everything else in that category.

### Changed

- Notifications are now small cards in the bottom-right corner instead of one wide bar across the bottom: several can be on screen at once, any of them can be closed, and hovering anywhere over them pauses the countdown on all of them — so you can take your time reading without one vanishing mid-sentence. Moving away starts the countdowns again from the top. The longest-standing one drops off once four are showing.
- Every notification now says two things: what happened, and what it happened to. "Mod installed" carries the mod's name, "Couldn't extract the archive" carries where the file was left. Messages about one of your mods lead with that character's portrait; mods filed under UI, Texture, Audio or Misc show that category's icon instead.
- The app no longer confirms things you can already see. Enabling a mod, favouriting one, renaming one, editing its tags, refreshing the library, changing language and deleting a mod all report only when they *fail* — the switch, the star, the name and the card itself already tell you when they work. Deleting in particular now only ever speaks in red.
- Notifications raised while a dialog is open are now visible — they used to be drawn behind it, which covered most messages from renaming, deleting, editing keybinds and the whole update flow.
- Install confirmations now name the mod that arrived and say nothing more about the work — the auto-tags and the list of fields copied from the mod page are gone. Anything you need to act on (a mod with no `.ini`, a download that turned out to be a patch, tracking that couldn't be saved) arrives as its own separate warning beside it, rather than several problems joined into one paragraph you have to read to the end to count.
- Mod descriptions are easier to read: body text is larger, lines are more generously spaced, and headings, lists, quotes, code, tables and horizontal rules now follow one consistent style everywhere a description is shown. A `---` divider is a hairline instead of a thick bar.
- Descriptions keep the spacing their author gave them: blank lines between paragraphs are a full line tall rather than a hairline gap, and a run of several stays as tall as it was written instead of collapsing into a single break.
- Downloaded archives now always land in the app's own downloads folder and are deleted once installed; an archive that fails to extract is kept, and the app tells you where to find it.

### Removed

- The embedded webview (Windows) and the Downloads-folder watcher (Linux) are gone, replaced by the built-in browser above. The watcher could only notice a file appearing and had to guess when your browser had finished writing it, so it also picked up unrelated downloads and could never tell which mod a file belonged to.

### Fixed

- A RAR or 7z mod that can't be unpacked because 7-Zip isn't installed now says so, and says the download itself is fine. It used to report the same "couldn't extract the archive, extract it by hand" as a genuinely broken file, which points away from the actual fix.
- A mod whose folder can't be written to now says so instead of failing quietly. Its update-tracking data can't be saved, so it is never checked for updates and looks like an ordinary untracked mod; the library now names it, and keeps saying so until the folder is fixed.
- Editing a mod's hotkey now updates the mod straight away. The new key was written to the `.ini` correctly, but the library kept showing the old one — in the right-click menu, the details dialog and the hotkey editor itself — until you switched tabs and back.
- Ukrainian counted messages now use the right form of the noun. The language has three where English has two, so anything between 2 and 4 read as "2 модів" instead of "2 моди" — and messages about a single mod said "1 мод" even when there were 21 of them, since Ukrainian uses that same form for every count ending in 1.
- Importing or deleting a mod no longer plays the whole "switched character" animation across the Mods grid — sliding everything out to the left, back in from the right, and re-animating every card. That transition now happens only when you actually switch character, which is what it was for.
- Turning a mod on or off no longer rebuilds its card from scratch, so the card keeps its hover lift instead of dropping it under your cursor until you move the mouse away and back. The active border and glow now ease in rather than snapping.
- "Detect tags for all mods" no longer blanks the Settings page behind a blocking dialog and then replays the whole page's entrance animation on the way back. The button reports on itself — it spins and disables while the pass runs — and nothing else on the page moves. The work is a scan of your mod folder names, so it is usually over in a moment.
- Collapsing or expanding the sidebar no longer causes an exception across the navigation buttons. A label that does not yet fit the sidebar's animating width now shortens with an ellipsis instead of spilling out of it.
- Mod cover images are decoded at the size they are shown rather than their full resolution, cutting the app's image memory dramatically — a 49-cover library previously held over 200 MB of decoded image data, enough that scrolling the library could push other images out of memory and force them to reload.
- Certificate validation is no longer disabled when downloading mods.
- Installing a mod no longer risks deleting the folder its archive was sitting in.
- A failed or interrupted marketplace download no longer leaves a partial file and an open file handle behind.
- Mod downloads ran several times slower than the connection allowed — pinned near 3 MB/s no matter how fast the server was. They now run at whatever speed the server will give: about four times faster on an average-sized mod, closer to five on a large one, and limited only by the connection.
- Mods downloaded from the Marketplace now carry a link back to their GameBanana page, so "open mod page" works on them straight away. A link already stored on a mod is never replaced.

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
