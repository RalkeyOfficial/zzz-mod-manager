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
> [`metadata-autofill.md`](metadata-autofill.md). Writing a newer download over an
> installed mod — which is the other route that rewrites a block — is
> [`applying-updates.md`](applying-updates.md). GameBanana's own protocol is
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

- **Only `exact` names a file with certainty** — and on *both* axes, since knowing
  the mod but not the file is not enough to know what to replace it with. Anything
  weaker may badge, suggest and prompt, but its verdict is capped at "possibly
  outdated" ([`update-checks.md`](update-checks.md#the-cap-that-confidence-imposes)).
  `inferred` in particular came from a free-form text field a human typed, so it must
  be confirmed once before any update acts on it.
  **This is not a licence to overwrite unattended.** `exact` is a claim about
  *which remote file this is*; it says nothing about what the mod folder holds,
  which is where every hazard of applying an update actually lives. No update is
  applied without the user present, and that is refused rather than unbuilt —
  [`applying-updates.md` §7](applying-updates.md#automatic-updating--considered-and-refused).
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
| **Applied update** ([`applying-updates.md`](applying-updates.md)) | `source`, `mod_id`, `file_id`, `version`, `version_label`, `provenance: downloaded`, `archive_md5`, `ingest`, `installed_at` | **`exact`** on both axes |

A download starts from a chosen row of a chosen mod's file list, so mod id, file id,
version and variant label are all known before the first byte. `exact` there is the
honest tier rather than an optimistic one: the user picked this file of this mod and
we fetched exactly that file id, with nothing inferred. What it buys is an
**uncapped verdict** — "an update is available" rather than "possibly outdated" —
so a download is what lets the check speak plainly about that mod afterwards.

Manual imports land at `unknown`, correctly. A dragged-in folder or a hand-supplied
archive carries no remote identity; its route to `exact` is an `archive_md5` match at
resolution time, not the install path.

**On any ingest we did not download ourselves, the inbound `origin` block is
dropped.** A mod folder passed around on Discord arrives carrying somebody else's
sidecar — a claim about a remote file we never made, on the field that decides
which mod page this folder is checked against and which file the Update button
would write over it. The user-facing fields are kept, since those travelling is the
whole point of a sidecar. This is enforced by construction rather than by a branch;
see [`metadata-schema.md`](metadata-schema.md#the-origin-block) for how.

**An applied update rewrites the block rather than amending it**, through
`ModOrigin.updatedTo`. It reaches `exact` on the same grounds a download does — the
user picked this row of this mod's file list and the app wrote exactly that file id —
and `provenance` becomes `downloaded` even for a folder originally imported by hand,
since the bytes in it now came from an archive this app fetched and extracted. Three
fields are **cleared**, each of which would otherwise be a lie about the folder as it
now stands: `baseline_remote_date` (a date-based guess beside an exact file id),
`updates_dismissed_until` (the update was taken, and keeping it would silence the next
release too) and `remote_missing`. `tracking` survives untouched — it is the user's
own statement about whether the mod should be watched at all. `ingest` is refreshed
from the layout the update actually used, which is how a pre-`ingest` mod gains one.

**A marketplace install writes both `origin.mod_id` and `source_url`**, and they are
kept apart because they answer to different readers: `mod_id` is the machine handle
this whole document is about, while `source_url` is the link the user clicks. The url
is filled by the autofill rather than by the origin write, so it obeys the same rule
every user-editable field does — *fill absence, never displace*. A folder that arrived
carrying somebody's own sidecar keeps their url, which may point at a mirror, a
collection or the author's page.

It is written as `gameBananaModUrl(mod_id)` rather than copied from `_sProfileUrl`,
and that is load-bearing rather than tidy: the canonical form is what
`gameBananaModIdFromUrl` parses back, so the offline backfill (§3) reads the same id
the origin block already holds, sees them agree, and writes nothing. A url in any
other shape would invite the two to argue about which mod this is.

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
| `mod_id_confidence` | `inferred` | It came from a free-form text field, so it may be a wrong paste or a different mod. May badge and suggest, but caps every verdict at "possibly outdated", and must be confirmed once before any update acts on it. |
| `installed_at` | oldest file mtime | With `installed_at_is_proxy: true`. |
| `provenance` | `imported_folder` | Genuinely unknown for a legacy mod — it may have been downloaded by an old build, imported, or hand-copied. Takes the least-privileged of the three, matching `OriginProvenance.parse`'s own fallback. Nothing gates on it — the confidences do that — so understating it costs nothing. |
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
| **`sourceGone`** | `remote_missing` | A muted **broken link**. The mod page is private, trashed or withheld, and nothing more can be checked. |
| **`none`** | version at `user` or `exact`, or `tracking: "off"` | Nothing at all. |

The rule the five states follow, in one line: **the slot speaks whenever tracking is
less than complete, and how loudly depends on how cheaply the user can act.** Amber
is the one that asks for something; the three muted states are statements of fact.

`versionGuessed` exists because `assumed_latest` and `user` used to render
identically, so a mod waved through by the bulk action was indistinguishable from one
whose file the user had actually picked — across a whole library, with no way to tell
but opening every dialog in turn. Two things about it:

- **It marks the weak state, not the strong one.** Marking "properly linked" instead
  was considered and rejected: those marks grow to cover every card as the library is
  resolved and then are permanent noise, where these *shrink as the user does the
  work*.
- **The three muted states differ by shape, not colour.** Three muted colours at
  9–15px are indistinguishable, and stay so for anyone colourblind — so it is a dot,
  a clock face and a broken link.

Three of those rows are decisions rather than mechanics:

- **`tracking: "off"` silences the slot; `remote_missing` gets a state of its own.**
  The first is the user's explicit "not from GameBanana / it's my own", and the
  promise attached to it is permanence — it wins over everything, including a gone
  page, because a stale `source_url` is exactly why somebody might have set it. The
  second is not amber, for the reason amber cannot be honoured here: that state's
  entire offer is *click to set the version*, which means reading a mod page that is
  private, trashed or withheld. It is not silence either: silence is defensible only
  while nothing writes the flag, and the bulk resolution pass
  ([§7](#7-the-bulk-resolution-pass)) writes it — so a mod that quietly stops being
  watched with no wording anywhere is a hole rather than a tidy default.
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
- **`sourceGone` is out too, for a different reason again.** The filter's promise is
  that everything in it can be dealt with, and a private, trashed or withheld page
  cannot be. Counting it would leave a number that never reaches zero however much
  work the user does, which is the one thing that turns a count into noise. The mark
  on the card still says what happened, and the resolve dialog still rebinds the
  folder for anyone whose mod was reuploaded elsewhere.

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
  `exact ? exact : user` would demote it — and dropping out of `exact` turns every
  later verdict about that mod into a hedge. Harmless while nothing preselected the
  recorded row; the moment
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
- **The search box is seeded with the mod's name, with underscores read as
  spaces** (`searchSeedFromName`). The name came from a folder inside an archive,
  so it routinely arrives as `Ellen_Joe_Cheongsam`, which matches nothing —
  leaving the user to retype what the app already knew. It is a **first guess,
  not a parse**: hyphens, dots and version suffixes are how mod pages are
  genuinely titled ("Ellen - Swimsuit v1.2"), and stripping them would change the
  words rather than restore them. Normalised in the panel rather than by each
  caller, so both dialogs search the same thing.

---

## 6. "Assume current" in bulk

The same "I don't know which file — I got it around then" answer, applied to a whole
view in one press. `services/bulk_assume_current.dart` holds the decisions;
`screens/dialogs/assume_current_dialog.dart` is the confirmation and the write loop,
reached from the mods toolbar's **library menu**.

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
  showing is the failure this rule exists to avoid.
- **The action turns the needs-attention filter on before it asks, and puts it
  back if it doesn't go through.** The rule is that the user must have *seen* the
  set being rewritten. Enforcing that by hiding the button until the filter happens
  to be on is the rejected alternative: it puts a bulk write in a row that appears
  and disappears. The menu entry flips the filter itself, so the grid behind
  the confirmation shows exactly those mods — and restores it on cancel, since
  turning it on *for* a confirmation means declining the one thing a confirmation
  exists to allow would otherwise leave the grid filtered behind the user's back.
  Restoring means restoring: a filter the user had already set stays on.
  Flipping it cannot change *which* mods are eligible, only which are on screen —
  `planBulkAssumeCurrent` already keeps only `versionUnknown` mods and
  needs-attention drops exactly the ones it would have skipped — so the count in the
  menu is the count that gets written.
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

## 7. The bulk resolution pass

The whole-library update check's **results screen is also the resolution screen**.
`services/bulk_resolution.dart` holds the decisions;
`screens/dialogs/bulk_resolution_dialog.dart` is the surface.

**It has two doors, and the second one is the correction that mattered.** A check
opens it by itself when the pass turned up something to ask; and *Sort out mod
tracking…* in the toolbar's library menu opens it on demand, from the records the
last check left in session state — or by running that check first when there are
none. Built only on the first door it was a modal that could be seen once and never
again: cancelling it, or closing it by accident, meant waiting for the next check.
Keeping the records (`modUpdateRecordsProvider`, never persisted, exactly like the
verdicts beside them) is what makes reopening free.

**Both doors must say the same thing**, which took fixing twice over. The update
count is read library-wide (`libraryUpdateCountProvider`) rather than from whichever
door opened the screen: the check's own tally is library-wide while the toolbar's
count is view-scoped, so one sentence in one dialog would otherwise mean "in your
library" or "on this character tab" depending on where the user was standing. And
the "couldn't be checked" line is real on the menu door too — it was hardcoded to
zero there, which dropped the accounting the whole screen is careful about, on the
door the rebuild exists to provide. The two numbers come from different fields on
purpose: the check door quotes what the pass failed to reach, the menu door quotes
`BulkResolutionPlan.unreachable` — every tracked mod with no record in hand — and
they differ where a batch *answered* a mod as `sourceGone`, since that answer
arrives without a record.

**There is deliberately no separate migration screen.** The check already fetches
every tracked mod's record in one or two requests
([`update-checks.md` §5](update-checks.md#5-checking-the-whole-library)), and that
response carries exactly what resolution needs: the mod's name, its whole file list
— current *and* archived, which `Mod/Multi` folds into one key — and the explicit
upstream-gone flags. So this costs no request at all, and there is no screen left
behind to go stale the day the last legacy mod is resolved.

### What each row may be asked

One row per mod, and a row can carry more than one question — a legacy mod
backfilled from a pasted url has both an unconfirmed identity and no version, and
both answers land in a **single** `updateOrigin` call so it cannot half-write itself.

**Rows are grouped by the question they lead with, under a heading that says what
the group is for and why it matters** — the same `DialogSection` shape the update
flow's dialogs use. That is a correction, and the report behind it was that the
screen took minutes to understand: ungrouped, a row asking *is this the right mod?*
looked identical to one asking *which file?*, nothing said what the screen was for,
and the type was the 11–13px the rest of the app had already moved away from.

The grouping is by **leading** question rather than by question, and a mod appears
once. A section per question with mods appearing in two of them reads better on
paper and is worse in practice: on a legacy library nearly every row asks both, so
every name would be listed twice. Order is identity → file → gone → back, main work
first, so a library with one dead page and fifty to confirm does not open on the
dead one.

That is a **cascade, not four independent filters**, and the first version was not:
a mod recorded as gone whose page has come back *and* whose identity nobody
confirmed carries both questions, and it was listed under two headings with the
same two checkboxes. Nothing was written twice — both copies key off one mod id —
but "Save 1 mod" under two visible rows contradicts the invariant this layout is
built on. It is a reachable state rather than a contrived one: writing
`remote_missing` never touches `mod_id_confidence`, so a legacy mod's identity is
still `inferred` when its page reappears.

| Question | When | What ticking it writes |
|---|---|---|
| Confirm the identity | `mod_id_confidence` is weaker than `user` | `mod_id_confidence: user` |
| Record the file | `version_confidence` is `unknown` and the page publishes files | `file_id`, `version`, `version_label`, at the tier below |
| The page is gone | the record says private/trashed/withheld and the block does not | `remote_missing: true` |
| The page is back | the block says gone and the record answered normally | `remote_missing: false` |

A mod with **no `mod_id` gets no row at all**, and the screen says how many were
excluded for that reason. This is the same rule the bulk "assume current" action
follows and it is the oldest one here: identifying an untracked mod means
fuzzy-matching a folder name (`Ellen final FIXED v2`, `bikini`, `mod`) against a
search, and a wrong match rubber-stamped in bulk would later let an "update"
overwrite a mod with an unrelated mod's files. That decision stays one-at-a-time and
user-confirmed, in the per-mod dialog, forever.

### Nothing is written until Apply

Writing the safe inferences immediately and offering an undo afterwards was
considered and loses on two counts. The control that gets the user here says
*check for updates* and nothing about rewriting sidecars; and the placement rule
this codebase already follows
([§6](#6-assume-current-in-bulk)) is that a bulk rewrite acts only on a set the user
has seen. A pre-ticked row costs one glance and one press, where an undo costs
noticing a summary nobody asked for.

**Identity starts unticked; everything else starts ticked**, and the asymmetry is the
point. A file the pass inferred, and a page the API itself reports as gone, are
statements the app is making and can defend from the response in hand. An identity is
the one thing only the user can settle — `mod_id` came from a free-form url somebody
pasted — so pre-ticking it would turn the glance test into a rubber stamp. A
*confirm all* shortcut sits at the head of that section for a user who has read it,
and the intro at the top of the screen states the asymmetry rather than leaving it
to be inferred from which boxes happen to be ticked.

### What the pass may answer by itself

Only two things arrive pre-ticked, and the difference between them is the confidence
model in miniature:

- a **banked `archive_md5`** matching a published checksum, recorded at `exact` — a
  matching key, never an integrity claim; and
- the mod publishing **exactly one file, uploaded at or before the install**,
  recorded at **`inferred`**.

`inferred` rather than `user` because the user consented to a plan; they did not look
at a file list and recognise their download. It caps every verdict it produces at
"possibly outdated" and renders as a guess on the card, which is what makes offering
it safe.

The install-date test on the single-file case is easy to drop and is load-bearing: a
mod whose only file was published *after* the install is one whose original file has
been deleted outright, so the single thing on the page is provably **not** what the
user has. Recording it would invent a version and then report the mod as up to date.

A **folder-name match is not** in that list. It is a suggestion, it appears in the
picker with its reason attached, and a suggestion may never be what a pre-ticked box
writes — the same rule the per-mod dialog holds
([§5](#what-it-is-allowed-to-write)). Anything else ambiguous gets an inline picker
with nothing chosen; choosing from it is the user saying so, so *that* writes `user`.

### What confirms an identity, and what must not

The tick does. So does a file recorded at `user` or `exact`: picking a row off this
mod's own file list is a stronger statement that it is your mod than ticking a box
beside its name, and a banked checksum matching a file the page publishes is proof
rather than testimony.

**A file at `inferred` does not**, and the trap is worth stating plainly. The pass
pre-ticks its own single-file inference, so letting a file answer raise identity
would mean pressing Save on a row whose *"yes, this is the right mod page"* was
deliberately left unticked still lifting `mod_id_confidence` to `user` — laundering
a guess parsed out of a pasted url into the tier that lets an update overwrite
files, on the one screen where the user has visibly declined to confirm it. It is the "never-confirmed ≠ safe" rule
([§1](#1-two-axes-confidence-and-provenance)) inverted. Both axes stay guesses
instead, which caps that mod's verdict at *possibly outdated* — honest, and exactly
what two separate confidences are for.

A row with **nothing ticked writes nothing**: it is not in the map the dialog hands
over, and the transform declines it even if it were.

### Two things it re-checks, and one it does not

Every answer is applied to the block **as freshly read from disk**, and each
precondition is re-tested there rather than trusted from the plan — the plan is
exactly what has gone stale in the case that matters. An inference abandons itself
against a version that is no longer `unknown`, so a mod resolved exactly while the
screen was open cannot be downgraded to a guess. A folder rebound to a different mod
meanwhile abandons the whole row. But a **declined file does not abandon a confirmed
identity**: they are independent answers about the same mod, and the version being
settled elsewhere is no reason to throw away the user's "yes, that's the mod".

A declined write is reported as a decline, never as a failure —
`updateOrigin` answers one bare `false` for "unwritable folder" and "the transform
said no", and blaming the user's filesystem for the guard working is the conflation
[§6](#6-assume-current-in-bulk) already had to untangle once.

### The comparison is name to name

The plan asked for a thumbnail beside each remote name. There isn't one, and the
reason is not cost: **`Mod/Multi` cannot supply the content-filter hint** —
`_sInitialVisibility` is rejected there as an unknown property
([`gamebanana-api.md`](gamebanana-api.md#bulk--modmulti)) — and the one available
proxy is unreliable. apiv13 publishes a server-pixelated `_sFileNNNSfw` copy only for
`warn`/`hide` mods, so its presence looks like a rating flag; measured across a real
57-mod library it is absent on a mod whose profile reports `hide` (`541825`).
Rendering an unblurred adult cover in the library tab to make a name comparison
prettier is not a trade worth making, and the realistic failure this pass catches — a
wrong paste — is one where the two names disagree completely. Every row links to the
mod page for anyone who wants to look.

### Cost, measured on a real library

57 mods against the live `Mod/Multi` response for their 56 distinct ids, one request
of 111 KB:

- **As the library actually stands** (every mod resolved to `user` or `exact`): the
  planner produces **0 rows** in 0.4 ms, so the screen never opens and the check
  reports through its summary notification as before.
- **The same library reduced to the shape a legacy one has** (identity `inferred`
  from a url, no version, real proxied install dates): **57 rows** in 2.8 ms, of
  which **24 arrive with their file already worked out** and 33 need a pick. 127
  candidate files ranked in total.

So the expensive part of resolving a library is the human, and the pass removes about
two fifths of it for nothing.

---

## 8. The write path

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

## 9. Reading it back: the installed-mods index

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

**Every layer of a folder's stack is indexed**, not only its bottom — see
[§10](#10-a-folder-that-holds-two-downloads). A patched folder really does hold
both mods' files, and before that the mod which was not the folder's headline
showed no badge on its own page at all.

---

## 10. A folder that holds two downloads

A mod folder is frequently two downloads: a *patch* plus the mod it patches. It is
recorded as a **stack**, `origin.downloads`, written bottom-up — index 0 is what
the folder is and everything above it is written over what is below.

That is the whole model, and everything in this section follows from it: position
is the role, so there is nothing to derive and nothing that can disagree.

### What the stack replaced

The block used to keep **one** download in `origin`'s own fields and the rest in
`origin.companions`, each with a role *relative* to the primary. **Which download
landed where was install order.** Patch a mod and the mod was primary; install the
patch first and name the mod afterwards and the patch was. The two folders were
byte-for-byte identical and the two records were mirror images.

So every reader paid to undo it — an absolute-role enum, a per-entry wrapper, a
two-signal derivation, a partition, a second summariser, a discarded verdict
recovered through a `folderOwn` field, and a five-branch write router — and one
operation could not be expressed at all. "Take this patch out" is removing the top
layer, and both orderings put the patch on top *physically*; only the record
disagreed, so for one of them the button had nowhere to point.

In the stack the same folder is the same list either way round. What is left of
that compensation layer is one function: `derivedPatchFiles`, which keeps the flat
`ingest.patch_files` in step for builds that read it
([`metadata-schema.md`](metadata-schema.md)).

Reading a sidecar written in the flat shape still works — `migrateFlatBlock` reads
it as `[base companions…, own, patch companions…]`, the ordering the old code
already derived — and the next save emits a stack. No version bump: that shape
never shipped.

### What a layer is

`ModDownload` (`models/mod_download.dart`) is **which remote file this layer is,
how sure we are, and which files it laid down**. Every layer carries the same
fields, because there is no privileged one.

What stays **outside** the list, on `ModOrigin` itself, is what a folder has
exactly one of: the service, how it got here, when it was installed, the archive
layout to replay, and whether the user wants it watched at all. A per-layer mute
would be a second switch on one card, and the installed-mods index depends on
there being exactly one.

**`mod_id` is nullable on every layer, including a patch.** A patch written in
from a local archive has no page — but the install still knows exactly which files
it laid down, so the layer is worth recording: it gets set aside when the base
updates and it can be taken back out. What it cannot do is be checked for updates,
and that follows from the null rather than needing to be said anywhere else. The
old shape *required* an identity and therefore recorded nothing at all for such a
patch.

### It lives inside `origin`, and that is what keeps it additive

`downloads` is a key **inside** the `origin` object rather than a restructuring of
it. Making `origin` an array instead would have an older build's `fromJson` return
null and silently untrack the mod; as a key it round-trips through
`ModMetadata.extra`, `ModInfo.origin` is unchanged, no schema bump is required, and
the rescan guard rides the value equality `ModOrigin` already has
([`metadata-schema.md`](metadata-schema.md#modinfoorigin-is-read-only-and-why-that-was-allowed)).

Equality over the list is **order-dependent**, unlike the set it replaced: order
is meaning now, so two layers swapped is a different folder and a rescan has to
say so.

### Parse rules

The sidecar's load-bearing rules apply, with consequences specific to an ordered
list:

- **An entry that knows nothing is still kept**, and this is the one rule that
  would be wrong in the old shape. A companion with no identity was worthless,
  because a companion *was* an identity. A layer with no identity and no file list
  still carries its **position** — "there is a download here and we know nothing
  about it" — and dropping it would renumber everything above it, turning a patch
  into the thing it was written over. Only an entry that is not an object at all
  is dropped.
- **A role that disagrees with its index loses to the index**, and the
  disagreement is logged. An unrecognised role loses the same way.
- **One bad entry costs only itself.** The rest of the list and the folder's own
  facts survive it.
- **A repeated mod id keeps the lower layer.** Kept, the second would have the
  check ask one page twice and report two verdicts for one folder — and the lower
  one is the one whose files the upper would have overwritten.
- **No nesting.** A layer carries no stack of its own.
- Absent from the json when empty, which is every sidecar that records only how
  the folder got here.

### Where it is shown

**Three dialogs, one implementation** — the details view, the resolve dialog and the
update dialog, through `screens/components/folder_downloads_summary.dart`.

**It renders the stack in the order the stack is in**, and there is nothing else to
it. That was the point of the change: this section used to hold a derivation
(`folderDownloads`) that read two signals to work out which entry was the patch,
and a partition to put the mod's half first, because a section that read the old
block straight would have put the same pair of mods in different places for two
users who did the same thing in a different sequence.

Bottom-first is the order the files themselves go on disk
([`applying-updates.md` §6](applying-updates.md#6-the-order-and-why-it-is-the-safety-argument)),
so the list needs no sorting — which also disposes of a hazard: `List.sort` is not
stable in Dart, and peers that reshuffled on a rewrite would make a sidecar edit
look like a change to the folder.

**Absent entirely for a folder with one download.** A one-row list is a heading plus a
restatement of the mod already on screen; and saying "nothing else here" would be a
claim about a scan this never performs.

**Nothing stores a name**, for either entry — a name belongs to the remote, and a
stored copy would be a second source of truth. So each caller supplies what it has,
and the row falls back:

| Surface | Where a name comes from | Explains the "why two" hint |
|---|---|---|
| Update dialog *(section headers, not this section)* | The records its own check fetched. Failing that it looks one up — **but only when the check did not run**, which is every reopen and every arrival from a card badge, since `initState` skips the check once a verdict is on record and only a *bulk* pass banks records in the session. Withheld once the check has run: a name missing then means that download's request failed, and asking again is a second failure per download on an offline check. | no |
| Resolve dialog | The session's records, else one small `Mod/Multi` request — it is already talking to GameBanana, and this is not a request it would otherwise make. | no |
| Details view | The session's records, else the fallback. **It never fetches**: a read-only view opened on a mod should not spend a request the reader did not ask for. | **yes** — the surface whose job is "what is this", and the one with a scrollable column to spend on it |

The fallback itself differs by entry and each uses the best thing available: the
**bottom** layer falls back to **the folder name**, which is what the user knows it
by everywhere else in the app and what the folder is named after; a layer above it
falls back to its id. Every row links to its page either way, because an id is not
something a person can act on.

**The file line appears only when it carries something.** Not
`describeRecordedFile`, which the resolve surfaces use and which always produces a
line: three of its six phrasings are how-we-know with no *what* — "the file you
chose", "the file you downloaded", "byte-identical to the archive you installed" —
and a download carrying a `file_id` and no version string is the common case, since
`_sVersion` is routinely null. On a row whose job is naming a download, that renders
as filler.

One of them used to be **wrong for the other download**, and one summariser over
one type is what removed the wart. The old `summarizeCompanion` folded `exact` to
*chosen* on the grounds that a companion is a download the app did not perform —
true of a user-named base, false of a patch the install prompt wrote at `exact`
precisely *because* the app fetched those bytes. So the line credited the user with
a choice they never made. `summarizeDownload` takes one layer and reads that
layer's own archive hash as the better witness where it has one. What survives is
the version when there is one, and the caveat when the record is short of a file.

**The update dialog does not use this section.** It renders a *full report* per
download instead — verdict, before-and-after box, file list, notes, and its own
actions — because a check is about the mods in a folder and a summary row answers a
different question for the second mod than the first one got. It shares the role
derivation above and the same patch marker, so the two screens agree about what each
download is; see
[`update-checks.md`](update-checks.md#the-dialog). The section here is for the two
surfaces where the folder's contents are *context* rather than the subject.

**The affordance is on the row, not beside the list.** A separate editable row below
the list would put one download in a place of its own again; as a button on the row
it looks like every other entry with one more thing on it. Which rows offer one, and
which of the two actions each offers, is passed in by mod id rather than derived:
what can be done to a layer depends on which flows exist, not on anything visible
in the row, and a widget guessing would offer a button that does nothing. The
resolve dialog gives a patch *remove* and a patch-shaped folder's bottom layer
*change* (see [below](#taking-a-patch-out)); the details view gives none, being a
read-only answer to "what is this".

### Naming what a patch applies to

Only the user can. They assembled the folder by hand, possibly from a source the app
never saw, so there is nothing to infer from and no bulk pass can propose it — folder
names match one mod at most.

The route is a **pushed step** off the resolve dialog
(`screens/dialogs/companion_resolve_dialog.dart`), reached from a row that appears
only when the folder is recorded as patch-shaped, or from that folder's bottom
layer once one has been named. It
is pushed rather than inline because that dialog is at its height budget and its two
escape hatches must stay one click from the bottom ([§5](#5-the-resolve-dialog)) — a
second identity card inline is exactly what pushes them off it.

Both steps share `IdentitySearchPanel` and `FileChoicePanel`
(`screens/components/resolve/`), so "on record" and "our best guess" cannot come to
mean different things on the two screens.

What it may write is narrower than the identity step:

| Answer | Writes |
|---|---|
| Pick a mod page | A layer **inserted at index 0**, `mod_id` at **`user`**. Never `exact` — we did not download these bytes. What was the only layer becomes the patch above it, with no role field to rewrite. |
| Pick a file | `file_id`, `version`, `version_label` at `user` on that layer. A banked-hash row's `exact` is discarded: the hash is a fact about the archive the layer *above* came from. |
| "I don't know which" | `assumed_latest` plus the other mod's **own creation date** as the baseline. The folder's install date belongs to the download we performed. |
| "This folder is one mod after all" | Removes the bottom layer and clears `patch_shaped`. What is left is one download that patches nothing, which is an ordinary mod. A wrong answer has to be undoable, or naming one is a trap. |

Changing the identity clears whatever was answered about the previous one, and the
baseline is read from the profile **when the answer is written** rather than held
from when the tile was tapped. A held date outlives the mod it describes: recorded
against a mod created earlier it sits in that mod's future, and a baseline later
than its subject hides every file published before it — silently, which is the one
direction this feature cannot afford.

`role` is never asked, and there is nothing to ask: the answer goes **underneath**,
so its role follows from the position. Reached from a patch-shaped folder, what the
user is naming is the mod their patch applies to; asking them to classify their own
folder would be a quiz whose answer the app already has.

**This step runs in one direction only, and that is why it is not the flow for a
patch written into a folder.** Every string in it reads *"this mod holds a patch"* →
*"name the mod it patches"*, and the search-plus-file-picker shape exists because a
download nobody recorded has to be identified from scratch. A patch the install
prompt wrote — with both axes already `exact` — needs none of that: the app
performed the download and knows exactly which file it was. Offering the search
would let an exact record be re-aimed
at a mod page its bytes never came from.

### Taking a patch out

The one thing a patch's record cannot know on its own is whether those files are
still in the folder. It goes stale for reasons unrelated to how confident it was:
the user deletes the patch by hand, an update overwrites the folder and flattens it
away ([`applying-updates.md`](applying-updates.md) §1), or its page comes down. A
stale one keeps a second mod page on the folder's books — its verdict competes for
the folder's headline through `foldDownloads`
([`update-checks.md`](update-checks.md)), and the updates dialog offers to write
files back that the user removed on purpose.

**The row runs the real removal**, the same
[`removePatchFlow`](applying-updates.md#taking-a-patch-back-out) the mod's
right-click menu does: it deletes what the patch added, puts the mod's own files
back, and snapshots first.

**Forgetting the record while the files stayed was worse than doing nothing**, and
that is why it is not an option. The record is what makes the next base update set
the patch aside instead of writing over it, and what makes the confirmation warn
when it cannot — so "stop tracking this patch" took the patch's only protection
away and left the patch. Worse, with a *second* patch recorded the derived
`patch_files` was rebuilt without the forgotten one, so the next base update
flattened it with no warning at all.

So there is one action, and it does what the situation allows:

| The recorded files are | What happens |
|---|---|
| **gone from the folder** | The record is dropped. There is nothing else to do, and the record was a lie. |
| **there, and the registry knows them** | The real removal: `added` files deleted, `replaced` files restored from the store. |
| **there, with no registry** | **Refused, and the record is kept.** Nothing says which of the folder's files are the patch's, and the record is what still makes the base update warn. What is useful to say is: delete those files yourself and the app will see they are gone. |

The removal is confirmed rather than immediate, and the confirmation states counts
— what goes, what comes back, and what it cannot put back — because a delete
affordance's first suggestion is that the *mod's* files go, and none do. Recorded
through `logConfirmation('patch.remove', …)`. Installing that patch through the app
again records it again; the install prompt is the only route to one.

**Both surfaces run the same flow**, and that is deliberate rather than convenient:
the menu entry is where a mod action belongs, and the row is where the user is
looking at the patch. Two spellings of one operation is how the record-only version
came to exist.

**Which affordance a row carries comes from what can be done to that layer**
(`FolderRowAction`, `screens/components/folder_downloads_summary.dart`), stated per
row by the caller rather than derived: what is possible depends on which flows
exist, not on anything visible in the row, and a widget guessing would offer a
button that does nothing. In the resolve dialog a patch row offers removal, and the
**bottom** layer offers *change* only for a patch-shaped folder — the one place a
"this is just one mod after all" undo exists. An ordinary mod's base row carries
nothing, because the identity card above it is the whole story there.

The row that *opens* the naming step is only the **empty** case — patch-shaped,
nothing underneath. Once a base exists it is the layer the identity card edits, so a
second row for it would be the duplicate this section exists to avoid.

The write happens on its own rather than folding into Save — it is a decision about a
different mod, and making the user press Save afterwards invites them to close the
dialog believing they already had.

### The install asks too, at the moment it finds a patch

The resolve dialog is the route for a folder already on disk. For one the install is
*about to create*, waiting is a research task: read a warning, understand it, switch
tabs, find the folder among the rest of the library, press a badge. So the marketplace
install raises the same question itself
(`screens/dialogs/patch_install_prompt.dart`), reusing the pushed step above for the
answer — one implementation, so the two cannot come to write different things.

It sits **after** the patch scan and **before** the copy, which is what gives it a
third answer nothing else can offer.

**Two questions, with different search spaces.** *Where do the files go?* is
answered by a **library folder**, because a destination has to exist. *What mod
does this patch?* is answered by a **mod page**, because the mod being patched may
not be installed at all — finding the patch first is an ordinary way round.
Answering the first with a library mod answers the second for free (that folder's
own `origin` *is* the base), so it stops being asked.

| Answer | What the install does |
|---|---|
| Its own folder, naming what it patches **and which file** | Writes `patch_shaped` and inserts that mod as the bottom layer, then **fetches that file and writes it into the folder** — base first, patch placed back over it. No warning: the folder works |
| Its own folder, naming the mod but not the file | Writes `patch_shaped` and inserts the layer. Nothing to fetch, so the pinned warning stands |
| Its own folder, saying nothing | Writes `patch_shaped` only, and the pinned warning stands |
| Into a library mod | **No new folder at all** — see below |
| Declines | Nothing is copied. A patch with nothing to patch is a folder the user may well not want |

**Naming the base is an instruction, not a note.** It recorded the answer and
installed nothing, which left the folder doing nothing in the game — the thing
naming it was supposed to fix. `installNamedBase` is that install, and it is the
ordinary update flow with the whole folder passed as the patch: the folder holds
only the patch at that moment, so it is set aside, the base is written, and the
patch goes back onto the base's layout
([`applying-updates.md` §6](applying-updates.md#base-first-then-patch--for-both-halves-of-a-mixed-folder)).
No second confirmation — they answered this a moment ago in the prompt.

Two consequences worth stating:

- **The warning is silenced by a folder that works, never by an answer about
  one.** Naming the base used to suppress it on its own, and the folder still did
  nothing — with the one sentence that would have said so now gone. A cancelled
  download or an unpickable file leaves as much to do as saying nothing did, so
  the warning stands.
- **The answer is recorded before the download starts**, so a cancelled or failed
  fetch leaves the layer the user named rather than nothing. A successful one
  upgrades that layer to `exact` on its way past — the second route to `exact` for
  a layer nobody identified by hand, and for the same reason as the first: we
  fetched those bytes. The record is the *answer*, never a claim the bytes
  arrived; the pinned warning is what says the folder still does not work.

The second destination is not offered when the import picker already chose to
combine several folders into one mod (different destinations), or when the library
is empty (nowhere to install into). Both say why rather than hiding the control.

**The drag/drop import raises the same prompt**, from the same code
(`patch_install_flow.dart`) — one decision before either path's copy, one set of
writes after it. What differs is only what can be *recorded*: a Marketplace
download knows which mod page and file it is, and a folder dragged off a disk has
none — so the layer written for the second carries **no `mod_id`**. It is still
written: a layer with no identity is a download nobody can name, and its *files*
are known, which is enough to set it aside on a base update and to take it back
out. What it cannot do is be checked for updates. (The old shape required an
identity and therefore recorded nothing at all for such a patch.) The install
itself — the placement, the snapshot, the refusals, the warnings — is the same
operation either way.

**With no identity the card stays quiet, and that ordering is deliberate.**
`untracked` outranks `secondIdentityUnknown` in `modOriginStatus`, so a hand-dragged
patch shows the quiet informational mark rather than the amber one — there is no page
to watch for *either* half of the folder yet, so the amber state's offer ("name the
other mod and get a real answer about it") has nothing to be an offer about. It is
still counted in **needs attention** as untracked, so the folder is never lost, and
the resolve dialog offers the naming row regardless — that row keys on
`needsBase`, not on the badge. The amber mark appears the moment the folder is
resolved to a mod page, which is the whole reason the flag is written at install
rather than when it is wanted. The same ordering is what keeps the bulk "assume
current" pass from writing baselines for folders it cannot check.

**The library is searched, not scrolled, and every row carries the mod's cover.**
A real library is long, and reading folder names down a list was the whole cost this
picker added — while the user arrives already knowing which mod they mean, and
recognises it by the picture faster than by the name. The search matches the folder
name *and* the recorded variant label, because both are on the row and **a list that
displays something it will not match on looks broken when you type the thing you can
see.**

Covers are decoded at row width (`AppConstants.modThumbnailDecodeWidth`) for the
reason `modCardDecodeWidth` records — `ImageCache` is bounded by decoded bytes and a
cover is a full screenshot — and it bites harder here, because a list scrolling a
whole library decodes far more of them than a grid of cards does. A missing file
falls to the placeholder through `errorBuilder` rather than an `existsSync` guard:
rows build while the user scrolls and types, and that guard is synchronous disk I/O
on the frame.

### Installing a patch into a mod that already works

The library mod the user picked is the one that ends up holding both downloads. Its
bottom layer is untouched — the folder is still that mod, because that is still
what it mostly is — and the patch is **added on top at `exact`**. That is the one
path to `exact` for a layer nobody identified by hand: every other route is the
user telling us about bytes they moved in themselves, which cannot be better than
`user`.

**Base first, then patch, whichever of the two the `origin` names.** A collision
resolves in favour of the patch, always — not "the newer file", not "whichever we
are writing now". Reversing it silently undoes the thing the user installed the
patch for. That ordering is also what makes a folder rebuildable from its two
identities rather than assembled once.

The write is **update-shaped, not install-shaped** (`UpdateApplier.applyPatchInto`):
deactivate, snapshot, place, reactivate, with no snapshot meaning no write. What
differs from an ordinary update is only the copy — individual files, each where the
target already keeps that name (`patch_placement.dart`), because the two downloads
are by different authors and nothing makes their layouts agree. Placed at the root
when the base keeps its textures in a subfolder, a file lands *beside* the mod
rather than over it: every reference still resolves to the original and nothing
changes in the game, with no error anywhere.

Two placements are **refused rather than guessed**. The download becomes an
ordinary new mod, nothing is written to the folder that was picked, and each
refusal names its own cause — because they ask different things of the user:

- **Nothing in the patch matches anything in the target.** Almost certainly the
  wrong mod, and a snapshot is not a reason to find out the expensive way.
- **The target holds its own files twice** (`sfw/body.dds` beside
  `nsfw/body.dds`). **No install path creates that shape** — the import picker
  settles separate-or-combined before anything is copied — so the folder was
  merged by hand outside that flow. It is not asked about, because the question
  has no good answer: writing a patch blind into a folder that is already wrong
  makes it worse. The folder is what needs sorting out, and the message says so.

That second one is why `resolvePatchPlacement` has no way to answer a
`PatchPlacement.choices` and try again. It reports the candidates so the refusal
can point at them, and there it stops.

Two rules it holds:

- **It answers nothing for the user.** The destinations are *ordered* by what the
  patch's files and its author's requirement point at
  ([`patch-destinations.md`](patch-destinations.md)), and nothing is preselected or
  hidden. What gets **recorded** is stricter still: that is a **mod page**, and
  nothing on disk names one. The prompt states the evidence it has and asks.
- **A prompt per install, not per folder.** An archive can produce several
  patch-shaped mods; a modal each is a queue to clear rather than a question.

An unanswered prompt is the user declining to say, which is not the same as saying
there is nothing — so the write only ever *adds* a layer and never clears one.

Once answered, the row states **both axes**: which mod, and which file of it. Naming
only the mod leaves a recorded file indistinguishable from "I don't know which" —
two states that are checked differently and one of which puts an amber mark on the
card. The file half is phrased by `describeRecordedFile`, the same function the
resolve dialog's own "currently tracked" line uses
(`summarizeDownload` folds a layer into the summary that feeds it), so "the file
you chose" cannot come to mean one thing about one layer of a folder and something
else about another.
