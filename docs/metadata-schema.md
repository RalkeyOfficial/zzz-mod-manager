# Metadata & persistence schema

Reference for every piece of data the app writes to disk: what the fields mean,
which file owns them, and the rules you must follow when changing them.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so — nothing here describes a format that doesn't exist yet.

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

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

Modelled by `ModMetadata` (`lib/models/mod_metadata.dart`) and written through
three layers, split by responsibility:

| Layer | File | Owns |
|---|---|---|
| `ModMetadataService` | `services/mod_metadata_service.dart` | Where a sidecar lives and how to read/write it. No opinions, no collaborators. |
| `ModMetadataRepository` | `services/mod_metadata_repository.dart` | The **rules** — legacy migration, what "no character" means on disk, which image paths are storable, and recording the origin block (its offline backfill is still planned). |
| `ModManagerService` | `services/mod_manager_service.dart` | Assembles a `ModInfo` from the above plus link state and config. Delegates; holds no metadata logic. |

Everything the repository needs is injected — the mods path, the legacy image
path, and the `config.json` tag mirror (as the narrow `ModCharacterTagStore`
role, *not* the whole `ConfigService`, which writes to real app-data on
construction). So the rules are testable against a temp dir with no app state:
see `test/mod_metadata_repository_test.dart`. Keep it that way — the riskiest
planned logic (the `source_url` → `mod_id` parse, the confidence tiers) lands in
`loadOrMigrate()`, and must ship under test. Those are pure functions with no
network and no UI, so there is no excuse for them to be untested.

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
  "images": [".zzz-mod-manager/images/01.png", "Preview.png"],
  "origin": {
    "provenance": "downloaded",
    "ingest": { "mode": "separate", "folders": ["Ellen Swimsuit"] },
    "installed_at": "2026-08-01T12:34:56.000Z",
    "archive_md5": "9e107d9d372bb6826bd81d3542a419d6"
  }
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
| `origin` | `object?` | non-null only | Where the mod came from. **Machine-owned** — see below. |

### The `origin` block

Written at ingest by `ModMetadataRepository.recordOrigin()`, modelled by
`ModOrigin` (`lib/models/mod_origin.dart`). Every sub-field is optional except
`provenance`, and **anything equal to its read-side default is omitted**, so the
common block is the four keys shown above rather than fifteen mostly-null ones.

| Field | Meaning |
|---|---|
| `source` | Which service, e.g. `gamebanana`. |
| `mod_id` / `file_id` | Remote handles. A mod publishes many files, so both are needed to say what is installed. |
| `mod_id_confidence` / `version_confidence` | See the tiers below. Identity and version resolve independently, so they carry separate confidences. |
| `version` / `version_label` | `version` is a version string; `version_label` is the author's free-text *variant* marker ("white hair ver"). **Never conflate them** — that makes two variants of one release look like two releases. |
| `provenance` | `downloaded` \| `imported_archive` \| `imported_folder`. |
| `ingest` | `mode` (`separate`/`combined`), `folders` (archive-relative **basenames**), `sibling_group`. |
| `installed_at` / `installed_at_is_proxy` | When, and whether that was observed or derived from file mtimes. |
| `baseline_remote_date` | For `assumed_latest`: only flag remote files newer than this. |
| `archive_md5` | md5 of the archive it was extracted from. |
| `tracking` | `auto` \| `off` (the user declared the mod local). |
| `remote_missing` | Gone upstream — read from the remote's explicit private/trashed/withheld flags, not inferred from a 404. |

**Confidence and provenance are separate axes.** Confidence is how sure we are
*which remote file this is*; provenance is *where the folder came from*. They
came apart the moment a hand-imported archive could be matched exactly by its
checksum: that mod is known precisely despite never having been downloaded by
us. The tiers are `exact`, `user`, `inferred`, `assumed_latest`, `unknown`, and
**only `exact` may drive an unattended overwrite** — on *both* axes, since
knowing the mod but not the file is not enough to know what to replace it with.

Three rules that are load-bearing rather than stylistic:

- **An unrecognised confidence value parses to `unknown`, never upward.** A
  future build inventing a stronger tier must not be read by this build as a
  claim it can act on.
- **`ModOrigin.fromJson` never throws, for any input.** A sidecar travels with
  its folder, so one can arrive from a stranger holding `"mod_id": "123"`. A
  throwing cast would propagate into `ModMetadataService.read`, which catches and
  returns null — and since that method cannot tell "missing" from "corrupt", the
  sidecar would then be **replaced wholesale on the next save**, destroying the
  user's own description, tags and images.
- **On any ingest we did not download ourselves, the inbound `origin` is
  dropped.** `_copyDirectory` copies a source folder's `.zzz-mod-manager/`
  wholesale, so a mod passed around on Discord arrives carrying someone else's
  block — a claim about a remote file we never made, on the field that gates
  unattended updates. `recordOrigin` enforces this *by construction*: it never
  reads or merges the inbound block, and `ModMetadata.withOrigin()` replaces the
  field outright. There is no branch where a stranger's block survives, and so
  none to get wrong. The user-facing fields are kept — those travelling is the
  whole point of a sidecar.

`archive_md5` deserves its own warning: it is a **matching key, never an
integrity or authenticity claim**. It exists only because GameBanana publishes
one per file, which is what lets a *hand-supplied* archive be identified exactly.
md5 is cryptographically broken and deliberate collisions are constructible —
harmless here precisely because a match grants no trust: it sets a version label,
skips no security check, and doesn't change what gets extracted. Never render a
match as "verified" or with a shield icon; the honest phrasing is "byte-identical
to file X on the mod page". If real integrity is ever wanted, add sha256 alongside
rather than reinterpreting this field.

### Field rules that aren't obvious from the type

- **`source_url` is mod-page-only.** Don't write machine handles, direct
  `/dl/<fileid>` links, or API URLs into it — it's a human-facing field shown as a
  clickable link and editable as free text. Machine identifiers get their own
  fields when the origin block lands (planned — see [§6](#6-planned-changes)).
- **`images` entries are relative paths, always.** Two valid shapes: a file we
  imported (`.zzz-mod-manager/images/01.png`) or a file the mod author shipped
  (`Preview.png`). On load they're resolved to absolute paths and **silently
  dropped if the file no longer exists**, so a stale entry degrades rather than
  erroring. `ModMetadataRepository.save()` discards any path that resolves outside the mod
  folder — call `ModMetadataService.importImageFile()` first to bring it inside.
- **Imported images are named `NN.<ext>`**, numbered by
  `_nextImageIndex()` (max existing number + 1). The extension follows the source
  file, so the gallery is a mix of `.png`/`.jpg`.
- **`character_id` empty or `"unknown"` is normalised to `null` on save.** Treat
  "no character" as absence, never as the literal string `unknown` on disk. This
  holds on *every* route in: `ModMetadataRepository.save()`, `setCharacter()` (which also
  drops the `config.json` mirror rather than storing the placeholder), and the
  legacy migration, which maps a `config.json` value of `"unknown"` to absence
  instead of copying it into a new sidecar. The placeholder is a **runtime**
  convention — `_buildModInfo()` substitutes it for the UI — and it must not
  round-trip back to disk from there.
- **A missing cover doesn't mean no image.** When `images` yields nothing,
  `_buildModInfo()` falls back to scanning the folder for
  `AppConstants.imageFileNames` (`Preview.png`, `preview.png`, `thumbnail.png`,
  `icon.png`), which is why a mod can display a thumbnail while its `images`
  array is empty on disk. The fallback is resolved at scan time, but it is **not**
  purely runtime: `_findModImage()` returns a path *inside* the mod folder, so the
  next metadata save relativises it to `Preview.png` and writes it into `images`.
  In other words the array is empty only until the user's first edit.

### Save semantics: three classes of field

`ModMetadataRepository.save()` builds the sidecar **from scratch** out of
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
| **Unknown / future** | any key this build doesn't recognise | Passed through verbatim via `ModMetadata.extra` |

All three are handled by one method, `ModMetadata.replaceUserFields()`, which is
what `ModMetadataRepository.save()` calls on the copy read from disk:

```dart
final existing = await _metadataService.read(modFolder);
final metadata = (existing ?? const ModMetadata()).replaceUserFields(
  description: …, sourceUrl: …, tags: …, characterId: …, images: …,
);
```

It replaces every user-editable field wholesale (so clearing still works) and
carries `schemaVersion` + `extra` over from `this`. The design does the
remembering for you, in both directions:

- **Every parameter is required**, so adding a user-editable field is a *compile
  error* at each save site — which is what you want, since a forgotten one is
  erased on the first edit.
- **The method never touches machine-owned fields**, so adding one (the origin
  block) needs no change here at all.

### Unknown keys: `extra` and `knownKeys`

`ModMetadata.knownKeys` is the set of keys this build understands.
`fromJson` routes everything else into `Map<String, dynamic> extra`, and `toJson`
re-emits those entries **after** the known keys — so a file this build wrote
comes back out unchanged, byte for byte.

That ordering is a convenience, not a contract: a *newer* build's file with its
own keys interleaved mid-object gets them collected to the end on the next save.
Harmless, but don't build anything that depends on key order.

Two rules:

- **Adding a typed field means adding its key to `knownKeys`.** Miss it and the
  field round-trips through `extra` *as well*, shadowing the typed one. The test
  `knownKeys matches the full set of typed keys` guards this by asserting set
  *equality* against a fully-populated fixture — a subset check would not, since
  most keys are emitted conditionally and a new field left null emits nothing.
  The fixture is therefore part of the guard: **add the new key there too**, or
  the test is blind to it.
- **`toJson` filters `extra` against `knownKeys`, not against what it just
  emitted.** This is load-bearing, not belt-and-braces: three known keys are
  written conditionally (`if (description != null)`), so filtering the other way
  would let a stale `extra['description']` reappear in the output precisely when
  the user *cleared* the description — resurrecting the field the
  full-replacement design exists to let them delete.

`extra` is opaque: never inspected. It is also `Map.unmodifiable` on every path
it arrives through (`fromJson`, `copyWith`, and the const default), so mutating
it throws rather than quietly editing a map shared with another instance.

#### Consequence: an inbound sidecar's unknown keys now persist

This cuts both ways, and the second edge matters for the origin block.
`_copyDirectory()` copies a source folder's `.zzz-mod-manager/` in wholesale, so
a mod folder from Discord or a friend arrives carrying **someone else's**
sidecar. Previously the first metadata edit silently stripped anything this build
didn't recognise — which accidentally scrubbed a foreign `origin` block. Now it
is preserved faithfully, forever.

Nothing reads `origin` yet, so there is no live risk. But it promotes one rule from
prudent to **load-bearing**:

> On any ingest we did not download ourselves (`imported_folder`,
> `imported_archive`), drop the inbound `origin` block entirely. Keep the
> user-facing fields — description, tags, images — since those travelling between
> people is the whole point of a sidecar.

That has to land in the same change as the origin write side. Without it, a
stranger's folder asserts `exact` confidence we never established, on the one
tier gated for unattended auto-update.

#### The failure mode this prevents

Before `replaceUserFields` and `extra` landed, a machine-owned or unrecognised
field was destroyed by an **unrelated** user action — which made it look like data
vanished at random. Kept here because it's the reason the rules above exist:

1. A mod is installed from the marketplace; the sidecar gets an `origin` block. ✅
2. A scan runs. `_buildModInfo()` builds a `ModInfo`, which has no `origin` field,
   so it isn't carried into memory. Disk is still intact.
3. A week later the user edits the mod's **description**.
4. The save path constructs a fresh `ModMetadata` from `ModInfo`. There is no
   `origin` to pass, so it's absent.
5. `write()` overwrites `metadata.json`. **The origin block is gone** and the mod
   silently reverts to untracked.

#### Known gap: a corrupt sidecar is still replaced wholesale

`read()` returns `null` for both "no file" and "unparseable file", so a corrupt
`metadata.json` is overwritten entirely on the next save — unknown keys included.
Unlike the case above this destroys *everything*, not just the tail.

Not fixed, deliberately: a real fix needs a policy decision (refuse the write and
surface an error? side-copy to `metadata.corrupt-<ts>.json`?) and changing
`read()`'s signature, which ripples into `loadOrMigrate()` — it reads
`null` as "migrate me" — and `autoTagAllMods()`. Half-fixing it on a read path,
by writing a backup file during a scan, is worse than leaving it documented. The
behaviour is pinned by a test so it stays deliberate.

#### Rules when adding a field

- **User-editable field?** Add it to `ModMetadata`, `ModInfo`, *and*
  `ModMetadata.knownKeys`, then add the parameter to `replaceUserFields()`. The
  last step breaks the build at every save site until each one passes it — which
  is the point.
- **Machine-owned field?** Add it to `ModMetadata` and `knownKeys`, and carry it
  in `replaceUserFields()`'s body alongside `schemaVersion` and `extra`. Do
  **not** route it through `ModInfo` — that's what makes it vulnerable to step 4
  above. Save sites need no change.

### Never-recreate rule

`ModMetadataService.write()` and the image helpers bail out if the mod folder
doesn't exist, instead of relying on `create(recursive: true)`. This prevents the
**"ghost folder" bug**: a mod renamed out from under a still-open edit dialog would
otherwise be re-materialised as a folder containing nothing but our sidecar.
Preserve this guard in any new write path.

### Don't litter empty sidecars

A mod with nothing worth saving should get **no `.zzz-mod-manager` directory at
all**. Users who never touch metadata shouldn't find new files appearing inside
their mods. `ModMetadataRepository.loadOrMigrate()` enforces this by writing only when
`!metadata.isEmpty` — i.e. only when it actually migrated something.

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

`ModInfo` has **no** `toJson`/`fromJson`, and must not gain them. It is a runtime
view, not a storage format: it holds absolute image paths and per-install state
(`is_active`, `is_favorite`, `keybinds`), all of which violate the split rule in
[§1](#the-split-rule). The only mod-level persistence is the sidecar, and
`ModMetadata` is its shape. (A dead pair did exist here; it was deleted precisely
because someone fixing the save path could have mistaken it for the sidecar
format.)

`ModMetadata.isEmpty` is what enforces the "don't write empty sidecars" rule in
`ModMetadataRepository.loadOrMigrate()`. Note it counts unknown keys as content — they're
someone else's data, and dropping them is what `extra` exists to prevent.

One remaining vestigial pair, recorded so it isn't rediscovered:
`KeybindInfo.toJson`/`fromJson` and `CharacterKeybinds.toJson`/`fromJson` have no
callers anywhere. Keybinds are parsed from `.ini` files at scan time and never
persisted. Harmless — unlike `ModInfo.toJson`, there's no sidecar to confuse them
with — but deletable in any pass that touches `models/keybind_info.dart`.

---

## 4. Versioning and migration

### What `schema_version` means

It marks the **on-disk format** of one sidecar. It is not the app version and not
a feature flag. `ModMetadata.currentSchemaVersion` is the version this build
writes; a file with no `schema_version` is assumed to be current (a tolerant
default, since v1 was the first format).

Current version: **2** — the format that carries the `origin` block.

### When to bump it

Bump only for changes an older build would **misinterpret** — a field changing
type or meaning, or a value being restructured. Do *not* bump for purely additive
fields: older builds ignore keys they don't know, so adding one is backward-safe
in the read direction.

The write direction is the dangerous one. Because saves replace the file
([§2](#save-semantics-three-classes-of-field)), a build will *strip* any key it
doesn't recognise.

**`fromJson`/`toJson` round-trip unknown keys verbatim**, via `ModMetadata.extra`
— see [§2](#unknown-keys-extra-and-knownkeys). A sidecar is an interchange format,
so the posture is "don't care what else is in there, as long as the keys we need
are present". That is what makes a purely additive field backward-safe in *both*
directions, not just the read one.

**Worked example — the `origin` block bumped it to 2, and the rule above did not
require that.** `origin` is a new key; nothing changed type or meaning, older
builds tolerate it, and strictly nothing breaks without a bump.

It was bumped anyway, which is worth recording because it refines the rule rather
than breaking it. The rule above is about *safety* — when a bump is mandatory. It
is silent on when one is merely **useful**, and here it is: without a version, a
sidecar holding no `origin` is ambiguous between "written before origin existed"
and "written by a current build; this mod is genuinely untracked". Those are
different facts and every future reader of this format will want to tell them
apart. The cost side of the ledger turned out to be near zero — no code branches
on `schema_version`, and a build reading a higher number than it knows carries it
through untouched.

So the working rule is: **bump when the format changes in a way an older build
would misinterpret, or when the version is the only thing that can answer a
question a future reader will actually ask.** Don't bump for a cosmetic field.

Two consequences that had to land with the bump, because a version that lies is
worse than no version:

- **A sidecar with no `schema_version` is assumed to be `1`, not "current".** The
  key has been written on every save since v1, so its absence dates the file.
  (`ModMetadata.assumedSchemaVersion`.)
- **Writing an `origin` block advances the stamp**, via `withOrigin()`, since the
  version describes the file's contents — a v1 stamp on a file holding an origin
  block would assert the opposite of what is true. It takes the max, so a sidecar
  from a newer build is never downgraded on its way past us.

The rest of this release's metadata work — notably the offline backfill — lands
as **2** as well. A version describes a format users can actually receive, and
nothing in this cycle has shipped, so a library goes from 1 to 2 in one step and
never observes anything in between. Burning a number on an intermediate
development state buys nothing.

For the backfill specifically there is also nothing to mark: it writes **no
sidecar at all** for a mod it can derive nothing from, so there is no file on
which an "already swept" version could be recorded. Re-sniffing those on each
scan is accepted by design — see the don't-litter rule in
[§2](#dont-litter-empty-sidecars).

Two limits worth being explicit about:

- **The fix is forward-only.** Builds already released will keep stripping unknown
  keys, and nothing can change that retroactively. This is why it landed *before*
  any field that's expensive to reconstruct (the planned origin block qualifies: a
  stripped `origin` means the user has to identify the mod and version again by
  hand).
- **The residual risk after the fix** is confined to folders touched by an
  already-published build — a user who downgrades, or who shares a mod folder with
  someone running an older version. Bounded, and not worth engineering around
  beyond landing the fix early.

### The migration hook

Migrations run **lazily, per mod, during a normal folder scan** — in
`ModMetadataRepository.loadOrMigrate()`, reached from
`ModManagerService._buildModInfo()`. There is no migration pass over the
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
| `mod_character_tags` | `mod_character_tags` | JSON-encoded string in SharedPreferences, real object in the file. **Legacy** — superseded by the sidecar's `character_id`, still mirrored by `ModMetadataRepository.setCharacter()` for backward compatibility |
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

**The origin block has shipped** — its write side, its field reference and the
rules around it are documented in [§2](#the-origin-block), which is now the
authoritative description. It shipped as **schema v2**; see
[§4](#when-to-bump-it) for why the bump was taken even though the additive-field
rule did not demand it.

What remains planned is everything that *reads* it: the offline backfill that
derives identity from an existing `source_url`, the status UI, and update
checking. Two decisions recorded here because they constrain the format rather
than merely the UI:

- **Confidence and provenance are separate axes.** *Confidence* is how sure we are
  which remote file this is; *provenance* is where the folder came from
  (`downloaded`, `imported_archive`, `imported_folder`). They are independent: a
  hand-imported archive whose md5 matches the checksum the remote publishes is known
  exactly, despite never having been downloaded by us. A single enum named after a
  source would therefore mislabel it.
- **Only exact knowledge may drive a destructive path.** The tiers are `exact` (we
  downloaded it, or its archive hash matched a published checksum), `user` (the user
  told us), `inferred` (guessed from local data — a URL parse, a name match),
  `assumed_latest` ("don't know what I have, got it around then"), and `unknown`.
  Anything short of `exact` may badge, suggest and prompt, but must never overwrite
  files unattended; `inferred` in particular came from a free-form text field a human
  typed, so it has to be confirmed once before any update acts on it.

Identity ("which remote mod is this?") and version ("which file of it?") resolve
independently and must be tracked as separate unknowns — the first is often
recoverable offline by parsing an existing `source_url`, the second almost never is,
because the archive is deleted after extraction.

The block's **prerequisite** shipped first, deliberately: the sidecar round-trips
unknown keys and preserves machine-owned ones across a save
([§2](#save-semantics-three-classes-of-field)), so an `origin` block survives
contact with a build that predates it. That had to come first because the fix is
forward-only ([§4](#when-to-bump-it)) — a released build will keep stripping keys
it doesn't know, and nothing can change that retroactively.

Still unresolved, and worth stating so it isn't mistaken for an oversight:
**identity is not yet obtainable at download time.** The marketplace intercepts a
CDN url, which yields no mod id, so every block written today carries
`provenance`, `ingest`, `installed_at` and `archive_md5` with both confidences at
`unknown`. That is the honest output, not a bug — but it does mean "the mod
carries an origin block" is not the same as "we know what it is".
