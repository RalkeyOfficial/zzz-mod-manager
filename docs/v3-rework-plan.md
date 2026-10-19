# v3 UI rework: working plan

The working plan for rebuilding the UI to the Zenith design. It lives on the `zenith-ui` branch only and is deleted when that branch merges. Everything durable (rules, reasoning) goes into the docs that own it, not here.

## Ground rules

- **Target:** the claude.ai Design canvas "Zenith v3 UI", https://claude.ai/artifact/1Sy7dkEKL6RwurthEEpZgv. Read it with the Artifact tool (`action: "read"`, then the `project/*.dc.html` files). It has 26 artboards.
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
  - Interim until phase 5: the library menu (check, sort out tracking, mark all as current, read again) is a ⋯ button in the row above the grid, and the tracking reminder sits under that row. The Library has no search or tag filter until the palette (phase 8) and the All mods table (phase 5).
  - The author line and the File / Uploaded facts show only once a check has the mod page in hand; phase 8's Edit info adds an author field of its own.
  - The roster's attributes, factions and roles are for the user to verify (Phoenix and Severian are unreleased; Belle and Wise are set to Phaethon with no attribute).
  - The details panel's "Made of N mods" list, committed (`36b59bc`): between the keys and the facts, base first and patches on top, each with a Base or Patch badge, its name, file, author and upload date, and a "Manage in History" link. It shows only when more than one download is registered on the mod (`origin.downloads`).
    - The panel draws its own list (`ModMadeOf` in `mod_detail_parts.dart`); `FolderDownloadsSummary` stays for the resolve dialog.
    - Like the facts, a row's file, author and date come from a page the session holds (fetched by a check, an install or a dialog), and the file and its date only for a confirmed file. A row's name links to its GameBanana page; a patch with no page reads "Patch from a local file".
    - Decided with the user: each download saves its page's title as `name` in the sidecar, a display copy that every fetch rewrites. Without it, a patch installed as its own folder listed the base by the patch's file name and the patch by its id until a check ran, since the folder takes the patch's archive name. No row uses the folder name for a layer with an id.
    - Not changed, and for the user to decide: that same folder's description and pictures come from the patch's page.
  - Follow-up, characters without mods (artboard `Main`): built, reviewed and committed (the commit after `476710a`). A "Hide empty" switch under the chips replaces the "Has mods" chip, off by default and stored as `hide_empty_characters`. On, it hides every row with no mods, categories and Unassigned included, and a line under the agents ("3 agents without mods hidden · Show") turns it back off. Written up in `library-screen.md` §2.
    - Decided with the user: the label is "Hide empty" rather than the canvas's "Show characters without mods", so the switch is on when rows are hidden. The row on screen stays listed when it has no mods, so deleting a character's last mod leaves their row under their page.
    - Decided without asking: only agents are counted, as on the canvas, and only those the field and chips would otherwise show, so Active or Updates never shows the line. The sidebar's Characters count follows the switch, counting the agents with a mod while it is on. A search that matches only hidden rows says "Only rows without mods match · Show". Until the first scan returns, neither the line nor the count speaks, and the count stays the roster.

- **Phase 4, Mod page** (artboard `ModPage`): built, reviewed and committed (the commit after `ab3fc69`). Written up in `library-screen.md` §15.
  - The page shows in place of the character view through `openModPageProvider`, with the character view kept mounted under it; the panel's full-page button opens it on Overview and "Manage in History" on History, for every stacked mod.
  - The canvas draws only History. Overview (description, tags, Made of, facts), In-game keys (the list, Change keys opening the keybinds dialog, an F10 line) and Note were designed in its style, with "In the folder" as the side column on every tab.
  - Decided with the user: opening the page fetches each download's GameBanana page and the base mod's update feed (Local and pageless mods fetch nothing); Stop ignoring is on History, while Ignore stays in the update dialog only; the install date reads "installed on <date>" on the page and as the bare date in the facts, however it was worked out.
  - Decided without asking: canvas copy that contradicted the docs is rewritten (snapshots are of the whole folder; taking a patch out also deletes what it added; an ignored update stays installable and lapses on anything newer; the note and snapshots live outside the folder). The retention line states no numbers ("older snapshots are cleared as the store fills; the newest is always kept") and has no "change" link until phase 7 adds the setting. A snapshot is named by its sidecar's file when that page is held, else by when it was saved. The page's mod name got a 30px `ZenithType.pageTitle` and its empty gallery a 120px `watermarkMedium`.
  - From review: the panel's note follows the page's; Stop ignoring re-folds the session verdict so the badge returns; restore and patch removal read the app's container and hold History's buttons while they write (`modWritesInProgressProvider`); the page refetches when the tracking changes and keeps a key fixed at opening (`ModPageRequest.pageKey`); drops and Ctrl+V are off under the page; Reinstall needs a confirmed file on a tracked mod in the menu and on History (`canReinstall`); the Characters row closes the page only when the Library is showing; links take the text colour on hover (`ZenithLink`). Canvas values matched: framed star, 12px gaps, `dialog`/`check`/`control` tokens, 14/16 Active box, radius 12 boxes, 12px side notes on the page and 11px regular ones in the panel.
  - The restore confirmation is shared with the backups dialog (`restoreSnapshotFlow`) and says a restore removes what was added since. Snapshots taken before a patch removal are labelled as such.
  - Not yet compared with the canvas on screen: KDE asks before xdotool may drive the window.

## Phases left

Each is reviewable on its own and ends with tests green, docs and changelog updated, and the user's go-ahead.

5. **All mods table and Updates** (artboard `AllMods`).
   - Table with multi-select and bulk Enable / Disable / Check / Add to loadout (hidden until phase 9) / Delete.
   - Filters: All, Active, Off, Updates, Folder missing, Favourites, Not tracked.
   - Folder missing needs a read-only look at dead links in ZZMI/Mods, which are never removed or offered for removal.
   - Group by.
   - The sidebar's Updates row then opens this table filtered, and All mods joins the sidebar.
   - The bulk-tracking and Assume current actions live here, above the table when Not tracked is on.
6. **Browse** (artboards `Browse`, `BrowseMod`, `Downloads`).
   - Grid restyle, carousel, character chip and type chips, Hide installed, the mature-content and sort menus, infinite scroll.
   - Mod page with Install for (a character override), multi-file pick and Turn on after installing.
   - The downloads side panel, Pause, and archive passwords.
   - "Needs your attention" as the panel's first group: one amber row per waiting decision (patch, several folders, password), each with the button that opens its dialog and Don't install. The patch and folders dialogs are restyled in phase 8; until then the buttons open the current ones.
   - `DownloadsNavItem` shows the amber warning badge (triangle and count) while anything waits. The canvas draws only that state; the idle look is designed in its style.
7. **Settings, Storage, About** (artboards `Settings`, `Storage`, `About`).
   - Section nav (General, Game & folders, Launching, Mods, GameBanana, Storage, Appearance, About), and Game & folders including Move library… (design note first). Game & folders holds only the ZZMI folder and the mod library.
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
