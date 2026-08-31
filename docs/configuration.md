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
  "save_mods_path": "/path/to/ZZMI/Mods",
  "active_mods": ["Ellen Swimsuit"],
  "favorite_mods": ["Ellen Swimsuit"],
  "theme": "dark",
  "language": "en",
  "sort_mode": "added",
  "content_filter": "blur",
  "marketplace_sort": "newest",
  "update_check_on_launch": false,
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
| `save_mods_path` | `save_mods_path` | The game's mods folder, where links are created |
| `active_mods` | `active_mods` | String list of mod folder names |
| `favorite_mods` | `favorite_mods` | String list of mod folder names |
| `theme` | `theme` | |
| `language` | `language` | Locale code (`en`, `uk`) |
| `sort_mode` | `sort_mode` | The **mods library** sort. Parsed into `ModSort`; falls back to `added` |
| `content_filter` | `content_filter` | Marketplace adult-content treatment: `blur` (default) \| `show` \| `hide`. Stored as a raw string and parsed by `ContentFilterMode.parse`, which **degrades anything unrecognised to `blur`** — the only value that is wrong in neither direction ([§3](#3-parsing-a-stored-value)) |
| `marketplace_sort` | `marketplace_sort` | The **marketplace browse** sort, as a `GbModSort` Dart name (`newest`, `latestModified`, …). Empty until chosen ([§3](#3-parsing-a-stored-value)) |
| `update_check_on_launch` | `update_check_on_launch` | Bool, **default `false`**. Whether the whole-library update check runs by itself at startup ([`update-checks.md` §5.1](update-checks.md#51-checking-at-startup)). The default is the safety property: the standing rule is that a check never runs unpressed, and this is the only opt-in out of it. It governs *checking* — nothing here consents to an update being applied |
| `file_logging` | `file_logging` | Bool, **default `true`** — the opposite call from the row above, and for the opposite reason: a log reaches nothing and costs kilobytes, and is worthless if it was switched off on the run that broke. **This is the one key read outside `ConfigService`**: `log_setup.dart` reads it straight off the file during bootstrap, because SharedPreferences does not exist until the first frame and the first lines worth keeping are written before that. Any failure to read it means `true` ([`logging.md` §9](logging.md#9-settings)) |
| `mod_character_tags` | `mod_character_tags` | JSON-encoded string in SharedPreferences, real object in the file. **Legacy** — superseded by the sidecar's `character_id`, still mirrored by `ModMetadataRepository.setCharacter()` for backward compatibility. See [`metadata-schema.md`](metadata-schema.md) |
| `first_run` | `first_run` | Bool; always serialised as `false` by `_saveToFile()` |

Note there are **two independent sort keys**, which is easy to misread: `sort_mode`
orders the local mods library, `marketplace_sort` orders GameBanana browse results.

### Naming note

`mods_path` is the **library** and `save_mods_path` is the **game folder**, which
reads backwards from how the UI labels them ("SaveMods folder" is presented to
users as their library). Don't rename these keys casually — they're on disk in
every existing install — but do expect the confusion when reading the code.

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

The Settings tab (`screens/settings_screen.dart`) renders section by section:
**Mod directories**, **Language**, **Updates**, **Marketplace**, **Automatic
tagging**, **Automatic mod reload**, **Appearance**. Only the paths are applied by
the *Save configuration* button; everything else writes as it is changed.

Anything with a description of its own lives in `screens/components/settings/` as
its own widget rather than inside the screen, which is already over a thousand
lines. Each takes a **writer seam** defaulting to the `ApiService` call, because
`ApiService` lazily builds a `ConfigService` against the developer's real
`<appData>/config.json` — a widget test that merely mounted such a section would
rewrite their library paths.

`SettingsRow` (label, description, control) exists because a setting with a
consequence cannot be a bare label. The older `_buildSettingRow` inside the screen
is label-and-control only, which is enough for *Dark mode* and for nothing that
contacts the network or decides whether adult content is on screen.

### Progress belongs on the control, not over the page

The screen's `isLoading` flag swaps the **entire body** for a spinner. That is
right exactly once — the first load, when there is nothing to show yet — and wrong
for everything after it, because the swap unmounts the `AnimationLimiter` that
wraps the sections. `_AnimationLimiterState` only lets its children animate during
the first frame after its own `initState`, so tearing the body down and putting it
back hands every section a fresh limiter and the whole page replays its 375 ms
staggered entrance. A change that touches nothing on the page appears to reload it.

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
| The post-upgrade "N mods aren't tracked" nudge | The feature is not built, so its dismissed flag has nothing to dismiss. |
| Automatic updating | Refused, not unbuilt — [`applying-updates.md` §7](applying-updates.md#automatic-updating--considered-and-refused). The **Updates** section's one switch is about *checking*, and its wording keeps that distinction visible. |

Two settings *are* surfaced and do **not** persist: **Dark mode** and **Automatic
mod reload** both write plain `StateProvider`s and nothing else, so they reset on
every launch — despite a `theme` key existing in `config.json` with no reader.
That is a real gap rather than a decision, and it is filed.
