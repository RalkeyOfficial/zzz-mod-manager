# Update checks

Reference for how the app decides that an installed mod has a newer version
published, how strongly it is allowed to say so, and what a user can do about it.

**This documents what the code does today.** Where behaviour is planned but not
implemented, it says so.

> Scope: turning "which remote file is this?" into "is there a newer one?" — the
> comparator, the confidence-aware verdicts, the whole-library pass, and the two
> surfaces that show a result. What the app knows about a mod's identity in the
> first place, and how sure it is, is
> [`origin-tracking.md`](origin-tracking.md); this doc consumes that and adds
> nothing to it. GameBanana's own protocol — including the `Mod/Multi` quirks the
> bulk pass is built around — is [`gamebanana-api.md`](gamebanana-api.md).
>
> **Applying** an update — writing the newer download over the folder, patch
> detection, snapshots and rollback — is
> [`applying-updates.md`](applying-updates.md) — a second doc rather than a
> section here, on this directory's own rule that the scope line decides.
> Nothing in the applying half is about *turning identity into a verdict*: it is filesystem
> semantics, and it shares no vocabulary with the comparator below. The two docs
> meet at exactly one point — the Update button, described at the end of
> [§6](#the-dialog).

Related: [`../CLAUDE.md`](../CLAUDE.md) for the service/layer architecture.

---

## 1. Why this is a suggestion system

GameBanana publishes **no orderable version**. That is not a limitation of our
client; it is what the data looks like. Two facts, both measured against real
captured mod pages:

- `_sVersion` is a free-form author string and is routinely **null on every file
  of a mod**, with the version written into `_sDescription` instead — the field
  that is otherwise the *variant* marker.
- Authors use `_sDescription` both ways, and there is no marker saying which. On
  one captured page it is the variant (`Main file`, `Glow demo`, `RabbitFX Fixer
  EXE Version`); on another it is the version (`v3.4`, `v3.3`, … `v1.2 - fixed
  hashes`), with all ten files current and none archived.

So no rule can separate "newer release of what you have" from "different variant
of the same mod" from those two fields alone. The comparator does not pretend
otherwise: it reports what it can prove and softens everything else.

**One signal is not a heuristic at all**, and it carries most of the accuracy
here: `Mod/<id>/Updates` lists the files an author released *together*
(`_aFileRowIds`). Two files in one release are variants of each other, never a
successor and a predecessor — the author grouped them, and nothing has to be
inferred. See [§3](#3-how-the-comparison-actually-works).

**The failure modes are deliberately asymmetric.** A false "up to date" hides an
update silently and the feature simply fails at its one job. A false "possibly
outdated" costs the user one look at the file list and corrects itself. Every
tie below is broken toward flagging — the same choice the `assume current`
baseline makes.

---

## 2. The verdicts

`services/update_check.dart` is pure: `(origin block, mod page) → UpdateCheck`.
No network, no filesystem, no widgets.

| Outcome | Means |
|---|---|
| `updateAvailable` | The installed file has been superseded, or a newer file carrying the **same variant label** is published. Requires confirmed evidence on both axes. |
| `possiblyOutdated` | Something newer exists, but which file it corresponds to — or whether the installed file is even what we think it is — is a guess. |
| `upToDate` | Nothing published that could be newer than what is installed. |
| `versionUnknown` | Identity known, installed file not, and nothing local identifies it. The resolve dialog is the fix, not this. |
| `untracked` | No remote identity at all. |
| `trackingOff` | The user declared the mod their own. |
| `sourceGone` | The mod page is private, trashed or withheld — read from the remote's own flags, not inferred from a status code. |
| `indeterminate` | The response carried no current file list, or a layer's page was never fetched — or it names no page to fetch. **Silence is not evidence**: concluding "nothing newer" from a question never asked is the one way this fails invisibly. |
| `tracksPatchOnly` | The folder holds a patch and nobody has said what it patches, so nothing here is a statement about the mod the folder actually contains. Distinct from `upToDate` because the patch genuinely has no newer file — that answer is true about the page asked and false about the folder. |

`isObsolete` rides alongside, never folded in. `_bIsObsolete` is the author
flagging a mod superseded; the mod still exists, still downloads, and can be
perfectly up to date. It is a different sentence from "your copy is old", and it
must stay distinct from `sourceGone`.

### The order the checks run in

`tracking: "off"` is tested **before** identity, matching the status slot: a
stale `source_url` still sitting in the block must not talk the user out of a
decision they made. That prefix — the answers no request could improve on — is
`verdictWithoutAsking()`, shared with the bulk planner so a mod can never be
requested and then given an answer that ignores the response.

### A folder with two identities still gets one verdict

A mixed folder is checked against two mod pages
([`origin-tracking.md` §10](origin-tracking.md#10-a-folder-that-holds-two-downloads)),
and the card has one slot, `modUpdateChecksProvider` is keyed by folder, and the
toolbar counts one number. So `checkForUpdate` **folds** rather than fanning out.

**The top-level fields describe whichever layer won**, and `subjectModId` names it
by its own id. This is load-bearing: every consumer reads `candidate` and
`newerFiles`, and `dismissableUpTo` is computed from the latter — a verdict folded
from one layer sitting on another's file list would illustrate one mod's finding
with another's files, and would write a dismissal cutoff from the wrong mod's
dates. `layers` carries **every** layer's own verdict for the dialog, the winner
included.

That last point is the difference from the shape this replaced. A
primary-plus-companions record made the fold discard exactly one verdict — the
primary's — so a folder whose patch had the update could say nothing at all about
the mod it patched, and a `folderOwn` field existed to smuggle it back. With a
stack there is no privileged entry and nothing is discarded.

The fold applies the file's existing asymmetry across layers — the most actionable
verdict wins, and `upToDate` is claimed only when every layer says it. Three rules
follow, none of them obvious:

- **A live finding beats a dismissed stronger one.** Ranking by outcome alone picks a
  dismissed `updateAvailable` and then reports `hasUpdate: false`, leaving a folder
  with a real update on another layer rendering as though it had none. A dismissal
  is per layer, so it disqualifies that layer rather than the folder.
- **A layer whose record was never fetched is `indeterminate`**, and so is one with
  no mod id to fetch. Claiming clean after looking at part of a folder is the false
  clean this whole feature exists to remove.
- **`tracking: "off"` short-circuits before any of it.** No layer is consulted,
  which is the folder-level switch doing its job.

`tracksPatchOnly` is therefore produced only while `ingest.patch_shaped` is set
*and* nothing is recorded under the folder's own download. Naming what it patches
retires it, per folder.

**Any layer's finding can be applied, and its *position* decides which write does
it.** A layer says that download is *in this folder*, so a newer file of it lands
in this folder — and the folder is written bottom-first-then-upward whichever layer
changed
([`applying-updates.md` §6](applying-updates.md#base-first-then-patch--for-both-halves-of-a-mixed-folder)).
`update_write_route.dart` is that decision on its own — now `indexOf` and two cases,
where it used to be a five-branch table over relative roles — so it can be read
without a download or a dialog.

What is refused is narrower and it is still a rule: **a verdict about a mod this
folder does not claim to hold is never written.** Nothing could apply it — it would
overwrite one mod's folder with another mod's archive and stamp a file id onto a
block that never published it, after which every later check asks the wrong page.
Two guards enforce that, because the first is a widget condition a later edit could
stop satisfying and the second is the call that touches a live folder.

The file is recorded **against the layer that was written**, and against no other:
`withDownloadUpdatedTo` amends that one by mod id and leaves its position alone,
reaching `exact` on the same grounds any layer does — we fetched those bytes off
that page. The folder's own facts (its install date, its provenance) are refreshed
only when the write was the **bottom** layer's: a patch arriving on top does not
re-date the folder.

**Every caller must supply the records for every layer**, or a mixed folder reads
`indeterminate`: the bulk pass batches every id ([§5](#5-checking-the-whole-library))
and the per-mod dialog fetches each upper layer's record and feed alongside the
bottom one's.

---

## 3. How the comparison actually works

**Nothing reads the mod folder.** Not once, on any path. The check compares what the
sidecar *records* about the file you installed — its id, its upload date, its version
string, the author's label for it — against the file list the mod page publishes
today. It does not hash your files, diff them, or look at them at all, so it cannot
know that you edited a `.ini`, merged a second mod in, or replaced a texture by hand.

Two consequences worth being blunt about:

- **A mod with no recorded file can only be judged by date**, which is a cutoff and
  not a comparison: everything the page offers that went up after that date is a
  candidate, and the verdict is capped at *possibly* outdated accordingly.
- **A verdict is about the mod page, never about the folder.** "This is the latest
  file" means the page publishes nothing newer than what we recorded — it is not a
  claim that the folder still holds what we put there.

What follows is the machinery that makes the first case better than a date cutoff
whenever there is enough on record to do so.

### When the installed file is known

Three questions, in order, and the order is the design.

1. **Is that file still offered?** If it has moved to the archived list — or
   vanished from the page entirely — it has been superseded. That is a *fact*,
   not a comparison; no version string is involved, and it is the strongest
   verdict this feature produces.
2. **Is there a newer file wearing the same variant label?** `Main file` v7.6 →
   `Main file` v7.7 is the shape an update takes on GameBanana, and the label is
   what survives across releases. Both labels must be **non-empty**: two
   unlabelled files matching each other is not evidence, it is two nulls.
3. **Is there anything newer at all?** Then say only that — `possiblyOutdated`.
   `v3.4` beside an installed `v3.0` and `Glow demo` beside an installed `Main
   file` are indistinguishable from here, and one of them is an update while the
   other is not.

Step 3 is what stops step 2 producing a **false "up to date"**. On the captured
page whose labels are version numbers, nothing is ever archived and no successor
ever shares a label, so a same-label rule on its own would report an installed
`v3.0` as current.

#### Two things are removed from the candidate pool first

Both are *suppressions* — they can only ever turn a flag off, never on — and
**neither can change the verdict on the archived branch**: once the installed
file is superseded that is a fact, and no label, version or grouping is allowed
to argue with it.

They differ in how far they reach, and the difference is deliberate:

- **The same-`_sVersion` rule applies only while the installed file is still
  offered.** Two files stamped alike says something about *those two files*, and
  against an archived install it would be arguing with the archive flag.
- **Release groups filter the candidate pool on both branches.** A file the
  author shipped alongside the installed one is its sibling variant whether or
  not the installed one has since been archived — it is the *old* build of the
  other variant, so it cannot be the replacement for yours. The verdict stays
  `updateAvailable` either way; what the grouping changes is which file gets
  named. When it filters out everything, the check says an update exists and
  names none, which is the honest answer: the file you had is gone and nothing
  on the page is identifiably its replacement.

- **Files the author released together** (`ReleaseGroups`, from `_aFileRowIds`).
  This is the authoritative one. Measured against a real library, it is what
  turns an `SFW Variants Only` install with an `NSFW Variants Included`
  published ninety seconds later from "possibly outdated" into "up to date", and
  likewise a mod that shipped four proportion variants in one post.
  **Absent groups suppress nothing**: a mod with no update posts, or one whose
  relevant post has scrolled off the feed's first page, simply gets the
  unrefined verdict. That is the safe direction.
- **Files stamped with the same `_sVersion` as the installed one.** The one use
  that free-form field reliably supports: ordering two of them is hopeless,
  comparing them for *equality* is not, and an author who stamps two
  still-offered files `1.01` has said they are the same version. This catches
  what release groups cannot — a `FULL MOD` and an `NSFW MOD` published nine
  days apart in *separate* update posts, both `1.01`.
  **Absent is not equal**: two files that both omit `_sVersion` have declared
  nothing, and treating that as agreement would silence most of the site.

The installed file is identified by `origin.file_id`, or failing that by a
**banked `archive_md5`** matching a published checksum — used read-only. A match
is exact-grade knowledge and costs nothing (it is the same lookup the resolve
dialog runs), but *recording* it is a resolution, and resolutions are written by
the resolve dialog, never as a side effect of asking a question.

**The variant label is read from the sidecar first, then from the published
record.** That is load-bearing rather than tidy: the strongest verdict is "the
file you installed is gone from the mod page", and in exactly that case there is
no published record left to read a label from.

### When only a date is known

For `assumed_latest` — "I don't know which file, I got it around then" — the
comparison is against `baseline_remote_date`, and **this is where the clamp
lives**:

```
baseline = max(stored baseline, mod's own _tsDateAdded)
```

The per-mod resolve dialog clamps as it writes, because it has the mod page in
hand. The zero-network bulk "assume current" action cannot, by design. So stored
baselines are a mix of clamped and unclamped and the comparison must not assume
otherwise — an install date proxied from file timestamps can read *years* early
for a hand-copied library, leaving a baseline from before the mod existed. This
is the correct home for the rule regardless: the clamp is a fact about the mod
page, not about the sidecar. It is a **sanity floor, not a false-positive
filter** — every published file is at or after its mod's creation date, so it
excludes only whatever was uploaded at creation.

A file newer than the clamped baseline gives `possiblyOutdated` and names that
file. With no file date able to answer, `_tsDateUpdated` is the fallback —
**never `_tsDateModified`**, which is bumped by cosmetic edits and would flag a
mod because its author fixed a typo.

This path is capped at `possiblyOutdated` structurally: nothing here knows what
is installed, only when it arrived.

### Where this stops, and why it stops there

Measured on a real 17-mod library after both suppressions: **2 soft flags**.

- A patch file — `Put it in the folder with the mod (replace it)` — published
  after the install on a mod with no update posts. Arguably a **true** positive:
  it is something the user should look at.
- A companion file with **no variant label**, uploaded two minutes after the
  installed one, in no update post, with no version on either.

Every metadata signal on the second is blank, so removing it means inferring
from something other than what the author stated. Three candidates were measured
against `_aFileRowIds` as ground truth across **300 ZZZ mods**, and all three
were rejected. This is the section to read before proposing a fourth.

**Only 27% of newer-than file pairs have both files named in an update post**,
so there is a real gap here and it is tempting to fill.

| candidate rule | agrees with author's grouping | disagrees | verdict |
|---|---|---|---|
| co-publication window (1 h) | 85/106 | 2/277 | rejected — see below |
| filename stem is a prefix of the other's | 13/106 | 38/277 | anti-correlated; GameBanana's random `_xxxxx` suffix makes stems unstable |
| filename stems equal | 0/106 | 5/277 | anti-correlated |
| candidate unlabelled while mine is labelled | 8/106 | 6/277 | a coin flip |
| identical file size | 0 | 0 | never fires; the CDN re-compresses |

**The time window measures well and was still rejected.** A 1 h threshold sits
on a flat plateau (15 min to 2 h are indistinguishable, the cliff is at 24 h),
and every disagreement inspected turned out to be a co-release the author had
split across two posts. But its contribution *over* the two rules already in
place is 99 pairs, and every one of those rests solely on "an author does not
upload twice in one session for two different reasons". A hotfix published
minutes after a broken file breaks that — in the **silent** direction. Nothing
in the data can confirm the assumption, only fail to contradict it.

**The strongest candidate is causal, and is rejected for a sharper reason.**
*A file that already existed when you installed cannot be an update to it — you
saw it on the page and chose otherwise.* No threshold, no behavioural
assumption, and it kills both remaining false positives outright (their
candidates predate the installs by eleven months and two months). It rests on
`installed_at`, which is a **proxy** taken from file mtimes for anything this
build did not install. A plain `cp -r` of a mods folder resets every mtime to
the copy time; the proxy then reads *late*, every published file predates it,
and the whole feature goes quiet with nothing on screen to say so. That is
precisely the hazard [`origin-tracking.md` §3](origin-tracking.md#3-the-offline-backfill)
names as the reason the proxy uses the oldest *contained file* rather than the
folder's own mtime — *"they skew later than the true install and would hide
updates."* A suppression built on that date reintroduces it.

So the line is: **a rule may turn a flag off only if the author stated the
fact.** What is left over is handled by the user rather than by the detector —
one click on [§4](#4-dismissing-an-update)'s "ignore this update", permanent,
with the mark returning only if something genuinely newer appears.

### The cap that confidence imposes

`updateAvailable` requires `exact` or `user` on **both** `mod_id_confidence` and
the version evidence. Anything weaker is folded down to `possiblyOutdated` and
carries `isGuess`.

Both axes, because both can be wrong in ways that invalidate everything below
them: an `inferred` mod id came from a free-form text field a human typed and may
name a different mod entirely, in which case every file compared belongs to a mod
the user does not own. A checksum match counts as confirmed whatever tier the
block records, since it identifies the file directly.

`isGuess` survives onto a *clean* answer too. "Probably nothing new" and "nothing
new" are different claims, and the weaker one must not borrow the stronger's
certainty.

---

## 4. Dismissing an update

`origin.updates_dismissed_until` — "I have seen what this mod published up to
here, and I don't want it."

**A date, not a file id**, so it expires by itself: the check stays quiet about
anything published at or before that instant and speaks again the moment the
author publishes something newer. A dismissal keyed on a file id would either be
permanent or need re-dismissing per variant, and neither is what *not this one*
means.

Six rules:

- **It is written as the date of the thing being dismissed, never as "now".** A
  mod page can publish something between the check and the press, and dismissing
  to the current time would swallow it before the user ever saw it.
- **"The thing being dismissed" is the newest file the finding *listed*, not the
  candidate it marked.** Those come apart precisely where the label rule is
  doing its job: your variant's successor can be older than some other file on
  the page ([§3](#one-file-gets-a-line-several-get-a-list)). Keyed on the
  candidate, a dismissal left every later file silenced while this section
  promised the opposite. The user was shown the whole list and ignored the whole
  finding, so the dismissal covers the whole list.
- **It belongs to the layer whose releases it waves away.** A folded verdict names
  that layer in `subjectModId`, and the cutoff goes on **that layer's** entry — one
  rule, `ModOrigin.withDismissal`, shared by the write and by the re-fold that
  follows it so the two cannot disagree. Written on the wrong layer a dismissal
  fails twice at once: it silences nothing, because the check reads each layer's own
  field, and it stamps another mod's release date where it can hide a finding nobody
  dismissed.
- **The verdict is kept, not rewritten.** Only `hasUpdate` — the badge — goes
  quiet. The dialog goes on saying what is published, because "there is an
  update and you dismissed it" and "there is nothing new" are different facts,
  and someone reopening that dialog is usually there to change their mind. The
  undo sits where the dismissal did.
- **A finding with no date is never suppressed.** If a dismissal cannot be shown
  to cover it, it does not.
- **It is dropped when the folder is rebound** to a different mod, like every
  other field that describes one mod page ([`origin-tracking.md`](origin-tracking.md#3-the-offline-backfill)).

It is deliberately **not** `tracking: "off"`. That answer says the mod is not
from GameBanana at all and silences it forever; this one keeps the mod tracked
and keeps the next release loud.

---

## 5. Checking the whole library

`services/bulk_update_check.dart`, driven from the mods toolbar. It runs **only
when pressed** — with one opt-in exception, [§5.1](#51-checking-at-startup),
which is off by default.

It runs in **two phases**. Phase one is `Mod/Multi`, which fetches many mods'
chosen fields in one request, so an 80-mod library is two requests rather than
eighty. Phase two fetches `Mod/<id>/Updates` — one request *per mod*, which
would undo everything phase one buys if it ran across the library, so it runs
**only for the mods that flagged**. A release group can only turn a flag off, so
that is exactly where it can do any work; a feed that fails to load leaves the
phase-one verdict standing rather than reporting an error.

Note what "flagged" counts: the mods flagged by phase one, **before** the
refinement, not the ones left flagged after it. On a real 17-mod library that is
four mods — of which two survived — so four extra requests rather than
seventeen.

Three properties of `Mod/Multi` shape the pass, all documented in
[`gamebanana-api.md`](gamebanana-api.md#bulk--modmulti):

- **`_aFiles` there is the union of current and archived files**, where a profile
  splits them. `GbMod.currentFiles` reads `_bIsArchived` rather than the key, so
  the same comparator serves both response shapes. Getting this wrong would make
  every mod on the bulk path look up to date.
- **`_aArchivedFiles` is not a requestable property**, which costs nothing given
  the above.
- **One unknown id fails the whole batch** with a `400`, naming only the first
  offender.

That last point is the interesting one, because most ids in a legacy library are
`inferred` — parsed out of a `source_url` somebody typed. A wrong paste or a mod
since deleted would otherwise report the other forty-nine as unreachable. So a
`_csvRowIds` error **halves the batch and retries**, down to single ids; an id
that fails alone is `sourceGone`, which is an answer rather than a failure. The
cost is about `2·log₂(n)` extra requests per bad id.

The guard that keeps that bounded: if `_aErrorData` names any field **other**
than `_csvRowIds`, our url is wrong rather than an id — every subset would fail
identically — so the pass aborts immediately instead of spending a hundred
requests to learn what the first one said. A network error is likewise never
split: an outage repeats for every half, and the honest answer is "we could not
look".

**"We could not look" is tracked separately from every verdict.** Mods the pass
never answered — an outage, an abort, a batch it never reached — come back in
`failed`, and the summary says so. "No updates" and "no updates among the mods we
could actually reach" are different statements, and reporting the second as the
first turns a network failure into false reassurance across a whole library. A
folder any of whose *layers* could not be reached is in `failed` too: it still gets
a verdict, which refuses to claim clean without the missing part, but half an answer
is not an answer.

### A mixed folder is two requests and one answer

A folder is listed under **every** mod id in its stack, so every page is fetched.
Two consequences shape the pass:

- **Nothing is folded as records arrive.** The ids can land in different batches,
  and folding on arrival writes one layer's verdict and then overwrites it with
  another's — whichever came last silently becoming the folder's whole answer,
  computed by comparing one mod's record against another mod's page. Every record
  is banked first; each folder is folded once afterwards.
- **`checkableCount` counts folders, `requests` counts pages.** The user counts
  cards, so the toolbar button must not promise more work than they can see.

A page the server says does not exist is banked as a record flagged missing rather
than short-circuited to a verdict, so a *layer* whose page has gone reads as
`sourceGone` instead of collapsing into "never asked".

Phase two asks the feed of **the identity that produced the finding**
(`subjectModId`), which for a mixed folder is frequently not its primary — groups
refine one mod's verdict, and the patch's grouping says nothing about the base mod's
files. The result is re-**folded** rather than patched in: if the groups withdraw the
finding the folder was reporting, the folder falls back to what its other identity
said.

**Cost, measured against a real 17-mod library** (16 distinct mod ids, all
tracked): **five requests, 226 ms** warm — one `Mod/Multi` plus one release feed
for each of four mods flagged by phase one. A cold first run of phase one alone
was 982 ms. There is no progress
UI and none is warranted; the button shows a spinner and disables while it runs.
Injecting one dead mod id into that same library — the wrong-paste case — cost
**9 requests and 1490 ms**, and every other mod still got a real verdict where
without the halving all seventeen would have been reported unreachable.

That library also shows what the verdicts look like on real data: 15 up to date,
0 confirmed updates, and **2 `possiblyOutdated`** — the two described in
[§3](#where-this-stops-and-why-it-stops-there). Neither reads as "an update is
available", which is
the distinction the two outcomes exist to make. Four mods flagged before the
release-group and same-version suppressions and two after, which is the whole
argument for phase two.

**The records it fetched come back with the verdicts**, in
`BulkUpdateCheckOutcome.records`, and that is what lets the results screen double as
the bulk **resolution** screen
([`origin-tracking.md` §7](origin-tracking.md#7-the-bulk-resolution-pass)). Every
question resolution asks — which file of this mod do you have, is this really your
mod, is the page gone — is answered by the same response the verdicts came from. So
folding the two together costs no request, and the two halves of one screen cannot
describe different states of the same mod page.

**Scope: the whole library, not the current view.** This is a deliberate
departure from where the bulk "assume current" action gets its list
([`origin-tracking.md` §6](origin-tracking.md#6-assume-current-in-bulk)). Both
follow the same rule — *a bulk control must act on the set the user can see* —
but the stake differs. "Assume current" rewrites sidecars, so acting past the
edge of the grid changes mods the user never enumerated. A check writes nothing;
its only effect is badges, and badges are drawn on every character tab, so
scoping it to one would leave the rest looking checked-and-clean.

### 5.1 Checking at startup

`update_check_on_launch` (`docs/configuration.md`), surfaced in the Settings
tab's **Updates** section and **off by default**. Turned on, the same pass above
runs once per session as soon as the library has been scanned.

**Off by default is what keeps the rule above true.** "No network on launch" is
not softened for anyone who has not asked; it is opted out of, by someone who
read a switch that says so. The setting's description states the cost — it
contacts GameBanana at startup — rather than the benefit, because that is the
half a user might object to.

**It checks; it never installs.** The switch says *check* and never *update*,
and its description says so a second time in a sentence. Applying an update is
not automated in this app at all, and that is a rejected design rather than an
unbuilt one — [`applying-updates.md` §7](applying-updates.md#7-what-is-not-built-and-what-is-refused).
A control a user could read as consenting to automatic installs would be
promising something that does not exist.

Four decisions, all in `services/launch_update_check.dart` (pure) and
`screens/components/launch_update_check_host.dart`:

- **It waits for the library, not for a timer.** The plan is derived from the
  scan `ModsScreen` runs on the way in, so it is empty until that lands — and
  empty forever for a library with no tracked mods. The first plan with
  anything checkable in it is the signal, which is why there is no "has the
  scan finished" condition and no special case for an unconfigured mods path.
- **Once per session, not once per scan.** A favourite, an import, a rename and
  a resolve each rebuild the plan; without the guard an ordinary afternoon
  issues the batch a dozen times. The flag is set *before* the first await, so
  two passes cannot overlap and race their results into one map.
  **The startup moment ends whether or not a check ran**, which is why
  `launchCheckAction` returns three states rather than a bool: `wait`, `close`,
  `run`. Switching the setting on mid-session must not fire a pass on the next
  rescan — the switch says *when the app starts*, and the next start is when it
  takes effect. An **unscanned** library does not close the moment, though, or
  the commonest ordering there is — the host mounts, the scan lands a moment
  later — would skip the check every time.
- **It speaks only when it found updates.** Two silences, and neither is an
  oversight. A "nothing new" card on every launch is noise nobody asked for,
  and the badges carry that answer anyway. A "couldn't reach N mods" card on
  every offline start is what gets the setting switched off — and it does not
  break §5's rule that *"no updates"* and *"no updates among the mods we could
  reach"* are different statements, because a silent pass asserts **neither**.
  The manual check is still the loud one and is one click away. A pass that
  found updates *and* failed reports the updates: that is the actionable half.
  The card's body says the check happened *at startup*, since a notification
  nobody pressed for has to explain its own presence.
- **It never opens the resolution screen.** The manual check does when there is
  something to sort out ([§6](#the-results-screen)); a modal thrown over an app
  the user has just opened is exactly the interruption that arrangement exists
  to avoid. The screen stays reachable from *Sort out mod tracking…*, which
  rebuilds from the records this pass leaves behind and therefore costs no
  second request.

**It is hosted above the tab switcher**, beside `DownloadQueueHost`, because
nobody pressed anything to start it and it outlives whatever the user does
next. `ModsToolbar` — which owns the manual check — is inside the Mods tab, and
the tabs are keyed `AnimatedSwitcher` children with no keep-alive, so a pass
owned by it dies the moment the user looks at the marketplace. Unlike the
download host it raises no dialog, so it does not need to sit below the
`Navigator`.

**Both surfaces run the same code.** `services/update_check_run.dart` holds the
request (including the cache bypass, for the reason the marketplace's refresh
button has one) and the merge rule — *merge, never replace*, since a per-mod
check the user ran on a mod this pass could not reach is still the best answer
available for it. Two copies of that would be wrong in a way nobody notices.

---

## 6. Where a result lives, and what it looks like

**Session-scoped and deliberately not persisted.** A verdict restored from disk
would be an assertion about a mod page nobody has looked at since, on a surface
whose whole job is to say what is true now. Emptying on restart costs one press
and cannot be stale — and for anyone who has turned on
[§5.1](#51-checking-at-startup) it costs not even that, since the badges are
filled in by a fresh pass rather than by a remembered one. That is the fix for
"the feature looks off until you find the button", and it is the *only*
acceptable one: caching the verdict would buy the same appearance by asserting
something nobody has checked. It is keyed by mod folder id, which is also the rename key —
so renaming a mod orphans its verdict until the next check, which is the correct
way round.

### The card

The library card's status slot renders **one** state, and `modSlotStatus()` folds
the origin block and the verdict together so precedence is a single decision in a
single place. An update beats every origin state: the two overlap exactly where
it matters (a mod tracked by date only can be flagged possibly-outdated, a mod
with no recorded version can still be identified by a banked hash), and "something
newer is published" is the newer and more actionable fact. The origin state it
replaces is one click away in the same dialog.

Blue, at the same weight as the amber "needs attention" mark rather than louder —
the card has no room above amber, and two filled pills differing only in
intensity read as one state rendered twice. `isGuess` changes the **tooltip**,
not the mark: a card has one badge, and splitting it into "definitely" and
"probably" would spend the library's whole visual budget on a distinction a
sentence can make.

`tracking: "off"` and `remote_missing` still silence the slot. The check cannot
produce a verdict for either, so this is belt and braces — but the promise
attached to "not from GameBanana / it's my own" is permanence.

The "needs attention" filter deliberately does **not** count updates. It answers
"what have I not dealt with", which is a property of the sidecar; folding in a
network result would make its count change whenever a check ran.

### The results screen

A whole-library check reports through **one** of two surfaces, and which one is
decided by whether the pass turned up anything the user could act on beyond the
badges:

| the pass found | shows |
|---|---|
| nothing to resolve | the summary as a notification |
| mods whose origin can be sorted out | the results screen, which states the summary itself |

On a fully sorted-out library a modal would stand between the user and the badges
they pressed the button to see; when there are questions, raising a notification
*behind* the dialog would be two reports of one press, which is how a user ends up
reading neither.

**Auto-opening is not the only way in**, and that is the fix for the complaint this
arrangement first produced: a screen reachable only as a side effect of a check can
be seen once and, if dismissed, not again. *Sort out mod tracking…* in the library
menu below reopens it from the records the check left behind.

The screen itself belongs to origin tracking rather than to this document, because
what it writes is origin data:
[`origin-tracking.md` §7](origin-tracking.md#7-the-bulk-resolution-pass).

### Where the controls live

The Mods toolbar is **two rows: search plus a library menu, then every filter.**
The split is what this feature needs rather than a tidy-up: with actions and
filters interleaved the results screen above has no home, so it can only be seen
as a side effect of pressing a filter toggle, and dismissing it means it is gone
until the next check.

**The library menu holds the three things you can do to the whole library**:
*Check for updates*, *Sort out mod tracking…* and *Mark all as current*. Each row
carries the number of mods it would act on, and is disabled when it can do
nothing — a disabled entry reading `0` says why, where a hidden one looks like a
missing feature. The menu's badge counts what *Sort out mod tracking* would open,
the only one of the three whose work is otherwise invisible.

*Sort out mod tracking* is the **exception to that, deliberately**: it is offered
at zero, because with nothing in hand it **runs a check first**, which is the
request it would have taken anyway. Greying it out until a check had run would
make the menu's most useful item the one disabled on launch. With records already
fetched it costs nothing, because they are session state
([`origin-tracking.md` §7](origin-tracking.md#7-the-bulk-resolution-pass)).

**The `↑` toggle is now only a filter.** A badge on a card is spatial — across
128 mods, three marks are something you hunt for — so the count filters the grid
to what the last check found. It used to run the check as well, on the reasoning
that a seventh control was too many; the trade never paid. Re-checking took three
clicks (turn the filter on, find *check again* in a row that only exists while a
filter is on, turn it off), and the screen the check produced could not be
re-opened at all. Checking is an action; it belongs with the other actions.

**Two scopes still meet here, deliberately.** The *check* covers the whole
library, because its badges are drawn on every character tab. The *filter* covers
the current view, because that is all it can narrow. So updates on other
character tabs are reachable from the "All" view, not from a tab with none of its
own.

Two properties of the filter, both of which had to be built rather than falling
out:

- **It switches itself off when the library runs out of updates.** Ignoring the
  last flagged mod would otherwise leave the grid filtered to nothing, with a
  control the user has to work out they need to press.
  That is keyed on the **library**, not on the view-scoped count beside it. On
  the view count it would fire merely because the user clicked a character tab
  with no updates of its own, and the filter would evaporate whenever they
  looked somewhere else. So on such a tab the grid *is* empty, the filter stands,
  and the control stays rendered to be switched off by hand.
- **It ANDs with the other filters**, like everything else here. Combining it
  with "needs attention" usually empties the grid, because a mod with no
  recorded version usually has no update either — the exception being one
  identified by a banked archive hash. `Clear filters` sits at the end of the
  filter row and resets this along with the rest.

### The dialog

One dialog serves both entry points — the context menu's "check for updates",
which arrives with nothing on record, and the card's blue badge, which arrives
with a verdict from the last pass. The only difference is whether a request is
made on open, so they are not two dialogs.

**A per-mod check asks `Mod/Multi` for one id, not `Mod/<id>/ProfilePage`** —
`fetchModRecord` in `update_check_run.dart`, with the same `updateCheckProperties`
the whole-library pass sends. That the two paths share one property list is the
point rather than a tidiness win: the comparator reads six fields off a `GbMod`,
and a list that drifted would let the card badge and the dialog give one mod two
different verdicts, with neither surface looking wrong on its own. It is also a
quarter of the bytes — measured live, 7.7 KB against 31 KB for one mod and 11 KB
against 48 KB for one with a long description — because a profile carries a
gallery, HTML prose, credits, licence text and requirements that no comparator can
use.

**`Mod/<id>/DownloadPage` is cheaper on paper and cannot serve this**, which is
worth stating because it is the obvious choice. It returns the two file lists plus
`_bIsTrashed` / `_bIsWithheld` and nothing else, so four of the six fields are
missing or partial: without `_tsDateAdded` and `_tsDateUpdated` a date-only
verdict ([§3](#when-only-a-date-is-known)) loses both its sanity floor and its last
fallback, which makes it *wrong* rather than quieter; `_bIsObsolete` silently
leaves every verdict; and `_bIsPrivate` is one of the three flags `remote_missing`
reads. `Mod/Multi` is smaller than it anyway — 7.7 KB against 8.1 KB — since it
sends no licence or submitter instructions.

**A folder holding two downloads gets a full report each.** Not a verdict plus a
summary of the other one: a check is about *the mods in a folder*, both are in scope,
so both get the whole treatment — headline, the before-and-after box, the file list
where there is a choice, the author's notes, and their own Ignore and Update. A
section per download, separated by a rule, ordered mod then patch.

Anything less answers a different question for the second mod than it answered for
the first. Before this, a download was named at all only when it **won** the fold, so
a folder holding a patch and reported *up to date* said nothing about the patch —
indistinguishable from a folder holding one mod.

Three things this rests on:

- **`UpdateCheck.layers` holds every layer's own verdict, the winner included.**
  Under the shape this replaced, the fold discarded exactly one — the primary's —
  so the single folder whose *patch* had the update was the one that could say
  nothing about the mod it patched, and a `folderOwn` field existed to carry it
  back. A stack has no privileged entry, so the field is gone and the section list
  is a plain lookup.
- **Everything per-download is keyed by mod id** — the release feed, whether its
  accordion is open, which file the user picked. One shared "chosen file" would let a
  choice made for the patch install the mod it patches.
- **Actions live in the section, not the action bar.** Two subjects cannot share one
  Update button: it would have to pick a mod on the user's behalf, and picking wrong
  writes another mod's archive over this folder. A **folder with one download is
  untouched** and keeps its buttons where they have always been — introducing
  per-section controls for a single subject would move a button for no reason.

Dismissing from a section re-runs the fold rather than flipping the folder's verdict,
because with two downloads a dismissal changes which one wins: waving away the
patch's update on a folder whose mod also has one must leave the mod's finding
standing.

**Sections are in stack order, bottom-most first** — the order the files themselves
go on disk, and the same order the details and resolve dialogs list them in
([`origin-tracking.md` §10](origin-tracking.md#where-it-is-shown), whose patch
marker this shares). No ranking is applied and none is needed: a stack records the
order, so nothing here has to work out which download is which.

**One id per request, not one request per folder.** A batch is all-or-nothing, so
folding one layer's id in with another's would let a layer whose page has been
deleted fail the whole folder's check — where the rule is that an unreachable layer
is left out and the folder is simply not called clean
([§2](#a-folder-with-two-identities-still-gets-one-verdict)). Recovering inside a
batch is the halving the bulk pass does, and it is not worth it for the two or
three ids a folder has.

It states both sides of the comparison as a **filename with the author's own
words underneath** — `v74.zip` over a greyed `7.4 · Main file`, against `v77.zip`
over `7.7 · Main file`. Those two rows sit directly above one another and are
frequently the same variant, so the version has to be there or the before and
after render identically with the date as the only difference.

That naming rule is shared by every surface that shows a file — see
[§7](#7-how-a-file-is-named).

**The "Update" button is the primary action, and it is the only control in this
feature that touches a live install.** It downloads the file the list marks and
writes it over the mod folder — see
[`applying-updates.md`](applying-updates.md) for the mechanism, the snapshot and
what the confirmation must say before any of it happens.

Two rules about *when* it appears, and both are about not guessing on the user's
behalf:

- **Only where a file could actually be named.** With the installed file gone
  from the page and nothing identifiably its successor, the check reports the
  finding and names nothing; the honest offer there is the mod page, not a guess
  installed over a live mod.
- **An ignored update is still installable.** The user waved the badge away, not
  the file, and this dialog is where they come to change their mind.

With several candidates the rows are **tappable** and the selection decides what
gets installed. The chip on the chosen row then says `your choice` rather than
`matches your variant` or `newest published` — those are the app's grounds for
its own pick, and reusing them for the user's would be taking credit for a
decision it did not make.

The marketplace shortcut stays beside it, demoted from the primary action: it
installs a *second* mod folder alongside this one, which is occasionally what
someone wants and is now clearly the other option rather than the only one.

**There is no "check again", and a retry appears only after a failure.** The
dialog has two entry points and neither leaves anything to press: arriving from
a card badge the bulk pass has just answered, so re-asking spends a request to
redraw the same sentence; arriving with nothing on record it checks on the way
in. A check that *failed* is the one state where pressing something helps, and
without it the only way back is closing and reopening — so the retry sits
**inline with the error message**, not in the action bar, which already carries
up to three buttons in every other state.

That retry bypasses the client's response cache, for the reason the
marketplace's refresh button does: a re-check answerable from a ten-minute-old
copy is a control that sometimes cannot do its one job, with no way for the user
to tell which press was which. Re-checking the whole library, cache and all, is
the toolbar button's job.

**"Ignore this update" and its undo live here**, and the dialog is the only
place either appears — ignoring from the card would mean dismissing something
the user has not read. It writes to the sidecar, so the dialog reports back
whether it wrote anything and the mods screen rescans on the way out; the status
slot is drawn from `ModInfo.origin`, which only a scan re-reads. See
[§4](#4-dismissing-an-update) for what it stores and why it is a date.

The label is worth guarding. It was "Not now", which reads as a deferral, and
this is not one: it is permanent until the author publishes something newer.

**The flag is flipped on the verdict already in hand, never re-derived from a
mod page**, and that is the fix for a bug worth remembering rather than an
implementation detail. Opened from a card badge this dialog fetches nothing —
the bulk pass already answered — so re-folding produced null, and a write that
had *succeeded* left the dialog, the card badge and the toolbar count all
showing the pre-dismissal state. The button looked dead. Nothing threw, and the
only test covering the button used the other entry point, where a fetched record
happens to be in hand.

The dialog also names **the release** a candidate shipped in (`Version 1.5`),
taken from the update post's `_sName`. Very often that is the only real version
number a mod page has, since `_sVersion` on the files themselves is routinely
null.

**Release notes — what the author says changed — are shown for releases published
after the file you have.** Two shapes, and they are complementary rather than
alternatives: `_aChangeLog` is a categorised bullet list and `_sText` is prose,
and captured feeds carry each without the other. The prose is HTML and goes
through the same `htmlToMarkdown` a mod page's description does.

`_aChangeLog` is **the one object in this API whose keys are not
Hungarian-prefixed** — bare `text` and `cat`, not `_sText` / `_sCat`. Reading them
the usual way yields an empty changelog for every mod, silently; that is exactly
how the `_aTags` two-shape bug went unnoticed, so it is pinned by a fixture test.

They live in a **collapsible section, closed by default**, whose header doubles
as the divider. Dropped into the middle of the dialog with no boundary and no way
to put them away, an author's three paragraphs push the verdict off the top of a
scroll view nobody asked to grow.

The notes are **fetched on demand when that section is first opened**, so
expanding it is also what fetches and one gesture does both — there is
deliberately no separate "show notes" button that then turns into a heading. It
matters on the card-badge path, which otherwise makes no request at all: the
bulk pass has already answered, and spending one on every badge click to render
a changelog nobody asked for is the cost that path exists to avoid. When the
dialog *did* check on the way in, the feed was already fetched for
[`ReleaseGroups`](#where-this-stops-and-why-it-stops-there) and opening the
section costs nothing.

Scoping them to releases newer than the installed file is the point: a mod with
forty update posts is not offering to tell you about all of them, it is offering
to tell you what you would be getting. With no date to compare against — an
`assumed_latest` install, or a page whose files carry none — the whole feed is
shown rather than nothing.

### One file gets a line; several get a list

When more than one file has been published since the installed one, the dialog
shows **all of them**, newest first, instead of naming the winner. That is not a
courtesy — it is the honest shape for the mods this feature actually meets. A
ZZZ mod routinely ships an SFW and an NSFW build in one release, and the choice
the check has to make is exactly the one the *user* is best placed to make: they
know which variant they installed and why.

The row the check would pick carries a chip saying **on what grounds**, and the
two grounds are very different:

- **`matches your variant`** — a real match on the author's own label
  (`SFW Variants Only` → `SFW Variants Only`). This beats recency: where a mod
  publishes an SFW and an NSFW build minutes apart, the SFW successor is marked
  even though the NSFW file is newer.
- **`newest published`** — the fallback, used when labels drift between
  releases. It may well be somebody else's variant. Rendering the two
  identically would hide precisely the case that needs a human.

`UpdateCheck.newerFiles` carries the list and is already filtered by every
suppression, so a co-released sibling or a file stamped with the installed
version never appears in it. On the `assumed_latest` path every file published
since the baseline is listed and none is marked, because nothing there knows
which file is installed.

Two behaviours worth knowing, both pinned by tests:

- **An old ignore never carries forward.** Having ignored the previous NSFW
  build does not silence the next release, because the dismissal is a date.
- **A superseded install with no matching successor names nothing.** The verdict
  is still `updateAvailable` — the installed file is archived, which is a fact —
  but the candidate is null and the list is the answer.

**The rows are informational; downloading still happens in the marketplace.**
Reusing `GbFileList` with its per-row download buttons would mean reaching the
install pipeline, which lives in `marketplace_screen` and is not extracted —
filed rather than done, and the reason the "view in marketplace" button is the
action here.

### The other mods from the same archive

One archive can have installed several mods, and pressing Update covers all of
them from a single download — that write and its rules are
[`applying-updates.md` §4](applying-updates.md#one-archive-several-mods-one-download).
What belongs *here* is the one line this dialog carries about it: *"2 other mods
came from the same archive as this one. Updating will offer them too."*

**It promises nothing about those mods**, and cannot. Whether each one's folder
still matches this archive is a question about the archive, which is not
downloaded yet — so the offer belongs to the confirmation, which is the first
screen that can answer it. What this line *can* say exactly is who is in the
group and who already holds the file being installed, because both are on record.

The count is screened on the same rule the confirmation uses, offline: a matching
`ingest.sibling_group`, a stack that puts this download at the bottom, and a
recorded file id that is not already this one. Sharing that screening is
deliberate — a mod named here and then missing from the next screen would read as
the app having lost it. Members the confirmation will offer *unticked* are still
counted, because "offer" is all this line claims.

**Two gates keep it free, both about not paying for a folder walk over the whole
library.** No sibling group is the case for every mod that predates the origin
block, so the field being absent ends it rather than starting a scan — and no
finding means there is no Update button for the line to sit beside, so an
up-to-date mod that *is* in a group does not pay for it either. The library
is read when the dialog opens rather than off a provider, for the reason in
[`../mod_manager_flutter/CLAUDE.md`](../mod_manager_flutter/CLAUDE.md)'s State
section: the Mods tab owns the cached list and is disposed while another tab is
up, so a mod the marketplace installed a moment ago would be missing from a group
it belongs to.

---

## 7. How a file is named

Every surface that lists a GameBanana file — the marketplace detail view, the
resolve dialog's picker, the update dialog's comparison and its options list —
names it the same way, from two pure helpers in
`services/gamebanana/file_selection.dart`:

```
v77.zip                                     ← fileDisplayName: the filename
7.7 · Main file · uploaded 2026-06-19       ← fileDisplayDetail plus the date, greyed
```

**The upload date joins the greyed line rather than the title.** It used to be
appended to the filename with a dash, and `v77.zip — 2026-06-19` reads as a file
called that. It is a fact *about* the file, the same kind as its version, and on the
rows where the author's labels are identical — which is the common shape of an
update — it is the only thing telling the two apart, so it has to be legible as a
date rather than as a suffix.

**The title is the filename, and this reverses an earlier decision.** It used to
lead with `_sDescription`, on the reasoning that the description is what
distinguishes rows in practice — which it often is. But that field is free text,
not a name. A real captured file describes itself as *"Put it in the folder with
the mod (replace it)"*: an instruction, standing where the file's identity
should be, with the filename — the thing actually downloaded, and the only field
guaranteed to exist beside the id — nowhere on screen at all.

So the filename leads, and the author's words go on a greyed line beneath it.
Three rules follow:

- **`fileDisplayDetail` returns null when the author said nothing**, so the
  caller draws no second line rather than an empty one.
- **The version joins the detail, never the title.** `_sVersion` is a free-form
  author string; it identifies a *release*, not a file, and it is routinely
  absent.
- **Neither is ever presented as a version.** `_sDescription` may be `Main
  file`, `white hair ver` or `v3.4`, and the app cannot tell which — the whole
  reason [§1](#1-why-this-is-a-suggestion-system) exists.

The cost, since it is real: a row is three lines rather than two, so fewer fit
the resolve dialog's height-bounded picker and more of it scrolls. That is the
trade that dialog already makes explicitly — anything new in it is paid for by
the list that scrolls, never by the escape hatches beneath, which have nowhere
to go.
