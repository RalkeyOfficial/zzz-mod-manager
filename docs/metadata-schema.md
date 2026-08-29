# Mod metadata schema

Reference for the **on-disk format** of the data the app records about a mod: the
per-mod `metadata.json` sidecar, what every field means, how it is read and written,
and how the format is versioned and migrated.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so — nothing here describes a format that doesn't exist yet.

> Scope: the file format and the rules for touching it. The app's *own* settings —
> `config.json`, the SharedPreferences mirror, the dual-storage pattern — are
> [`configuration.md`](configuration.md); the dividing line there is ownership rather
> than file format: if deleting it would lose information about a mod, it is here; if
> it would only reset a preference, it is there. What the app *does* with the
> `origin` block — the confidence model, the backfill, the resolve flow — is
> [`origin-tracking.md`](origin-tracking.md), and what an install fills in from a mod
> page is [`metadata-autofill.md`](metadata-autofill.md).

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## 1. Where data lives, and why it's split

Four storage surfaces, three of them current:

| Surface | Path | Owns |
|---|---|---|
| **Per-mod sidecar** | `<mod>/.zzz-mod-manager/metadata.json` | Everything *intrinsic* to a mod: description, source URL, tags, character, gallery images |
| **App config file** | `<appData>/config.json` | Everything *per-install*: folder paths, which mods are active, favourites, theme, language, sort modes — documented in [`configuration.md`](configuration.md) |
| **SharedPreferences** | platform-managed | A mirror of `config.json`, see [`configuration.md`](configuration.md) |
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
| `ModMetadataRepository` | `services/mod_metadata_repository.dart` | The **rules** — legacy migration, what "no character" means on disk, which image paths are storable, and recording the origin block. |
| `ModManagerService` | `services/mod_manager_service.dart` | Assembles a `ModInfo` from the above plus link state and config. Delegates; holds no metadata logic. |

Everything the repository needs is injected — the mods path, the legacy image
path, and the `config.json` tag mirror (as the narrow `ModCharacterTagStore`
role, *not* the whole `ConfigService`, which writes to real app-data on
construction). So the rules are testable against a temp dir with no app state:
see `test/mod_metadata_repository_test.dart`. Keep it that way — the riskiest
logic (the `source_url` → `mod_id` parse, the confidence tiers) reaches disk
through `loadOrMigrate()`, and ships under test. The decisions themselves are
pushed one level further out into `OriginBackfill`, which has no filesystem
dependency at all: see `test/origin_backfill_test.dart` and
[`origin-tracking.md`](origin-tracking.md#3-the-offline-backfill).

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
  "schema_version": 2,
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
| `schema_version` | `int` | always | On-disk format version. Missing → assumed `ModMetadata.assumedSchemaVersion`. See [§4](#4-versioning-and-migration). |
| `description` | `string?` | non-null only | Free-form, **rendered as markdown** in the UI (`utils/markdown_description.dart`). Users can paste rich text and get markdown — see the clipboard-HTML note in `CLAUDE.md`. |
| `source_url` | `string?` | non-null only | The mod's **page** URL. User-facing and user-editable via the edit dialog. |
| `tags` | `string[]` | **always** (even `[]`) | Arbitrary user tags. Drive the tag filters in the mods toolbar. |
| `character_id` | `string?` | non-null only | Canonical character/category id. Normalised through `canonicalCharacterId()` (`utils/zzz_characters.dart`) on read. |
| `images` | `string[]` | **always** (even `[]`) | Gallery, **relative to the mod folder root**. First entry is the cover. |
| `origin` | `object?` | non-null only | Where the mod came from. **Machine-owned** — see below. |

### The `origin` block

Written by `ModMetadataRepository.recordOrigin()` and amended by `updateOrigin()`,
modelled by `ModOrigin` (`lib/models/mod_origin.dart`). Every sub-field is optional
except `provenance`, and **anything equal to its read-side default is omitted**, so
the common block is the four keys shown above rather than fifteen mostly-null ones.

| Field | Meaning |
|---|---|
| `source` | Which service, e.g. `gamebanana`. |
| `mod_id` / `file_id` | Remote handles. A mod publishes many files, so both are needed to say what is installed. |
| `mod_id_confidence` / `version_confidence` | `exact` \| `user` \| `inferred` \| `assumed_latest` \| `unknown`. Identity and version resolve independently, so they carry separate confidences. What each tier means and who may write it: [`origin-tracking.md`](origin-tracking.md#1-two-axes-confidence-and-provenance). |
| `version` / `version_label` | `version` is a version string; `version_label` is the author's free-text *variant* marker ("white hair ver"). **Never conflate them** — that makes two variants of one release look like two releases. |
| `provenance` | `downloaded` \| `imported_archive` \| `imported_folder`. |
| `ingest` | `mode` (`separate`/`combined`), `folders` (archive-relative **basenames**), `sibling_group`. |
| `installed_at` / `installed_at_is_proxy` | When, and whether that was observed or derived from file mtimes. |
| `baseline_remote_date` | For `assumed_latest`: only flag remote files newer than this. |
| `archive_md5` | md5 of the archive it was extracted from. |
| `tracking` | `auto` \| `off` (the user declared the mod local). |
| `remote_missing` | Gone upstream — read from the remote's explicit private/trashed/withheld flags, not inferred from a 404. |
| `updates_dismissed_until` | "I have seen what this mod published up to here and I don't want it." A **date rather than a file id**, so it expires by itself the moment something newer appears; cleared when the folder is rebound to a different mod. Not the same as `tracking: "off"`, which silences the mod forever. See [`update-checks.md`](update-checks.md#4-dismissing-an-update). |

Three rules are load-bearing rather than stylistic:

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
  block — a claim about a remote file we never made, on the field that decides
  which mod page this folder is checked against and which file the Update button
  would write over it. `recordOrigin` enforces this *by construction*: it never
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
  clickable link and editable as free text. Machine identifiers have their own
  fields in the [`origin` block](#the-origin-block) — the two coexist and say
  different things, one to the user and one to the app. A marketplace install
  fills this with `https://gamebanana.com/mods/<id>` alongside the origin block's
  `mod_id`, deliberately in that canonical form so the offline backfill's parse
  agrees with what the block already records. It is still **absence-filled, never
  displaced**: a url the user typed, or one that travelled in an inbound sidecar,
  wins over the canonical one.
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
| **Machine-owned** | `schema_version`, `origin` | Carried over from the file on disk, never sourced from `ModInfo` |
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
carries `schemaVersion`, `origin` and `extra` over from `this`. The design does the
remembering for you, in both directions:

- **Every parameter is required**, so adding a user-editable field is a *compile
  error* at each save site — which is what you want, since a forgotten one is
  erased on the first edit.
- **The method never touches machine-owned fields**, so adding one (the origin
  block) needed no change here at all.

`save()` is not the only caller. `applyRemoteMetadata()`
([`metadata-autofill.md`](metadata-autofill.md)) goes through the same method with no
`ModInfo` in sight, passing the existing value for every field it is not filling.
That is the mechanism working as designed: a user-editable field is replaced
wholesale by *whoever* writes, so the way to leave one alone is to hand back what was
already there — never to omit it.

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

#### Consequence: an inbound sidecar's unknown keys persist

This cuts both ways. `_copyDirectory()` copies a source folder's `.zzz-mod-manager/`
in wholesale, so a mod folder from Discord or a friend arrives carrying **someone
else's** sidecar. An earlier build stripped anything it didn't recognise on the first
metadata edit — which accidentally scrubbed a foreign `origin` block. Now it is
preserved faithfully, forever.

That is why dropping the inbound `origin` on any ingest we did not download ourselves
is **load-bearing** rather than merely prudent, and why it is enforced by
construction ([above](#the-origin-block)). Without it, a stranger's folder asserts
`exact` confidence we never established — the tier at which the app stops hedging,
points the update check at a mod page nobody chose, and offers to write a file
from it over the user's folder.

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
  in `replaceUserFields()`'s body alongside `schemaVersion`, `origin` and `extra`. Do
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
`!metadata.isEmpty` — i.e. only when it actually migrated something. The one
deliberate exception is the user answering "not from GameBanana / it's my own",
which has to record that answer somewhere
([`origin-tracking.md`](origin-tracking.md#what-it-is-allowed-to-write)).

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

### `ModInfo.origin` is read-only, and why that was allowed

`ModInfo` carries the `origin` block, and **nothing may write it back**. It is
populated in `_buildModInfo()` from the sidecar that was read there anyway, so
carrying it costs no extra I/O, and it is the only field on the runtime view with
a one-way contract: set it in memory and the value is simply lost on the next
scan.

An earlier decision banned `origin` from `ModInfo` outright. That ban was correct
when written, and the hazard it named is the one walked through in
[§2](#the-failure-mode-this-prevents): `save()` used to build a fresh
`ModMetadata` out of the runtime view, so an unrelated description edit rebuilt
the sidecar with no origin block and silently erased it. What changed is the
mechanism, not the danger. `save()` now reads the sidecar and calls
`replaceUserFields()` on *that* copy; the method carries `origin` over from disk
and **takes no `origin` parameter**, so there is no route through which a value
set on `ModInfo` could be persisted. `setCharacter()` goes the same way.

The alternative was worse than it sounds: every status badge is rendered from
`ModInfo`, so keeping the block out of it meant re-reading and re-parsing every
sidecar in the library to draw data the scan had already parsed and thrown away.

Two rules keep this safe, and both are pinned by tests in
`test/mod_metadata_repository_test.dart`:

- **An origin forged on `ModInfo` can never reach disk.** The test writes a real
  origin block, then saves a `ModInfo` carrying a *different* one at `exact`
  confidence, and asserts the file still holds the original.
- **Adding a user-editable field still goes through `replaceUserFields()`**, i.e.
  the compile-error mechanism in
  [§2](#save-semantics-three-classes-of-field) is untouched. `origin` is not an
  exception to that rule; it is on the other side of it.

**The cost this did have, and it was not free.** Putting the block on the runtime
view means the mods screen's rescan guard has to *notice* it. That guard
(`utils/mod_group_diff.dart`) is a hand-written field comparison protecting
`charactersProvider` from being rewritten on every scan, and `origin` was not in
it — so a mod resolved through the resolve dialog was written to disk correctly,
re-read correctly, judged unchanged, and went on rendering its old status badge
until the tab was switched away and back. Nothing threw and no test failed.
`ModOrigin` therefore has full value equality, so the guard compares the block as
a whole and a *new origin field* is covered the day it is added. **Nothing else
on `ModInfo` has that protection**: any other field a surface starts rendering
must be added to that list by hand.

---

## 4. Versioning and migration

### What `schema_version` means

It marks the **on-disk format** of one sidecar. It is not the app version and not
a feature flag. `ModMetadata.currentSchemaVersion` is the version this build
writes.

Current version: **2** — the format that carries the `origin` block.

**A sidecar with no `schema_version` is assumed to be `1`, not "current"**
(`ModMetadata.assumedSchemaVersion`). The key has been written on every save since
v1, so its absence dates the file.

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

**Writing an `origin` block advances the stamp**, via `withOrigin()`, since the
version describes the file's contents — a v1 stamp on a file holding an origin
block would assert the opposite of what is true. It takes the max, so a sidecar
from a newer build is never downgraded on its way past us.

The offline backfill needs no marking of its own: it writes **no sidecar at all**
for a mod it can derive nothing from, so there is no file on which an "already
swept" version could be recorded. Re-sniffing those on each scan is accepted by
design — see the don't-litter rule in [§2](#dont-litter-empty-sidecars).

Two limits worth being explicit about:

- **Unknown-key preservation is forward-only.** Builds already released will keep
  stripping unknown keys, and nothing can change that retroactively. This is why it
  landed *before* any field that's expensive to reconstruct — a stripped `origin`
  means the user has to identify the mod and version again by hand.
- **The residual risk** is confined to folders touched by an already-published
  build — a user who downgrades, or who shares a mod folder with someone running an
  older version. Bounded, and not worth engineering around beyond having landed the
  fix early.

### The migration hook

Migrations run **lazily, per mod, during a normal folder scan** — in
`ModMetadataRepository.loadOrMigrate()`, reached from
`ModManagerService._buildModInfo()`. There is no migration pass over the
whole library and no version-upgrade step at startup.

Two pieces of catch-up work hang off it, and the important thing to understand
is that they are **siblings on opposite branches**, not one pipeline:

```
read sidecar
├── present  → origin backfill        (needs source_url)
└── absent   → legacy migration       (pre-sidecar storage)
```

**Legacy migration** — the older precedent, for storage that predates the
sidecar entirely:

1. Read the sidecar. If present, this branch is not taken.
2. Gather legacy data: the character tag from `config.json`, and
   `<appData>/mod_images/<mod>.png` if it exists.
3. Write the sidecar **only if** something was actually found (`!metadata.isEmpty`).
4. Either way, return usable values in memory — a read-only or unwritable mod
   folder must not break the app.

**Origin backfill** — for a mod that *has* a sidecar but predates the origin
block. It parses the existing `source_url` for a `gamebanana.com/mods/<id>` link
and records the mod id at `inferred`, plus an install-date proxy. Its decisions,
costs and limits are in
[`origin-tracking.md`](origin-tracking.md#3-the-offline-backfill).

**The branch is the whole design, and getting it backwards makes the backfill
dead code.** `source_url` only exists *in* the sidecar, so the legacy-migration
branch — reached precisely when there is no sidecar — builds its metadata from a
config character tag and an app-data image, and can never have a url to parse.
A backfill chained after the legacy migration would sit where `sourceUrl` is
null by construction and never fire once.

Follow this shape for new migrations. Two properties matter: it's **idempotent**
(re-running is harmless) and it's **offline** (scans happen on every launch with
no network, so a migration must never require a request).
