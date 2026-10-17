# v3 UI rework: working plan

The working plan for rebuilding the UI to the Zenith design. It lives on the `zenith-ui` branch only and is deleted when that branch merges. Everything durable (rules, reasoning) goes into the docs that own it, not here.

## Ground rules

- **Target:** the claude.ai Design canvas "Zenith v3 UI", https://claude.ai/artifact/1Sy7dkEKL6RwurthEEpZgv. Read it with the Artifact tool (`action: "read"`, then the `project/*.dc.html` files). It has 22 artboards.
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

## Status

- **Phase 1, theme and tokens:** done, commit `3b4cc66`. It added:
  - `core/palette.dart` (`ZenithPalette`: ink and paper grounds, four accents, signals, badges, element tiles);
  - `core/app_theme.dart` (`buildAppTheme`);
  - `core/type_scale.dart` (canvas roles, plus `ZenithType` for caps, mono, monoSmall, wordmark and watermark);
  - the bundled fonts with their OFL licences, the accent setting and the new icons.
  - Follow-up, commit `6c5d5ac`: component values matched to the canvas, with new palette tokens (`rowHover`, `rowDivider`, `dialog`, `menu`, `menuBorder`, `chip`, `track`, `edge`, `check`, `link`, `selected`), 36px fields, 16px icons, `ZenithSwitch`, the primary hover on every accent, and the test harness on `buildAppTheme`. Canvas colours still without a token (toast `#1E2125`/`#353941`, panel `#0D0E10`, danger hover `#FF7F70`, the 30px small button, Unbounded 30/22/18, the outlined slanted watermark) get one when a screen needs them.
- **Phase 2, title bar and shell:** done, commit `5e531d2`.
  - Follow-up, the commit after it: Linux refuses a Windows file by its extension whatever its mode; Windows launches through `ShellExecuteW`; Tab reaches the sidebar rows; the status bar shortens only a path inside home; saving Settings re-checks ZZMI; the window buttons are the canvas's line drawings; the selected row takes `rowSelected`; the top resize strip stops at the window buttons; the Downloads panel opens against the sidebar's edge.
  - The user has confirmed edge resize works on KDE Wayland and accepted the slight resize lag.
  - Not yet reported back on: the title bar's drag, double-click and right-click window menu, the window buttons, Super+arrow tiling, Launch game.
  - What it added:
    - the runner's hidden `GtkHeaderBar` with `TitleBarStyle.hidden`;
    - `screens/shell/` (`title_bar.dart`, `app_sidebar.dart`, `status_bar.dart`, `keycap.dart`, `launch_game.dart`);
    - `AppDestination` with `destinationProvider` in place of `tabIndexProvider`;
    - `zzmiPathProvider` and `zzmiFoundProvider`;
    - `launch_target` with `PlatformService.launchGame`, and `docs/launch-game.md`;
    - `DownloadsNavItem`;
    - a sidebar that scrolls when short.
  - Docs updated: `desktop-integration.md` §4 (the rule, the hazard and what still differs).

## Phases left

Each is reviewable on its own and ends with tests green, docs and changelog updated, and the user's go-ahead.

3. **Library character view and details sidebar** (artboard `Main`).
   - Add element, faction and specialty to the roster in `utils/zzz_characters.dart`; 64 entries for the user to verify.
   - Character list: element tiles, transparent portraits through `CharacterAvatar.assetPathFor`, initials as the fallback, update and active dots.
   - The list holds every agent, dimmed with "No mods yet" when it has none, as the canvas draws it. The sidebar's Characters count then counts every agent too; it follows the list, which today holds only agents with a mod.
   - Hero header and mod cards, with every update-check verdict mapped onto canvas badges: Active, Newer file (amber), Local, plus the tracking states in blue.
   - Favourites: these exist in `config.json` as `favorite_mods`.
   - Per-character "One at a time": today `activationModeProvider` is global and not persisted. Write a design note first.
   - Details sidebar in place of the details dialog: keys, facts, the note field, Open folder / Check for update / Delete.
   - Notes: a new sidecar field. Write a design note first, and update `metadata-schema.md` and `migrations.md`.
   - Rewrite `library-screen.md`.
4. **Mod page** (artboard `ModPage`).
   - A page route inside Library with Overview, In-game keys, History and Note tabs.
   - History: installed files with Reinstall and Restore (snapshots exist), the latest update post, the ignored update with Stop ignoring, and the In-the-folder facts.
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
7. **Settings, Storage, About** (artboards `Settings`, `Storage`, `About`).
   - Section nav, and Game & folders including Move library… (design note first).
   - Mods: One active per character, Snapshots to keep, Check for mod updates, Remind me to press F10. The reminder's "while the game runs" reads `PlatformService.findGameProcesses`.
   - GameBanana mature content, Appearance, Language.
   - Storage: the bar meter, per-category actions and Largest mods. Storage then leaves the sidebar.
   - About: version, an app update check (GitHub releases, a new network call), links, and app data / logs / system info.
   - Existing settings without a canvas place: auto-tagging goes to Mods, the file-logging switch to About.
8. **Dialogs and overlays** (artboards `ImportModal`, `UpdateModal`, `UpdateOneModal`, `ReinstallModal`, `TrackingModal`, `EditModal`, `DeleteModal`, `ContextMenu`, `Palette`).
   - Edit info: rename, cover, author, tags, "Use GameBanana text", key recording, add and remove keys, "Restore the author's keys".
   - Delete goes to the trash.
   - Right-click menu with Space / F / E / Del shortcuts. Remove patch goes into History and the menu.
   - Command palette on Ctrl K, with a design note first. This brings back the title bar's search field.
   - The patch-destination prompt keeps its logic, restyled.
9. **Loadouts** (artboard `Loadouts`), with a design note first.
10. **First run** (artboard `Onboarding`): ZZMI auto-detection with evidence lines, "Bring in mods you already have", and a language picker on the welcome step.
11. **Rename to Zenith:** the application id in its three places, the window title, and the app-data folder moved with a migration. This goes with the v3 release.

## Open items

- Offer the user a correction of the keybind copy on the canvas's Edit info and Reinstall artboards.
- The existing screens still hold about 177 `Color(0x…)` literals and sky-blue gradients. Each goes when its screen is rebuilt.
- The canvas's search field in the title bar waits for the palette in phase 8.
