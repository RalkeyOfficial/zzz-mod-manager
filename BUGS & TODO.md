# BUGS & TODO

Planning + backlog for the mod-downloading / marketplace / update overhaul.
This is a **pre-planning document** — it captures *what* we want to build and the
decisions made so far, not *how* to implement it. Items are grouped by area.

> **This file is temporary.** As each area ships, its schema details and rationale
> move into [`docs/`](docs/README.md), and the section here shrinks to a pointer.
> Don't let this document become the only written explanation of anything.

> **A checkbox means work.** `- [ ]` is something someone could pick up and do;
> `- [x]` is that same thing, done. Everything else — a locked decision, a
> measured fact about the API, a schema the code already implements, a design
> that was considered and refused — is a **plain bullet**, because a checkbox
> next to it is a promise nobody intends to keep and it buries the handful of
> entries that are real. Recording a finding is not the same as filing a task:
> if there is no action, do not give it a box.

---

## Locked decisions

- **Origin data is confidence-tiered, and "unknown" is a real state — not a
  migration to be finished.** Mods that predate the origin block (the whole
  existing library) and every future manual import carry no origin data, so the
  model gets an explicit unknown tier, a visible status, and a resolution flow
  that stays in the UI permanently. Fully planned in **§7**.
- **Marketplace = native GameBanana browser (not a webview).** One shared
  implementation for Linux and Windows. Motivation: minimal platform difference
  and easy in-app integration. Rejected alternatives: `desktop_webview_window`
  (separate popup window, weak download interception) and `webview_cef` (embeds
  but ships ~150MB+ of Chromium).

### Guiding principles

- **Scope the browser narrowly.** Two screens only — a results grid (search +
  filter → mod cards) and a mod detail view (images, description, file list →
  download). Filtered to ZZZ (GameBanana game `19567`). All mod categories
  (skins, UI, effects, …) share the same card + detail + download flow, so
  supporting them is nearly free. Out of scope: forums, threads, member pages,
  comments, non-ZZZ content — provide an **"open in browser"** escape hatch for
  those.
- **Update detection is heuristic / best-effort**, never presented as exact.
  Prioritise the mod's **version string** when available, combined with the
  **file/version label** (e.g. "white hair ver") to distinguish variants. When no
  version string exists, fall back to upload date / file hash. It's a *suggestion*
  system, not a guarantee.
- **Destructive paths require exact knowledge; guesses may only inform.** Every
  piece of origin data carries a confidence (§7.2). Anything short of `exact` can
  suggest, badge, and prompt; only `exact` lets the app stop hedging about which
  file is installed.
- **No update is applied without the user present.** Automatic updating is
  **refused**, not deferred — see §4. *Checking* is a different act and is
  automatable, opt-in and off by default. Confidence is not a licence for the
  first: `exact` is a claim about which remote file this is, and says nothing
  about what the mod folder holds, which is where every hazard of applying an
  update lives.
- **An update overwrites, it never replaces.** New files are copied *over* the mod
  folder; the folder is never emptied, moved or deleted. A mod folder frequently
  holds files from a second download — a *patch mod*, or a hand-merge — and
  replacing the folder destroys them. In the common case it destroys the mod
  itself: see §4.1, which is the whole reasoning.
- **An update always snapshots first, and never tries to reconstruct local
  edits.** Users rebind keybinds inside mod folders, and an update that ships the
  same `.ini` reverts them. That is **accepted loss**, recovered from the snapshot
  (§4.2) — nothing re-applies it automatically. Re-applying was considered and
  **rejected** in §4, recorded there so it isn't proposed again as an obvious
  kindness.

---

## Roadmap (prioritized)

The section numbers below (§1–§6) group work by *area*; this roadmap groups the
same work by *when it lands*. Dependency order is largely forced: the API layer
(§2) and origin model (§3) are roots, the download manager (§5) turns finds into
files, the browser (§1) sits on top, and updating (§4) is the payoff that needs
all of them. Decision: **ship a thin vertical slice first** (see M1), then thicken.

Each milestone's design rules live in the doc that owns the area — the table in
[`CLAUDE.md`](CLAUDE.md) says which.

### M1 — Thin vertical slice (both platforms)

**Shipped**: the API client over an injectable transport, the download service
(resume, stall timeout, backpressure), the origin block's write side, the offline
backfill, the native browser's two screens, and the content filter.

**Code-complete on Linux**, verified end to end against the live API. **Not
verified on Windows** — there is no Windows machine in this environment. The
implementation is shared with no platform branch (junction-vs-symlink and
`openUrlInBrowser` go through `PlatformService`), so the risk is low, but the exit
criterion names both.

### M2 — Smart installs (read the origin block)

**Shipped**: the pure read model behind the badges, metadata autofill on install,
"already installed" on every marketplace surface, the mod card's status slot, the
per-mod resolve dialog, and the zero-network "assume current" baseline.

### M3 — Updating

**Shipped**: the update check (per-mod and whole-library over `Mod/Multi`),
applying an update with its unconditional snapshot, and the bulk results screen
that doubles as the bulk resolution surface.

**Code-complete on Linux.** **Not verified on Windows**, and it matters more here
than in M1: §4.1's busy-file path exists *because* ZZMI holds handles on Windows,
and it has never been hit.

### M4 — Robustness & polish

**Shipped**: the download queue with its panel and pinned progress, the opt-in
update check on launch, the Settings sections for both, and the marketplace's
error and empty states.

**The queue has never been exercised against the live API**, and that is the gap:
two large archives arriving while the user browses, and an install running while a
second transfer is still coming in.

### Later — backlog

Everything under "Additional feature ideas" (paste-URL install, wishlist, feeds,
profiles, conflict detection, storage view). Pull items forward as they earn
priority.

---

## 1. Marketplace — native GameBanana browser

**Shipped.** [`docs/marketplace.md`](docs/marketplace.md) owns the grid, the
detail view, the carousel, the content filter and the error/empty states;
[`docs/gamebanana-api.md`](docs/gamebanana-api.md) owns the protocol facts they
rest on, including why a multi-file download button never defaults.

## 2. GameBanana API layer (the keystone)

**Shipped.** The protocol — endpoints, filters, sorts, field meanings, the
category tree and the gotchas — is
[`docs/gamebanana-api.md`](docs/gamebanana-api.md). Our client is
[`docs/app-architecture.md`](docs/app-architecture.md) §4, including the rule that
keeps it small: **one method per endpoint, and no method that isn't an endpoint.**

There is no `/apidocs` page; the surface is discoverable only by probing, which is
one more reason to keep the client tiny.

## 3. Mod metadata & origin model

**Shipped.** The origin block's fields are
[`docs/metadata-schema.md`](docs/metadata-schema.md) — including the rule that a
sidecar is untrusted input, so an inbound `origin` is dropped on any ingest we did
not download ourselves. What each confidence tier means and who may write it is
[`docs/origin-tracking.md`](docs/origin-tracking.md); what an install copies from a
mod page is [`docs/metadata-autofill.md`](docs/metadata-autofill.md).

### Open around the read side (known, deliberately not built)

- [ ] **Nothing keeps the library list live across a tab switch, and the third
  reader of it arrived as a bug.** `ModsScreen` is a keyed child of an
  `AnimatedSwitcher` with no keep-alive, so it is disposed on every tab change
  and `initState` re-scans on the way back. `charactersProvider` — which only
  that screen writes — therefore holds whatever the last visit to the Mods tab
  produced, while `modsProvider` derives from it. The read side works around
  that with its own snapshot, invalidated when the marketplace opens; the patch
  destination prompt did not, so it offered a patch every mod **except** the
  ones installed since that visit, including the base just installed for it.
  Fixed where it bit, by reading the library off disk at the prompt. What the
  fix does not do is stop the next reader making the same assumption, which is
  what inverting the ownership below would.

### Open around metadata autofill (known, deliberately not built)

- **A truncated gallery doesn't say it was truncated**, and on inspection that is
  a feature request rather than a gap — unboxed on those grounds.
  `RemoteModMetadata.maxImages` is 10 and real galleries reach 26+, so a mod can
  arrive with 10 of its 26 screenshots. The cap is deliberate and argued
  (`metadata_autofill.dart`): a real library's hand-built galleries run 1–7
  images, so copying a 26-shot marketing gallery into every folder is clutter.
  Saying "10 of 26" needs the total threaded through `RemoteModMetadata` and into
  the **sidecar** — a `metadata-schema.md` change — to still be sayable when the
  user later looks at the mod. That is a schema field to disclose a deliberate
  cap, on data the mod page shows in full one click away. If it is ever wanted,
  the cheaper half is the edit dialog offering to re-fetch the gallery, which
  needs no stored count.
- **The install-summary merge rests on an unasserted invariant.**
  `autoTags.addAll(fill.characterTags)` in `_installArchive` is correct only because
  the two maps are disjoint by construction — the autofill assigns a character solely
  when none is set, so folder-name detection and category detection can never both
  claim one mod. Nothing pins that. If the category is ever allowed to *override* a
  name match, the summary would report the category's answer while the sidecar keeps
  the name's, and the two would disagree silently. The wiring has no widget test
  either — `test/support/temp_library.dart` installs the library one would need,
  so this is a gap rather than a blocker — which is why the invariant is worth
  writing down.

## 4. Mod updating

**Shipped**, and two docs own it between them:
[`docs/update-checks.md`](docs/update-checks.md) turns *which remote file is this*
into *is there a newer one*, and
[`docs/applying-updates.md`](docs/applying-updates.md) writes it over a live
install. They meet at exactly one point, the Update button.

Two things are **refused rather than unbuilt**, both recorded in
`applying-updates.md` §7 so they aren't re-proposed:

- **Opt-in auto-update.** The confidence model reads like a runway towards it and
  is not one. `exact` on both axes is a strong claim about *which remote file this
  is*; it says nothing about what the folder holds, which is where every hazard in
  §4.1 lives — a byte-perfect identification of the right successor still
  overwrites a hand-merged second mod. The snapshot is not a mitigation either:
  none of the accepted losses announce themselves, so a recovery nobody knows to
  reach for is no substitute for having seen the change happen. *Checking* is a
  different act and **is** automatable, because it reads a mod page and draws a
  badge; that half shipped as M4's launch check.
- **Preserving user `.ini` edits across an update.** There is no pristine baseline
  to diff against — after install the file is the author's *and* every later change
  to it, with nothing marking which is which — and recording per-`.ini` hashes at
  ingest does not fix it: a hash divergence cannot tell a hand-edited keybind from
  a patch mod applied into the folder from a hand-merge of two mods. The write side
  is worse still, four guesses deep, and a wrong one writes a broken `.ini` where
  the user would have retyped a key in thirty seconds.
  What survives is **read-only**: after an update, list the keybinds parsed out of
  the snapshot ("before this update: Skin = F7"). `IniParserService.parseIniFile`
  already turns a path into `List<KeybindInfo>`, so this is one existing call and a
  list in the post-update summary. Ranked below everything in §4.1; drop it if it
  competes.

### Open around the update check (known, deliberately not built)

- [ ] **"In your library as …" is a dead label.** The opposite direction to the
  refusal above, and the thing actually missing: a mod you already own is named
  on the marketplace card and in the detail view's notice, and neither takes you
  to it. A link to the library entry is useful whether or not anything is out of
  date, needs no check to have run, and is the honest answer to "I already have
  this — what do I do about it?". Wants deciding where it lands the user: the
  Mods tab filtered to that folder, or the folder's own dialog.
- **The batch bisect could ask the error which id was bad.** A
  `NO_SUCH_RECORD` response names the offending id in `_sErrorMessage`
  (`Record Mod.999999999 doesn't exist`), so a parser could drop it and retry
  once instead of halving. Not taken because it trades a structural recovery
  for a string-format dependency on server English, and the message names only
  the *first* bad id anyway — several dead ids would still need several round
  trips. Revisit only if the request count is ever measured as a problem.
- [ ] **`_buildGroups` still owns the scan, and the flat list is derived from
  it.** `modsProvider` is a derived `Provider` over `charactersProvider`, which is
  the *opposite* direction to the tidier shape: scan into a flat list, derive the
  character groups. Inverting it is what would let the library live outside
  `ModsScreen`'s lifecycle, which is the filed item above ("nothing keeps the
  library list live across a tab switch"). Both are one piece of work whenever it
  is done.
- **`_bHasFiles` on an update record is unreliable** — it reads `false` on a
  record whose `_aFileRowIds` names two files (measured on `549029`). Nothing
  reads it; noted so nothing starts to.

### Open around applying an update (known, deliberately not built)

- [ ] **There is no "update all".** The bulk check finds every mod with something
  newer and the filter lists them, and then each one is a dialog. For the 3-of-128
  case that is fine; for a library that has not been updated in months it is not.
  The prerequisite exists (§7.6 shipped) and this is still not built,
  deliberately: that screen currently only ever rewrites *sidecars*, and an
  "update all" on it would download and overwrite mod folders from the same
  button. The two need visibly different weight before they share a surface —
  and each apply already has its own confirmation, its own snapshot and its own
  stale-`.ini` question, none of which collapses into a checkbox.
- [ ] **Nothing reports a group no folder claims.** Three ways to get one and
  all of them silent: a mod deleted outside the app, a folder duplicated in a
  file manager (both copies carry one uid, and an update to either prunes the
  other's), and a sidecar deleted by hand. Belongs with the disk-usage page
  below, which is where `SnapshotService.totalBytes()` gets its first reader.
- [ ] **Total backup size is not surfaced anywhere.** The rollback dialog shows a
  size per snapshot and there is no whole-library figure. Moved to the disk-usage
  page at the end of this file, which is the screen it belongs on; worth pairing
  there with a "delete all saved versions of this mod" action, which the per-row
  delete currently makes tedious.
- **The retention numbers are not user-configurable**, deliberately for now
  (30 days / 3 per mod / 5 GB). They are the kind of setting that is easy to add
  and hard to remove, and nobody has asked. If they are ever exposed it belongs
  with §6's Settings work, and the age floor has to keep beating the count cap in
  the UI too — a settings screen that presents them as two independent numbers
  would invite exactly the configuration §4.2 argues against.
- **Cancelling at the update confirmation still costs a full re-download.**
  `archiveConsumed` is set once extraction succeeds and the dialog comes after,
  so backing out deletes the archive. Deliberate — the alternative is keeping
  every declined archive in a folder the user does not manage, and the file-size
  tail reaches 1.24 GB — but it is a real cost on a slow connection and nobody has been
  asked whether they would rather keep it. Noted in the code; revisit if
  reported.
- [ ] **The type scale is per-dialog, not app-wide.** The update flow's four
  dialogs read their sizes from the theme (`bodyLarge` 16 / `bodyMedium` 14)
  after a report that everything was too small; the rest of the app still uses
  hardcoded 10–12px literals, so those now look smaller by comparison. **The
  mechanism is the real problem rather than the scope:** `ThemeData` in
  `main.dart` sets no `textTheme`, so Material's default `bodyMedium` of 14 is
  the base and every widget written from here gets it again by default. If 16 is
  genuinely the base it belongs in one `Typography(...).apply(fontSizeDelta: 2)`
  on the theme — which touches every screen at once, so the fixed-height layouts
  (`GbModCard`'s `mainAxisExtent`, the mods toolbar rows that have overflowed
  twice) need measuring at 480px afterwards rather than assuming.
- [ ] **A shader copied to the game root is the one leftover class outside every
  mod folder**, which is a smaller gap than a live stale shader and a harder one.
  Shader overrides are read from the **single** directory `override_directory`
  names (`ShaderFixes`, at the game root) — not recursively, and not per-mod — so
  a `ShaderFixes/` folder inside a mod is not loaded from where the app puts it.
  A standalone mod that wants its own shaders uses `CustomShader` or
  `ShaderRegex`, which are `.ini`-referenced and therefore already covered by the
  reference-based patch and stale rules. What escapes is a shader the user
  hand-copied to the root: nothing records it, no mod folder contains it, and
  removing the mod leaves it applied to the game. Recorded in
  `docs/applying-updates.md` §1. Bounded rather than urgent — no mod in a
  124-`.ini` library ships a `ShaderFixes/` subfolder at all.

### 4.1 How an update is actually applied

**The mechanism is overwrite** — extract to temp, then copy over the live folder.
Never empty it, never move it, never delete it.

A mod folder is often **mixed**: it holds files from two downloads, because a
*patch mod* was applied into it. Patches replace rather than add, so a mixed folder
looks completely ordinary from the outside. Replacing such a folder destroys the
other download, and the common case is worse than losing a fix — the app knows the
folder as *the patch*, so what remains is a lone `.ini` with nothing to apply to.

Everything that follows from that — the patch test, the stale-`.ini` rule, the
layout replay, removing what the last version shipped, replaying one archive into
every mod it installed, and the ordering that is the safety argument — is
[`docs/applying-updates.md`](docs/applying-updates.md).

### 4.2 Backups — where they live

**Shipped.** Snapshots, where they live, retention and rollback are
[`docs/applying-updates.md`](docs/applying-updates.md) §5.

## 5. Download manager

**Shipped.** [`docs/downloads.md`](docs/downloads.md) owns the isolate pump,
resume, the stall timeout, backpressure, `<appData>/downloads` as the single
landing spot, and the background queue.

### Filed while building the queue

- [ ] **There is no preflight free-space check.**
  `InsufficientSpaceException` has existed since M1 and nothing throws it. It
  matters more with a queue than it did with one download at a time: several
  archives now land in `<appData>/downloads` at once, `_nFilesize` gives an
  exact total up front, and running the volume out mid-transfer fails as a
  `DownloadWriteException` whose message says nothing about space. Dart has no
  portable free-space API, so it needs a `PlatformService` method rather than a
  `Platform.isX` branch.
- **A queued download cannot be reordered or paused.** The panel offers
  cancel, retry and dismiss; there is no "start this one first" and no
  pause-and-keep-the-partial, even though the service already supports exactly
  that (`DownloadHandle.cancel()` without `deletePartial` is a pause in
  everything but name, and re-enqueuing resumes). Not built because neither has
  been asked for, and a row three lines tall cannot carry more controls without
  becoming a decision — see `rowAction`.
- **An update decline costs the user their place in the queue.** If the file
  an update wants is already being fetched as a *new install*,
  `downloadFileWithProgress` declines with "already downloading" rather than
  attaching to it. Correct — the archive in flight belongs to somebody else and
  will be consumed by them — but the honest fix is for two intents to be able to
  share one transfer, which needs the archive to be reference-counted rather than
  deleted by whoever finishes first. Rare enough to leave: it needs the same file
  id to be both the newest release of a mod you own and something you are
  installing fresh, at the same moment.
- **Nothing tells the user a background install asked a question.** An
  archive with several top-level folders, or one whose hash is already banked,
  raises a dialog from `DownloadQueueHost` — which is right (it is the only way
  to ask) but arrives over whatever screen they are on, possibly minutes after
  they pressed Download. A quieter shape would park the job in the panel with a
  "needs you" state and let them open it. Not built because the two dialogs are
  the uncommon case and a job that silently waits is worse than one that asks;
  revisit if it reads as an interruption in practice.

## 6. Config / persistence

- Keys for §7: the post-upgrade nudge's dismissed flag, and the remote-lookup
  response cache — the latter should honour the API's own `max-age=600`, and
  probably belongs in app-data rather than config.
  Neither is due yet and both are waiting on their feature rather than on the
  key: the nudge (§7.4) is not built, and the client's ten-minute cache is
  in-memory and per session, so there is no persisted cache to configure.
- Key for §4.2: backup retention (count or age), once a cap is chosen. The cap
  is chosen (30 days / 3 per mod / 5 GB) and is deliberately **not** exposed —
  §4.2's own argument is that presenting the age floor and the count cap as two
  independent numbers invites exactly the configuration it rejects. Kept open
  rather than closed, since "if anyone asks" is still the standing answer.

The settings that *are* surfaced, and what asked for an entry and did not get one,
are [`docs/configuration.md`](docs/configuration.md).

### Filed while surfacing the settings

- [ ] **The auto-tag section has no widget test.**
  `_SettingsScreenState.initState` calls `ApiService.getConfig()`, so mounting
  the whole screen requires a library installed first —
  `test/support/temp_library.dart` provides one, and
  `test/flutter_test_config.dart` makes forgetting it a failure rather than a
  write to the developer's own `<appData>/config.json`. A section extracted to
  `components/settings/` with a writer seam needs neither, which is the cheaper
  shape for a section: `test/settings_sections_test.dart` covers the Updates and
  Marketplace sections on exactly those terms, and the auto-tag section has not
  had the treatment. Its `_buildRequirement` helper is used by nothing else, so
  extracting the section takes the helper with it.
- [ ] **`isLoading` is one flag doing two jobs, and only one of them is safe.**
  It swaps the whole page body, which unmounts the `AnimationLimiter` and makes
  every section replay its staggered entrance. That is correct for the first
  load and wrong for anything else, and nothing in the code says so except a
  comment on the field. A separate first-load flag — or a limiter that is not
  inside the swapped subtree — would make the mistake unavailable rather than
  merely documented.
- [ ] **Dark mode is surfaced but does not persist.**
  `isDarkModeProvider` is a plain `StateProvider` written by its Settings switch
  and by nothing else, so it resets on every launch. `config.json` even carries
  a `theme` key — written by `_saveToFile`, read back by `loadFromFile`, and
  **read by no UI at all**, so the value is round-tripped and then ignored. Not
  folded into §6's work: it is already *surfaced*, which is what §6 was about,
  and persisting it is a separate three-place change plus a decision about what
  `theme` should hold now that it stores `'dark-blue'` rather than a boolean.
- [ ] **Two `allowsUnattendedUpdate` predicates have no reader and now never
  will.** `ModOrigin.allowsUnattendedUpdate` and
  `OriginConfidence.allowsUnattendedUpdate` (`origin_enums.dart`) — with
  auto-update refused (§4) neither guards anything. Deleting them is not a
  drive-by: between them they are the only place the "`exact` on **both** axes"
  rule is written as code, and sixteen assertions across five test files use
  them to pin the tier table — so whoever removes them has to decide where that
  rule lives instead. Left in place with their doc comments corrected to say
  what they express rather than what they were for.

### Filed by §1 (found while building the native browser)

- **We cannot reproduce GameBanana's default ordering, and users will compare.**
  The site defaults to its own "ripe" ranking, which **neither API exposes**: every
  plausible `_sSort` alias is rejected, and the legacy Core API offers only `id`,
  `name`, `udate`. This is not academic: it is how the gap was found. A mod
  submitted in May but updated the same day sat 3rd on the site and **>420 mods
  deep** under a `Generic_Newest` default, which reads as "the marketplace is
  missing mods". The default is `Generic_Newest` by request, which is safe now that
  the sort choice persists — the default only decides a *fresh install*, and
  "Recently updated" is one click away and remembered thereafter. The orderings
  still differ from the site's. Options if it matters later: use
  `Game/<id>/Subfeed` for the unfiltered view (it matches the site closely — but
  accepts no filters and no sort, so it cannot be the only path), or accept the
  difference and say so in the UI. Written up in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §4.
  - The legacy Core API's self-describing `AllowedSorts` does **not** settle it:
    that API enumerates *its own* surface, and apiv11 accepts seven sorts that
    appear in no such list. It is corroboration, not proof — apiv11 has no
    discovery endpoint, so the claim rests on rejected guesses. Worth keeping in
    mind before treating any Core API absence as authoritative for apiv11.
- **Unrecognised top-level query params are silently ignored by apiv11.** Only
  `_aFilters[…]` keys and `_sSort` values are validated; a bogus `_sPeriod`,
  `_sRange` etc. returns `200` with unchanged results. So a successful response is
  **not** evidence a parameter works — five invented period params all "succeeded"
  while doing nothing. Any future probing must diff the results, not the status code.
- **Images are fetched with `Image.network` and cached only in memory.** Fine and
  measured-adequate for a browsing session — Flutter's `ImageCache` de-duplicates and
  holds decoded frames — but thumbnails are re-fetched from scratch after a restart. No
  dependency was added for this on purpose; revisit only if it is ever observed to be
  slow rather than assumed to be.
- [ ] **Generate thumbnails for local covers on import.** `cacheWidth` bounds
  *memory* only. The files are stored verbatim (measured: 3.8 MB PNGs, 2560px
  wide), so every cold load reads and decodes a full-size screenshot from disk. A
  cached thumbnail beside the original would cut disk reads and startup decode
  cost. A new feature rather than a bug fix, hence filed.

## 7. Unknown origin — backfill, warnings, and resolution

The origin block (§3) is written at **install time**. Everything that predates it
has none: the entire existing library, plus every drag-drop or manual-archive
import from here on. Without origin data, §3's read side and all of §4 are inert —
M3 would ship and look broken to anyone who already owns mods.

**Framing (the important part):** this is *not* a migration to be completed.
"Origin unknown" is a permanent state — legacy libraries, manual imports,
hand-shared folders, mods from sites we don't browse. So it gets a first-class
tier in the model, a visible status, and a resolution flow that lives in the UI
forever. The "migration" then shrinks to a cheap offline backfill that pre-fills
whatever is derivable without a network call.

### 7.1 Identity and version are separate unknowns

They resolve independently, so they must be modelled and tracked separately
rather than collapsed into one enum:

| | Recoverable offline? |
|---|---|
| **Which remote mod is this?** (identity) | **Often yes.** `source_url` already exists and is user-editable; parsing `gamebanana.com/mods/<id>` recovers identity for free. Measured: **23 of 23** mods in a real library, since the edit dialog is where people paste the mod page. |
| **Which file/version is installed?** | **Almost never.** The archive is deleted after extraction (§5), so GameBanana's per-file md5 has nothing local left to match against. |

### 7.2 Confidence-tiered origin block

**Shipped.** The block's fields are
[`docs/metadata-schema.md`](docs/metadata-schema.md); the tiers, what each one may
drive, and who may write which are
[`docs/origin-tracking.md`](docs/origin-tracking.md).

Two rules the rest of this section leans on:

- **Confidence and provenance are separate axes.** Confidence measures *how sure
  we are*; provenance records *where the mod came from*. They came apart the moment
  a hand-imported archive could be matched exactly (§7.8), so a tier named after a
  source would be actively misleading in the UI for a mod the user dragged in
  themselves.
- **Never-confirmed ≠ safe.** An `inferred` identity came from a free-form text
  field a human typed — it may be a wrong paste, a collection link, a Drive link,
  or a different mod entirely. It must be confirmed once (§7.6) before any update
  is allowed to overwrite files.

### 7.3 Offline backfill

**Shipped.** [`docs/origin-tracking.md`](docs/origin-tracking.md) §3 is
authoritative for how it behaves: it recovers identity from `source_url` during a
normal scan, strictly locally, hooked into the lazy per-mod migration in
`ModMetadataRepository.loadOrMigrate()`.

> **`schema_version` is not a swept marker.** Only a mod that actually gets an
> origin block is stamped v2; a legacy sidecar with no GameBanana url stays v1
> forever, correctly, per the don't-litter rule. A `1` means "no origin block has
> ever been written here", not "the backfill hasn't seen this mod yet" — it has,
> and found nothing.

- **Version sniffing from local files** (folder-name `_v2` tokens,
  `; version` comments in `.ini`, README lines): **hint only, never written.**
  Mods embed ZZMI/game versions and author-side numbering that are
  indistinguishable from mod versions, and a wrong stored version is worse than
  none. Surface detected tokens in the resolve dialog to help the user choose.

#### Open around the backfill (known, deliberately not built)

- **A backfilled sibling group can't be reconstructed, and two mods sharing a
  `mod_id` must not be read as one.** Nothing on disk records that two folders
  came from one archive, so the backfill leaves the group null — while mods
  sharing a `mod_id` are *common*: two occurrences in a real 23-mod library, two
  variants of one mod installed as separate folders. §7.6 must treat "same
  `mod_id`, no group" as **independent mods that happen to share a page**. What
  the group now drives, and what its absence costs, is
  [`docs/applying-updates.md`](docs/applying-updates.md) §4.
- [ ] **A mod resolved by *search* gets no "open mod page" link.** `openModLink`
  (`utils/url_utils.dart`) reads `mod.sourceUrl` and nothing else, so a mod whose
  origin block knows the page but whose `source_url` is empty has no way to reach
  it. That is a narrow set: an install writes `source_url` through the autofill,
  and the backfill derives `mod_id` *from* `source_url`, so both of those routes
  leave one behind. What does not is the resolve dialog — neither it nor
  `origin_resolution.dart` touches `sourceUrl` at all, so picking a mod out of its
  search box records `mod_id` at `user` and leaves the link empty. Either that path
  should normalise `source_url` to the mod page, or `openModLink` should fall back
  to `origin.mod_id`.

### 7.4 Visual status — one slot, three states

- [ ] One-time dismissible nudge after the upgrade ("N mods aren't tracked for
  updates"), re-openable from Settings. Not a modal wizard. **Not built** — the
  toolbar's count is a passive version of the same fact and was enough to ship
  the filter, but it only appears once the user is already looking at the Mods
  tab toolbar. Still worth doing; still needs the dismissed flag from §6.

### 7.5 Per-mod resolve dialog

One job: bind this folder to a remote mod + file. **Shipped** —
[`docs/origin-tracking.md`](docs/origin-tracking.md) §5 owns the candidate ranking
and what survives a rebind. Entry points: the status slot and the mod context menu
(the edit-mod dialog is filed below).

#### Open around the resolve dialog (known, deliberately not built)

- **A "tracked by date only" filter, if the card marker turns out not to be
  enough.** The muted clock makes the state visible but not *enumerable* —
  deliberately, since it is out of the "needs attention" count. At 17 mods
  seeing them is enough; at 80 it may not be, and the natural home is a second
  row on the `!` toggle rather than a sixth toolbar control. Filed rather than
  built, to see whether it is actually wanted.
- [ ] **A stale patch is only fixable from the tracking dialog or the mod menu.**
  Both routes into "take this patch out" are there, and the surface that *shows*
  the problem is the updates dialog, which has no route to either. The same gap
  as the filed item under §7.5 about the edit-mod dialog, and one menu entry away
  from being the same fix.
- [ ] **The two resolve dialogs still fetch a whole `ProfilePage`.** They read
  four fields off it — name, dates, files, archived files — where the update
  check now asks `Mod/Multi` for one id at a quarter of the bytes. Not a
  drop-in: both read `profile.files` / `profile.archivedFiles` directly, and
  `Mod/Multi` returns the union under one key, so they have to move to
  `currentFiles` / `allFiles` first.
- [ ] **A `/dl/` link could still pick the *file*, once the mod is known.** The
  identity step rejects one honestly — neither API resolves a file id to a mod —
  but the file step has the mod's `_aFiles` + `_aArchivedFiles` in hand, so a
  pasted file id is a direct row match costing no request. Small, and it turns a
  dead end into a shortcut for exactly the user who has the download link but not
  the page.
- [ ] **The resolve dialog reports an abandoned write as a read-only folder.**
  `ModMetadataRepository.updateOrigin` returns one bare `false` for three
  different things — folder missing, write failed, and the transform declined —
  and `mods.resolve.save_failed` renders all of them as "the folder may be
  read-only". So the re-read guard doing exactly its job (the sidecar was
  rebound while the dialog was open, so `pickFile` abandons rather than
  attaching a `file_id` to somebody else's mod) tells the user they have a
  filesystem permission problem. The **bulk** action hit the same conflation and
  worked around it locally, by wrapping the transform so a decline is
  distinguishable at the call site; the durable fix is for `updateOrigin` to
  return a small result type instead of a bool, which would then serve both call
  sites and let the workaround go.
- [ ] **Two local-side write seams exist with the same signature.**
  `ResolveOriginGateway.writeOrigin` and `BulkOriginWriter`
  (`dialogs/assume_current_dialog.dart`) both wrap `ApiService.updateModOrigin`
  for the same reason — a focused widget test asserts what the dialog *would*
  write, so it wants the transform in hand rather than a library to write it into
  — and both spell that rationale out. One shared typedef would stop them
  drifting. It belongs with the item
  above, since fixing `updateOrigin`'s return type has to touch both anyway.
  The bulk resolution screen imports `BulkOriginWriter` rather than declaring a
  third, so the drift did not get worse — but it now lives in
  `assume_current_dialog.dart` and is used by two other files, which is the wrong
  home for it, and the bool-return conflation is worked around a *second* time
  there in the same shape. Two workarounds for one missing result type is the
  point at which the durable fix is cheaper than the next copy.
  **A third seam of the same shape but a different signature** is
  `ContentFilterWriter` (`components/settings/marketplace_section.dart`, reused
  by the marketplace's filtered-empty state). It writes a setting rather than an
  origin block, so unifying it with these two would be forcing one typedef over
  two different writes — but it is the same rationale spelled out a third time,
  which is the thing worth noticing.
- [ ] **The resolve dialog cannot be reached from the edit-mod dialog.** §7.5
  names three entry points; the status slot and the context menu are wired, the
  edit dialog is not. That is the dialog where `source_url` is shown and edited,
  so it is where a user most plausibly notices the binding is wrong.
- [ ] **`CharacterInfo.keybinds` is never written, and one widget renders it.**
  `enrichCharactersWithKeybinds` sets keybinds on each `ModInfo` and carries the
  group through with `character.copyWith(skins: …)`, so the group-level field
  keeps whatever it had — and nothing anywhere constructs a `CharacterInfo` with
  one. It is therefore permanently null, which makes
  `components/character_cards_list_widget.dart`'s `if (character.keybinds !=
  null && …)` branch unreachable. Either the group level was meant to carry the
  union of its mods' bindings and never got wired, or the field is left over
  from before they moved to the mod — whoever looks has to decide which, so it
  is filed rather than deleted.
- **The dialog is per-mod only, by design, and that leaves the two-variant
  case tedious.** Two folders from one mod page are common (measured: two in a
  23-mod library), and each needs its own trip through the dialog even though the
  identity step's answer is identical. §7.6's bulk screen is the proper fix;
  noting it here so it isn't mistaken for something the per-mod dialog should
  grow.

### 7.6 Bulk resolution = §4's "check all" screen

**Decision: no separate migration screen.** Bulk resolution folds into the §4
bulk update-check results list, which already fetches exactly the data needed.
One screen, two jobs, and nothing that goes stale once libraries are migrated.
**Shipped** — [`docs/origin-tracking.md`](docs/origin-tracking.md) §7 owns it.

- **Bulk acts only on precise handles (`mod_id`).** Fuzzy identity matching is
  always one-at-a-time and user-confirmed (§7.5's search box). Rationale: a mass
  fuzzy name-match that a user rubber-stamps can bind a folder to an unrelated
  mod — and then an "update" overwrites their mod with a different mod's files.
  Folder names in the wild (`Ellen final FIXED v2`, `bikini`, `mod`) are exactly
  where fuzzy matching is least reliable. **Untracked mods therefore get no bulk
  feature at all** — they get no row, and the screen says how many were excluded
  for that reason, because "eleven mods" out of a library of fifty reads as though
  it covered the library unless the rest are accounted for.

#### Open around the bulk resolution pass (known, deliberately not built)

- [ ] **Resolving a mod does not refresh its verdict.** The screen writes a
  `file_id` for a mod the check had answered `versionUnknown`, and that verdict
  stays in session state until the next press — so a user who sorts out 24 mods
  learns nothing about *their* updates without checking again. Re-folding is
  free (the records are still in hand and `checkForUpdate` is pure), and it was
  still not taken: phase two's release feeds were fetched only for the mods that
  flagged, so a freshly-resolved mod re-folded now would miss the
  `ReleaseGroups` suppression and could show the variant-shaped false positive
  the pass had already learned to remove. The honest options are a second full
  check (a request nobody asked for) or fetching one feed per newly-flagged mod;
  both are decisions about the check, not about this screen.
- [ ] **Untracked mods are listed as a count and nothing more.** The bulk rule
  forbids acting on them, which is right, but the screen could still offer to
  open the per-mod dialog for each in turn rather than leaving the user to find
  them through the "needs attention" filter afterwards. Small, and it is the one
  place the two surfaces could hand off to each other.
- **There is no "I don't know which" per row.** The ambiguous rows get a
  picker or nothing; the `assumed_latest` escape hatch exists per mod (§7.5) and
  in bulk, but not *here*, where the user is already looking at the list. It
  would need its own column and its own wording, and it overlaps a button that
  already exists — filed rather than guessed at.
- **The card cannot say "the mod page is still a guess".** `modOriginStatus`
  keys on the *version* confidence once an identity exists, so a mod at
  `inferred`/`inferred` renders the same muted clock as one the user resolved to
  a date on purpose. Pre-existing — the backfill has always produced `inferred`
  identities — but this screen makes the state reachable in bulk, since ticking
  only the pre-ticked file answer leaves exactly that pair. A fourth slot
  state is the wrong fix (the slot has one mark by rule); the honest options are
  the tooltip saying so, or the resolve dialog's existing "worked out from the
  source link — not confirmed" line being enough.
- **The character header still holds two global controls.** Refresh and
  Single/Multi sit at the right of a block titled *Characters*, which is where
  they ended up because there was room rather than because they belong. The
  toolbar rebuild deliberately stopped short of them: they are not library *bulk*
  actions, and moving them into the same menu would mix "rescan the folder" with
  "rewrite 24 sidecars". Whether the header's right side should become an explicit
  action bar is a separate question, and it is the last place in this tab where
  placement is accidental.

### 7.7 Self-healing (why none of this has to be perfect)

- Any mod whose **identity** is known becomes fully known the first time it
  updates *through* us — the download writes an `exact` origin block. So
  version-unknown is a one-time speed bump per mod, and the heuristics only need
  to get identity right. This is what justifies keeping the guessing conservative
  and the UI light instead of building a heavyweight migration wizard.

### 7.8 Archive hashing — hash every ingest, not just downloads

**Shipped.** GameBanana publishes an md5 per file, so hashing a *manually
supplied* archive can identify the exact file the user has — the one route to
exactness for a hand-imported mod. The hash is taken before the archive is deleted,
because it cannot be recovered from extracted files, and it pays off later: at
resolution (§7.5) or in the bulk pass (§7.6), a banked hash matching a published
checksum sets `file_id` and `version` at `exact` and skips the "which file?"
picker. The flow is [`docs/origin-tracking.md`](docs/origin-tracking.md), the field
is [`docs/metadata-schema.md`](docs/metadata-schema.md).

Two limits, because they bound what may be built on it:

- **A bonus fast-path, never load-bearing.** An untouched GameBanana zip matches;
  anything re-zipped never does, because a repack changes the md5 even when the
  contents are byte-identical. A real 23-mod library banks **none** at all — the
  hash is recorded at ingest, so this pays off for mods installed by this build
  onward rather than for the legacy library it would help most. A miss costs
  nothing: the field is null-or-exact, so no match falls through to the normal
  guess path.
- **`archive_md5` is a matching key, never an integrity or authenticity claim.**
  No "✓ verified", no shield icon. The honest phrasing is "byte-identical to file X
  on the mod page". md5 is cryptographically broken, so a deliberate collision is
  constructible — harmless here precisely because a match grants no trust. If real
  integrity is ever wanted, add sha256 alongside rather than reinterpreting this
  field.

## 8. Cross-cutting work (easy to forget, not optional)

- **Localization is a per-screen tax.** Every user-facing surface needs keys in
  **both** `assets/l10n/en.json` and `uk.json`, and it is the most repetitive cost
  in the plan — budget it per milestone rather than discovering it at the end.
  The load-bearing half is always the *caveat* copy: "possibly outdated", "a best
  guess, not a guarantee — GameBanana publishes no comparable version numbers",
  "nothing is saved until you press Apply", why untracked mods are excluded. Those
  sentences *are* the feature, which is why they are translated rather than
  interpolated into English.
  The check worth reusing: extract every `loc.t('…')` literal from `lib/` and diff
  it against both JSON files in each direction. It catches a missing translation
  **and** a key left behind by deleted UI.
- **Name the tests, because the risky parts are pure functions.** The pieces most
  likely to be quietly wrong need no network and no UI: `source_url` → `mod_id`
  parsing (§7.3), the confidence state machine and what each tier permits (§7.2),
  the dangling-`.ini`-reference scan (§4.1), hash → file matching across
  `_aFiles` + `_aArchivedFiles` (§7.6), and the sidecar unknown-key round-trip.
  **Fixtures beat mocks**, and repeatedly changed a design rather than confirming
  it: real captured profiles are where `_sVersion` turns out to be null on every
  file of a mod, where two profiles disagree about what `_sDescription` means, and
  where the single timestamp that discriminates two candidate rules lives. A
  hand-written fixture has round numbers and tidy version strings, and a rule
  built on one looks obviously correct while being wrong. Pin the surprising facts
  as **canaries** rather than examples — that all 60 live character categories map
  to a roster id and none of the 4 roots do; that listing records carry
  `_sInitialVisibility` at all, since if it ever disappears upstream the filter
  silently blurs the entire grid.
- **One seam for offline tests.** HTTP stays behind a single injectable interface —
  `HttpTransport`, with `ImageFetcher` as the one deliberate second seam for bytes.
- **One seam for the local library, and it is a static one** because `ApiService`
  is a static facade: `useLibraryForTests` installs a real `ConfigService` over a
  temp directory, `test/support/temp_library.dart` builds it, and
  `test/flutter_test_config.dart` refuses the real `<appData>` for every test
  under `test/`. Real services over a temp directory rather than a fake
  filesystem — these flows *are* the file writes, so a fake replaces the only
  part worth trusting.
- [ ] **Widgets read the static facade instead of the providers that wrap it.**
  `modManagerServiceProvider` exists and dialogs call `ApiService` directly: 13
  `getModManagerService` and 9 `updateModOrigin` call sites over ~25 files. What
  routing them buys is disposal, no static mutable state and no init ordering —
  **not** coverage, since the library seam above already unblocks the tests, which
  is why it is filed rather than built.

---

## Additional feature ideas (backlog — not yet committed)

### Acquisition
- [ ] **Paste-a-URL-to-install** — drop a GameBanana link → fetch + install + tag
  automatically.
- [ ] **Wishlist / bookmarks** for mods.
- [ ] **Trending / by-character feeds** in the browser.

### Library management
- [ ] **Mod profiles / load-outs** — named **library-wide** saves of *which mods
  are active* (on/off state across the whole library), switchable in one click
  (e.g. "Combat", "Photo mode"). Ties into Single/Multi activation mode. Lives in
  its **own sidebar tab** with a dedicated page + list (the Mods tab header is
  too cluttered for an inline switcher). Later: export/share a profile.
  - **Not** per-mod settings saves — a mod's in-game state/config is owned by
    ZZMI itself, not this manager, so we can't snapshot it.
- [ ] **Conflict detection** — warn when two mods target the same character/slot.
- [ ] **Storage view + orphan cleanup** — disk usage per mod, prune dead links /
  stale downloads.
- [ ] **Mod grouping — only when someone asks for it.** The need is "handle these
  two mods together"; the answer is a grouping in the library listing, not a
  folder holding both. **A folder must never hold two independent mods**: they
  share one on/off state, one snapshot and one set of `.ini` files, so
  activating, updating or rolling back either acts on both. The record is a
  **stack of overwrites** (`mod_download.dart`), so downloads that do not overlap
  have no defined order and no meaning as layers — which is why `base` and
  `patch` are the complete set of positions and a third is refused rather than
  unbuilt.
  Doing it properly means reworking the mod list's UI/UX, which is reason enough
  to wait for a real request rather than guess at the shape.

---

# Other issues

## Packaging

- **The portable builds ship their own 7-Zip, and the obvious choice is wrong
  twice.** `ArchiveService` looks beside `Platform.resolvedExecutable`, and in a
  `tools/` beside it, before falling back to PATH, with the filenames on
  `PlatformService.bundledSevenZipNames` rather than a `Platform.isX` branch. Both
  CI workflows fetch the binary and **fail the build if it cannot report `Rar5`**,
  so the packaging cannot silently regress to shipping nothing. No pub package
  covers this: `archive` has the 7z *codec* but not the container and no RAR,
  `rar` skips Linux and Windows entirely, and `unrar` is RAR-only.
  - **Never `7za`.** 7-Zip's own readme calls it "reduced formats support", and
    RAR is among what it drops — so it would find a binary, run it, and decline
    the one format the bundle exists for. Windows needs the **`7z.exe` + `7z.dll`
    pair** from `7z<ver>-x64.exe`, not `7za.exe` from "7-Zip Extra".
  - **Linux takes `7zzs`, the statically linked build.** A portable tarball runs
    against a libstdc++ it cannot know, which is what a dynamic binary cannot
    promise. It is 3.6 MB against `7zz`'s 2.9 MB.
  - The versions are **pinned** in both workflows, because 7-zip.org serves each
    build at its own `/a/` URL with no "latest" alias — bumping them is a
    deliberate act. 7-Zip's `License.txt` ships beside the binary; it is LGPL.
  **Not verified from a built artifact.** The Linux fetch was run by hand and the
  binary confirmed to list `Rar5`; the Windows step and the installer's `[Files]`
  entries have not been exercised.

## Planned: rethink the whole UI

- [ ] Redesign the entire UI from scratch. Until that happens, leave UI layout
  and polish bugs alone — the fix would be thrown away.

Waiting on it:

- [ ] A marketplace file row overflows at 2× text scale. The scan chip and
  Download button can't shrink. Seen at 530px and 600px window widths.

Other todo's:

- [ ] Add a disk usage page, where you can see with graphs how much disk is being used and for what (images, mods, backups / previous versions, etc.)
  - It owns two things filed elsewhere, because both are the same screen: the
    **whole-library backup figure** (`SnapshotService.totalBytes()`, which has
    no reader, so the 5 GB retention budget currently bounds something
    invisible) and the **saved versions no folder claims any more** — a mod
    deleted outside the app, a duplicated folder, a deleted sidecar. Those are
    reported and reclaimed by hand, never swept automatically: an unclaimed
    group is recoverable data right up until it is deleted.
- [ ] **Give the portable build its icon with nothing to install** — set it via
  `xdg_toplevel_icon_v1` from the runner, dropping the one-command setup. GTK3
  can't, but the runner can bind the protocol itself; newer compositors only.
  [`docs/desktop-integration.md`](docs/desktop-integration.md).
