# Reading data an older version wrote

**Scope:** every place this app copes with data it did not write in the shape it
writes today — the per-mod sidecar, `config.json`, and the app-data directories.
What each individual format *is* belongs to its own doc
([`metadata-schema.md`](metadata-schema.md),
[`configuration.md`](configuration.md)); this is the index of what happens to
the old shapes, and the one rule they all follow.

## There is no `migrations/` folder, and that is a decision

The familiar shape — a numbered directory of scripts, a table recording which
have run — assumes **one store that advances monotonically**. One database, at
one version; run 001, 002, 003, write down where you got to.

None of that holds here:

- **The data lives inside the things being managed.** A library is ~80
  independent `metadata.json` files, one per mod folder, each at whatever
  version last touched it.
- **Old data arrives after the upgrade.** A mod folder is copied from a friend,
  restored from a zip, pulled out of a backup, or dropped in by hand — so a v1
  sidecar can turn up tomorrow, on a library that "finished migrating" months
  ago. There is no point at which a migration is *done*, so there is nothing to
  record having run.
- **The library may be read-only.** A step that must complete before the app
  can proceed would make an unwritable folder fatal. Every migration here
  returns usable values **in memory** whether or not the write lands.

So migrations are **read-side**: the code that reads a format understands every
shape that format has ever had, and the newer shape is written the next time
something saves for its own reasons. A folder upgrades when it is touched, and a
folder nobody touches keeps working.

Three properties follow, and every entry below has all three:

| Property | Why it is forced |
|---|---|
| **Idempotent** | it runs on every scan, forever — there is no "already done" flag to check |
| **Offline** | scans happen at launch with no network, so a migration may never make a request |
| **Non-fatal** | an unwritable folder still has to produce a working mod |

`ModMetadataRepository.loadOrMigrate()` is where most of them hang, reached from
`ModManagerService._buildModInfo()` on every scan.
[`metadata-schema.md` §4](metadata-schema.md#the-migration-hook) has the shape
in detail, including why two of them are **siblings on opposite branches**
rather than a pipeline.

## The migrations

| What | Where | From → to | Notes |
|---|---|---|---|
| Character tag in `config.json` and image in `<appData>/mod_images/` → the mod's own sidecar | `loadOrMigrate`, no-sidecar branch | pre-2.0.0 → 2.0.0 | Writes the sidecar, then deletes the legacy image — **in that order**, since the copy is referenced by nothing until the sidecar names it |
| `source_url` → an `origin` block at `inferred` confidence | `loadOrMigrate`, has-sidecar branch (`OriginBackfill`) | 2.2.2 → 3.0.0 | Writes only when it actually derives something. Pure and filesystem-free, so it is tested on its own ([`origin-tracking.md`](origin-tracking.md#3-the-offline-backfill)) |
| A mod folder gets a `uid` | `loadOrMigrate`, **both** branches | 2.2.2 → 3.0.0 | The only one that touches every mod: the others fire on evidence, this one on absence. See [`metadata-schema.md`](metadata-schema.md#uid--the-identity-a-rename-cannot-take-away) |
| Flat `origin` block + `companions` → the `downloads` stack | `ModOrigin.migrateFlatBlock` | dev builds only | The flat shape never shipped, so this reads sidecars written by development builds and nothing else. No version bump: the next save emits a stack |

## Tolerances, which are not migrations

Each of these lets an old or unknown shape through unchanged, rather than
converting it. They are listed because they answer the same question — *what
happens to data this build did not write?* — and because deleting one looks
harmless.

| What | Where | Rule |
|---|---|---|
| A sidecar with no `schema_version` | `ModMetadata.assumedSchemaVersion` | Assumed **1**, the literal first format — never "current", which would stamp the newest version onto the oldest files |
| Sidecar keys this build does not know | `ModMetadata.extra` | Carried through reads and writes untouched, so an older build never strips a newer one's data. **2.2.2 does not do this**, which is what makes running 3.0.0 and then downgrading lossy |
| `ingest.patch_files` | `ModIngest._paths` | Stays a plain `string[]` **permanently**. A released build reading objects there would see no patch files at all and flatten a patch on the next base update |
| An unrecognised `InstalledFileRole` | `InstalledFileRole.parse` | Resolves to `replaced`, the one lenient parse in this codebase that resolves *upward*: `added` licenses a delete |
| A `config.json` key this build does not know, or one it expects and does not find | `ConfigService.loadFromFile` | Every read is `containsKey`-guarded, so absent keys take their defaults and new keys are pure additions. **The one store with no version field** — see the gap below |

## Cleanups, in the same family

Not migrations either: they remove data that a migration or a rename left
unreachable. Grouped here because each one exists for the same underlying
reason — **app-data keyed by folder name, and a rename outside the app is not an
event this app can see.**

| What | Where | When |
|---|---|---|
| Legacy images no mod can reach | `ModMetadataRepository.sweepLegacyImages` | after every scan |
| `mod_character_tags` entries for mods that are gone | `ConfigService.cleanupInvalidTags` | after every scan |
| Links in `saveModsPath` whose source is gone, and their `active_mods` entry | `ModManagerService._cleanupInvalidLinks` | after every scan |
| A `.zzz-mod-manager/replaced/` store arriving inside an imported folder | `PatchStore.discardAll` | at ingest |

Saved versions are **not** in this list, and that is the point of them being
keyed by `uid`: a rename cannot strand them, so there is nothing to clean up
([`applying-updates.md`](applying-updates.md#snapshots-live-outside-modspath)).

## Known gaps

- **`config.json` has no `schema_version`, and one bad value fails the whole
  load.** `loadFromFile` decodes the file inside a single `try`, so a value
  whose *type* changed would throw and the entire config would silently fail to
  load — resetting the user's library paths rather than migrating them. Nothing
  has changed type, so this is latent; it is the one store that could not detect
  that it should migrate.
- **`favorite_mods` is never pruned**, where `mod_character_tags` is, and
  `active_mods` is pruned only when a dangling link gives it away. A mod deleted
  outside the app leaves its entry behind.
