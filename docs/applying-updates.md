# Applying an update

Reference for how the app **writes a newer download over an installed mod**, what it
refuses to do, and how a bad update is undone.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so.

> Scope: the mechanism that touches a live install — the overwrite, patch detection,
> the orphaned-`.ini` rule, replaying the recorded install layout, the pre-update
> snapshot and its retention, and rollback. Deciding *whether* a mod has a newer
> version is [`update-checks.md`](update-checks.md); this doc starts once that
> question is answered and the user has pressed Update. What a **fresh install**
> copies from a mod page is [`metadata-autofill.md`](metadata-autofill.md), and the
> `origin` block this path rewrites is [`origin-tracking.md`](origin-tracking.md).

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## 1. The mechanism is overwrite

**Extract to a temp directory, sanity-check it, then copy over the live folder.**
Never empty it, never move it, never delete it. Everything else in this document
follows from that one decision, so the reasoning comes first.

A mod folder is often **mixed**: it holds files from two downloads, because a *patch
mod* was applied into it. Patches replace rather than add — a patch `.ini` carries
the **same filename** as the mod's own and takes its place, and a patch asset
likewise overwrites one of the mod's files. So a mixed folder looks completely
ordinary from the outside: one `.ini`, every referenced file present, nothing extra.
There is no way to look at such a folder and see that it is two things.

Replacing such a folder destroys the other download, and the common case is worse
than losing a fix. The ordering that produces it is routine:

1. A page looks like a normal mod, so it gets installed.
2. The game shows nothing.
3. The user reads the page properly, finds it is a patch, and drags the base mod's
   files in around it.

The app now knows that folder as **the patch**. Replace it and what remains is a lone
`.ini` with nothing to apply to — the mod is *gone*, not merely unfixed. Overwrite in
the same situation copies the new patch file over the old one and touches nothing
else, which is exactly right.

Three properties fall out of overwrite for free, each of which the rejected
swap-the-folder design needed machinery for:

- **The active link survives by construction.** Moving the folder would dangle
  `saveModsPath/<name>`, which the next scan prunes — silently switching the mod off.
  Nothing moves, so nothing dangles, and no deactivate → move → reactivate dance is
  needed for link integrity.
- **The folder name never changes.** The new archive's root folder is frequently
  named differently (`Ellen` → `Ellen v2`), and `config.json` keys `active_mods`,
  `favorite_mods` and `mod_character_tags` by folder name. Overwrite never names
  anything, so this is satisfied without a rule.
- **A half-finished extraction never touches the install.** The crash-safety worry
  that made the swap plan attractive is answered by the temp step, not by the swap.

The mod **is** still deactivated for the duration of the copy, but for **open file
handles only** — the game's loader holds them on Windows and the copy would fail
against them. It is put back exactly as it was afterwards, active or not.

`utils/directory_copy.dart` is the copy: `Directory.create(recursive: true)` no-ops
on an existing directory and `File.copy` replaces its destination, so colliding files
are replaced and everything else is left alone.

### What overwrite leaves behind

Files the new version stopped shipping stay in the folder. For models and textures
that is wasted space and nothing more, because the loader only touches what an `.ini`
references. **`.ini` files are the exception** and are handled in [§3](#3-orphaned-ini-files).

Two caveats worth knowing rather than discovering:

- Do **not** "solve" leftovers by clearing all `.ini` files before copying. Harmless
  on a folder with one `.ini`, destructive on a folder where two are live (two mods
  merged by hand), and it buys only what §3's prompt already does with consent.
- Shaders are picked up by **filename convention** from a `ShaderFixes/` directory
  rather than by reference, so a mod shipping its own is the one file class where a
  leftover can still be live. Unverified against the loader; noted as the known gap.

### Excluded from the copy: `.zzz-mod-manager/`

The sidecar holds the description, the user's imported gallery, the tags and the
`origin` block that decides which mod page this mod is checked against. A download
can legitimately contain a `.zzz-mod-manager/` of its own the moment anybody shares a
folder they managed with this app, so an unfiltered copy would swap the user's
metadata for a stranger's.

Note the *install* path handles the same hazard differently and deliberately: it
keeps a stranger's description and images on purpose and replaces only their origin
block. This path **excludes rather than merges**, because there is nothing here we
want from the archive.

---

## 2. Patch detection

**A patch replaces rather than adds**, and it comes in two shapes that need two
rules. Both live in `services/patch_detection.dart`, both are pure, and
`services/patch_scan.dart` is the thin I/O wrapper the install paths use.

| Shape | What it ships | The test |
|---|---|---|
| **`.ini` patch** | A replacement `.ini`, no assets | It has an `.ini`, that `.ini` references resources that are absent, and **not one referenced resource is present** |
| **Asset patch** | Bare assets, **no `.ini` at all** | It has no `.ini`, and some one mod folder in the library already holds **every** file it ships |

**Neither rule can answer for the other's shape**, and that is structural rather
than a tuning problem. `assessPatchShape` is defined over what the `.ini` files
reference; an asset patch has no `.ini`, so there are no references, nothing to
compare, and no threshold that would help. `assessAssetPatch` is defined over what
the download carries; a download carrying an `.ini` is the first rule's question,
and two rules answering for one folder is how they come to disagree about it. So
each declines the other's input outright.

The two rules share their shape, which is the thing to preserve if either is ever
revisited: **no threshold, and a fact about the download itself rather than a
proportion of one or a comparison with something else.** "Brought none of what it
references" and "brought content nothing here can load" are the same sentence about
different evidence.

`services/ini_resources.dart` collects what the `.ini` files ask for.

### Why it is not "references a file it does not ship"

That was the first rule, and it is empirically wrong for this game. Measured over
**29 real ZZZ archives** it produced **one true positive and six false ones** — and it
did not flag the one archive in the corpus with "Patch" in its name.

The reason is the dominant idiom. A ZZZ character is several components (body, hair,
wings, jets…) and the extraction tools emit an `.ini` covering **all** of them. An
author replacing only the wings ships that component's buffers and textures and
nothing else, while the `.ini` still declares *and references* every other component.
The unshipped references simply never load and the game's own data stays in place.

> `Remielle combat wings replaced` (GameBanana 701954) is a complete, working,
> standalone mod. Its `.ini` references **36** files. The archive contains **8**.

"Partial mod" is therefore the normal case, and the old rule could not tell it from a
patch. **Nor can a ratio**: the six false positives sat at 0%, 2%, 18%, 22%, 32% and
92% of their references present — the entire range — so there is no cutoff to put
between the populations. Recorded because "require most of it to be missing" is the
obvious next idea, and it was measured and rejected.

What separates them cleanly is whether the download brought anything at all:

| Archive | Referenced | Present | Verdict |
|---|---:|---:|---|
| `Nicole Casual Wear (Updated Ini's 3.0)` — 5.8 KB, five `.ini` files, no assets | 52 | **0** | patch |
| `Remielle combat wings replaced` | 36 | 8 | partial mod |
| `HK416 - Zhu Yuan` | 13 | 5 | partial mod |
| `UI Functions Default Theme` | 193 | 3 | partial mod |
| `Belle's Blank Case and Patch` | 16 | 16 | complete mod |

Includes are excluded from "present": one `.ini` including another is a patch's own
internal structure, not content. Without that, the five-file `Nicole` archive counts
its own include and stops looking like a patch.

Two of those `.ini` files are checked in — `test/fixtures/ini/miyabi_student.ini` is
the one that produced the original false positive — and
`test/patch_detection_corpus_test.dart` re-runs the real rule over a directory of
**extracted archives** when `ZZZ_PATCH_CORPUS` points at one. The archives themselves
are hundreds of megabytes and are not in the repo, so that test skips by default; it
exists so the table above can be re-derived rather than trusted.

### A declaration is not a requirement

The rule that matters most, and the one that was wrong first time. A `[Resource…]`
section carrying a `filename` **defines** a resource; the loader only opens that file
when something else **references** the section:

```ini
Resource\ZZMI\Diffuse = ref ResourceMiyabiBodyADiffuse   ; the reference

[ResourceMiyabiBodyADiffuse]                             ; the definition
filename = MiyabiBodyADiffuse.dds
```

A definition nobody references is **inert** — the file is never opened, so its absence
costs nothing. That is not an edge case: authors start from a full character template
and delete only the override sections they don't need, leaving the resource
definitions behind.

Measured on a real, working mod — `Miyabi Transfer Student`, GameBanana 700727, the
v1.2 archive: **31 sections declare a `filename`, 29 are referenced and ship their
file, and the 2 that are never referenced are the only two absent.** Counting
declarations instead of references reported that mod — freshly downloaded, complete,
running fine — as a patch. Its `.ini` is checked in at
`test/fixtures/ini/miyabi_student.ini` so the case cannot regress.

So **only a referenced section's `filename` becomes a required file.** The patch test
survives intact, and for the right reason: a patch `.ini` is the working `.ini` for
the mod it patches, so the sections it declares are exactly the ones it references —
that is the mechanism by which it patches.

Reference matching takes **every token of every other line's value** rather than a
list of recognised syntaxes (`ref X`, `ps-t0 = X`, `this = X` are all references, and
there are more). A stray word that happens to match a section name is harmless; a
syntax left off a list would silently drop a resource that really is required. Tokens
are compared on their **last `\`-separated segment**, because a namespaced reference
reads `ref \author\mod\ResourceBody` while the declaration is still `[ResourceBody]`.

### What is not a reference at all

| Not a reference | Why |
|---|---|
| A section with no `filename` at all | 3DMigoto's `[Resource…]` sections describe run-time buffers as well as files. Counting those would call **every** mod a patch — it is the single most available false positive. |
| A value containing `$`, `*` or `?` | A variable or a wildcard. "We could not resolve this" is a different fact from "this file is absent", and only the second supports a conclusion. |
| An absolute path | Machine-specific; says nothing about this folder. |
| A path climbing out of the folder | Refused, the same way archive members are. |

Two more rules that keep ordinary mods out of the false-positive bucket:

- **The folder's `.ini` files are read collectively, never one at a time.** A mod that
  declares resources in one file and overrides in another is ordinary, and asking each
  file whether it ships what *it* references reports that mod as broken. The
  referenced-name set is gathered across the whole folder for the same reason.
- **Paths and section names are compared case-insensitively on every platform.**
  3DMigoto is a Windows loader, so authors write `Body.dds` against `body.dds` freely;
  a case-sensitive comparison on Linux would report those as missing files.

`include` and `include_recursive` are references too — of a file and of a directory
respectively — and they skip the reference filter, because an include **is** its own
reference. `namespace = …` does not affect a *path*: it renames sections, and a
`filename` is always relative to the `.ini` that wrote it.

### What the reference filter is still for

It no longer carries the patch verdict — "brought no content" does that — but it is
not redundant:

- It keeps `PatchAssessment.missing` honest, which is the count the warning quotes.
- **The stale-`.ini` rule depends on it** ([§3](#3-orphaned-ini-files)), and that rule
  is about overlap rather than absence, so a dead declaration there changes the
  answer.

### The asset patch: an asset with no `.ini` is waiting for someone else's

A patch that replaces one texture ships that texture and nothing else. Measured on
a real pair: one is a 6.7 MB `.rar` containing **exactly one `.dds`**, and the mod
it patches ships 17 files including a `.dds` of that name, whose `.ini` references
it. Drop the first into the second's folder and one texture is replaced, every
reference still resolves, and the folder is indistinguishable from an ordinary
mod — [§1](#1-the-mechanism-is-overwrite)'s mixed folder, arrived at without a
single `.ini` being involved.

The rule is **intrinsic to the download**: nothing in the game reaches a `.dds`,
`.buf`, `.ib` or `.vb` except through an `.ini`, so assets arriving without one are
assets meant to land beside a mod that has one. `assessAssetPatch` takes the file
set and `hasIni`, and nothing else.

**Images are deliberately not assets** for this purpose. A `.png` or `.jpg` in a
mod folder is overwhelmingly a screenshot, so counting them would make a `previews`
folder installed as its own mod read as a patch — the one case the "may be
incomplete" warning is genuinely for. A real patch shipping a screenshot beside its
texture is still a patch, because something in it still needs an `.ini`.

#### The rejected alternative, and why it lost

The first version compared against the library instead: *a download that brings
nothing you don't already have is replacing rather than adding*, naming the folder
that held every file. It reads well and it is wrong in a way that matters.

- **It depends on install order.** Downloading a patch before the mod it patches is
  an ordinary way round — you find the patch, then go and get what it patches. With
  nothing to compare against, the patch was reported as *"the mod may be
  incomplete"*, which points at the wrong fix.
- **It is a filename collision away from a wrong answer**, in both directions.
- **It costs a full library walk per install**, at 0.51 ms per mod, for an answer
  the intrinsic rule gets from the folder already in hand.
- **It could only ever suggest a folder.** What gets recorded is a **mod page**,
  and no folder name yields one; the user names it either way
  ([`origin-tracking.md` §10](origin-tracking.md#the-install-asks-too-at-the-moment-it-finds-a-patch)).

The residue is the reverse mistake: a folder that really is a broken download of
assets, reported as a patch. That is the milder direction — the user is told the
download cannot work on its own and asked what it belongs to, which is true either
way, and they can decline to answer and move on.

### Two uses, one implementation

- **At install.** An asset patch is reported *instead of* the "may be incomplete"
  warning rather than beside it — the two are answers to the same question about one
  folder, and giving both would say two different things about it.

  The two ingest paths ask at different moments, and only one of them acts on the
  answer. The **marketplace** path scans the extracted folders *before* the copy —
  scoped by the import picker, since patch-shape is a property of a resulting mod
  and not of a folder (`scanPlannedMods`) — and raises the question there
  ([`origin-tracking.md` §10](origin-tracking.md#the-install-asks-too-at-the-moment-it-finds-a-patch)).
  The **drag/drop** path scans after the copy and only warns — it records no
  `patch_shaped`, so the folder never reaches the state that would offer to name
  what it patches. There is a block to record it on: that path seeds every folder
  it imports (`ModOriginSeed.importedFolder`, or `importedArchive` for one out of
  an archive), so `importMods` writes an origin for each. Only the write is
  missing.
- **Before an update.** If the *incoming* download has dangling references, the
  folder being written into must be mixed. The confirmation says so, and states that
  only part of the folder is being replaced. This works on the existing library with
  no recorded data and no extra request, because the new archive is already in hand.
  Only the `.ini` rule is used here: an update replaces a folder that already
  works, so "it brought assets and no `.ini`" says nothing — the `.ini` it needs is
  the one already on disk.

**The limit bounds the whole feature and is stated rather than papered over:**
neither rule can see a mixed folder whose *tracked* download is the base mod with a
patch applied on top. Nothing is missing and nothing is unfamiliar, so nothing looks
wrong. That direction is accepted loss, and it is the milder one — the base mod's
own update usually contains the same fix.

---

## 3. Orphaned `.ini` files

The loader reads **every** `.ini` in a mod folder. When an update renames its own —
`ellen.ini` becomes `ellen_v2.ini` — the overwrite writes the new one and the old one
simply stays, and both are live: duplicate hotkeys, two sets of overrides on the same
hashes, and a user who reports that the update broke their mod.

The obvious rule — *any `.ini` we did not just write is a leftover* — is wrong, and
wrong in the direction this whole path exists to avoid. It would offer, by default,
to delete the `.ini` of a second mod merged into the same folder.

So the test is not "did we write this file" but **"does this file describe the
content we just wrote"**:

> A leftover `.ini` is stale when every resource it names **and the folder actually
> has** is a file the incoming download ships.

- An upstream rename satisfies that by construction: the renamed `.ini` is a full
  replacement for the old one, so it references the same resources.
- A hand-merged second mod does not — it names *its own* files, which the incoming
  download knows nothing about.
- A patch `.ini` shares the mod's filename, so it is **overwritten** rather than
  orphaned and never reaches this rule at all. That is why this is an occasional
  prompt rather than a routine screen needing a bulk path.

**"And the folder actually has" is load-bearing, not a guard.** Because of the
template-`.ini` idiom described in [§2](#2-patch-detection), an ordinary mod's `.ini`
references several components' worth of files it never shipped. Comparing against the
whole reference list would find those absent from the incoming download too, conclude
"not stale", and quietly stop offering to remove the very file this rule exists for.
Restricting to references the folder satisfies today asks the question that was always
meant.

An `.ini` naming nothing checkable is **kept without asking**. "We could not tell" is
not "safe to delete", and the cost of keeping one is a duplicate the user can still
remove by hand, against the cost of deleting somebody's merged mod.

### Comparison paths are normalised; filesystem paths are not

Every path in `FolderContents` is lower-cased, because 3DMigoto is case-insensitive
and the comparison has to be. **That spelling is correct for comparing and wrong for
everything else.** `FolderContents.actualPaths` maps each normalised path back to the
name on disk, and anything that touches `File` or reaches a user goes through it.

This is not a hypothetical. Mod authors ship `Ellen.ini`, `Miyabi.ini`,
`MasterNico.ini`; all-lower-case is the rare spelling. Deleting a stale `.ini` through
the normalised path opened nothing on Linux — `exists()` answered false, the loop
reported nothing removed, no error was raised anywhere, and the user was left with the
two live `.ini` files this rule exists to prevent, having ticked the box and been told
nothing. The confirmation had the same fault cosmetically, naming `ellen.ini` for a
file called `Ellen.ini`.

**Every test in the suite wrote a lower-case filename**, which is why nothing caught
it: the feature was only ever exercised on the one spelling that happened to work.
`update_applier_test.dart` now pins the mixed-case case in both directions.

The confirmation defaults to **remove**, names the files, and separately names the
ones the rule refused to touch — the second list is also the signal that the folder
is mixed.

The residual cost is honest and small: if a stale file had itself been patched,
deleting it drops the patch. Keeping it is worse (two live `.ini` files), and the
snapshot still holds it.

`services/update_apply/stale_ini.dart` is the rule, and it is used in **both
directions** — a rollback orphans the `.ini` the newer version added, which is stale
exactly when the snapshot carries everything it names.

---

## 4. Replaying the install layout

One archive does not map to one mod folder. The install asks "which of these folders,
and separately or combined?" and records the answer in `origin.ingest`. **An update
never re-asks it.** Asking again turns a one-click action into a quiz whose right
answer the app already knows, and a user who answers differently the second time
silently restructures their own mod.

`services/update_apply/update_layout.dart` is the pure replay. It has exactly two
outcomes: a set of mappings, or a **stop-and-ask**. There is no third where it picks
something plausible.

| Recorded | Archive | Result |
|---|---|---|
| nothing | one folder | that folder → the mod folder root |
| nothing | several | **stop**: `layoutUnknown` |
| `separate`, one folder | a folder of that name | it → the mod folder root |
| `separate`, one folder | one differently-named folder | it → the root (an upstream rename) |
| `separate`, one folder | several, none matching | **stop**: `layoutChanged` |
| `combined`, N folders | all N present | each → its recorded subfolder |
| `combined`, N folders | any missing | **stop**: `layoutChanged` |

**The unrecorded case is the common one, not the exception.** `ingest` is written by
this build and by nothing else, and the offline backfill deliberately recovers
identity and not layout — so on a pre-existing library it is absent everywhere. That
path is answered by the only unambiguous shape, one top-level folder.

A **renamed upstream folder is expected, not a mismatch**, and is absorbed for a
single folder. It cannot be absorbed for a combined install: with three subfolders
and three differently-named incoming ones there is no way to tell which became which,
and guessing writes a mod's textures over its buffers. A combined install also keeps
its **recorded** subfolder names rather than the archive's, because the subfolder is
what the mod's own `.ini` paths were written against.

Folders in the archive that are not part of this mod — a `previews/` folder, or a
sibling mod that lives in its own library folder — are named in the confirmation
rather than dropped silently.

### After a successful update

`ModOrigin.updatedTo` rewrites the block. Both confidences reach `exact` on the same
grounds a marketplace install does — the user picked this row of this mod's file list
and we wrote exactly that file id — and `provenance` becomes `downloaded` even for a
folder originally imported by hand, because the bytes in it now came from an archive
this app fetched. Three fields are **cleared**, and each would otherwise be a lie
about the folder as it stands:

- `baseline_remote_date` — a date-based guess sitting beside an exact file id.
- `updates_dismissed_until` — the user waved an update away and has now taken it;
  keeping it would silence the *next* release too.
- `remote_missing` — we just fetched the page and a file off it.

`tracking` survives untouched: it is the user's own statement about whether this mod
should be watched at all.

`ingest` is refreshed from what actually happened, which is a real gain for the
pre-`ingest` library — a mod that had no layout on record now has one, so its *next*
update replays instead of stopping to ask.

---

## 5. Snapshots

### Every apply snapshots, unconditionally

The update path deliberately accepts losses it cannot distinguish from intended
changes: a rebound keybind reverted by a shipped `.ini`, a patch overwritten by the
mod it patches, any hand edit. Each of those is defensible **only** while the recourse
exists, so the snapshot is not a setting and not an opt-in. **If it cannot be taken,
nothing is written** — proceeding would trade a recoverable failure for an
unrecoverable one.

It is also the only recovery from a copy that fails part-way. Overwrite has no
aside-folder to fall back on the way a swap would, and a partly-copied folder holds
some new files and some old.

### They live outside `modsPath`

A snapshot placed *inside* the mod folder is reachable through the active symlink, so
the loader walks into it and reads the old version's `.ini` alongside the new one —
the exact duplicate-hotkey failure §3 exists to prevent.

```
<appData>/backups/
  <mod folder name>/
    20260809-142530-000/
      manifest.json     ← what this is, taken when, of what version
      files/            ← the mod folder, verbatim, sidecar included
```

The manifest sits **beside** `files/` rather than inside it, so a restore copies
`files/` back wholesale without carrying bookkeeping into the mod. The sidecar **is**
included: a rollback that restored the files but kept the new origin block would leave
the app checking for updates against a file the folder no longer holds. A corrupt or
missing manifest never hides the snapshot — the files are still restorable, and a
rollback the user cannot reach is the failure this exists to prevent.

`manifest.json` is its own small format and is **not** the mod sidecar; nothing in
[`metadata-schema.md`](metadata-schema.md) describes it. Fields: `mod`, `taken_at`,
`size_bytes`, `file_count`, `reason` (`before_update` | `before_restore`), and
optionally `version` / `version_label` as they stood before the update.

### Retention

`services/backup/retention.dart` is pure and takes an injected clock. Three numbers:
**30 days**, **3 per mod**, **5 GB total**.

**Retention has to outlive *discovery*, which is a stronger constraint than any cap.**
None of the accepted losses announce themselves during the update. They surface the
next time the user launches the game and finds a hotkey dead or a texture back to
default — plausibly days and several further updates later. So "keep the newest
snapshot per mod" throws away exactly the one they come looking for.

**The age floor beats the count cap, and where they conflict, age wins.** The cap is
also **size-aware rather than purely count-based**: the median mod archive is ~22 MB,
so three per mod costs almost every library nothing, but the tail reaches 1.24 GB and
a handful of those quietly eat several gigabytes.

Deletion walks four tiers in order and stops as soon as the budget is met:

| Tier | What | When it is pruned |
|---|---|---|
| 0 | the newest snapshot of each mod | **never** |
| 1 | beyond the count cap **and** older than the age floor | unconditionally |
| 2 | beyond the count cap, inside the age floor | only under size pressure, oldest first |
| 3 | inside the count cap | only after tier 2, oldest first |

If the budget is still exceeded after tier 3, the plan **reports the overage**
(`RetentionPlan.overBudgetBytes`) rather than reaching into tier 0. A user with one
1.2 GB mod is over any sane budget by keeping a single snapshot of it, and the honest
answer is to say so, not to leave them with no rollback.

Pruning runs after a successful update — the one moment a snapshot has just been
added, and already an operation the user is waiting on. Nothing else triggers it.
The numbers are **not user-configurable**; add a setting only if it is actually asked
for.

### Rollback

Reachable from a mod's right-click menu, and only for mods that have a snapshot (one
`readdir` of the backups root answers that for the whole library). If restoring meant
finding `<appData>/backups/` in a file manager, "recoverable from the snapshot" would
not be a real answer to a user who has just lost a mesh fix.

A restore **snapshots first**, so it is itself undoable, then overwrite-copies the
snapshot back and applies §3's rule in reverse.

**The rollback list is refreshed whenever a snapshot was taken, not only when the
update succeeded** — and the failure path is the one that matters. A copy that broke
halfway leaves the folder half-old and half-new, and the error message sends the user
straight to "Restore a previous version…". That entry is drawn from
`modBackupsProvider`'s cached set, so for a mod being updated for the first time it
was absent: the single moment the rollback is needed was the one moment it was missing
from the menu. `applyUpdateFlow` invalidates *before* the success check, so there is
one call rather than one per branch.

### What survives of "preserve the user's `.ini` edits"

Re-applying a user's keybind edits across an update was considered and **rejected**.
The reasoning, recorded so it is not re-proposed:

- **There is no pristine baseline to diff against.** After install, `<mod>/*.ini` is
  the author's file *and* every later change to it, with nothing marking which is
  which. A merge therefore compares old-with-edits against new-shipped and reports
  every **author** change to a keybind section as a user conflict.
- **Recording per-`.ini` hashes at ingest does not fix that.** A hash divergence
  cannot tell a hand-edited keybind from a patch applied into the folder from a
  hand-merge of two mods — so the report's headline would be a guess about *why* the
  file changed, which is the one thing it existed to stop being.
- **The write side is where every hazard lives.** Putting a key back means knowing
  whether the `.ini` still exists or was renamed, whether the keybind still carries
  the same identifier, whether its other settings still make the old key correct, and
  whether it now collides with one the new version added. Four guesses, and a wrong
  one writes a broken `.ini` into the folder — strictly worse than a key the user
  retypes in thirty seconds.

What survives is **read-only**: the result dialog names the keys this update moved.
`IniParserService.parseCharacterDirectory` already turns a folder into keybinds, so it
is two existing calls — the snapshot and the folder afterwards — with no matching, no
conflict logic and no write path. A reset keybind is otherwise self-announcing in the
worst way: the user finds out by pressing the old key in-game and having nothing
happen.

**A diff, not an inventory** (`services/update_apply/keybind_changes.dart`). The first
version listed every keybind the mod had before the update, which is unreadable — a
column of `Skin — F7` with no context asks the reader to remember what it used to be
and compare by hand — and it could never be empty, so it appeared after every update
whether anything had moved or not, which trains people to skip it. Reporting only what
*differs* makes the section self-explanatory and makes it vanish in the common case.

Matched by section name, case-insensitively, because that is the only stable
identifier an `.ini` gives a keybind — the key itself is exactly what changed.
Comparison is on the **display** form and as an unordered token set, so `VK_F7` → `F7`
and `ctrl F7` → `F7 ctrl` are not reported: those are the author's editor, not a
change the user could act on. Keys the new version *added* are not reported either —
they are not something the user lost, and they would land under a heading that says
they were.

---

## 6. The order, and why it is the safety argument

`screens/dialogs/apply_update_flow.dart` owns the sequence. Each step exists to make
the next one refusable:

1. **Download** to `<appData>/downloads`. Cancellable; nothing local has changed.
2. **Extract to temp** and check it produced folders. A failed extraction keeps the
   archive and says where it is.
3. **Preview** — layout, patch shape, orphaned `.ini` files. Every question that can
   only be asked before the copy.
4. **Ask.** Including the accepted keybind loss and the snapshot, stated rather than
   discovered. Those three sit together under *what this does to the folder*, with
   **the snapshot first within that section** — overwriting and reverting keybinds
   are only acceptable because a copy was taken, so the copy is read before the two
   things it pays for. The patch warning is the only notice given the amber emphasis,
   because it is the only one that changes what the update will *do* rather than
   describing it.
5. **Deactivate → snapshot → copy → resolve leftovers → reactivate.**
6. **Record** the new origin block, prune snapshots, rescan.

The orchestration is at the widget layer because it is a *conversation*. Every
decision inside it is in `services/update_apply/`, which knows nothing about dialogs
and is tested against real temp directories rather than a fake filesystem — the point
of the mechanism is what it does to files, so a fake would be asserting the fake's
semantics.

### The same order, for a patch installed into a mod

`UpdateApplier.applyPatchInto` is the second caller of that order, and it is here
rather than in the install path because it carries the update's risk rather than an
install's: it writes over a folder the user is already using, and the snapshot is the
only way back. Deactivate, snapshot, place, reactivate — with **no snapshot meaning
no write**, the same trade §5 refuses to make.

What differs is only the copy. An update replaces whole folders by
[§4](#4-replaying-the-install-layout)'s layout; a patch replaces **individual files,
each where the target already keeps that name** (`patch_placement.dart`), because
the two downloads are by different authors and nothing makes their layouts agree.

Three consequences of the file-by-file copy:

- **The extraction wrapper cannot end up nested inside the target.** What is copied
  is the *contents* of the source folder, never the folder — so a folder invented for
  a rootless archive cannot become a subfolder holding a second live `.ini` whose
  `filename` paths resolve beside itself.
- **The orphaned-`.ini` rule has nothing true to say**, so nothing is removed. It
  looks for an `.ini` whose every resource the incoming download also carries — the
  renamed predecessor of an update — and a patch by definition carries less than the
  mod it patches.
- **Our own sidecar is skipped**, as on the update path. An archive can arrive
  carrying one, and copying it over would replace the target's description, gallery
  and origin block.

Where the placement cannot be settled without a guess, the install falls back to an
ordinary new mod and says why — see
[`origin-tracking.md` §10](origin-tracking.md#installing-a-patch-into-a-mod-that-already-works).

---

## 7. What is not built, and what is refused

### Automatic updating — considered and refused

**No update is ever applied without the user present.** This is a rule about the
feature, not a gap in it, and it is recorded here so it is not re-proposed as an
obvious convenience.

The reason is the subject of this whole document: **an update overwrites a live
install, and ZZZ modding has no standard.** Everything §1 to §3 describes is the
app doing its careful best with folders that are frequently two downloads deep,
`.ini` files written against a case-insensitive loader by hand, and archives
whose layout the author changed between releases. When that goes wrong the
recovery is a person looking at a mod folder and working out what happened —
and that person has to be **at the keyboard when it lands**, not discovering
days later that a mod they have since edited was silently replaced.

Two things follow, and the second is the one that is easy to get wrong:

- **Confidence is not the mitigation.** `ModOrigin.allowsUnattendedUpdate`
  demands `exact` on both axes, which is a strong statement about *which file
  this is*. It says nothing about what the folder holds, which is where every
  hazard in this document lives. A byte-perfect identification of the right
  successor still overwrites a hand-merged second mod.
- **Nor is the snapshot.** §5 makes it unconditional, so recovery exists — but
  none of the accepted losses announce themselves, which is exactly why the age
  floor beats the count cap. A recovery nobody knows to reach for is not a
  substitute for the user having seen the change happen.

**Checking is a different act and is automatable**, because it reads a mod page
and draws a badge: nothing it does is hard to undo. That half is opt-in and
shipped — [`update-checks.md` §5.1](update-checks.md#51-checking-at-startup).

`allowsUnattendedUpdate` consequently has no reader in `lib/`. It is kept
because it is the only place the "`exact` on both axes" rule is written as code,
and its tests are what pin the tier table
([`origin-tracking.md` §1](origin-tracking.md#1-two-axes-confidence-and-provenance)).

### Known gaps

Stated because each one bounds what this feature currently promises.

- **A sibling group updates one member at a time**, and each member re-downloads the
  same archive. One archive can install as several mods, each with its own origin
  block and its own update check; nothing groups their updates. For a 1.24 GB archive
  that is a real cost.
- **The precise file list an archive laid down is not recorded.** With it, an update
  could remove exactly the paths the old version wrote before writing the new ones,
  and an overwritten patch would be detectable. The data does not exist for a single
  currently-installed mod, and re-downloading the old archive to reconstruct it is
  both a second full transfer and unavailable exactly for the old mods most likely to
  have been patched.
- **A mixed folder is only watched in full once the user says what else is in it.**
  The origin block's own fields describe one download, and in the common ordering
  they name the *patch* — so a check against them alone never looks at the base mod.
  Applying an update is **not** the broken part; overwrite does the right thing there.
  Two things close it, and the second needs a person:
  `ingest.patch_shaped` is recorded at install, which is enough to refuse the clean
  verdict ([`UpdateOutcome.tracksPatchOnly`]) but not to watch the other mod; naming
  that mod adds a **companion** to the block, and the check then folds both pages
  into one verdict ([`origin-tracking.md`](origin-tracking.md#10-a-folder-that-holds-two-downloads)).
  **The flag is recorded rather than derived because the folder is legible only at
  install**: once the base mod's files are dragged in around the patch, every
  reference resolves — and for an asset patch the two downloads have merged into
  one set of files — so no later scan can tell it apart
  ([§1](#1-the-mechanism-is-overwrite)). That is also why **nothing can offer to fix
  a folder that is already mixed** — the app has no way to know it should ask, and the
  resolve dialog is the only route in.
- **There is no "install this into that mod's folder" operation.** Both install paths
  refuse a name collision, so every mixed folder in existence was assembled by hand in
  a file manager and the app is reduced to inferring it afterwards from `.ini`
  contents. An explicit "apply as a patch to…" install would make it a recorded fact
  at write time, at `exact` rather than the `user` tier a person's answer earns.
- **`ModManagerService._copyDirectory` is a second copy of the same walk** as
  `utils/directory_copy.dart`, with one behavioural difference: it follows links,
  where the shared one does not. Unifying them changes the *import* path's behaviour,
  so it was left alone rather than fixed as a drive-by.
