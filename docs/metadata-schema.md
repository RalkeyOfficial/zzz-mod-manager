# Metadata & persistence schema

Reference for every piece of data the app writes to disk: what the fields mean,
which file owns them, and the rules you must follow when changing them.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so and links out — nothing here describes a format that
doesn't exist yet.

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture,
[`../BUGS & TODO.md`](../BUGS%20&%20TODO.md) for planned schema work.

---

## 1. Where data lives, and why it's split

Four storage surfaces, three of them current:

| Surface | Path | Owns |
|---|---|---|
| **Per-mod sidecar** | `<mod>/.zzz-mod-manager/metadata.json` | Everything *intrinsic* to a mod: description, source URL, tags, character, gallery images |
| **App config file** | `<appData>/config.json` | Everything *per-install*: folder paths, which mods are active, favourites, theme, language, sort mode |
| **SharedPreferences** | platform-managed | A mirror of `config.json` — see [§5](#5-configjson-and-the-dual-storage-pattern) |
| **Legacy image dir** | `<appData>/mod_images/<mod>.png` | *Deprecated.* Read once and migrated into the sidecar, never written to |

`<appData>` resolves via `PathHelper.getAppDataPath()`:

- Linux — `$XDG_DATA_HOME/zzz-mod-manager`, defaulting to `~/.local/share/zzz-mod-manager`
- Windows — `%APPDATA%\zzz-mod-manager`

### The split rule

> **Intrinsic to the mod → sidecar. Specific to this installation → `config.json`.**

The reason is that the sidecar lives *inside the mod folder*, so it travels with
the mod: rename the folder and the metadata follows; zip the folder and send it to
someone and your description, tags, and images arrive with it. Per-install state
must **not** travel — whether a mod is active depends on this machine's symlinks,
and a favourite is this user's opinion.

Consequence to keep in mind: a mod folder can arrive carrying a sidecar written by
a *different user, possibly on a different app version*. Sidecars are effectively
a public interchange format, not private storage.

---

## 2. `metadata.json` — the per-mod sidecar

Written by `ModMetadataService` (`lib/services/mod_metadata_service.dart`),
modelled by `ModMetadata` (`lib/models/mod_metadata.dart`).

```
<mod folder>/
└── .zzz-mod-manager/
    ├── metadata.json
    └── images/
        ├── 01.png
        └── 02.jpg
```

```json
{
  "schema_version": 1,
  "description": "Ellen swimsuit retexture.\n\nSupports **markdown**.",
  "source_url": "https://gamebanana.com/mods/123456",
  "tags": ["swimsuit", "4k"],
  "character_id": "ellen",
  "images": [".zzz-mod-manager/images/01.png", "Preview.png"]
}
```

| Field | Type | Written when | Meaning |
|---|---|---|---|
| `schema_version` | `int` | always | On-disk format version. Missing → assumed `ModMetadata.currentSchemaVersion`. See [§4](#4-versioning-and-migration). |
| `description` | `string?` | non-null only | Free-form, **rendered as markdown** in the UI (`utils/markdown_description.dart`). Users can paste rich text and get markdown — see the clipboard-HTML note in `CLAUDE.md`. |
| `source_url` | `string?` | non-null only | The mod's **page** URL. User-facing and user-editable via the edit dialog. |
| `tags` | `string[]` | **always** (even `[]`) | Arbitrary user tags. Drive the tag filters in the mods toolbar. |
| `character_id` | `string?` | non-null only | Canonical character/category id. Normalised through `canonicalCharacterId()` (`utils/zzz_characters.dart`) on read. |
| `images` | `string[]` | **always** (even `[]`) | Gallery, **relative to the mod folder root**. First entry is the cover. |

### Field rules that aren't obvious from the type

- **`source_url` is mod-page-only.** Don't write machine handles, direct
  `/dl/<fileid>` links, or API URLs into it — it's a human-facing field shown as a
  clickable link and editable as free text. Machine identifiers get their own
  fields when the origin block lands (planned — see [§6](#6-planned-changes)).
- **`images` entries are relative paths, always.** Two valid shapes: a file we
  imported (`.zzz-mod-manager/images/01.png`) or a file the mod author shipped
  (`Preview.png`). On load they're resolved to absolute paths and **silently
  dropped if the file no longer exists**, so a stale entry degrades rather than
  erroring. `saveModMetadata()` discards any path that resolves outside the mod
  folder — call `ModMetadataService.importImageFile()` first to bring it inside.
- **Imported images are named `NN.<ext>`**, numbered by
  `_nextImageIndex()` (max existing number + 1). The extension follows the source
  file, so the gallery is a mix of `.png`/`.jpg`.
- **`character_id` empty or `"unknown"` is normalised to `null` on save.** Treat
  "no character" as absence, never as the literal string `unknown` on disk.
- **A missing cover doesn't mean no image.** When `images` yields nothing,
  `_buildModInfo()` falls back to scanning the folder for
  `AppConstants.imageFileNames` (`Preview.png`, `preview.png`, `thumbnail.png`,
  `icon.png`). That fallback is **runtime-only and never persisted** — which is
  why a mod can display a thumbnail while its `images` array is empty.

### Save semantics: three classes of field

`ModManagerService.saveModMetadata()` builds the sidecar **from scratch** out of
the in-memory `ModInfo` rather than patching the existing file. That is
deliberate and must stay: `copyWith`-style merging can't tell "unchanged" from
"the user cleared this field", so merging would make emptying a description or URL
impossible.

But full replacement is only correct for fields `ModInfo` actually carries. The
sidecar really has **three** classes of field, and only the first may be sourced
from `ModInfo`:

| Class | Examples | Save behaviour |
|---|---|---|
| **User-editable** | `description`, `source_url`, `tags`, `character_id`, `images` | Replaced wholesale from `ModInfo` — clearing must work |
| **Machine-owned** | `schema_version` (today), planned `origin` | Carried over from the file on disk, never sourced from `ModInfo` |
| **Unknown / future** | any key this build doesn't recognise | Should be passed through verbatim — **not yet implemented** |

`schema_version` is already handled the machine-owned way, via
`existing?.schemaVersion`. It's just the only such field today, so the pattern
reads like a one-off rather than a rule.

#### The failure mode, concretely

If a machine-owned field is added to `ModMetadata` but not handled, it is
destroyed by an **unrelated** user action — which makes it look like data vanishes
at random:

1. A mod is installed from the marketplace; the sidecar gets an `origin` block. ✅
2. A scan runs. `_buildModInfo()` builds a `ModInfo`, which has no `origin` field,
   so it isn't carried into memory. Disk is still intact.
3. A week later the user edits the mod's **description**.
4. `saveModMetadata()` constructs a fresh `ModMetadata` from `ModInfo`. There is no
   `origin` to pass, so it's absent.
5. `write()` overwrites `metadata.json`. **The origin block is gone** and the mod
   silently reverts to untracked.

#### The trap when reading the code

```dart
// mod_manager_service.dart, saveModMetadata()
final existing = await _metadataService.read(modFolder);
```

This looks like the existing sidecar is being preserved. It isn't — `existing` is
used for `schemaVersion` and nothing else. Don't assume any other field survives.

#### Rules when adding a field

- **User-editable field?** Add it to `ModMetadata`, `ModInfo`, *and*
  `saveModMetadata()`. Miss the last one and the first metadata edit erases it.
- **Machine-owned field?** Add it to `ModMetadata` and carry it from `existing` in
  `saveModMetadata()`. Do **not** route it through `ModInfo` — that's what makes it
  vulnerable to step 4 above.

### Never-recreate rule

`ModMetadataService.write()` and the image helpers bail out if the mod folder
doesn't exist, instead of relying on `create(recursive: true)`. This prevents the
**"ghost folder" bug**: a mod renamed out from under a still-open edit dialog would
otherwise be re-materialised as a folder containing nothing but our sidecar.
Preserve this guard in any new write path.

### Don't litter empty sidecars

A mod with nothing worth saving should get **no `.zzz-mod-manager` directory at
all**. Users who never touch metadata shouldn't find new files appearing inside
their mods. `_loadOrMigrateMetadata()` enforces this by writing only when it
actually migrated something.

---

## 3. `ModMetadata` vs `ModInfo`

Easy to confuse, since their fields overlap almost entirely:

| | `ModMetadata` | `ModInfo` |
|---|---|---|
| Defined in | `models/mod_metadata.dart` | `models/character_info.dart` |
| Role | **On-disk shape** of the sidecar | **Runtime view** of a mod for the UI |
| Paths | relative to the mod folder | absolute |
| Extra fields | — | `id`, `name`, `isActive`, `isFavorite`, `keybinds`, `imagePath` |
| Persisted? | yes, it *is* the file format | no |

`ModInfo` is assembled by `ModManagerService._buildModInfo()` from three sources:
the sidecar, the filesystem (active-link state, image existence), and
`config.json` (favourites, legacy character tag).

### Vestigial code — don't assume it's load-bearing

Both of these have an agreed disposition recorded in
[`../BUGS & TODO.md`](../BUGS%20&%20TODO.md) §8, to be done alongside the next
change that touches the same file. Until then:

- **`ModInfo.toJson()` / `ModInfo.fromJson()` are never called** — not in `lib/`,
  not in tests. `ModInfo` is a runtime view, **not** a storage format; the only
  mod-level persistence is the sidecar. **Slated for deletion.** Never reach for
  `ModInfo.toJson()` when writing a sidecar: it emits absolute image paths and
  per-install state (`is_active`, `is_favorite`, `keybinds`), all of which violate
  the split rule in [§1](#the-split-rule).
- **`ModMetadata.isEmpty` is never called in `lib/`**, though it *is* tested
  (`test/mod_metadata_service_test.dart:38`). The "don't write empty sidecars" rule
  is currently enforced by a parallel `hasLegacyData` bool in
  `_loadOrMigrateMetadata()`. **Slated to be wired up** in place of that flag —
  the two are equivalent, since `description`/`source_url`/`tags` are always empty
  in that code path.

---

## 4. Versioning and migration

### What `schema_version` means

It marks the **on-disk format** of one sidecar. It is not the app version and not
a feature flag. `ModMetadata.currentSchemaVersion` is the version this build
writes; a file with no `schema_version` is assumed to be current (a tolerant
default, since v1 was the first format).

Current version: **1**.

### When to bump it

Bump only for changes an older build would **misinterpret** — a field changing
type or meaning, or a value being restructured. Do *not* bump for purely additive
fields: older builds ignore keys they don't know, so adding one is backward-safe
in the read direction.

The write direction is the dangerous one. Because saves replace the file
([§2](#save-semantics-three-classes-of-field)), a build will *strip* any key it
doesn't recognise.

**Decided: `fromJson`/`toJson` must round-trip unknown keys verbatim.** A sidecar
is an interchange format, so the correct posture is "don't care what else is in
there, as long as the keys we need are present". Not yet implemented.

Two limits worth being explicit about:

- **The fix is forward-only.** Builds already released will keep stripping unknown
  keys, and nothing can change that retroactively. So the exposure window shrinks
  the sooner this lands — it should precede any field that's expensive to
  reconstruct (the planned origin block qualifies: a stripped `origin` means the
  user has to identify the mod and version again by hand).
- **The residual risk after the fix** is confined to folders touched by an
  already-published build — a user who downgrades, or who shares a mod folder with
  someone running an older version. Bounded, and not worth engineering around
  beyond landing the fix early.

### The migration hook

Migrations run **lazily, per mod, during a normal folder scan** — in
`ModManagerService._loadOrMigrateMetadata()`. There is no migration pass over the
whole library and no version-upgrade step at startup.

The existing precedent migrates pre-sidecar storage:

1. Read the sidecar. If present, use it and stop.
2. Otherwise gather legacy data: the character tag from `config.json`, and
   `<appData>/mod_images/<mod>.png` if it exists.
3. Write the sidecar **only if** something was actually found (`hasLegacyData`).
4. Either way, return usable values in memory — a read-only or unwritable mod
   folder must not break the app.

Follow this shape for new migrations. Two properties matter: it's **idempotent**
(re-running is harmless) and it's **offline** (scans happen on every launch with
no network, so a migration must never require a request).

---

## 5. `config.json` and the dual-storage pattern

`ConfigService` writes **every setting twice**: through `SharedPreferences` *and*
into `<appData>/config.json`. The JSON file is the portable/inspectable copy;
SharedPreferences is what the app actually reads at runtime. `loadFromFile()`
imports the JSON back into SharedPreferences.

```json
{
  "mods_path": "/home/user/mods",
  "save_mods_path": "/path/to/ZZMI/Mods",
  "active_mods": ["Ellen Swimsuit"],
  "favorite_mods": ["Ellen Swimsuit"],
  "theme": "dark",
  "language": "en",
  "sort_mode": "added",
  "mod_character_tags": { "Ellen Swimsuit": "ellen" },
  "first_run": false
}
```

| Key | SharedPreferences key | Notes |
|---|---|---|
| `mods_path` | `mods_path` | The library — where mod folders live |
| `save_mods_path` | `save_mods_path` | The game's mods folder, where links are created |
| `active_mods` | `active_mods` | String list of mod folder names |
| `favorite_mods` | `favorite_mods` | String list of mod folder names |
| `theme` | `theme` | |
| `language` | `language` | Locale code (`en`, `uk`) |
| `sort_mode` | `sort_mode` | Parsed into `ModSort`; falls back to `added` |
| `mod_character_tags` | `mod_character_tags` | JSON-encoded string in SharedPreferences, real object in the file. **Legacy** — superseded by the sidecar's `character_id`, still written by `setModCharacter()` for backward compatibility |
| `first_run` | `first_run` | Bool; always serialised as `false` by `_saveToFile()` |

> ⚠ **The recurring mistake.** Adding a setting means touching **three** places:
> the getter/setter pair, *and* the map inside `_saveToFile()`, *and* the parsing
> in `loadFromFile()`. Miss `_saveToFile()` and the setting works all session then
> vanishes on restart — with no error.

### Naming note

`mods_path` is the **library** and `save_mods_path` is the **game folder**, which
reads backwards from how the UI labels them ("SaveMods folder" is presented to
users as their library). Don't rename these keys casually — they're on disk in
every existing install — but do expect the confusion when reading the code.

---

## 6. Planned changes

The metadata schema is slated for a **v2** that adds an *origin block* — where a
mod came from, which remote file it is, and how confident we are about that — plus
the offline backfill and status UI around it.

That work is specified in [`../BUGS & TODO.md`](../BUGS%20&%20TODO.md) §3 and §7,
including the confidence tiers, what each tier is allowed to trigger, and the
reasoning behind the safety gates. **None of it is implemented yet.**

When it lands: fold the field reference into [§2](#2-metadatajson--the-per-mod-sidecar)
of this document and the rationale into a decision record here, so this file stays
the durable home once the planning doc is retired.
