# Mod origin tracking

Reference for how the app works out **which remote mod and which file** a local mod
folder is, how sure it is of that, and what each level of certainty is allowed to
drive.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so.

> Scope: the meaning and the lifecycle of a mod's `origin` block — the confidence
> model, every route that writes one, the offline backfill, how an unknown origin is
> surfaced and resolved, and the read model built on top. The block's **on-disk
> shape** (every field, its type, and how it survives a save) is
> [`metadata-schema.md`](metadata-schema.md#the-origin-block). What an install fills
> in *besides* origin — description, gallery, tags, character — is
> [`metadata-autofill.md`](metadata-autofill.md). GameBanana's own protocol is
> [`gamebanana-api.md`](gamebanana-api.md).

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## 1. Two axes: confidence and provenance

**Confidence** is how sure we are *which remote file this is*. **Provenance** is
*where the folder came from*. They are separate axes, and a single enum named after a
source would mislabel the interesting case: a hand-imported archive whose md5 matches
the checksum the remote publishes is known exactly, despite never having been
downloaded by us.

Confidence tiers, strongest first:

| Tier | Means | Reached by |
|---|---|---|
| `exact` | We know the file | We downloaded it, or its archive hash matched a published checksum |
| `user` | The user told us | Confirming an identity or picking a file in the resolve dialog |
| `inferred` | Guessed from local data | A `source_url` parse, a name match |
| `assumed_latest` | "Don't know what I have, got it around then" | The resolve dialog's third answer, or the bulk action |
| `unknown` | Nothing on record | A manual import; the default |

Provenance values are `downloaded`, `imported_archive` and `imported_folder`.

Three rules follow from the split, and they govern everything below:

- **Only `exact` may drive an unattended overwrite** — on *both* axes, since knowing
  the mod but not the file is not enough to know what to replace it with. Anything
  weaker may badge, suggest and prompt. `inferred` in particular came from a
  free-form text field a human typed, so it must be confirmed once before any update
  acts on it.
- **Identity and version are separate unknowns.** "Which remote mod is this?" is
  often recoverable offline by parsing an existing `source_url`; "which file of it?"
  almost never is, because the archive is deleted after extraction. So they carry
  separate confidences (`mod_id_confidence`, `version_confidence`) and resolve
  independently.
- **"Origin unknown" is a permanent state, not a migration to be finished.** Legacy
  libraries, drag-dropped folders, mods from sites we don't browse: all of them are
  legitimately untracked. That is why the model gives it a first-class tier, the
  library card gives it a visible status ([§4](#4-the-status-slot-and-the-needs-attention-filter)),
  and resolution lives in the UI rather than in a one-time wizard.

---

## 2. Where an origin comes from

| Route | Writes | Confidence |
|---|---|---|
| **Marketplace download** | `source`, `mod_id`, `file_id`, `version`, `version_label`, `provenance: downloaded`, `archive_md5` | **`exact`** on both axes |
| **Imported archive** | `provenance: imported_archive`, `ingest`, `installed_at`, `archive_md5` | `unknown` on both |
| **Imported folder** | `provenance: imported_folder`, `ingest`, `installed_at` | `unknown` on both |
| **Offline backfill** ([§3](#3-the-offline-backfill)) | `source`, `mod_id`, `installed_at` | `inferred` identity, no version |
| **Resolve dialog** ([§5](#5-the-resolve-dialog)) | identity and/or version, or `tracking: "off"` | `user`, or `exact` on a hash match |

A download starts from a chosen row of a chosen mod's file list, so mod id, file id,
version and variant label are all known before the first byte. `exact` there is the
honest tier rather than an optimistic one: the user picked this file of this mod and
we fetched exactly that file id, with nothing inferred. Note the consequence —
`exact` is the one tier eligible for unattended auto-update, so in-app downloads are
what makes future auto-update possible at all.

Manual imports land at `unknown`, correctly. A dragged-in folder or a hand-supplied
archive carries no remote identity; its route to `exact` is an `archive_md5` match at
resolution time, not the install path.

**On any ingest we did not download ourselves, the inbound `origin` block is
dropped.** A mod folder passed around on Discord arrives carrying somebody else's
sidecar — a claim about a remote file we never made, on the field that gates
unattended updates. The user-facing fields are kept, since those travelling is the
whole point of a sidecar. This is enforced by construction rather than by a branch;
see [`metadata-schema.md`](metadata-schema.md#the-origin-block) for how.

**A marketplace install writes remote identity but *not* `source_url`**, which stays
a user-editable field. So a freshly downloaded mod has a `mod_id` and no url, while a
backfilled legacy mod has a url and a `mod_id` derived from it. Anything that wants
"a link to the mod page" builds it from `origin.mod_id`.

---

## 3. The offline backfill

Recovers, from data already on disk, what an existing mod's origin block *would* have
said. It runs lazily during a normal folder scan, on the branch of the migration hook
reached when a sidecar is present
([`metadata-schema.md`](metadata-schema.md#the-migration-hook)).

Split across two units so the decisions are testable with no filesystem:
`OriginBackfill` (`services/origin_backfill.dart` — pure, plus one injected
`InstallDateProbe`) and `utils/install_date_proxy.dart` (the one real filesystem
walk).

Two rules govern every decision:

- **It never displaces something better** — which is narrower than "it only fills
  absence", and the difference matters. A stored `mod_id` at `exact` or `user` is
  never overruled: those came from a download, a checksum match, or the user
  confirming it, none of which came from `source_url`. But an id at any weaker tier —
  including our own earlier backfill — **follows the url**, because that is where it
  came from. Otherwise a user who pasted the wrong mod page once is stuck with it:
  correcting the url would be a silent no-op. A `tracking: off` mod is skipped
  entirely — "not from GameBanana / it's my own" is a decision the user made, and a
  stale `source_url` is exactly why they might have made it.
- **Re-pointing at a different mod clears what described the old one.** `file_id`,
  `version`, `version_label` and `baseline_remote_date` mean something only relative
  to one mod page, so carrying them across a rebind would leave a block asserting
  that mod B ships file 555 of mod A. `remote_missing` resets for the same reason.
  `archive_md5` **survives**: it is a fact about the archive we extracted, not about
  which remote mod we currently believe it to be, so it can still be matched against
  the new mod's published checksums.
- **Nothing derivable means nothing written.** No empty sidecar, no "already swept"
  marker. Re-sniffing on the next scan costs one string parse, and it keeps the
  don't-litter rule ([`metadata-schema.md`](metadata-schema.md#dont-litter-empty-sidecars))
  intact.

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

**The install-date proxy, and how much to trust it.** Folder mtime and ctime are both
bumped by an `.ini` edit, so they skew *later* than the true install and would hide
updates; the oldest contained file is the earliest defensible answer. Our own
`.zzz-mod-manager/` is excluded — it was written by us, often long after the install,
and a folder holding nothing else would otherwise report our own write time as an
install date. How good the proxy is depends on how the mod got there: imported
*through the app* it is good (`_extractZip` writes fresh files and `_copyDirectory`
uses `File.copy`, neither carrying source timestamps over, so mtimes land near import
time), but hand-placed in `modsPath` (`cp -p`, the user's own 7-Zip run, a synced
folder) the author's build timestamps survive and it can read *years* early. That is
what `installed_at_is_proxy` is for; anything comparing dates must read it.

**Cost.** Measured on a real 23-mod / 748-file library: a first scan that backfills
all 23 mods takes **30 ms** end to end, a subsequent scan **7 ms** with zero writes
(the re-read below accounts for ~3 ms of the first figure). The folder walk alone is
~10 ms for the library, ~0.45 ms per mod. Crucially it is a **one-time cost per
mod**, not per scan — once a block is written the mod no longer qualifies and is
never walked again — and it runs only *after* an id has been recovered, so an
untracked mod costs one string parse and no I/O at all. The one exception is a folder
whose write *fails* (read-only, an odd network share), which would otherwise be
re-walked on every scan forever to re-attempt a write that cannot work;
`ModMetadataRepository` remembers those for the session, deliberately not across
restarts, since a folder that becomes writable should be retried.

**The write re-reads first.** The folder walk is an `await`, and a scan runs after
every toggle and rename, so a user confirming the edit dialog can land a `save()`
inside that window. The backfill therefore re-reads the sidecar immediately before
writing and re-checks its decision against what came back, contributing only the
machine-owned key to whatever is on disk *now*. Writing back the copy read before the
walk would quietly revert the user's description and tags.

**Known limit: sibling groups can't be recovered.** One archive can install as
several mod folders, and `origin.ingest.sibling_group` is what ties them together so
an update rewrites the group rather than one member. The backfill cannot reconstruct
it — nothing on disk records that two folders came from one archive. Two mods sharing
a `mod_id` after a backfill is therefore common and expected (observed twice in a
23-mod library), and must not be read as a group.

---

## 4. The status slot and the "needs attention" filter

`services/origin_status.dart` folds an `origin` block into the single thing a library
card may render. It is a pure function, and the "needs attention" filter in the mods
toolbar is built from the *same* function — so the badge and the filter cannot
disagree about which mods are which.

| Status | When | How it looks |
|---|---|---|
| **`versionUnknown`** | `mod_id` known, `version_confidence` is `unknown` | Amber, actionable. We can query the file list but can't judge what comes back, and one pass through the dialog fixes it. |
| **`versionGuessed`** | `mod_id` known, version at `assumed_latest` or `inferred` | A muted **clock**. A version is on record but it is a guess. |
| **`untracked`** | no `origin` block, or no `mod_id` | A muted **dot**. **Informational, never alarming** — most of a pre-origin library looks like this, and badging all of it loudly trains the user to stop seeing the slot. |
| **`none`** | version at `user` or `exact`, `tracking: "off"`, or `remote_missing` | Nothing at all. |

The rule the four states follow, in one line: **the slot speaks whenever tracking is
less than complete, and how loudly depends on how cheaply the user can act.** Amber
is the one that asks for something; the two muted states are statements of fact.

`versionGuessed` exists because `assumed_latest` and `user` used to render
identically, so a mod waved through by the bulk action was indistinguishable from one
whose file the user had actually picked — across a whole library, with no way to tell
but opening every dialog in turn. Two things about it:

- **It marks the weak state, not the strong one.** Marking "properly linked" instead
  was considered and rejected: those marks grow to cover every card as the library is
  resolved and then are permanent noise, where these *shrink as the user does the
  work*.
- **The two muted states differ by shape, not colour.** Two muted colours at 9–15px
  are indistinguishable, and stay so for anyone colourblind.

Three of those rows are decisions rather than mechanics:

- **`tracking: "off"` and `remote_missing` both silence the slot**, for different
  reasons. The first is the user's explicit "not from GameBanana / it's my own", and
  the promise attached to it is permanence. The second is different: the amber
  state's entire offer is *click to set the version*, which means reading a mod page
  that is private, trashed or withheld — offering an action that cannot complete is
  worse than staying quiet. Nothing writes `remote_missing` yet; when something does,
  it wants its own wording ("source no longer available") rather than one of the
  states here.
- **Only `unknown` is actionable.** `assumed_latest` is the user having already
  answered "I don't know which, I got it around then", and `inferred` is a guess we
  recorded and label as one. Re-ambering either would make the dialog impossible to
  finish.

The **filter** keeps `untracked` and `versionUnknown`, and this is the one place it
and the badge deliberately come apart:

- **Untracked mods are in**, though the badge keeps them quiet. The badge asks "how
  loudly should this card speak", the filter asks "what have I not dealt with", and
  the dialog acts on an untracked mod perfectly well. Excluding them would leave a
  legacy library with an empty filter and no way to enumerate the mods it exists to
  enumerate. (What they get no access to is *bulk* resolution — a separate rule,
  about fuzzy name matching being unsafe to rubber-stamp, see
  [§6](#6-assume-current-in-bulk).)
- **`versionGuessed` is out.** The bulk "assume current" action turns amber mods into
  guessed ones, and the count dropping is the entire visible proof that it worked.
  Were guessed mods still counted, the number would sit unchanged while the marks
  merely changed shape, which reads as a button that did nothing.

---

## 5. The resolve dialog

Everything the backfill cannot recover — and everything a manual import will keep
producing forever — is resolved *by the user*, through the per-mod resolve dialog
(`screens/dialogs/resolve_origin_dialog.dart`).

### What it says is already recorded

Before offering to change anything, the dialog states the current answer — two lines
inside the identity card, folded from the block by `summarizeOrigin()`
(`services/origin_summary.dart`), plus an **on record** chip on the file row the
block names.

It had none of this: the dialog read `mod_id` to know what to fetch and `installed_at`
to rank files, and never read `file_id`, `version_confidence` or
`baseline_remote_date` at all. So it could not state its own subject's answer, and a
resolved mod opened looking exactly like one never touched — with no row selected,
because the recorded file was not among the things that preselected.

Rules worth knowing:

- **Two lines, because the block has two independent axes.** Knowing the mod says
  nothing about knowing the file, and the same field reads very differently at
  different tiers: "you confirmed this" and "worked out from the source link — not
  confirmed" are the same `mod_id`.
- **The recorded file is preselected, and every selection says why.** The ambiguity
  worth removing is not *that* something is selected but *what put it there*, so "on
  record" and "our best guess" carry different chips. This is also why the recorded
  row is preselected ahead of a suggestion.
- **The recorded baseline is quoted, never a recomputed one.** `assumeCurrent` clamps
  the stored baseline to the mod's creation date, so it legitimately differs from the
  install date the dialog would derive today; quoting the derived one would state a
  cutoff that is not in force.
- **The summary disappears after "Change".** `mod_id` then names a different mod than
  the block does, and the recorded file, version and baseline all belong to the
  previous one.
- **The panel is inside the identity card, not beside it.** A second bordered box
  cost about forty pixels and pushed the escape hatches below the fold. The file
  picker's height came down from 280 to 230 to pay for the two lines — that list
  scrolls inside itself and so loses no content, while the hatches beneath it have
  nowhere to go.

### What it is allowed to write

The decisions live in `services/origin_resolution.dart`, pure and separate from the
dialog, because what is easy to get wrong is not the layout but *what each answer may
claim*.

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
  unattended updates. Harmless while nothing preselected the recorded row; the moment
  the dialog does, pressing Save is enough. The rule is one-directional: re-picking a
  row recorded at `inferred` still *raises* it to `user`, which is precisely the
  confirmation that tier waits for.
- **Confirming raises `inferred` to `user`, and nothing raises anything to `exact`
  except a checksum match** (or the no-demotion rule above). An `inferred` identity
  came from a free-form text field a human typed and could be a wrong paste; the user
  looking at the mod page and saying yes is exactly what `user` means. `exact` stays
  reserved for "we downloaded it" and "its bytes matched the published md5".
- **A suggestion is never preselected.** Candidate rows are ranked with a stated
  reason — banked hash, folder-name match, newest file that already existed at
  install time — and the reason is *shown*, because a ranking with no visible reason
  is indistinguishable from a ranking with a wrong one. Only two things start out
  selected: a hash match (which is exact) and a mod that publishes exactly one file
  (where there is nothing to guess between).
- **Both `_aFiles` and `_aArchivedFiles` are ranked.** An old install matches a
  superseded file far more often than the current one, and they arrive in the same
  response.
- **The date candidate is the newest file that already existed**, not the nearest in
  absolute terms: a file uploaded *after* the install cannot be the installed one.
- **The "assume current" baseline is clamped to the mod's own creation date.**
  `installed_at` is frequently a proxy taken from the oldest file in the folder, and
  for a library placed on disk by hand it can read *years* early, leaving a baseline
  from before the mod existed. Two qualifications, both easy to get wrong: the clamp
  is a **sanity floor, not a false-positive filter** — every published file is at or
  after its mod's creation date (checked: 32 files across the three captured
  profiles, none earlier), so it excludes only the file uploaded at creation — and
  the **bulk action does not apply it at all** ([§6](#6-assume-current-in-bulk)).
- **`tracking: "off"` is the one decision that writes a sidecar into a folder that
  had none**, deliberately breaking the don't-litter rule
  ([`metadata-schema.md`](metadata-schema.md#dont-litter-empty-sidecars)): absence
  means "not looked at yet", which is precisely what the user is switching off.
- **A pasted `/dl/` link cannot name a mod.** The dialog accepts a pasted URL: a
  **mod page** url resolves directly and skips the search, but a `/dl/<fileid>` link
  is a *file* id in a different id space and neither GameBanana API can say which mod
  owns it (probed exhaustively — see
  [`gamebanana-api.md`](gamebanana-api.md#a-file-id-cannot-be-turned-back-into-a-mod-id)).
  So the dialog says that instead of searching for the url as though it were a mod
  name.

---

## 6. "Assume current" in bulk

The same "I don't know which file — I got it around then" answer, applied to a whole
view in one press. `services/bulk_assume_current.dart` holds the decisions;
`screens/dialogs/assume_current_dialog.dart` is the confirmation and the write loop,
offered from the mods toolbar.

It makes **no requests at all**, which is what makes it worth having: it turns a
legacy library from something that can never report an update into something that
can, without a mod page, a version string, or a single answer from the user.

Four rules, in the order they matter:

- **It acts only on precise handles.** A mod with no `mod_id` is excluded, and the
  confirmation says how many were excluded for that reason. Identifying one means
  fuzzy-matching a folder name against a search, and a wrong match rubber-stamped in
  bulk lets a later "update" overwrite a mod with a different mod's files. That
  decision stays one-at-a-time and user-confirmed, forever.
- **Eligibility is re-checked against the block as freshly read from disk.**
  `bulkAssumeCurrent` is the transform handed to `updateOrigin`, and it returns null
  — abandoning that one mod — for anything that is no longer `versionUnknown`.
  Without it, a mod resolved *exactly* while the batch was running would be
  **downgraded** to a guess, silently, in a pass nobody is watching per-mod.
  A decline is reported as a decline, never as a failure. `updateOrigin` answers one
  bare `false` for "unwritable folder" and "the transform said no", so the loop wraps
  the transform to tell them apart — otherwise the guard's own correct behaviour
  surfaces as "those folders may be read-only". The reachable case needs no
  concurrency at all: press the button, then press it again before the rescan has
  refreshed the plan.
- **The confirmation states the size first.** The answer is usually either nothing or
  most of the library, and a user expecting the first who gets the second has had
  dozens of mods rewritten on a press. It also names what it is *not* touching
  (untracked mods, and mods with no derivable install date), so "12 mods" can't be
  mistaken for "all of them".
  That number is built from the list **the grid is rendering**, not from the wider
  list the toolbar's `!` toggle counts: combine the needs-attention filter with the
  search box and the two come apart, and a control that rewrites more mods than it is
  showing is the failure this placement exists to avoid. The two counts are therefore
  allowed to differ, and do so only when a second filter is active.
- **The baseline it writes is unclamped, and that is a deferred problem, not a solved
  one.** The per-mod dialog clamps `baseline_remote_date` to the mod's own
  `_tsDateAdded`, because a proxy install date taken from file timestamps can read
  years early for a hand-copied library. That clamp needs the mod page, which this
  action deliberately does not fetch — so **the update check must clamp when it
  compares**, which is the more correct place for it anyway: the clamp is a fact
  about the mod page, not about the sidecar. The confirmation states the risk in the
  meantime.

Nothing is probed for a missing install date, unlike the per-mod dialog. Every path
that can derive one from a folder walk has already run one — the offline backfill
probes every mod it gives an identity to, the ingest paths record an observed date,
and the resolve dialog probes before it binds — so a tracked mod still missing the
field is one whose walk found no files, and re-walking would return null again. Those
mods are listed as skipped rather than dropped quietly.

Measured against a mirror of a real library (17 mods with sidecars, 10 of them
eligible): **13 ms** for the whole pass including all 10 rewrites, and a re-run is a
4 ms no-op because `assumed_latest` is no longer eligible. There is no progress UI and
none is needed; the button simply disables while it runs.

---

## 7. The write path

`ModMetadataRepository.updateOrigin(modName, update)` **amends** the block, where
`recordOrigin` replaces it — so the archive hash, the ingest shape and the provenance
survive a decision that was only about identity and version.

`update` receives the block **freshly read from disk**, not the one the dialog was
opened with. That is not defensive habit: this dialog fetches a mod page and then
waits for a human, and a scan is kicked off after every toggle and rename, so the
sidecar genuinely can be rewritten inside that window — the same hazard the backfill
re-reads for. Returning **null from `update` abandons the write**, which is how a
decision that no longer makes sense against what came back (the folder was rebound to
a different mod meanwhile) declines to clobber it rather than attaching a `file_id`
to somebody else's mod.

A failed write is reported, not swallowed: nothing re-attempts it, and the scan-time
backfill is no substitute — it only ever recovers identity from a `source_url`, at a
weaker confidence than anything decided here.

---

## 8. Reading it back: the installed-mods index

`services/installed_mods_index.dart` is the read model built on top of all of the
above: given an already-scanned `List<ModInfo>`, it answers "is this remote mod /
file already in the library?". Pure — no filesystem, no network — so the questions
are unit-tested rather than clicked (`test/installed_mods_index_test.dart`).

It indexes three keys because they answer three different questions, and the
distinction is the locked decision about what may be claimed where:

| Key | Question | Where it surfaces |
|---|---|---|
| `origin.mod_id` | "this mod is in your library", possibly as a different file | badge on the marketplace card, notice on the detail view |
| `origin.file_id` | "this exact file is what you installed" | per-row marker in the file list |
| `origin.archive_md5` | "the archive you installed was byte-identical to this published file" | per-row marker, and the duplicate-import gate |

Three properties are load-bearing rather than incidental:

- **Every lookup returns *all* matching folders.** One GameBanana page becoming two
  mod folders is common, not an edge case — two occurrences in a real 23-mod library.
  Returning the first would under-report the library. A shared `mod_id` must not be
  read as a sibling *group* either (see
  [the backfill's known limit](#3-the-offline-backfill)).
- **`tracking: "off"` is excluded from the identity keys but not from the hash key.**
  That setting is the user saying "not from GameBanana / it's my own", and a stale
  `source_url` is exactly why they might have said it — so a leftover mod id must not
  badge somebody else's mod page. A hash is a fact about bytes on disk rather than a
  claim about which remote mod they are, so local dedup keeps working for a mod
  declared local.
- **A file-id match and a hash match stay distinguishable.** The first is a record of
  what we installed; the second says only that the bytes matched. They are worded
  differently in the UI for the reason `archive_md5` carries its own warning in
  [`metadata-schema.md`](metadata-schema.md#the-origin-block): a match is a matching
  key and never verification.

**What this can actually answer today, measured rather than assumed.** In a real
23-mod library, all 23 mods carry a `mod_id` (recovered offline from `source_url`)
and **none** carries a `file_id` or an `archive_md5` — the archive is deleted after
extraction, so nothing local survives to match a published checksum. So the mod-level
answer works for a legacy library from the first launch, while the file-level ones
are inert until mods are installed by a build that records them, or until the resolve
flow fills them in. Nothing may be built on file-level knowledge being present.
(Checked against the live API: those backfilled ids resolve to real mods whose names
match the local folders, and each publishes 3–4 files — which is the ambiguity the
file-level marker exists for.)
