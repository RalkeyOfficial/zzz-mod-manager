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
> [`applying-updates.md`](applying-updates.md). An earlier version of this line
> said it would want a section here rather than a second doc; that was wrong on
> this directory's own rule, which is that the scope line decides. Nothing in the
> applying half is about *turning identity into a verdict*: it is filesystem
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
| `indeterminate` | The response carried no current file list. **Silence is not evidence**: concluding "nothing newer" from a question never asked is the one way this fails invisibly. |

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

---

## 3. How the comparison actually works

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

Four rules:

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
when pressed** — no network on launch, ever.

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
first turns a network failure into false reassurance across a whole library.

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

**Scope: the whole library, not the current view.** This is a deliberate
departure from where the bulk "assume current" action gets its list
([`origin-tracking.md` §6](origin-tracking.md#6-assume-current-in-bulk)). Both
follow the same rule — *a bulk control must act on the set the user can see* —
but the stake differs. "Assume current" rewrites sidecars, so acting past the
edge of the grid changes mods the user never enumerated. A check writes nothing;
its only effect is badges, and badges are drawn on every character tab, so
scoping it to one would leave the rest looking checked-and-clean.

---

## 6. Where a result lives, and what it looks like

**Session-scoped and deliberately not persisted.** A verdict restored from disk
would be an assertion about a mod page nobody has looked at since, on a surface
whose whole job is to say what is true now. Emptying on restart costs one press
and cannot be stale. It is keyed by mod folder id, which is also the rename key —
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

### The toolbar button does two jobs

A badge on a card is spatial: across 128 mods, three marks are something you
hunt for. So the same control that runs the check also **filters the grid to
what it found**, and which job it does is decided by whether there is anything
to show:

| state | shows | pressing it |
|---|---|---|
| nothing found, or not checked yet | a bare icon | runs the check |
| *n* found in this view | a count | filters the grid to them |

A separate filter toggle beside it was the obvious design and was rejected —
this toolbar already carries six controls, and a seventh that means nothing
until a check has run is a permanent cost for an occasional state. What keeps
the overload legible is that **the control does the only useful thing
available**: with no findings, checking is all there is to do; with findings,
seeing them is. The count is the visible signal for which mode it is in, so
nothing about it is hidden state — and because results are session-scoped, every
launch starts in check mode.

The cost, stated plainly: re-checking once results exist means turning the
filter on, pressing **check again** in the row below, and turning it off. That
row is where the bulk "assume current" button already lives, and for the same
reason — a secondary action that only makes sense while a particular filter is
on.

**Two scopes meet in that one button, and they differ deliberately.** The
*check* covers the whole library, because its badges are drawn on every
character tab. The *filter* covers the current view, because that is all it can
narrow. So on a tab whose mods are all current, the button falls back to check
mode — the same rule applied, not an exception to it. The consequence worth
knowing: updates on other character tabs are reachable from the "All" view, not
from a tab that has none of its own.

Two more properties, both of which had to be built rather than falling out:

- **The filter switches itself off when the library runs out of updates.**
  Ignoring the last flagged mod would otherwise leave the grid filtered to
  nothing, with a control the user has to work out they need to press — the same
  "the reward for pressing the button is an empty grid" the bulk "assume
  current" action already avoids.
  That is keyed on the **library**, not on the view-scoped count beside it. On
  the view count it would fire merely because the user clicked a character tab
  with no updates of its own, and the filter would evaporate whenever they
  looked somewhere else. So on such a tab the grid *is* empty, the filter stands,
  and the control stays rendered to be switched off by hand.
- **It ANDs with the other filters**, like everything else here. Combining it
  with "needs attention" usually empties the grid, because a mod with no
  recorded version usually has no update either — the exception being one
  identified by a banked archive hash. `Clear filters` is the way out, and it
  resets this filter along with the rest.

### The dialog

One dialog serves both entry points — the context menu's "check for updates",
which arrives with nothing on record, and the card's blue badge, which arrives
with a verdict from the last pass. The only difference is whether a request is
made on open, so they are not two dialogs.

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
only test covering the button used the other entry point, where a profile
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
as the divider — an earlier version dropped them into the middle of the dialog
with no boundary and no way to put them away, so an author's three paragraphs
pushed the verdict off the top of a scroll view nobody had asked to grow.

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

---

## 7. How a file is named

Every surface that lists a GameBanana file — the marketplace detail view, the
resolve dialog's picker, the update dialog's comparison and its options list —
names it the same way, from two pure helpers in
`services/gamebanana/file_selection.dart`:

```
v77.zip                     ← fileDisplayName: the filename
7.7 · Main file             ← fileDisplayDetail: version · description, greyed
2026-06-19                  ← the row's own metadata
```

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
