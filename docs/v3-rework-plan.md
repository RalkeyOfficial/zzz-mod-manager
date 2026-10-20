# v3 UI rework: working plan

The working plan for rebuilding the UI to the Zenith design. It lives on the `zenith-ui` branch only and is deleted when that branch merges. Everything durable (rules, reasoning) goes into the docs that own it, not here.

## Ground rules

- **Target:** the claude.ai Design canvas "Zenith v3 UI", https://claude.ai/artifact/1Sy7dkEKL6RwurthEEpZgv. Read it with the Artifact tool (`action: "read"`, then the `project/*.dc.html` files). It has 30 artboards.
- The canvas was designed without seeing the code. It is the target; the current UI is replaced, not preserved. Everything on it gets built, including features the app lacks.
- Where the canvas has a gap, design the missing piece in its style without asking. Where it moved something (rename is the Name field in Edit info, not a right-click dialog), the canvas placement wins. Ask only when it contradicts a decision written in `docs/`.
- **Branch:** `zenith-ui`, cut from `development`. Never commit unless the user says so.
- **Workflow:**
  - Run the app with `flutter run -d linux` and hot reload. A run started in the background from Claude has no terminal, so it can't be hot reloaded: stop it and relaunch.
  - Judge resize smoothness only on `flutter run --profile -d linux`.
  - The test suite takes about 15s: `timeout 90 flutter test`.
  - Screenshots: `spectacle -b -n -f -o <file>`, then crop with `magick` (the screen is 4480×1440 across two monitors).
- **Every change also:**
  - adds a `CHANGELOG.md` `[Unreleased]` line that is a net change against the last release (rewrite contradicted lines rather than stacking new ones);
  - puts new strings in both `assets/l10n/en.json` and `uk.json`, with counted strings through `loc.plural`;
  - has no `fontSize:` or `Color(0x…)` literals in new code (roles from `core/type_scale.dart`, colours from `ZenithPalette.of(context)`);
  - keeps platform behaviour in `PlatformService`;
  - updates the doc that owns the area.
- New features with real logic (Loadouts, notes, favourites rework, palette, per-character mode, library watcher, Move library, archive passwords, Pause) get a short design note in `docs/` **before** their code.

## Decisions already made

The memory note `v3-canvas-vs-docs-decisions` holds these. In short:

- **Toggle toast:** the "X is on… press F10" reminder shows only while the game is running, gated by a "Remind me to press F10" setting. Undo is an optional action added to `context.notify` in one place.
- **Keybind edits:** not carried over an update (`applying-updates.md` §8 stands). Correct the canvas copy in Edit info and Reinstall ("keys included, are put back") to say what happens.
- **Browse cards:** follow the canvas, with "Update ready" and an Update button. Rewrite `marketplace.md` §7.
- **Bulk update:** allowed, with a file picked per mod and nothing preselected unless a mod has one newer file. Rewrite `applying-updates.md` §7.
- **Built as drawn:**
  - amber = update, blue = tracking and information;
  - Snapshots to keep is a per-mod count, default 3, with no separate age number;
  - delete goes to the system trash, with "also delete snapshots";
  - Pause, archive passwords, a library file watcher, Move library…;
  - 13px body text.
- **Combine choice:** the combine-or-separate option stays when a download's files look like a base mod plus a patch.
- **Mod page:** no file-tree preview anywhere. "In the folder" keeps its note and the Stored at / Linked as / Tracking facts.
- **Rename to Zenith:** application id, window title and app-data folder, as the last phase with a migration. The UI already says Zenith.
- **Paper accent:** the canvas's option B. Paper fills the primary button and a selected chip; links, switches, badges and other on-states stay violet.
- **Install decisions wait in Downloads:** a background download that needs a decision (looks like a patch, several folders in the archive, a password) doesn't open a dialog. It waits in the Downloads panel's "Needs your attention" group with a button that opens its dialog, and the sidebar's Downloads item shows an amber warning badge with that count.
- **Recommended Proton builds:** Proton-GE, Proton-Cachy and DWProton (for example `dwproton-11.0-5`) carry a Recommended badge in first run's Proton list.

## Status

- **Phase 1, theme and tokens:** done, commit `3b4cc66`. It added:
  - `core/palette.dart` (`ZenithPalette`: ink and paper grounds, four accents, signals, badges, element tiles);
  - `core/app_theme.dart` (`buildAppTheme`);
  - `core/type_scale.dart` (canvas roles, plus `ZenithType` for caps, mono, monoSmall, wordmark and watermark);
  - the bundled fonts with their OFL licences, the accent setting and the new icons.
  - Follow-up, commit `6c5d5ac`: component values matched to the canvas, with new palette tokens (`rowHover`, `rowDivider`, `dialog`, `menu`, `menuBorder`, `chip`, `track`, `edge`, `check`, `link`, `selected`), 36px fields, 16px icons, `ZenithSwitch`, the primary hover on every accent, and the test harness on `buildAppTheme`. Canvas colours still without a token (toast `#1E2125`/`#353941`, panel `#0D0E10`, danger hover `#FF7F70`, the 30px small button, Unbounded 30/22/18, the outlined slanted watermark) get one when a screen needs them.
- **Phase 2, title bar and shell:** done, commit `5e531d2`.
  - Follow-up, commit `53474e9`: Tab reaches the sidebar rows; the status bar shortens only a path inside home; saving Settings re-checks ZZMI; the window buttons are the canvas's line drawings; the selected row takes `rowSelected`; the top resize strip stops at the window buttons; the Downloads panel opens against the sidebar's edge.
  - Follow-up, the commit after it: Launch game runs the XXMI Launcher beside ZZMI with editable arguments, through `ShellExecuteW` on Windows and on Linux under a Wine or Proton build picked from the ones found (Proton through umu-run, or directly when switched off).
  - The user has confirmed edge resize works on KDE Wayland and accepted the slight resize lag.
  - Not yet reported back on: the title bar's drag, double-click and right-click window menu, the window buttons, Super+arrow tiling, and Launch game with Proton started directly.
  - The user has confirmed Launch game through umu-run, with the Zenless Zone Zero game id, starts the game with mods.
  - Follow-up: on Linux, while the game runs, locks keep the screen on and the computer from sleeping on its own, held by `systemd-inhibit`, `gnome-session-inhibit` and `kde-inhibit` beside the game ([`launch-game.md`](launch-game.md), "Keeping the screen awake"). Measured on Plasma through umu-run with the commands the button runs, started by hand; not yet through the button itself.
  - What it added:
    - the runner's hidden `GtkHeaderBar` with `TitleBarStyle.hidden`;
    - `screens/shell/` (`title_bar.dart`, `app_sidebar.dart`, `status_bar.dart`, `keycap.dart`, `launch_game.dart`);
    - `AppDestination` with `destinationProvider` in place of `tabIndexProvider`;
    - `zzmiPathProvider` and `zzmiFoundProvider`;
    - `launch_target`, `launch_arguments`, `wine_runner`, `wine_prefix` and `wine_use_umu`, with `PlatformService.launchGame(LaunchRequest)`, and `docs/launch-game.md`;
    - `DownloadsNavItem`;
    - a sidebar that scrolls when short.
  - Docs updated: `desktop-integration.md` §4 (the rule, the hazard and what still differs).

- **Phase 3, Library character view and details panel:** built, reviewed and committed (`3a163d3`).
  - Agreed with the user: the scan does not guess a character from the folder name, so a mod with no stored character is under Unassigned.
  - The manual update check runs in `LibraryActionsHost` above the page switcher.
  - A known limit, in `library-screen.md` §10: One at a time can't swap two mods with a shader file at the same path and different contents.
  - Decided with the user: notes live in `config.json` (`mod_notes`), not the sidecar, since a note is per-user opinion and the canvas says "Only you see this".
  - Decided without asking, written into `library-screen.md`: one status badge per card beside the Active badge (amber update, blue asks, grey states, "Local" for tracking off); One at a time defaults on for agents and off for categories, absent on Unassigned, stored as `one_at_a_time`; a drop on a character the user picked files the mod under them; dates stay `2026-09-28` as elsewhere in the app; no "open character folder" button, since the library is flat.
  - Wind and Lumiflux tiles are colours designed in the canvas's style (Wind green, Lumiflux rose); the canvas has only the five original elements.
  - The Library's search is the All mods table's (phase 5); a tag filter waits for the palette (phase 8).
  - The author line and the File / Uploaded facts show only once a check has the mod page in hand; phase 8's Edit info adds an author field of its own.
  - The roster's attributes, factions and roles are for the user to verify (Phoenix and Severian are unreleased; Belle and Wise are set to Phaethon with no attribute).
  - The details panel's "Made of N mods" list, committed (`36b59bc`): between the keys and the facts, base first and patches on top, each with a Base or Patch badge, its name, file, author and upload date, and a "Manage in History" link. It shows only when more than one download is registered on the mod (`origin.downloads`).
    - The panel draws its own list (`ModMadeOf` in `mod_detail_parts.dart`); `FolderDownloadsSummary` stays for the resolve dialog.
    - Like the facts, a row's file, author and date come from a page the session holds (fetched by a check, an install or a dialog), and the file and its date only for a file on record, confirmed or worked out in the tracking screen (phase 5). A row's name links to its GameBanana page; a patch with no page reads "Patch from a local file".
    - Decided with the user: each download saves its page's title as `name` in the sidecar, a display copy that every fetch rewrites. Without it, a patch installed as its own folder listed the base by the patch's file name and the patch by its id until a check ran, since the folder takes the patch's archive name. No row uses the folder name for a layer with an id.
    - Not changed, and for the user to decide: that same folder's description and pictures come from the patch's page.
  - Follow-up, characters without mods (artboard `Main`): built, reviewed and committed (the commit after `476710a`). A "Hide empty" switch under the chips replaces the "Has mods" chip, off by default and stored as `hide_empty_characters`. On, it hides every row with no mods, categories and Unassigned included, and a line under the agents ("3 agents without mods hidden · Show") turns it back off. Written up in `library-screen.md` §2.
    - Decided with the user: the label is "Hide empty" rather than the canvas's "Show characters without mods", so the switch is on when rows are hidden. The row on screen stays listed when it has no mods, so deleting a character's last mod leaves their row under their page.
    - Decided without asking: only agents are counted, as on the canvas, and only those the field and chips would otherwise show, so Active or Updates never shows the line. The sidebar's Characters count follows the switch, counting the agents with a mod while it is on. A search that matches only hidden rows says "Only rows without mods match · Show". Until the first scan returns, neither the line nor the count speaks, and the count stays the roster.

- **Phase 4, Mod page** (artboard `ModPage`): built, reviewed and committed (the commit after `ab3fc69`). Written up in `library-screen.md` §15.
  - The page shows in place of the character view through `openModPageProvider`, with the character view kept mounted under it; the panel's full-page button opens it on Overview and "Manage in History" on History, for every stacked mod.
  - The canvas draws only History. Overview (description, tags, Made of, facts), In-game keys (the list, Change keys opening the keybinds dialog, an F10 line) and Note were designed in its style, with "In the folder" as the side column on every tab.
  - Decided with the user: opening the page fetches each download's GameBanana page and the base mod's update feed (Local and pageless mods fetch nothing); Stop ignoring is on History, while Ignore stays in the update dialog (phase 5b puts it on the Updates page's Newer files rows too, which also show the file you have beside the newer one); the install date reads "installed on <date>" on the page and as the bare date in the facts, however it was worked out.
  - Decided without asking: canvas copy that contradicted the docs is rewritten (snapshots are of the whole folder; taking a patch out also deletes what it added; an ignored update stays installable and lapses on anything newer; the note and snapshots live outside the folder). The retention line states no numbers ("older snapshots are cleared as the store fills; the newest is always kept") and has no "change" link until phase 7 adds the setting. A snapshot is named by its sidecar's file when that page is held, else by when it was saved. The page's mod name got a 30px `ZenithType.pageTitle` and its empty gallery a 120px `watermarkMedium`.
  - From review: the panel's note follows the page's; Stop ignoring re-folds the session verdict so the badge returns; restore and patch removal read the app's container and hold History's buttons while they write (`modWritesInProgressProvider`); the page refetches when the tracking changes and keeps a key fixed at opening (`ModPageRequest.pageKey`); drops and Ctrl+V are off under the page; Reinstall needs a file on record on a tracked mod in the menu and on History (`canReinstall`; a worked-out file counts from phase 5); the Characters row closes the page only when the Library is showing; links take the text colour on hover (`ZenithLink`). Canvas values matched: framed star, 12px gaps, `dialog`/`check`/`control` tokens, 14/16 Active box, radius 12 boxes, 12px side notes on the page and 11px regular ones in the panel.
  - The restore confirmation is shared with the backups dialog (`restoreSnapshotFlow`) and says a restore removes what was added since. Snapshots taken before a patch removal are labelled as such.
  - Not yet compared with the canvas on screen: KDE asks before xdotool may drive the window.

- **Phase 5, All mods table** (artboard `AllMods`): built, reviewed and committed (`f9a0dbc`, with `429ce0c` after it). Written up in `library-screen.md` §16.
  - The Library has two views on one page, Characters and All mods (`AppDestination.allMods`), with a mod's page over either; the sidebar gains All mods.
  - Folder missing rows come from a read-only listing of dead links in ZZMI's mods folder (`PlatformService.listDeadModLinks`); a library mod whose own link is dead isn't listed again. Not yet run on Windows. Windows links are made and read through the Win32 API, never through `cmd`.
  - Needs a Windows session before release: a mod named `Ellen&Lycaon` and one named `x&calc` turned on (a junction with exactly that name, no program started); a junction and a directory symlink each detected and turned off; a failed replace leaving the old link untouched, a successful one leaving no `DISABLED.zzz-mod-manager.relink.<name>` or `….relink-old.<name>` behind, and renaming a junction and a directory symlink aside and back (`Link.rename`, which the swap relies on); the unprivileged symlink falling back to a junction, and only that error doing so; a symlink to a mod on a mapped drive leading to the share (`dir` shows the plain target), reading On, and the game started elevated through the launcher loading it; existing mods still reading On; a mod whose link path passes 260 characters turned on and off; a library on a network share with Developer Mode on (the mod reads On once turned on, turns off, and follows a library change) and off (turning it on with the switch or bulk Enable, or changing the library to it, leaves the mod off with no dead junction and a notice that a mod on a network folder needs Windows Developer Mode); "Open in file explorer" on a mod whose folder name has a comma in it.
  - Decided with the user, from the redesigned `AllMods` artboard: no ⋯ menu and no "Read the library again", no tracking reminder strip and so no Settings switch or `tracking_nudge_dismissed` setting for one, a "Can't be checked" chip on the table where the character view has Needs attention (the same filter under its own name), the tracking badges in the Updates column, and "Mark N as current" in the selection bar opening the new `AssumeCurrentModal`. An Updates column replaces File uploaded and Source, one state per cell, the check's verdict where the app could check and the tracking prompt where it couldn't (`library-screen.md` §16). Base unknown shows a live update of the patch's own page; a mod marked as current reads Up to date with a tooltip saying it was checked by its date; a mod with no verdict reads "—", never Up to date; an ignored update reads Up to date, since it was ignored as not the user's file; Not on GameBanana and Couldn't check are grey text with a tooltip saying why; Local is grey text. The column sorts by need, Newer file first, with "—" last. In the check itself, for the card and the chips too: a layer with no mod page, such as a patch from a local folder, is left out of the folder's verdict, and an ignored update counts as up to date per layer, so another layer that couldn't be checked makes the folder Couldn't check (`update-checks.md` §2). Decided without asking: it is 172px wide, the longest state in Ukrainian, and drops after Size and before Character / type at narrow widths.
  - Decided with the user and the designer: a guessed file ("Guessed file") is shown like a known one everywhere, its name and upload date with no badge, since the user accepted it in the tracking screen. "Base unknown" is settled in the tracking dialog, so "Mark as current" leaves it out.
  - Decided without asking: bulk Enable leaves all of a character's ticked mods off when One at a time is on for them, and says so, since picking which one stays on is the user's call (`library-screen.md` §10); bulk actions act only on ticked rows the table shows; bulk Delete is the existing permanent delete until phase 8's trash; "Update N" waits for phase 8's `UpdateModal`.
  - Decided with the user in review: Reinstall is offered for a worked-out file and a guessed page too; a switch press on a mod whose folder is being written waits for the write, and the bulk actions skip such a mod and name it (`library-screen.md` §16); at a narrow window the selection bar's actions are icons with tooltips. Decided by the council at the user's request: a mod's keys are re-read when its `.ini` files change, and the library is rescanned when the window regains focus (`library-screen.md` §12); a mod reads On only when the link of its name points at its own folder, and changing the Mod library re-points links into the old folder (`configuration.md`).
  - The character view has no library menu, tracking reminder or "Read the library again"; the `AssumeCurrentModal` is Mark as current's confirmation.

- **Phase 5b, Updates page** (artboard `Updates`): built, reviewed and committed (the commit after `429ce0c`). Written up in `library-screen.md` §17.
  - A third Library view (`AppDestination.updates`) inside `ModsScreen`, so a mod's name opens its page over it ("Updates / <mod>"). The sidebar's Updates row opens it; the table's Updates chip stays a filter of the table. All mods' line under Can't be checked reads "Sort these out on Updates" and opens the page.
  - Built as drawn: header with Last checked and Check all for updates; the coverage strip and legend; Newer files with Ignore (a page-level `ignoreUpdate`, the dialog's write) and Update (today's update dialog); Can't be checked with Hide, the Which file? card, the marked card with Check them now and Undo, and the shared Not tracked / Base unknown card. "Update N" in the header is not built; it comes with phase 8's `UpdateModal`.
  - Decided with the user:
    - A mod the app can check reads checked only once this session's check has answered from its page. Before that it has no pill of its own ("N not checked yet" in the legend). The strip starts at 60 pills, empty ones between the checked mods and the ones that can't be checked; each mod the check reaches takes an empty pill's place, and once they run out the strip grows a pill per mod, batch by batch, filling from the left. Which file?, Base unknown and Not tracked are drawn from the start.
    - Dated only counts as checked in "N of your M", as the canvas's after-marking numbers do (50 of 61), once a check has compared it.
    - Local mods have no pill and are left out of M, with a "N Local, not counted" legend item, so the line can reach all of them; the canvas has no Local mods in its example.
    - Both See them links open All mods on Can't be checked; the table has no Which file?-only filter.
    - Ignore stays on the Newer files rows, since they show the file you have beside the newer one, as the update dialog does.
  - Decided without asking:
    - Undo puts back only mods whose base still holds what the marking wrote, skips and names mods whose folder is being written, keeps those and the ones whose write failed in the marking so Undo can be pressed again, names a folder gone since and lets it go, and takes back the base's session verdict: a folder of one download loses it, a mixed folder is folded again with the base asking which file, and a base page found gone or that couldn't be compared keeps its verdict. The marking lasts until nothing is left to undo, the next marking or the app closing. The marked card comes first, with the Which file? card under it while any mod still asks.
    - Marking reports a failure, always names mods skipped because their folder was being written, and reports other skips only when nothing was written, since the card shows the success.
    - New tokens: `coverageWhich`, `hatch` and `infoWash` in the palette, and `ZenithType.lead` for the 18px coverage line.
  - Checked in renders from a widget test (wide, 700px, after marking, and the strip before, during and after a check), not yet in the running app.
  - Follow-ups:
    - An Ignore or an applied update from the update dialog while a check runs is overwritten when the check's results land, and All mods' Update button is enabled during checks. Check all for updates is also enabled while the Updates page's Undo or Ignore is still writing, and that check's results then bring back what they took away. One fix covers all of them: skip merging the results for folders whose tracking changed while the check ran.
    - For a native Ukrainian speaker to check: `library.updates.coverage_all_single` at 21 ("Ваш 21 мод перевірено"), `legend_base_*` keeping "основа невідома" whatever the count, and `undo_failed_write`.
    - `refoldDismissal` (Ignore, the update dialog) finds a layer by its mod id, so a patch from its base's own mod page shares the base's Ignore. Finding the layer by position, as Undo's `forgetBaseVerdict` does, would keep them apart.
    - In the strip, a fade still running among the question pills can land on the neighbouring pill when the strip grows or shrinks, since fades are kept by position.
    - The Base unknown legend tooltip says "The patch is checked" before any check has run this session.
    - A mixed folder whose patch already had an update counts as checked, by date, the moment it is marked, where §17 says a mod just marked isn't checked until the next check.
    - A rare verdict, a taken-down installed file whose page lists only files released with it, gives an update with no date to ignore up to, so nothing on the Updates page or in the dialog can silence it. The row reads "Its page changed" with Ignore off.
    - The `openModPageProvider` doc comment in `state_providers.dart` says "Null shows the character view", which has been stale since phase 5.

## Phases left

Each is reviewable on its own and ends with tests green, docs and changelog updated, and the user's go-ahead.

5c. **Notifications** (artboard `Notifications`), before Browse, since the Downloads panel reports through them.
   - One card for everything `context.notify` raises: an optional icon, colour, body line, up to two text actions, a close button and a progress bar along its bottom edge. An error also tints the card's border red.
   - A notification about one mod shows its character's portrait in place of the icon, with the kind as a small round badge on its corner (spinner, check or a red cross; none for a Note). One about several mods, or about a mod with no character (UI, Unknown, Unassigned), keeps the plain icon.
   - Kinds, and how long each stays:
     - Working: a spinner and the bar, until it ends; then the same card becomes its result, never a second card. With no known length the bar sweeps instead of filling.
     - Done: the accent check, only when the result isn't already on screen; 5 seconds.
     - Note: grey, a plain fact, such as the F10 reminder with Undo (shown only while the game runs, under "Decisions already made"); 5 seconds.
     - Update: amber, "3 newer files" with Review opening the Updates page; 8 seconds.
     - Needs you: blue, shown once; closing it is fine, since the Downloads badge keeps the count.
     - Warning: the amber triangle, for something that may fail next; 8 seconds.
     - Error: red, saying what failed and what to do next; stays until closed.
   - Bottom right above the status bar, the newest nearest the corner. At most 3 show; older ones fold into a "+N more" pill. Hovering pauses every timer. A repeat updates its card ("3 mods installed") instead of adding one.
   - No notification history and no countdown line on timed cards: Downloads and the badges already keep what waits for the user.
   - The `Main` artboard still draws the F10 toast at the bottom centre in an older style; build it from the `Notifications` artboard.
   - The card's colours replace the toast colours listed under phase 1: `#1B1D21` with a `#30333A` border, and `#1E1514` with a `#5A2620` border for an error.
6. **Browse** (artboards `Browse`, `BrowseMod`, `Downloads`).
   - Grid restyle, carousel, character chip and type chips, Hide installed, the mature-content and sort menus, infinite scroll.
   - Mod page with Install for (a character override), multi-file pick and Turn on after installing.
   - The downloads side panel, Pause, and archive passwords.
   - "Needs your attention" as the panel's first group: one amber row per waiting decision (patch, several folders, password), each with the button that opens its dialog and Don't install. The patch and folders dialogs are restyled in phase 8; until then the buttons open the current ones.
   - `DownloadsNavItem` shows the amber warning badge (triangle and count) while anything waits. The canvas draws only that state; the idle look is designed in its style.
7. **Settings, Storage, About** (artboards `Settings`, `Storage`, `About`).
   - Section nav (General, Game & folders, Launching, Mods, GameBanana, Storage, Appearance, About), and Game & folders including Move library… (design note first). Game & folders holds only the ZZMI folder and the mod library.
     - Move library… re-points links with the rule a changed Mod library already follows ([`configuration.md`](configuration.md#changing-the-mod-library), `ModManagerService.relinkLibrary`): a link whose target is exactly `<old>/<its own name>`, live or dead, follows when the new library has that folder; a mod the new library lacks keeps its link; a refused shader placement keeps the old link and names the mod.
     - Across drives the order is copy, re-point, then delete the old folder, so every link always points at a whole copy and a failed copy deletes nothing.
     - Open question for the designer: how Move… behaves when the current library folder is already gone because the player moved it by hand. Saving the new path in Settings already re-points the dead links and copies nothing.
   - Launching: its own section for phase 2's launch settings, laid out per platform (the artboard's Platform tweak shows both).
     - Both: XXMI Launcher (`launch_target`, path with a Found line and Change) and Launch arguments (`launch_arguments`, a text field; empty opens the launcher's window).
     - Linux only, under the line "On Linux the game runs through Proton, so Zenith needs to know how to start XXMI": Use umu-launcher (`wine_use_umu`, with where `umu-run` was found), Proton (`wine_runner`, a dropdown of the builds found plus a folder button) and Wine prefix (`wine_prefix`, Open and Change).
     - No preview of the command that Launch game runs.
   - Mods: One active per character, Snapshots to keep, Check for mod updates, Remind me to press F10. The reminder's "while the game runs" reads `PlatformService.findGameProcesses`.
   - GameBanana mature content, Appearance, Language.
   - Storage: the bar meter, per-category actions and Largest mods. Storage then leaves the sidebar.
   - About: version, an app update check (GitHub releases, a new network call), links, and app data / logs / system info.
   - Existing settings without a canvas place: auto-tagging goes to Mods, the file-logging switch to About.
8. **Dialogs and overlays** (artboards `ImportModal`, `UpdateModal`, `UpdateOneModal`, `ReinstallModal`, `TrackingModal`, `EditModal`, `DeleteModal`, `ContextMenu`, `Palette`, `PatchModal`, `FoldersModal`, `MakePatchModal`).
   - Update several mods at once (`UpdateModal`): every mod with a newer file, a file picked per mod (nothing preselected unless a mod has one newer file), Ignore with Undo, then each update in turn. It brings the primary "Update N" button beside Check all for updates on All mods and on the Updates page, shown while the last check found updates. On the Updates page, a newer file's Update then opens `UpdateOneModal`. Rewrite `applying-updates.md` §7 with it.
   - Edit info: rename, cover, author, tags, "Use GameBanana text", key recording, add and remove keys, "Restore the author's keys".
   - Delete goes to the trash.
   - Right-click menu with Space / F / E / Del shortcuts. Remove patch goes into History and the menu. The menu also has "Make this a patch for…".
   - Registering a patch by hand, for when detection misses one:
     - Make this a patch (`MakePatchModal`): turns an installed mod into a patch. Two radio cards, the same split as the install-time patch dialog, each with its own "What happens":
       - Put it into a mod you already have: library search and a ranked list with hints, nothing picked. The target is snapshotted, the files go on top with the originals kept, the patch's own folder and its ZZMI link are removed, it shows in the target's History with its tracking, and the target's on/off is unchanged.
       - Install the mod it patches from GameBanana: search or a pasted link, the linked mod suggested as a hint, a file picked. The patch's folder is snapshotted and stays; the base file goes underneath it in the same folder (the patch wins where both have a file); the mod becomes the base mod with the patch on top, both tracked; it keeps its on/off and its place.
     - Update tracking (`TrackingModal`) gets an optional step 3, Patches in this folder: patches from other GameBanana pages that were copied in by hand, added from GameBanana and removable. It only records layers; no files are downloaded or changed.
   - Command palette on Ctrl K, with a design note first. This brings back the title bar's search field.
   - Install a patch (`PatchModal`, the patch-destination prompt): "This looks like a patch", the missing-file count with an expandable list, and two radio cards with Don't install.
     - Add it to a mod you already have: library search and a ranked list with the match reasons as dashed hints ("Same author", "12 of 14 missing files are here"), nothing picked (`patch-destinations.md`).
     - Install it as a new mod with the mod it patches: GameBanana search or a pasted link, the patch page's linked mod suggested as a hint, and a file picked from that mod.
     - The install button names the result ("Patch Winter Maid Uniform", "Install as new mod") and stays disabled until the choice is complete.
   - Archive with several folders (`FoldersModal`): the archive's folders as checkboxes with a content summary, size and hints ("Looks like preview images"), nothing ticked; One mod or Separate mods; a name and character per resulting mod; the button counts the mods it creates. Where this meets the base-plus-patch combine choice under "Decisions already made", design the overlap in the canvas's style.
9. **Loadouts** (artboard `Loadouts`), with a design note first.
10. **First run** (artboards `Onboarding`, `OnboardingLaunch`): ZZMI auto-detection with evidence lines, "Bring in mods you already have", and a language picker on the welcome step.
    - On Linux a Set up launching step comes after Find ZZMI, making five steps; Windows keeps four (the `Onboarding` artboard's Platform tweak shows both step lists).
    - Set up launching: the XXMI Launcher found next to ZZMI, the Proton builds found with Recommended on the three named under "Decisions already made", the umu-launcher switch, a suggested new prefix, and launch arguments collapsed. Skip leaves it for Settings.
    - Two states, behind the artboard's scenario tweak: no Proton found (install links for the three, Check again, choose a folder; Continue disabled) and umu-run not installed (switch off and disabled, Proton started directly, Check again).
11. **Rename to Zenith:** the application id in its three places, the window title, and the app-data folder moved with a migration. This goes with the v3 release.

## Open items

- Offer the user a correction of the keybind copy on the canvas's Edit info and Reinstall artboards.
- The install links in `OnboardingLaunch`'s no-Proton state point at a placeholder; the user supplies the real Proton-GE, Proton-Cachy and DWProton pages. The Proton-Cachy folder name on the canvas is a guess.
- Ask the user whether the Settings Proton dropdown also marks the recommended builds.
- The status bar's "Watching library for changes" and the library file watcher behind it have no phase yet; give them one before phase 7, whose Settings may want a switch for it.
- The existing screens still hold about 177 `Color(0x…)` literals and sky-blue gradients. Each goes when its screen is rebuilt.
- The canvas's search field in the title bar waits for the palette in phase 8.
- **Launch game follow-up: the app knows whether the game is running.** Design note first, in `launch-game.md`.
  - A launch log: the runner's stdout and stderr go to a file in the app-data folder, never to a pipe the app holds, since closing the app must not kill the game. A Proton or Wine failure is then readable, and one that quits within a few seconds can be reported instead of passing as started.
  - A running state: the app tracks the game from the press until it closes, whether it quits or crashes. While it runs, Launch game is disabled, and the "Remind me to press F10" toast from phase 7 has its "while the game runs" signal.
  - `PlatformService.findGameProcesses` can't be that signal as it stands: its match on `zzz` also catches the app's own `zzz-mod-manager`. It needs fixing or replacing. On Linux, the screen locks already follow the runner's process id and then the prefix's wineserver, which is the same lifetime.
