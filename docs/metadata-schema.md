# Mod metadata schema

Reference for the data the app records **about a mod**: the per-mod
`metadata.json` sidecar, its `origin` block, what every field means, and the rules
you must follow when changing the format.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so — nothing here describes a format that doesn't exist yet.

> Scope: mod-owned data. The app's *own* settings — `config.json`, the
> SharedPreferences mirror, the dual-storage pattern — are
> [`configuration.md`](configuration.md). The dividing line is ownership rather than
> file format: if deleting it would lose information about a mod, it is here; if it
> would only reset a preference, it is there.

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
| `OriginBackfill` | `services/origin_backfill.dart` | *Whether* an existing mod's origin can be derived offline, and what it should say. Pure; its one piece of I/O is injected. |
| `ModManagerService` | `services/mod_manager_service.dart` | Assembles a `ModInfo` from the above plus link state and config. Delegates; holds no metadata logic. |

Everything the repository needs is injected — the mods path, the legacy image
path, and the `config.json` tag mirror (as the narrow `ModCharacterTagStore`
role, *not* the whole `ConfigService`, which writes to real app-data on
construction). So the rules are testable against a temp dir with no app state:
see `test/mod_metadata_repository_test.dart`. Keep it that way — the riskiest
logic (the `source_url` → `mod_id` parse, the confidence tiers) reaches disk
through `loadOrMigrate()`, and ships under test. The decisions themselves are
pushed one level further out into `OriginBackfill`, which has no filesystem
dependency at all: see `test/origin_backfill_test.dart`.

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
  clickable link and editable as free text. Machine identifiers have their own
  fields in the [`origin` block](#the-origin-block). Note the asymmetry that
  creates and don't rely on this field being set: a marketplace install writes
  `origin.mod_id` and *no* `source_url`, while a backfilled legacy mod has the url
  and a `mod_id` derived from it — so anything wanting a link to the mod page
  builds it from `origin.mod_id`.
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

`save()` is not the only caller. `applyRemoteMetadata()` (see
[below](#autofill-at-install-what-a-mod-page-may-write)) goes through the same
method with no `ModInfo` in sight, passing the existing value for every field it
is not filling. That is the mechanism working as designed: a user-editable field
is replaced wholesale by *whoever* writes, so the way to leave one alone is to
hand back what was already there — never to omit it.

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

### Autofill at install: what a mod page may write

A mod installed from the marketplace used to arrive with an `origin` block and
nothing else — no description, no gallery, no tags, and a character only if its
folder name happened to contain one. The mod page it came from knows all four, and
the profile response was already fetched to render the file list, so three of them
cost nothing. `ModMetadataRepository.applyRemoteMetadata()` writes them, once,
right after the import.

Two pure units, plus the I/O layer around them — split this way so every
judgement is testable with no filesystem and no network:

| Unit | Owns |
|---|---|
| `services/gamebanana/remote_mod_metadata.dart` | Translating a `GbMod` into `RemoteModMetadata` — *what the page is worth*. Pure. |
| `services/metadata_autofill.dart` | `planMetadataAutofill()` — *what may be written*. Pure. |
| `ModMetadataRepository.applyRemoteMetadata()` | The I/O: fetch, store, save. |

**The one rule: fill absence, never displace.** It is not politeness. A mod folder
can arrive carrying somebody else's sidecar — `_copyDirectory` copies
`.zzz-mod-manager/` wholesale, and this format deliberately *keeps* the
user-facing half of an inbound sidecar (only `origin` is dropped, see
[§2](#the-origin-block)). So "this field is already set" routinely means "the
author wrote this", and their text is better than the mod page's copy. Applied per
field, so a folder with a description still gets a gallery.

| Field | Source | Notes |
|---|---|---|
| `description` | `_sText`, converted | HTML upstream, markdown here, through `utils/html_to_markdown.dart` — shared with the editors' paste-as-markdown so the two conversions can't drift. |
| `character_id` | the **category** name | Not the mod name, not the tags. Under Character Skins the category is the character's full in-world name, picked from a list; `detectCharacterId()` resolves it. |
| `tags` | `_aTags`, flattened | All-or-nothing: a non-empty local list is a curation, and merging into it would produce a set nobody chose. |
| `images` | `_aPreviewMedia`, fetched | The only field that needs the network, because our `images` are paths inside the mod folder. |

Four decisions inside that are load-bearing rather than arbitrary:

- **The character comes from the category because that mapping is exact, and
  measured.** All **60** children of Character Skins resolve to a roster id, and
  **none** of the 4 root categories or the 22 Bangboo categories falsely matches
  one. The install's existing folder-name detection still runs first and still
  wins — it is *per folder*, so when one archive becomes several mods it is the
  only signal that can differ between them — and this fills the case it cannot
  answer, a folder called `bikini` or `mod v2`. A test pins the 60/0 result as a
  canary: if GameBanana adds a character our roster doesn't know, it fails and
  names it.
- **`Software Used` tags are dropped.** `tags` is *structural* — it drives the
  filter chips in the mods toolbar — so noise there has a UI cost a noisy
  description does not, and this is not a marginal family: 3 of the 6 distinct tag
  values across the captured listings are it.
- **A shipped `Preview.png` keeps the cover slot.** When the gallery is imported,
  an author-shipped preview found at the folder root is written *first*, so
  nothing local is lost or demoted. Rare — 1 of 16 mods in a real library ships
  one — which is exactly why the autofill is worth having. The lookup is
  `utils/shipped_preview.dart`, shared with the scan's own cover fallback so the
  two cannot disagree.
- **Ten images, and the cap is not about bandwidth.** Measured: GameBanana's
  full-size screenshots are web-compressed at ~115–310 KB, so whole galleries of
  15 and 26 images came to 2.3 MB and 5.5 MB against a median mod archive of
  21.9 MB. The cap is about what a gallery is *for* — the same real library's
  hand-built galleries run 1–7 images (median 3), and a 26-shot marketing gallery
  copied into every mod folder is clutter. Images are stored at full size for the
  same measured reason: only the *cover* publishes a smaller rung at all.

Three properties of the I/O half:

- **Each image is fetched once, however many mods the archive became.** One
  archive installing as five folders must not mean five downloads of the same
  screenshot; the fetch is a separate pass between planning and writing.
- **It re-reads and re-decides immediately before writing**, for the same reason
  [the origin backfill does](#the-origin-backfill): the fetch is a network await,
  and a scan runs after every toggle and rename, so a user's `save()` can land
  inside that window.
- **Best-effort, and it never writes an empty sidecar.** A mod arrives installed
  and working, so nothing here may fail an install: an unreachable image is
  skipped, and if *nothing* survives (every image failed and nothing else was
  missing) no file is written at all — the don't-litter rule holds.

Measured end to end against the live API: profile fetch 366 ms, then 827 ms to fill
**two** sibling mods with the same 8-image gallery — 8 downloads, 16 files, 882 KB
per folder.

The bytes seam is `services/http/image_fetcher.dart`, deliberately separate from
`HttpTransport` (whose body is a decoded `String` because everything above it is
JSON) and from the file downloader (which earns its ranges and resume on
hundred-megabyte archives).

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

### The installed-mods index

`services/installed_mods_index.dart` is the read model built on top of the above:
given an already-scanned `List<ModInfo>`, it answers "is this remote mod / file
already in the library?". Pure — no filesystem, no network — so the questions are
unit-tested rather than clicked (`test/installed_mods_index_test.dart`).

It indexes three keys because they answer three different questions, and the
distinction is the locked decision about what may be claimed where:

| Key | Question | Where it surfaces |
|---|---|---|
| `origin.mod_id` | "this mod is in your library", possibly as a different file | badge on the marketplace card, notice on the detail view |
| `origin.file_id` | "this exact file is what you installed" | per-row marker in the file list |
| `origin.archive_md5` | "the archive you installed was byte-identical to this published file" | per-row marker, and the duplicate-import gate |

Three properties are load-bearing rather than incidental:

- **Every lookup returns *all* matching folders.** One GameBanana page becoming
  two mod folders is common, not an edge case — two occurrences in a real 23-mod
  library. Returning the first would under-report the library, and §4 must not
  read a shared `mod_id` as a sibling *group* either (see [the backfill's known
  limit](#the-origin-backfill)).
- **`tracking: "off"` is excluded from the identity keys but not from the hash
  key.** That setting is the user saying "not from GameBanana / it's my own", and
  a stale `source_url` is exactly why they might have said it — so a leftover mod
  id must not badge somebody else's mod page. A hash is a fact about bytes on
  disk rather than a claim about which remote mod they are, so local dedup keeps
  working for a mod declared local.
- **A file-id match and a hash match stay distinguishable.** The first is a record
  of what we installed; the second says only that the bytes matched. They are
  worded differently in the UI for the reason `archive_md5` carries its own
  warning in [§2](#the-origin-block): a match is a matching key and never
  verification.

**What this can actually answer today, measured rather than assumed.** In a real
23-mod library, all 23 mods carry a `mod_id` (recovered offline from
`source_url`) and **none** carries a `file_id` or an `archive_md5` — the archive
is deleted after extraction, so nothing local survives to match a published
checksum. So the mod-level answer works for a legacy library from the first
launch, while the file-level ones are inert until mods are installed by a build
that records them, or until the resolve flow fills them in. Nothing may be built
on file-level knowledge being present. (Checked against the live API: those
backfilled ids resolve to real mods whose names match the local folders, and each
publishes 3–4 files — which is the ambiguity the file-level marker exists for.)

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

Two pieces of catch-up work hang off it, and the important thing to understand
is that they are **siblings on opposite branches**, not one pipeline:

```
read sidecar
├── present  → origin backfill        (§7 of the plan — needs source_url)
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
and records the mod id at `inferred`, plus an install-date proxy. Decisions live
in `OriginBackfill`; see [The origin backfill](#the-origin-backfill) below.

**The branch is the whole design, and getting it backwards makes the backfill
dead code.** `source_url` only exists *in* the sidecar, so the legacy-migration
branch — reached precisely when there is no sidecar — builds its metadata from a
config character tag and an app-data image, and can never have a url to parse.
A backfill chained after the legacy migration would sit where `sourceUrl` is
null by construction and never fire once.

Follow this shape for new migrations. Two properties matter: it's **idempotent**
(re-running is harmless) and it's **offline** (scans happen on every launch with
no network, so a migration must never require a request).

### The origin backfill

Recovers, from data already on disk, what an existing mod's origin block *would*
have said. Split across two units so the decisions are testable with no
filesystem: `OriginBackfill` (pure, plus one injected `InstallDateProbe`) and
`utils/install_date_proxy.dart` (the one real filesystem walk).

Two rules govern every decision:

- **It never displaces something better** — which is narrower than "it only
  fills absence", and the difference matters. A stored `mod_id` at `exact` or
  `user` is never overruled: those came from a download, a checksum match, or
  the user confirming it, none of which came from `source_url`. But an id at any
  weaker tier — including our own earlier backfill — **follows the url**, because
  that is where it came from. Otherwise a user who pasted the wrong mod page once
  is stuck with it: correcting the url would be a silent no-op, and until the
  resolve dialog ships there is no other way to fix the binding. A `tracking:
  off` mod is skipped entirely — "not from GameBanana / it's my own" is a
  decision the user made, and a stale `source_url` is exactly why they might
  have made it.
- **Re-pointing at a different mod clears what described the old one.**
  `file_id`, `version`, `version_label` and `baseline_remote_date` mean something
  only relative to one mod page, so carrying them across a rebind would leave a
  block asserting that mod B ships file 555 of mod A. `remote_missing` resets for
  the same reason. `archive_md5` **survives**: it is a fact about the archive we
  extracted, not about which remote mod we currently believe it to be, so it can
  still be matched against the new mod's published checksums.
- **Nothing derivable means nothing written.** No empty sidecar, no "already
  swept" marker. Re-sniffing on the next scan costs one string parse, and it
  keeps the don't-litter rule intact.

What it writes, and what it deliberately doesn't:

| Field | Value | Why |
|---|---|---|
| `source` | `gamebanana` | The only service the parser understands. |
| `mod_id` | from `source_url` | `/mods/<id>` and `/mods/download/<id>` only. A `/dl/<id>` link is a **file** id in a different id space and yields null. |
| `mod_id_confidence` | `inferred` | It came from a free-form text field, so it may be a wrong paste or a different mod. May badge and suggest; never drives an unattended overwrite, and must be confirmed once before any update acts on it. |
| `installed_at` | oldest file mtime | With `installed_at_is_proxy: true`. |
| `provenance` | `imported_folder` | Genuinely unknown for a legacy mod — it may have been downloaded by an old build, imported, or hand-copied. Takes the least-privileged of the three, matching `OriginProvenance.parse`'s own fallback. It is not the auto-update gate, so understating it costs nothing. |
| `file_id`, `version`, `version_confidence` | **not written** | Identity and version are separate unknowns. The archive is deleted after extraction, so nothing local remains to match against the per-file checksums the remote publishes. Sniffing a version out of folder names or `.ini` comments is deliberately not done: mods embed ZZMI and game versions indistinguishable from mod versions, and a wrong stored version is worse than none. |
| `ingest.sibling_group` | **not written** | Unrecoverable — see the known limit below. |

**The install-date proxy, and how much to trust it.** Folder mtime and ctime are
both bumped by an `.ini` edit, so they skew *later* than the true install and
would hide updates; the oldest contained file is the earliest defensible answer.
Our own `.zzz-mod-manager/` is excluded — it was written by us, often long after
the install, and a folder holding nothing else would otherwise report our own
write time as an install date. How good the proxy is depends on how the mod got
there: imported *through the app* it is good (`_extractZip` writes fresh files
and `_copyDirectory` uses `File.copy`, neither carrying source timestamps over,
so mtimes land near import time), but hand-placed in `modsPath` (`cp -p`, the
user's own 7-Zip run, a synced folder) the author's build timestamps survive and
it can read *years* early. That is what `installed_at_is_proxy` is for; anything
comparing dates must read it.

**Cost.** Measured on a real 23-mod / 748-file library: a first scan that
backfills all 23 mods takes **30 ms** end to end, a subsequent scan **7 ms** with
zero writes (the re-read below accounts for ~3 ms of the first figure). The folder walk alone is ~10 ms for the library, ~0.45 ms per mod.
Crucially it is a **one-time cost per mod**, not per scan — once a block is
written the mod no longer qualifies and is never walked again — and it runs only
*after* an id has been recovered, so an untracked mod costs one string parse and
no I/O at all. The one exception is a folder whose write *fails* (read-only, an
odd network share), which would otherwise be re-walked on every scan forever to
re-attempt a write that cannot work; `ModMetadataRepository` remembers those for
the session, deliberately not across restarts, since a folder that becomes
writable should be retried.

**The write re-reads first.** The folder walk is an `await`, and a scan runs
after every toggle and rename, so a user confirming the edit dialog can land a
`save()` inside that window. The backfill therefore re-reads the sidecar
immediately before writing and re-checks its decision against what came back,
contributing only the machine-owned key to whatever is on disk *now*. Writing
back the copy read before the walk would quietly revert the user's description
and tags — the one class of damage this whole file exists to prevent.

**Known limit: sibling groups can't be recovered.** One archive can install as
several mod folders, and `origin.ingest.sibling_group` is what ties them together
so an update rewrites the group rather than one member. The backfill cannot
reconstruct it — nothing on disk records that two folders came from one archive.
Two mods sharing a `mod_id` after a backfill is therefore common and expected
(observed twice in a 23-mod library), and must not be read as a group.

---

## 5. Resolving an unknown origin

The backfill ([§4](#the-origin-backfill)) recovers identity where a `source_url`
happens to hold one. Everything it cannot recover — and everything a manual
import will keep producing forever — is resolved *by the user*, through the
per-mod resolve dialog (`screens/dialogs/resolve_origin_dialog.dart`).

**"Origin unknown" is a permanent state, not a migration to be finished.** Legacy
libraries, drag-dropped folders, mods from sites we don't browse: all of them are
legitimately untracked, so the model gives that a first-class tier, the library
card gives it a visible status, and the resolution flow stays in the UI rather
than being a one-time wizard.

### The status slot: one slot, three states

`services/origin_status.dart` folds an `origin` block into the single thing a
library card may render. It is a pure function, and the "needs attention" filter
in the mods toolbar is built from the *same* function — so the badge and the
filter cannot disagree about which mods are which.

| Status | When | How it looks |
|---|---|---|
| **`versionUnknown`** | `mod_id` known, `version_confidence` is `unknown` | Amber, actionable. We can query the file list but can't judge what comes back, and one pass through the dialog fixes it. |
| **`versionGuessed`** | `mod_id` known, version at `assumed_latest` or `inferred` | A muted **clock**. A version is on record but it is a guess. |
| **`untracked`** | no `origin` block, or no `mod_id` | A muted **dot**. **Informational, never alarming** — most of a pre-origin library looks like this, and badging all of it loudly trains the user to stop seeing the slot. |
| **`none`** | version at `user` or `exact`, `tracking: "off"`, or `remote_missing` | Nothing at all. |

The rule the three states follow, in one line: **the slot speaks whenever
tracking is less than complete, and how loudly depends on how cheaply the user
can act.** Amber is the one that asks for something; the two muted states are
statements of fact.

`versionGuessed` exists because `assumed_latest` and `user` used to render
identically, so a mod waved through by the bulk action was indistinguishable
from one whose file the user had actually picked — across a whole library, with
no way to tell but opening every dialog in turn. Two things about it:

- **It marks the weak state, not the strong one.** Marking "properly linked"
  instead was considered and rejected: those marks grow to cover every card as
  the library is resolved and then are permanent noise, where these *shrink as
  the user does the work*.
- **The two muted states differ by shape, not colour.** Two muted colours at
  9–15px are indistinguishable, and stay so for anyone colourblind.

Three of those rows are decisions rather than mechanics:

- **`tracking: "off"` and `remote_missing` both silence the slot**, for different
  reasons. The first is the user's explicit "not from GameBanana / it's my own",
  and the promise attached to it is permanence. The second is different: the
  amber state's entire offer is *click to set the version*, which means reading a
  mod page that is private, trashed or withheld — offering an action that cannot
  complete is worse than staying quiet. Nothing writes `remote_missing` yet;
  when the bulk pass does, it wants its own wording ("source no longer
  available") rather than one of the three states here.
- **Only `unknown` is actionable.** `assumed_latest` is the user having already
  answered "I don't know which, I got it around then", and `inferred` is a guess
  we recorded and label as one. Re-ambering either would make the dialog
  impossible to finish.

The **filter** keeps `untracked` and `versionUnknown`, and this is the one place
it and the badge deliberately come apart:

- **Untracked mods are in**, though the badge keeps them quiet. The badge asks
  "how loudly should this card speak", the filter asks "what have I not dealt
  with", and the dialog acts on an untracked mod perfectly well. Excluding them
  would leave a legacy library with an empty filter and no way to enumerate the
  mods it exists to enumerate. (What they get no access to is *bulk* resolution
  — a separate rule, about fuzzy name matching being unsafe to rubber-stamp.)
- **`versionGuessed` is out.** The bulk "assume current" action turns amber mods
  into guessed ones, and the count dropping is the entire visible proof that it
  worked. Were guessed mods still counted, the number would sit unchanged while
  the marks merely changed shape, which reads as a button that did nothing.

### What the dialog says is already recorded

Before offering to change anything, the dialog states the current answer — two
lines inside the identity card, folded from the block by `summarizeOrigin()`
(`services/origin_summary.dart`), plus an **on record** chip on the file row the
block names.

It had none of this: the dialog read `mod_id` to know what to fetch and
`installed_at` to rank files, and never read `file_id`, `version_confidence` or
`baseline_remote_date` at all. So it could not state its own subject's answer,
and a resolved mod opened looking exactly like one never touched — with no row
selected, because the recorded file was not among the things that preselected.

Rules worth knowing:

- **Two lines, because the block has two independent axes.** Knowing the mod
  says nothing about knowing the file, and the same field reads very differently
  at different tiers: "you confirmed this" and "worked out from the source link
  — not confirmed" are the same `mod_id`.
- **The recorded file is preselected, and every selection says why.** The
  ambiguity worth removing is not *that* something is selected but *what put it
  there*, so "on record" and "our best guess" carry different chips. This is
  also why the recorded row is preselected ahead of a suggestion.
- **The recorded baseline is quoted, never a recomputed one.** `assumeCurrent`
  clamps the stored baseline to the mod's creation date, so it legitimately
  differs from the install date the dialog would derive today; quoting the
  derived one would state a cutoff that is not in force.
- **The summary disappears after "Change".** `mod_id` then names a different mod
  than the block does, and the recorded file, version and baseline all belong to
  the previous one.
- **The panel is inside the identity card, not beside it.** A second bordered
  box cost about forty pixels and pushed the escape hatches below the fold,
  which the rule below forbids. The file picker's height came down from 280 to
  230 to pay for the two lines — that list scrolls inside itself and so loses no
  content, while the hatches beneath it have nowhere to go.

### What the dialog is allowed to write

The decisions live in `services/origin_resolution.dart`, pure and separate from
the dialog, because what is easy to get wrong is not the layout but *what each
answer may claim*.

| Answer | Writes |
|---|---|
| Confirm / pick a mod page | `mod_id` at **`user`**. Rebinding to a *different* mod clears `file_id`, `version`, `version_label`, `baseline_remote_date` and `remote_missing`, and keeps `archive_md5`. |
| Pick a file | `file_id`, `version` (`_sVersion`), `version_label` (`_sDescription`) at **`user`** — or at **`exact`** when the row was matched by a banked `archive_md5`, **or when the row picked is the one already recorded at `exact`**. |
| "I don't know which" | `version_confidence: assumed_latest` and `baseline_remote_date`. No file, no version. |
| "Not from GameBanana / it's my own" | `tracking: "off"`. Identity is left in place, so turning it back on is an undo. |

Rules worth knowing before changing any of it:

- **Re-picking the recorded file never lowers its tier.** Confirming a file we
  downloaded ourselves is `user`-grade evidence on its own, so a plain
  `exact ? exact : user` would demote it — and `exact` is the tier that gates
  unattended updates. Harmless while nothing preselected the recorded row; the
  moment the dialog does, pressing Save is enough. The rule is one-directional:
  re-picking a row recorded at `inferred` still *raises* it to `user`, which is
  precisely the confirmation that tier waits for.
- **Confirming raises `inferred` to `user`, and nothing raises anything to
  `exact` except a checksum match** (or the no-demotion rule above). An `inferred` identity came from a free-form
  text field a human typed and could be a wrong paste; the user looking at the
  mod page and saying yes is exactly what `user` means. `exact` stays reserved
  for "we downloaded it" and "its bytes matched the published md5".
- **A suggestion is never preselected.** Candidate rows are ranked with a stated
  reason — banked hash, folder-name match, newest file that already existed at
  install time — and the reason is *shown*, because a ranking with no visible
  reason is indistinguishable from a ranking with a wrong one. Only two things
  start out selected: a hash match (which is exact) and a mod that publishes
  exactly one file (where there is nothing to guess between).
- **Both `_aFiles` and `_aArchivedFiles` are ranked.** An old install matches a
  superseded file far more often than the current one, and they arrive in the
  same response.
- **The date candidate is the newest file that already existed**, not the nearest
  in absolute terms: a file uploaded *after* the install cannot be the installed
  one.
- **The per-mod dialog's "assume current" baseline is clamped to the mod's own
  creation date.** `installed_at` is frequently a proxy taken from the oldest
  file in the folder, and for a library placed on disk by hand (`cp -p`, the
  user's own 7-Zip run, a synced folder) the author's build timestamps survive
  and it can read *years* early, leaving a baseline from before the mod existed.
  Two qualifications, both easy to get wrong: the clamp is a **sanity floor, not
  a false-positive filter** — every published file is at or after its mod's
  creation date (checked: 32 files across the three captured profiles, none
  earlier), so it excludes only the file uploaded at creation — and the **bulk
  action does not apply it at all**, because the date comes from the mod page
  and that action makes no requests. See
  ["Assume current" in bulk](#assume-current-in-bulk).
- **`tracking: "off"` is the one decision that writes a sidecar into a folder
  that had none**, deliberately breaking the don't-litter rule
  ([§2](#dont-litter-empty-sidecars)): absence means "not looked at yet", which
  is precisely what the user is switching off.

### "Assume current" in bulk

The same "I don't know which file — I got it around then" answer, applied to a
whole view in one press. `services/bulk_assume_current.dart` holds the
decisions; `screens/dialogs/assume_current_dialog.dart` is the confirmation and
the write loop, offered from the mods toolbar.

It makes **no requests at all**, which is what makes it worth having: it turns a
legacy library from something that can never report an update into something
that can, without a mod page, a version string, or a single answer from the
user.

Four rules, in the order they matter:

- **It acts only on precise handles.** A mod with no `mod_id` is excluded, and
  the confirmation says how many were excluded for that reason. Identifying one
  means fuzzy-matching a folder name against a search, and a wrong match
  rubber-stamped in bulk lets a later "update" overwrite a mod with a different
  mod's files. That decision stays one-at-a-time and user-confirmed, forever.
- **Eligibility is re-checked against the block as freshly read from disk.**
  `bulkAssumeCurrent` is the transform handed to `updateOrigin`, and it returns
  null — abandoning that one mod — for anything that is no longer
  `versionUnknown`. Without it, a mod resolved *exactly* while the batch was
  running would be **downgraded** to a guess, silently, in a pass nobody is
  watching per-mod.
  A decline is reported as a decline, never as a failure. `updateOrigin` answers
  one bare `false` for "unwritable folder" and "the transform said no", so the
  loop wraps the transform to tell them apart — otherwise the guard's own
  correct behaviour surfaces as "those folders may be read-only". The reachable
  case needs no concurrency at all: press the button, then press it again before
  the rescan has refreshed the plan.
- **The confirmation states the size first.** The answer is usually either
  nothing or most of the library, and a user expecting the first who gets the
  second has had dozens of mods rewritten on a press. It also names what it is
  *not* touching (untracked mods, and mods with no derivable install date), so
  "12 mods" can't be mistaken for "all of them".
  That number is built from the list **the grid is rendering**, not from the
  wider list the toolbar's `!` toggle counts: combine the needs-attention filter
  with the search box and the two come apart, and a control that rewrites more
  mods than it is showing is the failure this placement exists to avoid. The two
  counts are therefore allowed to differ, and do so only when a second filter is
  active.
- **The baseline it writes is unclamped, and that is a deferred problem, not a
  solved one.** The per-mod dialog clamps `baseline_remote_date` to the mod's
  own `_tsDateAdded`, because a proxy install date taken from file timestamps
  can read years early for a hand-copied library. That clamp needs the mod page,
  which this action deliberately does not fetch — so **the update check must
  clamp when it compares**, which is the more correct place for it anyway: the
  clamp is a fact about the mod page, not about the sidecar. The confirmation
  states the risk in the meantime.

Nothing is probed for a missing install date, unlike the per-mod dialog. Every
path that can derive one from a folder walk has already run one — the offline
backfill probes every mod it gives an identity to, the ingest paths record an
observed date, and the resolve dialog probes before it binds — so a tracked mod
still missing the field is one whose walk found no files, and re-walking would
return null again. Those mods are listed as skipped rather than dropped quietly.

Measured against a mirror of a real library (17 mods with sidecars, 10 of them
eligible): **13 ms** for the whole pass including all 10 rewrites, and a re-run
is a 4 ms no-op because `assumed_latest` is no longer eligible. There is no
progress UI and none is needed; the button simply disables while it runs.

### The write path

`ModMetadataRepository.updateOrigin(modName, update)` **amends** the block, where
`recordOrigin` replaces it — so the archive hash, the ingest shape and the
provenance survive a decision that was only about identity and version.

`update` receives the block **freshly read from disk**, not the one the dialog was
opened with. That is not defensive habit: this dialog fetches a mod page and then
waits for a human, and a scan is kicked off after every toggle and rename, so the
sidecar genuinely can be rewritten inside that window — the same hazard the
backfill and the autofill re-read for. Returning **null from `update` abandons the
write**, which is how a decision that no longer makes sense against what came
back (the folder was rebound to a different mod meanwhile) declines to clobber it
rather than attaching a `file_id` to somebody else's mod.

A failed write is reported, not swallowed: nothing re-attempts it, and the
scan-time backfill is no substitute — it only ever recovers identity from a
`source_url`, at a weaker confidence than anything decided here.

### A pasted `/dl/` link cannot name a mod

The dialog accepts a pasted URL. A **mod page** url resolves directly and skips
the search. A `/dl/<fileid>` link is a *file* id in a different id space, and
**neither API can say which mod owns it** — probed live (2026-08-08): apiv11's
`File/<id>` returns the file record in full (name, size, date, md5, scan results,
even its archive tree) with no owning mod anywhere, its `_sProfileUrl` comes back
as the broken `https://gamebanana.com//<id>`, and the legacy Core API's
self-describing field list for `File` offers nothing better. So the dialog says
that instead of searching for the url as though it were a mod name.

---

## 6. Planned changes

**The origin block has shipped** — its write side, its field reference and the
rules around it are documented in [§2](#the-origin-block), which is now the
authoritative description. It shipped as **schema v2**; see
[§4](#when-to-bump-it) for why the bump was taken even though the additive-field
rule did not demand it.

**The offline backfill has shipped too** — it derives identity from an existing
`source_url` during a normal scan, and is documented in
[§4](#the-origin-backfill).

**The first reader has shipped too** — "already installed" detection, described in
[§3](#the-installed-mods-index): the marketplace reads the library's origin blocks
to badge mods it already has, mark which rows of a file list are installed, and
ask before re-installing an archive it recognises rather than quietly making a
second copy.

**Metadata autofill on install has shipped** — a marketplace install no longer
leaves description, gallery, tags and character blank, since the mod page it came
from knows all four. Documented in
[§2](#autofill-at-install-what-a-mod-page-may-write), including the one rule that
keeps it safe against an inbound sidecar: fill absence, never displace.

**The library-side status slot, the "needs attention" filter and the per-mod
resolve dialog have shipped** — documented in
[§5](#5-resolving-an-unknown-origin), which is now authoritative for how an
unknown origin is surfaced and what each answer is allowed to write. **The
zero-network bulk "assume current" action has shipped with them**, described in
[§5](#assume-current-in-bulk).

What remains planned is *remote* bulk resolution (one screen shared with the bulk
update check — identity confirmation and per-row version pickers, which need the
network the action above deliberately avoids) and update checking itself. Two
decisions recorded here because they constrain the format rather than merely the
UI:

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

**Identity at download time: now resolved.** This section previously recorded a
gap — the marketplace was a webview, it intercepted a CDN url, and so every
origin block it wrote carried `provenance`, `ingest`, `installed_at` and
`archive_md5` with *both* confidences at `unknown`. The native GameBanana browser
closed it. A download now starts from a chosen row of a chosen mod's file list,
so `source`, `mod_id`, `file_id`, `version` and `version_label` are all known
before the first byte, and the block lands with both confidences at **`exact`**.

That tier is the honest one, not an optimistic one: the user picked this file of
this mod and we fetched exactly that file id. Nothing is inferred. Note the
consequence — `exact` is the one tier eligible for unattended auto-update, so
in-app downloads are the path that makes future auto-update possible at all,
which is the self-healing property the plan relies on.

Two things this does **not** change:

- **Manual imports still land at `unknown`,** correctly. A dragged-in folder or a
  hand-supplied archive carries no remote identity; its route to `exact` is an
  `archive_md5` match at resolution time, not the install path.
- **The backfill is still the only thing that rescues the legacy library,** and it
  is independent of the above. It runs on `source_url`, recovering identity at
  `inferred` for mods that predate any of this (23 of 23 in a real library, since
  the edit dialog is where people paste the mod page). Neither path substitutes
  for the other.

One asymmetry worth knowing: a marketplace install writes remote identity into
the `origin` block but **does not** write `source_url`, which stays a
user-editable field. So a freshly downloaded mod has a `mod_id` and no url, while
a backfilled legacy mod has a url and a derived `mod_id`. Anything that wants "a
link to the mod page" should build it from `origin.mod_id` rather than expecting
`source_url` to be populated.
