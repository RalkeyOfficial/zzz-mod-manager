# Application configuration

Reference for the app's own settings: `config.json`, the SharedPreferences mirror,
every key, and the rules you must follow when adding one.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so.

> Scope: settings that belong to the *application*. Data describing a *mod* — the
> per-mod `metadata.json` sidecar, its `origin` block, schema versioning and
> migration — is [`metadata-schema.md`](metadata-schema.md). The dividing line is
> ownership, not file format: if deleting it would lose information about a mod, it
> belongs there; if it would only reset a preference, it belongs here.

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## 1. The dual-storage pattern

`ConfigService` writes **every setting twice**: through `SharedPreferences` *and*
into `<appData>/config.json`. The JSON file is the portable/inspectable copy;
SharedPreferences is what the app actually reads at runtime. `loadFromFile()`
imports the JSON back into SharedPreferences.

App-data locations are `~/.local/share/zzz-mod-manager` (Linux) and
`%APPDATA%\zzz-mod-manager` (Windows), resolved by `PathHelper.getAppDataPath()`.

```json
{
  "mods_path": "/home/user/mods",
  "zzmi_path": "/path/to/ZZMI",
  "save_mods_path": "/path/to/ZZMI/Mods",
  "active_mods": ["Ellen Swimsuit"],
  "favorite_mods": ["Ellen Swimsuit"],
  "mod_notes": { "Ellen Swimsuit": "Use with the white hairpin." },
  "one_at_a_time": { "cat_ui": true },
  "theme": "system",
  "accent": "violet",
  "launch_target": "",
  "launch_arguments": "--nogui --xxmi ZZMI",
  "wine_runner": "/home/user/.local/share/Steam/compatibilitytools.d/GE-Proton10-1/proton",
  "wine_prefix": "/home/user/Games/zzz-prefix",
  "wine_use_umu": true,
  "language": "en",
  "sort_mode": "added",
  "content_filter": "blur",
  "marketplace_sort": "newest",
  "update_check_on_launch": false,
  "hide_empty_characters": false,
  "file_logging": true,
  "mod_character_tags": { "Ellen Swimsuit": "ellen" },
  "first_run": false
}
```

---

## 2. Every key

| Key | SharedPreferences key | Notes |
|---|---|---|
| `mods_path` | `mods_path` | The library — where mod folders live |
| `zzmi_path` | `zzmi_path` | The ZZMI folder, the one holding `d3dx.ini`. The links folder and the shader folder are both worked out from it. Absent in a config an older build wrote, and then read as the parent of `save_mods_path` ([`migrations.md`](migrations.md#the-migrations)) |
| `save_mods_path` | `save_mods_path` | The links folder, where links are created. Derived from `zzmi_path` and written for older builds; read only when `zzmi_path` is absent |
| `active_mods` | `active_mods` | String list of mod folder names |
| `favorite_mods` | `favorite_mods` | String list of mod folder names |
| `mod_notes` | `mod_notes` | Object from mod folder name to the note the user wrote in the details panel; JSON-encoded string in SharedPreferences. Moved by an in-app rename, removed with the mod, absent when empty. Per install, never in the sidecar ([`library-screen.md` §11](library-screen.md#11-notes)). A value that is not a string is dropped and the rest kept |
| `one_at_a_time` | `one_at_a_time` | Object from a character or category id to a bool: whether turning one of its mods on turns the others off. Holds only groups the user has switched; the rest take the default, on for agents and off for categories ([`library-screen.md` §10](library-screen.md#10-one-at-a-time-per-character)). JSON-encoded string in SharedPreferences. A value that is not a bool is dropped and the rest kept |
| `theme` | `theme` | The theme, as a `ThemeMode` Dart name (`light` \| `system` \| `dark`). Empty until chosen ([§3](#3-parsing-a-stored-value)), and parsed by `parseThemeMode`, which **degrades anything unrecognised to `system`** — the key is older than the setting and holds a palette name (`dark-blue`) in any config an earlier build wrote, so the tolerance is what an upgrade lands on |
| `accent` | `accent` | The accent, as an `AccentChoice` Dart name (`violet` \| `paper` \| `lime` \| `teal`). Empty until chosen, and parsed by `AccentChoice.parse`, which degrades anything unrecognised to `violet` |
| `launch_target` | `launch_target` | The file the sidebar's Launch game button starts. Empty means the XXMI Launcher beside the ZZMI folder. Set by the button's first press when there is none, or by **Launch game with**, both saving at once. See [`launch-game.md`](launch-game.md) |
| `launch_arguments` | `launch_arguments` | The arguments Launch game passes, as typed. Read on `containsKey` and written only when set: absent means `--nogui --xxmi ZZMI`, while a stored empty string is a choice and stays empty. Reset removes it |
| `wine_runner` | `wine_runner` | Linux only. The Wine or Proton that runs the launcher, picked from the builds Settings finds or as any other file: empty means `wine` from PATH, a file named `proton` means that Proton, started directly or through umu-run when `wine_use_umu` is on, any other file is a wine binary |
| `wine_prefix` | `wine_prefix` | Linux only. The Wine prefix the launcher runs in. Empty means the runner's own default, which Proton started directly doesn't have |
| `wine_use_umu` | `wine_use_umu` | Linux only. Bool, **default `true`**. Whether a Proton runner starts through umu-launcher, inside the Steam runtime it is built for, rather than directly on the system's libraries. See [`launch-game.md`](launch-game.md) |
| `language` | `language` | Locale code (`en`, `uk`) |
| `sort_mode` | `sort_mode` | The **mods library** sort. Parsed into `ModSort`; falls back to `added` |
| `content_filter` | `content_filter` | Marketplace adult-content treatment: `blur` (default) \| `show` \| `hide`. Stored as a raw string and parsed by `ContentFilterMode.parse`, which **degrades anything unrecognised to `blur`** — the only value that is wrong in neither direction ([§3](#3-parsing-a-stored-value)) |
| `marketplace_sort` | `marketplace_sort` | The **marketplace browse** sort, as a `GbModSort` Dart name (`newest`, `latestModified`, …). Empty until chosen ([§3](#3-parsing-a-stored-value)) |
| `update_check_on_launch` | `update_check_on_launch` | Bool, **default `false`**. Whether the whole-library update check runs by itself at startup ([`update-checks.md` §5.1](update-checks.md#51-checking-at-startup)). The default is the safety property: the standing rule is that a check never runs unpressed, and this is the only opt-in out of it. It governs *checking* — nothing here consents to an update being applied |
| `hide_empty_characters` | `hide_empty_characters` | Bool, **default `false`**. Whether the Library's character list hides the characters and categories with no mods, the **Hide empty** switch ([`library-screen.md` §2](library-screen.md#2-the-character-list)). A value that is not a bool is ignored |
| `file_logging` | `file_logging` | Bool, **default `true`** — the opposite call from the row above, and for the opposite reason: a log reaches nothing and costs kilobytes, and is worthless if it was switched off on the run that broke. **This is the one key read outside `ConfigService`**: `log_setup.dart` reads it straight off the file during bootstrap, because SharedPreferences does not exist until the first frame and the first lines worth keeping are written before that. Any failure to read it means `true` ([`logging.md` §9](logging.md#9-settings)) |
| `mod_character_tags` | `mod_character_tags` | JSON-encoded string in SharedPreferences, real object in the file. **Legacy** — superseded by the sidecar's `character_id`, still mirrored by `ModMetadataRepository.setCharacter()` for backward compatibility. See [`metadata-schema.md`](metadata-schema.md) |
| `first_run` | `first_run` | Bool; always serialised as `false` by `_saveToFile()` |

Note there are **two independent sort keys**, which is easy to misread: `sort_mode`
orders the local mods library, `marketplace_sort` orders GameBanana browse results.

### Naming note

`mods_path` is the **library**, labelled "Mod library" in the UI. `zzmi_path` is labelled "ZZMI folder". The links folder has no field of its own: it is the ZZMI folder's `Mods/`, and in code it is called `saveModsPath`. Don't rename `mods_path` or `save_mods_path` casually, since they're on disk in every existing install.

### Picking the ZZMI folder

A picked folder that holds `d3dx.ini` is the ZZMI folder. A folder named `mods` in any case with `d3dx.ini` beside it is the links folder itself, and the field takes its parent. One that has a `ZZMI/` child holding `d3dx.ini` is the XXMI Launcher's folder, and the field takes that child instead. Anything else is kept as picked, and a warning under the field says shader fixes can't be installed; it does not block saving, since mods without shader files work without `d3dx.ini`.

The links folder is the ZZMI folder's existing child named `mods` in any case, because ZZMI under Wine sees a case-insensitive disk while Linux does not. An exact `Mods` wins when both spellings exist, and with no such child it is `<ZZMI>/Mods`. `ConfigService` works it out when the ZZMI folder is set or loaded and caches it.

### Changing the Mod library

Saving a Mod library that differs from the one before points the links into the old folder at the new one (`ModManagerService.relinkLibrary`), so a library the player moved, or copied elsewhere, keeps its mods on. Nothing is asked. A link that could not be changed is reported, and shader files placed or taken out on the way raise the restart notice, as turning a mod on or off does ([`shader-fixes.md`](shader-fixes.md) §6).

- **The Mod library can't be ZZMI's Mods folder, be within it, or hold it**, by its path or through a link, such as `~/ZZZMods` pointing at `…/ZZMI/Mods` (`libraryOverlap`). As the Mods folder, every link there would be pointed at itself, and every mod would read as Folder missing. Within it, ZZMI reads the Mods folder as a whole, so every mod in the library loads whether it is on or off, unless a folder on the way to the library, or the library itself, is named so ZZMI skips it: ZZMI's `d3dx.ini` sets `exclude_recursive = DISABLED*`, which skips a folder whose name starts with `DISABLED` in any letter case, at any depth, with all below it. So `Mods/DISABLED_Library`, `Mods/disabled_x` and `Mods/Stash/DISABLED/Library` are allowed, and `Mods/Library` with a `DISABLED_old` folder inside it is not. The app reads ZZMI's rule this way for `.ini` files too ([`library-screen.md`](library-screen.md) §12). Holding it, the Mods folder would show up as a mod, and turning it on would make a link inside itself.
  Saving such a library in Settings shows an error worded for the case (is, leads to, within, holds) and saves nothing (`LibraryOverlapsLinksFolder`), and the welcome screen refuses it too; `relinkLibrary` re-points nothing when it is given one anyway.
  The two folders are compared by path, and also with their links resolved when both exist, so a library folder that doesn't exist yet is compared as it is typed. A folder whose name only begins like the Mods folder, such as `Mods2` beside it, is apart from it.
- **A link follows only when its target is exactly `<old library>/<its own name>`**, whether that folder is there or gone, and the new library has a folder of that name. Paths compare whole, so a link into `/mods2` never matches an old library of `/mods`.
- **A link into the old folder for a mod the new library lacks is left as it is**, as is any other entry in the links folder. The app never removes a link here.
- **The old copy's identity** (`ModUid`) is read from its folder. One whose folder can't be read, such as one on an unplugged drive, is known by the folder path the shader record keeps for the files placed from it ([`shader-fixes.md`](shader-fixes.md) §5). A copy the record keeps no folder for has no identity known, and nothing guesses one.
- **A copy with another identity than the old one**, or with none known for the old one, places its shader files first, as turning a mod on does ([`shader-fixes.md`](shader-fixes.md) §3). A refusal leaves that link as it was, and the mod reads off in the new library; turning it on there takes the old copy's shader files out first when they are what conflicts and its identity is known ([`shader-fixes.md`](shader-fixes.md) §6). Once the link has followed, the old copy's shader files are taken out as turning it off would, so only the new copy's load, unless another working link in the links folder still leads to it. An old copy with no identity known keeps its files.
- **A copy with the same identity is the same mod moved**, and its files are already in place, so nothing is placed or taken out; the shader record's folder path follows it.
- **A link that can't be changed lets go only of what its placement took hold of.** A mod still on in the old library keeps every shader file it placed, including when its old folder is gone and the copy has its identity.
- **On Linux the new link is made under a temporary name and renamed over the old one**, so the name always points somewhere. On Windows the new link is made under the same temporary name first, so one that can't be made leaves the old link untouched; since a link can't be renamed over another there, the old one is then renamed aside, the new one into its name, and the old one deleted. A rename that fails partway renames the old link back, never making it again, which would need rights or a local target a working symlink to a network share may not have; the mod is one the warning names. Not yet run on Windows.
- **The temporary names are `DISABLED.zzz-mod-manager.relink.<name>` and, on Windows, `DISABLED.zzz-mod-manager.relink-old.<name>`.** ZZMI's `exclude_recursive = DISABLED*` never loads one that a replace stopped partway left behind, and the app's own readers of the links folder (the Folder missing rows, the relink, the check for another link still keeping a mod's shader files) skip exactly these names. The next replace of that mod removes them, by their exact names and only when they are links.
- **Each change logs one line** with the old target and the new one.
- A link that could not be changed leaves its mod off in the new library, and so does a mod whose folder couldn't be read, which is logged with the reason; the mods after it still follow. One warning counts them in its title and names them in its body. A mod whose link was refused because the new library is on a network folder and Windows has no Developer Mode is named in an error of its own instead, which says that Developer Mode is what it takes ([`app-architecture.md`](app-architecture.md)). The library is read again after the save, since either path changes which mods read as on.
- The first-run welcome screen has no library before it, so nothing is re-pointed there.

---

## 3. Parsing a stored value

A config file is editable by hand and is written by *other versions* of the app, so
reading a value is never a plain cast. Two rules, both learned from the settings
above:

- **Store our own identifier, not a third party's.** `marketplace_sort` holds a
  `GbModSort` **Dart name** (`latestModified`), not GameBanana's `_sSort` wire value
  (`Generic_LatestModified`). The stored value lives in our file; pinning it to an
  upstream protocol string would mean a rename there silently invalidating every
  user's saved setting.
- **Decide which direction is safe to fail in, per setting.** They are not the same:
  - An unrecognised `marketplace_sort` falls back to the default. Harmless — you get
    a different ordering.
  - An unrecognised `content_filter` must fall back to **`blur`**, never `show`. The
    two failure modes are not symmetric: failing open un-blurs adult content, and
    failing to `hide` silently empties the grid. `blur` is wrong in neither
    direction.
  - An unrecognised `theme` falls back to **`system`**, and that path is the common
    one rather than the corrupt one: the key is older than the setting that reads
    it, so every config written by an earlier build holds a palette name
    (`dark-blue`) there. Following the desktop is the only answer that is not a
    claim about what the user wanted.

Anything unparseable therefore degrades rather than throwing — a corrupt or
hand-edited config must not prevent startup.

**A bool is read on `containsKey`, never on truthiness.** `update_check_on_launch`
is the first one that a user can switch back *off*, and a load that treated a
stored `false` as "nothing stored" would fall through to the default and turn the
setting on again at the next launch — a switch that cannot be un-switched, with
nothing on screen to say why. `first_run` never had this problem because it is only
ever written in one direction. A test turns the setting on, off, and restarts.

---

## 4. Adding a setting

> ⚠ **The recurring mistake.** Adding a setting means touching **three** places:
> the getter/setter pair, *and* the map inside `_saveToFile()`, *and* the parsing
> in `loadFromFile()`. Miss `_saveToFile()` and the setting works all session then
> vanishes on restart — with no error, and invisible to `flutter analyze`.

**This is enforced rather than remembered.** `test/config_service_test.dart`
round-trips through a real temp file — write, then a *fresh* service with empty
preferences over the same file, which is the only honest simulation of a restart —
and asserts that every key `_saveToFile()` emits has a matching branch in
`loadFromFile()`. Verified to catch the mistake: deleting one line from the
`_saveToFile` map fails two tests.

That test needed a seam. `ConfigService(prefs, configFile: …)` overrides the file
location, because without it a test would write over the user's real
`<appData>/config.json` — which is why this class had no tests at all for so long.
Use it for anything that touches persistence.

### Settings surfaced as providers

A setting the UI reacts to also needs a Riverpod provider, declared in
`utils/state_providers.dart` and **hydrated from config in
`ApiService.initialize`** — that hydration is what makes the saved value take
effect on launch. `contentFilterProvider` and `marketplaceSortProvider` are the
worked examples.

Where a *preference* and the *live state* differ, keep them separate. The
marketplace sort is the case to copy: `marketplaceSortProvider` is "what the user
prefers", while `MarketplaceQuery.sort` is "what is applied right now". The query
**reads** the preference for its initial value rather than watching it, because
re-creating the query whenever the preference changed would discard the current
page and category.

---

## 5. Where a setting is surfaced

The Settings tab (`screens/settings_screen.dart`) renders section by section: **Mod directories**, **Language**, **Updates**, **Marketplace**, **Automatic tagging**, **Appearance**, **Diagnostics**.
Under the two paths sit the launch rows: **Launch game with** and **Launch arguments**, plus **Wine or Proton**, **Run Proton through umu-launcher** (for a Proton runner) and **Wine prefix** on Linux.
Only the paths are applied by the *Save configuration* button; everything else, the launch rows included, writes as it is changed.

Anything with a description of its own lives in `screens/components/settings/` as
its own widget rather than inside the screen, which is already over a thousand
lines. Each takes a **seam** for its write defaulting to the production call,
because `ApiService` lazily builds a `ConfigService` against the developer's real
`<appData>/config.json` — a widget test that merely mounted such a section would
rewrite their library paths. The auto-tag section's seam is the pass itself, and
its default reads the library service through `modManagerServiceProvider`.

`SettingsRow` (label, description, control) exists because a setting with a
consequence cannot be a bare label. The older `_buildSettingRow` inside the screen
is label-and-control only, which is enough for the language dropdown and for
nothing that contacts the network, decides whether adult content is on screen, or
offers a choice whose name does not explain it — *System* needs the sentence
saying it tracks the desktop.

### The theme is two questions, not one

`themeModeProvider` is what the user picked and `isDarkModeProvider` is what the
app draws, and only the first is stored. *System* is answered by
`platformBrightnessProvider`, which `MyApp` refreshes from its
`didChangePlatformBrightness` observer — one observer for the whole app, so a
desktop that switches at sunset takes every screen with it and no screen has to
hold a `MediaQuery` to notice.

Everything that paints its own colours watches `isDarkModeProvider`, and
`MaterialApp`'s `ThemeData` is built from the same value rather than from
`themeMode`, so the hand-rolled palettes and the Material one cannot disagree
about which brightness is on screen.

The accent is a separate setting, `accentProvider`, written live from the same **Appearance** section. `buildAppTheme` takes both, so a change to either rebuilds one theme.
Each swatch is painted in the colour it gives the current brightness: on paper that is the darkened accent.
*Paper* is the one accent that is not a single colour. Paper-white beside paper-white text would mark nothing, so *Paper* fills only the primary button and a selected chip (ink on the paper theme), and links, switches, badges and every other on-state stay violet. Its swatch shows the primary button's colour.

### Progress belongs on the control, not over the page

The screen's `_loaded` flag swaps the **entire body** for a spinner until the first
read of the config lands, and it flips once: nothing sets it back, because the swap
unmounts the `AnimationLimiter` that wraps the sections. `_AnimationLimiterState`
only lets its children animate during the first frame after its own `initState`,
so tearing the body down and putting it back would hand every section a fresh
limiter and the whole page would replay its 375 ms staggered entrance. A change
that touches nothing on the page would appear to reload it.

Raising a blocking modal over the swap does not rescue it: the modal hides the swap
on the way in, leaving the user only the replay on the way out.

So a long-running action reports **where it was started**: the language dropdown
spins in place beside itself, and the auto-tag button spins in place of its own
icon and disables. Neither disturbs the rest of the page.

The modal was also the wrong weight for the work. `autoTagAllMods` is a folder scan
plus one sidecar read per mod and a write for the few it tags — entirely local, no
network. The same shape is measured elsewhere in this repo at **30 ms for 23 mods
including every write** ([`origin-tracking.md` §3](origin-tracking.md#3-the-offline-backfill)),
so the honest UI is a spinner that usually flashes, not a barrier.

One trade this accepts: without the barrier the user can leave the Settings tab
mid-pass, and the tab is disposed, so the summary dialog never appears. The tagging
itself still completes — it is done in the service, not the widget — and at this
duration the window is very small.

**The content filter has two homes deliberately.** The marketplace toolbar is
where it is first needed — the grid is where a user meets it — and Settings is
where anyone looks for a preference they set once. Both write `content_filter` and
both read `contentFilterProvider`, so they cannot disagree.

### What is deliberately not surfaced

Recorded so each is not mistaken for an oversight:

| Not in Settings | Why |
|---|---|
| The download directory | Not configurable at all. Archives land in `<appData>/downloads` and are deleted once installed — see [`downloads.md`](downloads.md). A setting would have to come after making it configurable, not before. |
| Backup retention (30 days / 3 per mod / 5 GB) | Deliberately fixed, and [`applying-updates.md` §5](applying-updates.md#retention) argues why: the age floor has to beat the count cap, and a screen presenting them as two independent numbers invites exactly the configuration that breaks it. Add it only if it is actually asked for. |
| The remote response cache TTL | The client's ten-minute cache is in memory and per session; there is no persisted cache to configure. |
| Automatic updating | Refused, not unbuilt — [`applying-updates.md` §7](applying-updates.md#automatic-updating--considered-and-refused). The **Updates** section's one switch is about *checking*, and its wording keeps that distinction visible. |
