# Mixed folders — watching both mods, and not making mixed folders

**Planning file, repo root, temporary.** It is not a `docs/` reference and must not
become one. `docs/` documents what the code does in the present tense; this
describes work that does not exist. When it ships, the durable half moves into
`docs/applying-updates.md` §1/§7, `docs/origin-tracking.md` §5/§8/§9 and
`docs/metadata-schema.md`, and **this file is deleted**.

Covers the two open items under §4 of `BUGS & TODO.md`:

- *A folder should be able to carry more than one origin block.*
- *There is no "install this into that mod's folder" operation.*

They are **one piece of work**. The reason is in [§6](#6-the-two-items-are-one-question-asked-twice).

---

## 0. What is already true

Not re-derived. Stated so nothing below argues with it.

```
  A mod folder is MIXED when it holds a patch plus the mod it patches.

  A patch REPLACES rather than adds — its ellen.ini carries the same
  filename as the mod's own and takes its place.

  So a mixed folder looks completely ordinary:  one .ini,
                                                every reference resolves,
                                                nothing extra.
```

The folder is legible **exactly once**, and it is not now:

```
  install the patch          drag the base mod in           six months later
  ────────────────────       ─────────────────────          ─────────────────
  EllenBikini/               EllenBikini/                   EllenBikini/
  └─ ellen.ini               ├─ ellen.ini  (the patch's)    ├─ ellen.ini
                             ├─ body.dds   ← from mod 111   ├─ body.dds
     refs body.dds  ✗        └─ face.dds   ← from mod 111   └─ face.dds
     refs face.dds  ✗
                                every ref resolves.            unchanged
     ▲                          nothing to see.
     └── THE ONLY MOMENT
         WE CAN TELL
```

**Half of this already shipped.** `ingest.patch_shaped` is written at install and
`UpdateOutcome.tracksPatchOnly` stops the check calling such a folder up to date:

```
  before        check asks page 222 (the patch) → nothing new → "Up to date"   ✗ lie
  today         check asks page 222 (the patch) → nothing new → "Only the
                                                   patch is tracked here"      ~ honest
  this plan     check asks 222 AND 111           → "111 has v4"                ✓ useful
```

**Nothing here helps a folder that is already mixed.** The evidence is gone and
cannot be recovered — no scan distinguishes the third box above from an ordinary
mod. The one thing an existing mixed folder ever gets is [§3](#3-naming-the-second-mod)'s
manual "add the other mod", which the user has to reach for themselves because
the app has no way to know it should ask. Said here rather than designed around.

---

## 1. The shape of the data

### What it looks like on disk

```
  <mod>/.zzz-mod-manager/metadata.json

  {
    "schema_version": 2,
    "origin": {
      "provenance": "downloaded",
      "source": "gamebanana",
      "mod_id": 222,                    ← the patch. what WE installed.
      "mod_id_confidence": "exact",
      "file_id": 1491924,
      "version_confidence": "exact",
      "ingest": { "mode": "separate", "folders": ["EllenBikini"],
                  "patch_shaped": true },

      "companions": [                   ← NEW. everything else in this folder.
        { "role": "base",
          "mod_id": 111,
          "mod_id_confidence": "user",  ← only the user can supply it
          "file_id": 1490003,
          "version_label": "Main file",
          "version_confidence": "user" }
      ]
    }
  }
```

### Why the list goes *inside* `origin` and not beside it

Two shapes were considered. The grid is the whole argument:

| | `origin` becomes an array | `origin` keeps its shape, gains `companions` |
|---|---|---|
| Older build reads it | `fromJson` gets a `List`, returns null → **mod silently untracked** | unknown key → `extra` → round-tripped verbatim |
| `ModInfo.origin` | type changes; every reader in `lib/` at once | unchanged |
| Rescan guard (`mod_group_diff`) | new comparison to hand-write | rides `ModOrigin.==`, which already exists for exactly this |
| `knownKeys` / `replaceUserFields` | new machine-owned field to carry | none — `origin` is already a known key |
| Schema bump | mandatory (meaning changed) | not required (purely additive) |

The right column wins on every row. **`companions` is a key inside the `origin`
object.**

### What a companion is *not*

A companion is a statement about **a different download that is also in this
folder**. It is not a statement about this folder's ingest. Six `ModOrigin` fields
are therefore wrong on it, and each is wrong for its own reason:

```
  ModOrigin field         why a companion must not carry it
  ─────────────────────   ────────────────────────────────────────────────────
  provenance              describes how WE put this folder here. we didn't.
  ingest                  there was no ingest — the user dragged files in.
  installed_at            the folder has one install date, not two.
  installed_at_is_proxy   ditto.
  source                  one folder, one service. inherited from the parent.
  tracking                "not from GameBanana / it's my own" is about the
                          FOLDER. a per-companion mute is a control nobody
                          asked for, and two mute switches on one card is a
                          support question waiting to happen.
```

What is left is a **remote identity plus what we know about which file of it**:

```
  ModCompanion
  ├─ role                 base | patch
  ├─ mod_id               required. a companion with no identity is nothing.
  ├─ mod_id_confidence    user, normally. exact only if WE wrote the bytes (§4).
  ├─ file_id
  ├─ version
  ├─ version_label
  ├─ version_confidence
  ├─ archive_md5          only when we wrote it (§4). null otherwise.
  ├─ baseline_remote_date "I don't know which file" applies per identity.
  ├─ remote_missing       a companion's page can go private too.
  └─ updates_dismissed_until   dismissing the base's update must not
                               silence the patch's, and vice versa.
```

That is `ModOrigin` minus six fields — close enough that extracting a shared
"remote identity" base type is tempting. **Do not bundle that refactor**: it
touches every reader of `ModOrigin` in `lib/`, and this work already touches
enough of them. See [§7](#7-open-questions) Q1.

### Parse rules, inherited rather than invented

The three load-bearing rules in `docs/metadata-schema.md` apply unchanged and
each has a specific consequence here:

```
  never throws, for any input      →  a bad companion entry is DROPPED,
                                      the rest of the list survives, and the
                                      primary origin is untouched.
                                      (a sidecar travels; one can arrive from
                                      a stranger holding "companions": "yes")

  unrecognised value degrades       →  an unknown `role` reads as `base`?  NO.
  DOWNWARD, never upward               it reads as an unusable entry and is
                                      dropped. role decides which page the
                                      check treats as the folder's real
                                      subject; guessing it is worse than
                                      losing the entry.

  omit anything equal to its        →  no "companions": [] in any sidecar.
  read-side default                    absence is the common case forever.
```

Two more that are specific to a list:

- **A companion carries no `companions` of its own.** Nesting is dropped on read.
  One level, no tree.
- **Duplicate `mod_id` collapses.** A companion naming the same mod as the
  primary is not a second thing in the folder; it is the same thing said twice,
  and keeping it would make the check ask one page twice and report two verdicts
  for one mod.

---

## 2. Every reader this touches

Ordered by how easy each is to get wrong, not by file path.

```
                          ┌─────────────────────────┐
                          │   ModOrigin.companions  │
                          └────────────┬────────────┘
        ┌──────────────┬───────────────┼──────────────┬───────────────┐
        ▼              ▼               ▼              ▼               ▼
   toJson/fromJson   == / hashCode   checkForUpdate  InstalledMods   the dialogs
        │              │               │              Index           │
        │              │               ▼              │               ▼
        │              │          planBulkUpdate      │          resolve, update,
        │              │          runBulkUpdate       │          apply
        │              ▼               ▼              ▼
        │        mod_group_diff   modSlotStatus   marketplace badge
        │        (rides == )      modNeedsAttention
        ▼
   boundTo / updatedTo
```

### 2a. The three that are nearly free

| Reader | Change |
|---|---|
| `ModOrigin.==` / `hashCode` | Add the list, compared **order-independently** (`Object.hashAllUnordered`). n ≤ 3, so the O(n²) equality is free. **This one is load-bearing**: it is the whole reason a resolve write reaches the card. It is the exact bug value equality was added for — a mod resolved through the dialog was written correctly, re-read correctly, judged unchanged, and went on rendering its old badge. |
| `mod_group_diff.dart` | **None.** It collapsed to `before != after`, so it is covered the day the field is added. |
| `metadata-schema.md` `knownKeys` | **None.** `origin` is already a known key. |

### 2b. `boundTo` and `updatedTo` — what survives what

```
  boundTo   ("no, this folder is mod 333")
  ──────────────────────────────────────────────────────────────────
  companions SURVIVE.  the folder's CONTENTS did not change — only our
  belief about which page the primary came from. a companion is still a
  true statement about what else is in there.

  EXCEPT: rebinding the primary onto a companion's own mod_id collapses
  them. otherwise the folder claims mod 111 twice, once as each role.

  updatedTo   (an update was written over this folder)
  ──────────────────────────────────────────────────────────────────
  companions SURVIVE.  applying-updates.md §1: overwrite copies over and
  touches nothing else, so the companion's files are still there.

  they may now be INERT — overwriting the folder with the base mod's new
  archive can replace the patch's .ini, which §5 already names as an
  accepted loss paid for by the snapshot. "installed but possibly no
  longer applied" is not "not installed", and clearing the entry would
  lose the only record of what the snapshot holds.
```

### 2c. `checkForUpdate` — one folder, two questions, still one answer

The card has **one** slot. `modUpdateChecksProvider` is `Map<String, UpdateCheck>`
keyed by folder. The toolbar counts one number. So the check must fold, not fan out.

```
  today                          with companions
  ─────────────────              ────────────────────────────────────────

  origin ──► checkForUpdate      origin      ─┐
                  │              companion[0] ─┼─► checkForUpdate
                  ▼              companion[1] ─┘         │
             UpdateCheck                                 ▼
                                                    UpdateCheck
                                                    ├─ outcome   ← the WINNER's
                                                    ├─ candidate, newerFiles,
                                                    │  installedFile, evidence
                                                    │            ← the WINNER's
                                                    ├─ subjectModId
                                                    │  └─ null = the primary
                                                    └─ companions: [ … ]
                                                       └─ every identity's own
                                                          verdict, for the dialog
```

**The top-level fields describe whichever identity won the fold, not always the
primary**, and that is load-bearing rather than a convenience. Every existing
consumer reads them: the dialog renders `candidate` and `newerFiles`, and
`dismissableUpTo` is computed from `newerFiles`. An outcome folded from the
companion sitting on top of the *primary's* file list would render a verdict
about mod A illustrated with mod B's files — and, worse, "ignore this update"
would write a dismissal cutoff derived from the wrong mod's dates. `subjectModId`
is what lets the UI name the mod the verdict is about.

Precedence for the fold is the file's existing asymmetry, unchanged: a false "up
to date" hides an update silently and the feature fails; a false "possibly
outdated" costs one look. So **the most actionable verdict across identities
wins**, and `upToDate` is only reported when every identity says it. Three rules
fall out of that and each needs stating, because none is obvious:

- **A live finding beats a dismissed stronger one.** Ranking by outcome alone
  picks the primary's `updateAvailable`, then reports `hasUpdate: false` — a
  folder with a real update on its other identity rendering as if it had none.
  A dismissal is per identity (it is a statement about one page's releases), so
  the fold considers undismissed findings first.
- **A companion we never fetched a record for is `indeterminate`, not
  `upToDate`.** Silence is not evidence — the same rule the file already applies
  to a response that carried no file list. Claiming clean because we only looked
  at half the folder is precisely the false clean this work exists to remove.
- **`tracking: "off"` short-circuits before any of it.** No companion is
  consulted at all, which is the folder-level switch doing its job.

### Every caller must supply the companion records

The third rule above has teeth: a caller that forgets downgrades every mixed
folder to `indeterminate`. That is the safe direction, and it is still wrong on
the screen it would hit hardest.

```
  caller                            today            needs
  ────────────────────────────────  ──────────────   ─────────────────────────
  bulk_update_check.dart:234,:282   Mod/Multi batch  fold once per folder,
                                                     after ALL records land
                                                     (§2d)
  mod_update_dialog.dart:258        one modProfile   fetch the companion's
                                    for the primary  profile too — one extra
                                                     request on a screen the
                                                     user deliberately opened
```

The one branch that changes meaning:

```dart
// today
if (check.outcome == upToDate && (origin?.ingest?.patchShaped ?? false))
  return check.withOutcome(tracksPatchOnly);

// with companions — the handover point between the shipped half and this plan
if (check.outcome == upToDate &&
    (origin?.ingest?.patchShaped ?? false) &&
    !origin!.hasCompanionOfRole(base))          // ← the new clause
  return check.withOutcome(tracksPatchOnly);
```

`tracksPatchOnly` **does not go away**. It stays as the verdict for a patch-shaped
folder nobody has named the base mod for, which is every such folder until the
user acts. Naming the base is what retires it, per folder.

### 2d. `planBulkUpdateCheck` / `runBulkUpdateCheck` — the real cost

This is the most invasive change in the plan and it is not obvious from the
schema.

```
  today                                    needed
  ──────────────────────────────────────   ────────────────────────────────────
  byModId: { 222: [EllenBikini] }          byModId: { 222: [EllenBikini],
                                                      111: [EllenBikini] }
                                                            ▲
                                                            same folder,
                                                            twice

  fold as each record arrives:             CANNOT fold on arrival — 111 and 222
    for record in fetched:                 may land in different batches, and
      checks[mod.id] = check(record)       folding twice overwrites the first
                                           verdict with the second.

                                           collect all records, THEN fold once
                                           per folder across its identities.
```

Two consequences to decide rather than discover:

- **`checkableCount` counts folders today.** With a folder under two ids it
  either double-counts (the toolbar promises more work than there is) or needs a
  distinct-folder count while the *request* count is per id. See [§7](#7-open-questions) Q2.
- **Phase two (`Mod/<id>/Updates`) is per flagged mod id.** A folder flagged on
  its companion pulls the companion's feed. That is correct and costs one more
  request per mixed folder that flagged — bounded by how many mixed folders exist,
  which is small.

### 2e. `InstalledModsIndex` — this one is a **gain**

```
  page 111 in the marketplace, today:      with companions:

  ┌────────────────────┐                   ┌────────────────────┐
  │  Ellen Bikini      │                   │  Ellen Bikini      │
  │                    │                   │  [ In library ]    │  ← correct
  │  (no badge)        │                   │                    │
  └────────────────────┘                   └────────────────────┘
   ✗ its files ARE in                       ✓ EllenBikini/ holds it
     EllenBikini/
```

`fromMods` indexes companion `mod_id` and `file_id` into `_byModId` / `_byFileId`
alongside the primary's. The `tracking: "off"` exclusion applies at the folder
level — one switch, the whole folder — which is [§1](#what-a-companion-is-not)'s
reason for keeping `tracking` off the companion.

`installsOfMod` already returns *all* matching folders, so nothing about its
contract changes.

### 2f. `update_layout.dart` — no change, but know why

An update to a **companion** has no recorded ingest at all, so the replay hits its
"nothing recorded" row:

```
  Recorded    Archive        Result
  ─────────   ───────────    ────────────────────────────────
  nothing     one folder     that folder → the mod folder root
  nothing     several        stop: layoutUnknown
```

That is correct and needs no code. The doc already calls the unrecorded case the
common one rather than the exception.

---

## 3. Naming the second mod

The identity can only come from the user. They dragged those files in by hand,
possibly from a source the app never saw.

### Where it goes in the existing dialog

The resolve dialog is **already at its height budget**. `docs/origin-tracking.md`
§5 records the constraint as an outright rule: the two escape hatches must stay
one click from the bottom, and the file picker was cut from 280px to 230px to pay
for the identity card's two "currently tracked" lines. A second identity card
inline spends that budget again and pushes the hatches below the fold — which the
doc calls the one thing this dialog must never do.

So the second identity is a **pushed step, not an inline section**:

```
  ┌─ Resolve: EllenBikini ────────────────────────────┐
  │                                                   │
  │  ┌─ Tracked ─────────────────────  [↗] [Change]┐  │
  │  │  Ellen Bikini — No Blur                     │  │   unchanged
  │  │  🔗 you confirmed this                      │  │
  │  │  📄 Main file — downloaded by this app      │  │
  │  └─────────────────────────────────────────────┘  │
  │                                                   │
  │  Which file                                       │
  │  ┌─────────────────────────────────────────────┐  │   unchanged
  │  │ ⦿ NoBlur_v2.zip      [on record]            │  │
  │  │ ○ NoBlur_v1.zip      [archived]             │  │
  │  └─────────────────────────────────────────────┘  │
  │                                                   │
  │  ☐ Also fill in what's missing from the mod page  │   unchanged
  │  ───────────────────────────────────────────────  │
  │  ⑂  This folder holds a patch                  ›  │  ← NEW. one row.
  │     Name the mod it patches                       │
  │  ───────────────────────────────────────────────  │
  │  ？ I don't know which file                       │   unchanged,
  │  🔕 Not from GameBanana / it's my own             │   still one click
  │                                            [Save] │   from the bottom
  └───────────────────────────────────────────────────┘
                          │
                          │ pushes
                          ▼
  ┌─ The mod this patches ────────────────────────────┐
  │                                                   │
  │  🔍 [ ellen bikini                          ] →   │   the same search
  │                                                   │   UI as the primary
  │  ┌─────────────────────────────────────────────┐  │   identity step
  │  │ [img] Ellen Bikini                          │  │
  │  │       by Author · Ellen                     │  │
  │  ├─────────────────────────────────────────────┤  │
  │  │ [img] Ellen Bikini Recolour                 │  │
  │  └─────────────────────────────────────────────┘  │
  │                                                   │
  │  (after picking: the same file list, for THAT mod)│
  │                                                   │
  │  ？ I don't know which file                       │   → baseline, per
  │  🗑  Remove — this folder is one mod after all    │     companion
  │                                    [Cancel] [Add] │
  └───────────────────────────────────────────────────┘
```

The new row is **only shown when there is something to say**: the folder is
patch-shaped, or a companion already exists (then it reads as the companion's
name and reopens for editing).

### What it costs to build

`_identitySearch()` and `_fileSection()` are private methods on
`_ResolveOriginDialogState`, closed over `_modId`, `_profile`, `_selectedFile`,
`_installedAt` and `widget.mod`. The pushed step needs both, against a *different*
mod id, writing to a *different* place.

```
  extract, in this order:

    IdentitySearchPanel   ← search box, results list, pasted-url handling
    FileChoicePanel       ← rankResolveCandidates + the rows + the chips

  both already take everything they need as data; what binds them to the
  dialog is only the setState target. parameterise that and both steps use
  the same two widgets, which is also the only way the two steps cannot
  drift in what a chip means.
```

Not optional, and not a nice-to-have: two hand-written copies of the file picker
is the shape in which "on record" and "our best guess" start meaning different
things on two screens.

### What each answer writes

The rules are `services/origin_resolution.dart`'s, applied to a companion. Same
table, one new column:

| Answer | Writes on the primary (today) | Writes on a companion |
|---|---|---|
| Pick a mod page | `mod_id` at **`user`** | `mod_id` at **`user`**, `role: base` |
| Pick a file | `file_id`, `version`, `version_label` at `user` — `exact` on a banked-hash row | same, but **never `exact`**: there is no banked hash for a download we did not perform |
| "I don't know which" | `assumed_latest` + `baseline_remote_date` | same, on that companion |
| "Not from GameBanana" | `tracking: "off"` on the block | **not offered** — one switch per folder |
| "Remove" | — | drops the entry. The folder is one mod after all. |

Two rules carry over verbatim and one is new:

- **A suggestion is never preselected.** Applies to the companion search results
  exactly as it does to the primary's.
- **Nothing raises anything to `exact` except a checksum match.** A companion the
  user named is `user`, permanently, until [§4](#4-not-making-mixed-folders-in-the-first-place)
  writes one itself.
- **New: `role` is not a question.** The dialog knows it. Reached from a
  patch-shaped folder, the primary is the patch and the companion is the `base`.
  Asking the user to classify their own folder is a quiz whose answer we have.

---

## 4. Not making mixed folders in the first place

Today both install paths **refuse** a name collision, which is why every mixed
folder in existence was assembled by hand in a file manager:

```
  mod_manager_service.dart:517   importMods         if (exists) continue;   skip
  mod_manager_service.dart:626   importCombinedMod  if (exists) return ();  abort
```

### First, a correction to the obvious sketch

The tempting design is a split **Download** button on the mod page:

```
   [ Download ▾ ]
        ├─ Install as a new mod
        └─ Apply as a patch to…  ▸ [ pick a mod ]     ✗ CANNOT WORK
```

**It cannot be offered there.** Patch detection needs the extracted files —
`services/patch_detection.dart` compares what the `.ini` files reference against
what the folder holds. Nothing on a mod page says "this is a patch": the measured
rule that works is *"the download brought no content at all"*, and the download
has not happened yet. Offering the choice before the download means asking the
user a question the app is about to be able to answer itself.

So the offer lives **after extraction, inside the install flow**, beside the two
modals already there.

### Where the new step sits

```
  installArchiveFlow, today                installArchiveFlow, proposed
  ─────────────────────────────────────    ────────────────────────────────────
  1  extract to temp                       1  extract to temp
  2  ⟦ duplicate-archive prompt ⟧          2  ⟦ duplicate-archive prompt ⟧
       "byte-identical to X.                   unchanged — it is about the
        install anyway?"                       ARCHIVE, before anything else
                                               about the contents is known
  3  ⟦ multi-root folder picker ⟧          3  ⟦ multi-root folder picker ⟧
       "which folders, separate                unchanged
        or combined?"
                                           4  patch scan  ← MOVED. runs on the
  4  import (copy into modsPath)               TEMP folders, not the installed
                                               ones. this move is the whole
                                               enabler: the answer already
                                               exists before the copy — but it
                                               must be SCOPED by step 3, and
                                               that is not free. see below.

                                           5  ⟦ destination prompt ⟧  ← NEW,
                                               only when 4 says patch-shaped

  5  patch scan on the INSTALLED folders   6  import — one of two paths (below)

  6  ⚠ pinned warning + write              7  ⚠ warning / write, per branch
     ingest.patch_shaped
```

### Step 4 is scoped by the picker, and moving it is not free

**Patch-shape is a property of a resulting *mod*, not of a folder.** The
multi-root picker is what decides what the resulting mods are, so the scan has to
run after it and in the shape it chose:

```
  combine = false          each selected folder becomes its own mod
                           → assess each independently
                           → one prompt listing the patch-shaped ones,
                             NOT one dialog per folder

  combine = true           the N folders become ONE mod
                           → assess the UNION, once
                           → one prompt, or none
```

Today's post-import scan gets this right **for free** and the move throws that
away. `modsThatLookLikePatches` runs on `importedMods`, which for a combined
install is the single merged folder:

```
  archive                 picked as       today (post-import)  naive per-folder
  ────────────────────    ───────────     ───────────────────  ────────────────
  Body/                   combine → one   ONE mod, and it      two temp dirs:
    ├─ body.ini             mod           brought content:     Body/ → refs
    └─ body.dds     ← ships               presentResources 1     body.dds,
  Wings/                                  → not a patch  ✓       HAS it → ok
    └─ wings.ini    ← ships nothing                            Wings/ → refs
       refs wings.dds                                            wings.dds,
                                                                 has none
                                                                 → PATCH  ✗
```

A false positive on an ordinary mod, firing the new prompt. The rule is *"the
download brought no content at all"* and the download is the **mod**, not one of
its folders.

**The union must also be taken under the subfolder prefixes the install will
create**, not raw. References resolve relative to their own `.ini`
(`ini_resources.dart` `_resolveAgainst`), so the two differ whenever one folder
carries the `.ini` and another carries the file:

```
  Patch/  patch.ini  refs body.dds, ships nothing
  Extras/ body.dds   (no .ini)

  raw union        refs {body.dds}, files {body.dds}      → satisfied → not
                                                            a patch    ✗
  prefixed union   refs {patch/body.dds},                 → missing,
                   files {extras/body.dds}                  0 present
                                                          → PATCH      ✓
                                                            (post-import agrees)
```

No new machinery. `FolderContents.underPrefix()` and `.merge()` already exist for
exactly this, and `update_apply/update_applier.dart:98` already assembles an
incoming archive as it *will* land before writing it:

```dart
incoming = incoming.merge(contents.underPrefix(mapping.targetSubPath));
```

The pre-import scan is that same line with the subfolder names taken from
`ImportPlan` instead of from `ingest`.

### The destination prompt, and the thing it must not conflate

The user's constraint, and it is the one that shapes this: *some patches go well
beyond "changes a small thing"*. So "where do the files go" and "what does this
patch belong to" are **two questions**, not one:

```
                    patch detected in the extracted folder
                                    │
        ┌───────────────────────────┴───────────────────────────┐
        ▼                                                       ▼
  WHERE DO THE FILES GO?                          WHAT MOD DOES THIS PATCH?
  ──────────────────────                          ─────────────────────────
  ⦿ Install as a new mod        ← DEFAULT         [ pick from library ]
  ○ Apply into an existing        always            or  ○ I don't know
    mod's folder ▸ [ pick ]

        │                                                       │
        │  if "apply into <mod>"  ─────────────────────────────► answered
        │                                          for free: that folder's
        │                                          primary origin IS the base
        ▼
  if "new mod": the second question is still worth asking, and
  its answer is written as a companion (§3).
```

That orthogonality is the point. A 400 MB "patch" that also reships the whole
body mesh is a mod the user wants in its own folder **and** a thing that patches
another mod. Forcing one answer to cover both is what makes option 3 look like it
excludes option 2. It doesn't; it *feeds* it.

### The two import branches

```
  branch A — "install as a new mod"
  ─────────────────────────────────────────────────────────────────────
  importMods / importCombinedMod, exactly as today.
  plus: ingest.patch_shaped = true      (as today)
  plus: companions += { role: base, mod_id: <the answer> }   if given
  → no pinned warning when the base was named. the warning exists to
    tell the user something is missing; it isn't.

  branch B — "apply into <existing mod>'s folder"
  ─────────────────────────────────────────────────────────────────────
  NOT an install. This writes over a live mod folder, which makes it an
  UPDATE-shaped operation and it must obey update rules:

     ⚠ deactivate → SNAPSHOT → overwrite-copy → reactivate
                    ▲
                    └── unconditional. applying-updates.md §5: if the
                        snapshot cannot be taken, NOTHING is written.
                        the argument is identical — this destroys the
                        user's folder contents on a wrong answer, and
                        the recourse has to exist before the write.

  → reuse services/update_apply/update_applier.dart, NOT importMods.
  → the orphaned-.ini rule (§3 of that doc) applies: a patch .ini shares
    the mod's filename and is overwritten rather than orphaned, so the
    prompt is rare here — but the rule still runs, because a patch that
    renames its .ini would leave two live ones.
  → writes on the TARGET folder's sidecar:
        companions += { role: patch, mod_id: <the patch>,
                        mod_id_confidence: EXACT,     ← we downloaded it
                        file_id, version, archive_md5 }
    this is the one path that writes a companion at `exact`.
```

**Branch B is mutually exclusive with the multi-root "combine" option.** Merging
three extracted folders into one *new* mod and writing them into an *existing*
mod are different destinations, so the combine radio is not offered in branch B.
**It is the only restriction in this plan.** Everything else the picker allows
stays allowed — it exists *because* archives are laid out badly, and taking
options away when the archive is worse is backwards.

### Branch B: the two shapes rarely line up

The patch and the mod it patches are two different downloads by two different
authors, and nothing makes their layouts agree. This is the part of branch B that
decides whether it writes a working folder or a dead `.ini`.

**First: the wrapper is an extraction artifact, not part of the mod.**
`ArchiveService._prepareDirectoriesForImport` (`archive_service.dart:370`) wraps
a rootless archive — the common patch shape — in a folder named after the
*archive*:

```
  patch archive                    after extraction
  ─────────────                    ────────────────
  ellen.ini    (loose at root)  →  Ellen No Blur v2/     ← wrapper
                                      └─ ellen.ini
```

For branch A that wrapper is exactly right: it becomes the new mod folder's name.
For branch B it must be **stripped**, and copying it instead is silently
destructive:

```
  copying the FOLDER                 copying its CONTENTS
  ──────────────────                 ────────────────────
  EllenBikini/                       EllenBikini/
  ├─ ellen.ini      (the base's)     ├─ ellen.ini   ← replaced. correct.
  ├─ body.dds                        ├─ body.dds
  ├─ face.dds                        └─ face.dds
  └─ Ellen No Blur v2/
     └─ ellen.ini   ← a SECOND LIVE .ini, and its `filename`
                      paths resolve beside ITSELF, so body.dds
                      is absent there
                      → the patch does not apply, AND duplicate
                        hotkeys — the §3 failure, caused by us
```

`.ini` files are read collectively across the folder and a `filename` is always
relative to the `.ini` that wrote it, so a nested patch is the worst of both
outcomes. **Rule: branch B copies a wrapper's contents, never the wrapper.**
Nothing downstream can currently tell a wrapper from a real folder — see
[§7](#7-open-questions) Q10.

**Second: where inside the target do the files go?** The mod's own shape decides,
and only one row of the grid is unambiguous:

```
  target's recorded ingest    incoming              destination
  ────────────────────────    ──────────────────    ───────────────────────────
  separate (one folder)       one wrapper/folder    mod folder root        ✓
  separate (one folder)       several folders       stop and ask           ⟦?⟧
  combined (N subfolders)     one wrapper/folder    WHICH subfolder?       ⟦?⟧
  combined (N subfolders)     several folders       name-match, else stop  ⟦?⟧
  nothing recorded            one wrapper/folder    root — but the mod's
                              (the pre-ingest        real .ini may live in
                               library, i.e. most    a subfolder           ⟦?⟧
                               of it)
```

The combined row is the one that bites, and it is your `previews/` case from the
other side: the base was installed as several folders, the patch is a single bare
`.ini`, and there is no name to match it against — the wrapper is called
`Ellen No Blur v2`, which matches nothing.

`planUpdateLayout` **cannot** answer this. Its combined replay matches recorded
folder names against incoming ones and returns `layoutChanged` when it can't.
That refusal is correct and must be kept: it is the same two-outcomes-and-no-third
discipline the update path already holds — *a set of mappings, or a stop-and-ask;
there is no third where it picks something plausible*. Guessing a subfolder here
writes a mod's `.ini` into the wrong half of itself.

So branch B needs its own resolver over the same discipline: replay where the
shape answers itself, and otherwise **show the target's subfolders and let the
user place it**, which is a question only they can answer and one they can answer
from looking at the folder. The snapshot is what makes a wrong answer survivable,
which is [§4](#the-two-import-branches)'s reason for routing through
`update_applier` in the first place.

### Where the destination picker's list comes from

**Folder name alone does not identify a destination.** One archive routinely
becomes several mods — two versions of a mod installed as separate mods is a
thing the picker deliberately allows, and `sibling_group` exists to record it —
so several library folders can be bound to the **same** `mod_id`:

```
  ┌─ Apply into which mod? ─────────────────────────┐
  │  ⦿ Install as a new mod            ← default    │
  │  ○ Apply into an existing mod's folder          │
  │      ┌─────────────────────────────────────┐    │
  │      │ Ellen v1   Ellen Bikini · Main file │    │  both bound to
  │      │ Ellen v2   Ellen Bikini · NSFW ver  │    │  mod_id 111
  │      └─────────────────────────────────────┘    │
  └─────────────────────────────────────────────────┘
                          ▲
                          └── folder name + the origin's `version_label`.
                              the label is the field that exists to stop two
                              variants of one release reading as two releases,
                              and this is exactly that case.
```

No preselection — guesses may inform, never drive. Ranking, and whether the list
is filtered at all, are open questions with a real candidate signal: see
[§7](#7-open-questions) Q7.

---

## 5. The status slot

The codebase resists a fourth slot state, and the resistance is specific rather
than general: `ModStatusSlot` renders **five visual treatments** from six enum
values already. What it cannot absorb is a sixth *visual*, or a stack.

### The proposal adds a state and no visual

```
  ModOriginStatus                    treatment            new?
  ──────────────────────────────     ─────────────────    ────
  none                               (nothing)
  untracked                          ● muted dot
  versionGuessed                     🕐 muted clock
  sourceGone                         🔗 muted broken link
  versionUnknown                     ❗ AMBER filled
  secondIdentityUnknown              ❗ AMBER filled   ←  NEW VALUE,
                                                          SAME PIXELS
  updateAvailable                    ⬆ BLUE filled
```

`secondIdentityUnknown` is the same amber pill with the same glyph and its own
tooltip. That is the honest cost: **one precedence decision, no new visual
language.** Three muted colours at 9–15px would already be indistinguishable, and
that is why the quiet states are told apart by shape — a rule this change does not
touch.

Why it is not folded into `versionUnknown` outright: the tooltip would then say
*"we don't know which file you have"*, which is false for a patch resolved at
`exact`. A shared treatment with a different sentence is exactly the pattern the
slot already uses for `updateAvailable` vs `possiblyOutdated` — keyed on the
outcome, not on a proxy for it.

### Where it goes in the order

```
  modOriginStatus(origin):

    tracking == off        → none            unchanged, wins over everything
    remote_missing         → sourceGone      unchanged
    !hasIdentity           → untracked       unchanged
    needsCompanion         → secondIdentityUnknown       ← NEW, HERE
    switch versionConfidence …               unchanged

  where  needsCompanion = ingest.patch_shaped && no companion with role=base
```

Above the version switch, because "which file of the patch is installed" is an
ambiguous question while the folder is known to be two things and only one is
named. Low-stakes ordering — **one pass through the resolve dialog answers both**,
since the pushed step is reached from the same screen.

### It joins "needs attention", and that is the point

```
  modNeedsAttention:  untracked ✓   versionUnknown ✓   secondIdentityUnknown ✓ NEW
                      versionGuessed ✗   sourceGone ✗   updateAvailable ✗
```

The filter's promise is that its count **can reach zero**. It does here: naming
the base mod clears the state, permanently, per folder. That is what disqualifies
`sourceGone` (a private page cannot be fixed) and what qualifies this one. It is
also the honest home for the prompt — a card asking "tell me what else is in
here" belongs in the list of things the user has not dealt with, not in a new
badge nobody has a mental model for.

---

## 6. The two items are one question asked twice

```
              what the app KNOWS         what the app WRITES
              ─────────────────────      ────────────────────────────
  item 1      two identities per         the user tells us, in the
  (§1–§3)     folder                     resolve dialog

  item 2      two identities per         WE tell us, at install time,
  (§4)        folder                     because we performed both writes
              ▲
              └── the same schema. the same readers. the same slot.
                  only the SOURCE of the second identity differs,
                  and that is one field: mod_id_confidence.
```

Building item 1 alone gives a schema with one writer (a dialog) and a permanent
`user` ceiling on the second identity. Building item 2 alone gives a write path
with nowhere to write. They ship together or the first one ships and the second
becomes a field addition.

**Recommended order within one piece of work:**

```
  1  ModCompanion + parse/serialise + == + tests          no UI, no readers
  2  checkForUpdate folds                                 pure, testable
  2b every caller supplies companion records —            NOT optional: without
     the bulk pass and the per-mod dialog                 it every mixed folder
                                                          reads `indeterminate`
  3  InstalledModsIndex + status slot + needs-attention   read-only surfaces
  4  extract IdentitySearchPanel / FileChoicePanel        refactor, no behaviour
  5  the pushed resolve step                              item 1 is now usable
  6  move the patch scan before the import, SCOPED by     NOT a no-op — §4.
     the picker (underPrefix/merge for combine)           gets it wrong and
                                                          ordinary combined
                                                          mods read as patches
  7  the destination prompt + branch A                    item 2, cheap half
  8  branch B on top of update_applier, incl. the         item 2, expensive
     wrapper rule and the placement resolver              half
```

Steps 1–5 are shippable on their own and leave the app strictly better. **Step 8
is the one that can be dropped** if it competes: without it, a patch still lands
in its own folder and the companion still gets named, which is [§0](#0-what-is-already-true)'s
"actually works" row. What is lost is only *not creating the second folder*.

---

## 7. Open questions

Each blocks something specific. Nothing below is rhetorical.

**Q1 — `ModCompanion`, or reuse `ModOrigin` with six fields documented as
ignored?**
Blocks step 1. The narrow type is recommended in [§1](#what-a-companion-is-not):
a type where half the fields must be ignored is one where something will read
them. Against it: the two types then share ten near-identical fields and their
parse rules, and a fix applied to one can miss the other. The third option — a
shared `RemoteIdentity` base — is right and is a refactor across every reader of
`ModOrigin`, which this work should not also be.

**Q2 — does the toolbar's "check N mods" count folders or identities?**
Blocks 2d. A mixed folder is one card and two requests. Counting identities makes
the button promise more work than the user can see; counting folders makes the
request count exceed the promise. Recommend: **count folders** (the user counts
cards), and leave `BulkUpdateCheckOutcome.requests` as the internal number it
already is.

**Q3 — does branch B run the full update machinery, snapshot included?**
Blocks step 8, and it is the difference between a week and a day. Recommended
**yes** in [§4](#the-two-import-branches), on `applying-updates.md` §5's own
argument. The consequence to accept with it: the stale-`.ini` prompt can now
appear during an *install*, which it never has.

**Q4 — one companion, or a list of N?**
The schema is a list either way. The question is the UI. Recommend: **schema
takes N, the dialog offers one.** A user stacking two patches on one mod is real
and the format should not need a bump for it; a resolve dialog for three
identities is a screen nobody has asked for.

**Q5 — the drag/drop import has no origin block to write into.**
A hand-dragged folder gets **no** `origin` at all (`importMods` records one only
when a seed was supplied), so today's `updateModOrigin` returns null and writes
nothing — meaning `patch_shaped` cannot be recorded on the path where mixed
folders are most likely to be made. Does a patch-shaped hand-import write a
sidecar it otherwise would not, breaking the don't-litter rule? There is
precedent: `tracking: "off"` already does exactly that, deliberately, for the
same reason — absence means "not looked at", which is not what is true here.
Recommend **yes**, and say so in `metadata-schema.md` beside the existing
exception. See also the finding in [§8](#8-a-gap-in-what-already-shipped).

**Q6 — what does the marketplace card say when a mod is only a companion?**
`InstalledModsIndex` will answer `hasMod(111) == true` with the folder named
`EllenBikini` — which is the patch's name, not 111's. The badge is correct; the
folder name in the detail view's "you have this as: …" line reads oddly.
Recommend: leave it. It is the truth, and inventing a second phrasing for it
costs more than it buys.

**Q7 — can the destination picker be ranked or filtered, and is the signal
real?**
A patch's `.ini` references files it does not ship — `body.dds`, `face.dds` —
which is precisely the fingerprint of the base mod's contents. A library folder
holding exactly those files is a strong candidate, with a stated reason
("references three files this mod has"), never preselected.
**This must be measured before it is built.** The corpus exists:
`test/patch_detection_corpus_test.dart` runs the real rule over extracted
archives when `ZZZ_PATCH_CORPUS` points at one, and the 29-archive measurement
behind the patch rule is the same population. Until it is measured the picker is
an unranked, searchable list of the library, which is a perfectly good first
version.
Filtering is the sharper half of the question and the answer is probably **no**:
narrowing to folders sharing the patch's own `mod_id` is right whenever the patch
page names what it patches and wrong whenever it doesn't, which is common — and a
filter that hides the correct answer is worse than a list that doesn't rank it.

**Q8 — does `role` need a third value?**
`base` and `patch` cover the two-download case. A folder holding two *independent*
mods hand-merged by the user is a different thing — `applying-updates.md` §3 names
it as the case the orphaned-`.ini` rule exists to protect. It wants
`role: separate` rather than being forced into `base`. Recommend deferring: the
unknown-role-is-dropped rule in [§1](#parse-rules-inherited-rather-than-invented)
makes adding it later safe, and nothing today produces one.

**Q9 — one destination per run, or several?**
A patch can genuinely apply to both `Ellen v1` and `Ellen v2`. Each is a live
folder needing its own snapshot, so "several" is N sequential update-shaped
writes rather than one. Against single-select: the archive is deleted after a
successful install (`_safeDeleteArchive`), so a second application means a second
download. Cheap mitigation either way — **keep the archive when the user chose
branch B**, the one flow where re-running is plausible. Recommend single-select
plus archive retention; revisit if anyone actually asks for both.

**Q10 — should extraction report that it wrapped a rootless archive?**
`_prepareDirectoriesForImport` invents a folder for a loose pile of files and
returns it indistinguishably from a folder the archive really had. Branch B needs
to know the difference ([§4](#branch-b-the-two-shapes-rarely-line-up)), and
nothing downstream can currently tell. One added field on
`ArchiveExtractionResult` — the alternative, re-deriving it by comparing the
folder name to the archive basename, is a guess that breaks the moment an author
names the folder after the archive.

---

## 8. A gap in what already shipped

Found while reading for this plan; **not part of it**, filed here so it is not
lost.

```
  installArchiveFlow (marketplace)          mods_screen (drag/drop + button)
  ────────────────────────────────          ────────────────────────────────
  patch scan                    ✓           patch scan                    ✓
  warning                       ✓           warning                       ✓
  warning is PINNED             ✓           warning is pinned             ✗
  writes ingest.patch_shaped    ✓           writes patch_shaped           ✗
                                                 mods_screen.dart:1652-1664
```

So the shipped half of this work — the pinned warning and the refusal to claim
"up to date" — covers the **marketplace path only**. The path where a user drags
a patch in by hand still warns for eight seconds and records nothing.

Half of the fix is a one-line `pinned: true`. The other half runs straight into
[Q5](#7-open-questions): on that path there is frequently no origin block to
amend. Both belong in `BUGS & TODO.md` as their own item rather than inside
either of the two this plan covers.

---

## 9. Explicitly out of scope

```
  ✗  folders that are ALREADY mixed
        the evidence is gone. no scan recovers it. the only route is the
        user opening the resolve dialog and naming the second mod
        themselves — and the app has no way to know it should ask.

  ✗  a bulk pass that proposes companions
        bulk resolution matches folder NAME to mod page, fuzzily. a folder
        name names one mod at most. there is nothing for it to match a
        second identity against.

  ✗  per-companion `tracking: "off"`
        one mute switch per folder. two on one card is a support question.

  ✗  automatic detection of which library mod a patch belongs to
        Q7 may make it a ranked SUGGESTION with a stated reason. it may
        never preselect, and it may never write without the user.

  ✗  extracting a shared RemoteIdentity base out of ModOrigin
        right, and not this work. see Q1.

  ✗  three or more identities in the resolve UI
        the schema carries N. see Q4.

  ✗  detecting a patch before it is downloaded
        impossible: the rule needs the extracted files. see §4.

  ✗  restricting what the multi-root picker allows
        REJECTED, not unbuilt. the obvious reflex when an archive is
        awkward — two versions of one mod, a patch beside a previews
        folder — is to narrow the options. wrong on three counts:
        the picker exists BECAUSE archives are laid out badly, so
        taking choices away when the archive is worse is backwards;
        "install both versions as separate mods" is a deliberate act
        the app already records (`sibling_group`); and nothing else in
        this codebase narrows a legitimate choice — it asks, or it
        stops and says why.
        The picker's answer SCOPES the patch question (§4) instead of
        being limited by it. The one real restriction is combine + branch
        B, which are different destinations rather than a judgement about
        the user.
```
