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
