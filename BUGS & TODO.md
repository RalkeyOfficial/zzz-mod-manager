# BUGS & TODO

Planning + backlog for the mod-downloading / marketplace / update overhaul.
This is a **pre-planning document** — it captures *what* we want to build and the
decisions made so far, not *how* to implement it. Items are grouped by area.

> **This file is temporary.** As each area ships, its schema details and rationale
> move into [`docs/`](docs/README.md) — the origin block and confidence model (§3,
> §7) belong in [`docs/origin-tracking.md`](docs/origin-tracking.md). Don't let this
> document become the only written explanation of anything.

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
  and easy in-app integration. Today the marketplace is asymmetric — Windows uses
  an embedded `flutter_inappwebview`, Linux falls back to the external browser +
  a Downloads-folder watcher because that package has no Linux desktop support.
  Rejected alternatives: `desktop_webview_window` (separate popup window, weak
  download interception) and `webview_cef` (embeds but ships ~150MB+ of Chromium).

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

### M1 — Thin vertical slice (both platforms)

Goal: kill the broken Linux external-browser path and get one real end-to-end
install working identically on Linux and Windows.

- [x] **§0** — measure the large-download unknown. Results in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §8, which is authoritative:
  file-size distribution, per-node throughput, resume mechanics, rate limits.
  Two consequences that shaped everything after it — resume is M1 rather than
  M4 polish, and every download timeout is a **stall** timeout.
- [x] **§2 (subset)** — `GameBananaClient` (`services/gamebanana/`) over an
  injectable `HttpTransport` seam, so the whole layer tests offline against
  captured fixtures. Protocol in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md), our client in
  [`docs/app-architecture.md`](docs/app-architecture.md). Two things this doc
  had wrong and §2 below now records: browse is `Mod/Index`, not `Subfeed`, and
  `Mod/Categories` is a fourth endpoint the filter needs.
- [x] **§5 (basic)** — `services/download/`, written up in
  [`docs/downloads.md`](docs/downloads.md): resume, stall timeout, backpressure,
  cancellation, and `<appData>/downloads` as the single landing spot. The
  archive is hashed in-stream on every ingest path — free there and
  unrecoverable afterwards (§7.8).
- [x] **§3 (write side)** — the origin block, on every ingest path, with the
  confidence fields from day one and the drop-inbound-origin rule enforced by
  construction. Schema **v2**; `ModInfo` gains nothing. Every route that writes
  a block and the tier each may claim is in
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §2.
- [x] **§3 (prerequisite)** — the sidecar round-trips unknown keys, and
  `replaceUserFields()` makes that structural: a new machine-owned field needs
  no save-site change, a new user-editable one is a compile error at every save
  site. [`docs/metadata-schema.md`](docs/metadata-schema.md) §2.
- [x] **§7 (offline backfill)** — `services/origin_backfill.dart` (pure, with
  the one filesystem walk injected) recovers identity from `source_url` during
  a normal scan. Measured on a real 23-mod library: 23 of 23 recovered, 30 ms
  first scan including all writes, 7 ms and zero writes on the second. Two
  limits to know before building on it: sibling groups are unrecoverable
  (§7.3), and it helps only the *legacy* library — nothing in the install path
  writes `source_url`.
- [x] **§1 (plain)** — `screens/components/marketplace/`, the grid and the
  detail view; the webview gate, the Linux open-in-browser view, the Downloads
  watcher and `flutter_inappwebview` are all gone. See
  [`docs/marketplace.md`](docs/marketplace.md). Two things this doc had wrong
  and §1 below now records: the default-selection rule cannot have a "highest
  version" branch, and the category filter has no offline fallback.
- [x] **§6 (as needed)** — `content_filter` (`blur` | `show` | `hide`) through
  the dual-storage pattern, decided by a pure unit
  (`services/gamebanana/content_filter.dart`). The control is in the marketplace
  toolbar; **a Settings-tab entry is still open**, filed under §6.

**M1 is code-complete on Linux**, verified end to end against the live API.
**Not verified on Windows** — there is no Windows machine in this environment.
The implementation is shared with no platform branch (junction-vs-symlink and
`openUrlInBrowser` go through `PlatformService`), so the risk is low, but the
exit criterion names both.


### M2 — Smart installs (read the origin block)

Goal: make the data recorded in M1 pay off in the UI.

- [x] **§3 (read side)** — `services/installed_mods_index.dart`, the pure read
  model (mod id / file id / archive md5 → mod folders) behind
  `installedModsIndexProvider`. It **re-snapshots** rather than deriving from
  `charactersProvider`, which is stale exactly when the badges are on screen
  because `ModsScreen` is disposed; 4 ms warm, 12 ms cold for 23 mods.
  Measured limit to know before building on it: on a legacy library every mod
  has a `mod_id` and **none** has a `file_id` or an `archive_md5`, so every
  file-level answer — hash dedup included — is inert until mods are installed by
  this build or resolved by hand (§7.5).
- [x] **§3** — metadata autofill on install. Two pure units
  (`services/gamebanana/remote_mod_metadata.dart`,
  `services/metadata_autofill.dart`) with the I/O in
  `ModMetadataRepository.applyRemoteMetadata()`. One rule, and it is a safety
  rule rather than a courtesy: **fill absence, never displace** — an inbound
  sidecar's user-facing text is usually the author's.
  [`docs/metadata-autofill.md`](docs/metadata-autofill.md) owns it. The images
  are the only part that costs anything: 827 ms for two sibling mods sharing an
  8-image gallery.
- [x] **§1** — "already installed" indicators on cards and detail. The badge
  names the *folders* (one mod page is often several) and file rows separate
  "installed" (a recorded `file_id`) from "you have this" (a hash match), which
  per §7.8 must never read as verification. Design rules, including the
  alternatives that lost, are in
  [`mod_manager_flutter/CLAUDE.md`](mod_manager_flutter/CLAUDE.md) and
  [`docs/marketplace.md`](docs/marketplace.md) §7.
  - [x] **"Update available"** shipped for the *library* card with M3 — a blue
    mark at amber's weight in the same one slot, precedence folded into
    `modSlotStatus` so the two cannot stack. It is a **library** state only: the
    marketplace half was considered and refused, see §1.
- [x] **§7** — the mod-card **status slot** (§7.4), the **"needs attention"**
  filter, and the per-mod **resolve dialog** (§7.5). Three pure units carry the
  decisions: `services/origin_status.dart` (the one-slot fold, shared by badge
  *and* filter so they cannot disagree), `services/origin_resolution.dart`
  (candidate ranking with a stated reason) and `ModOrigin.boundTo` (what
  survives a rebind). The write path is
  `ModMetadataRepository.updateOrigin`, which **amends** rather than replaces
  and re-reads before applying.
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §5 and §7 own it.
  Two constraints that are not obvious from the code: **a `/dl/` link cannot be
  resolved to a mod by either API**, and **the filter covers the muted state as
  well as the amber one**.
- [x] **§7** — the zero-network **"assume current"** baseline action.
  `services/bulk_assume_current.dart` is the pure half (a plan split into
  eligible / untracked / undatable); `screens/dialogs/assume_current_dialog.dart`
  is the confirmation and the write loop.
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §6 owns it. On a real
  17-mod library the whole pass including 10 rewrites is 13 ms and re-running it
  is a 4 ms no-op, so there is no progress UI and none is warranted.
  Two hazards it is built around, both invisible rather than obvious:
  - **Each write re-reads and re-checks eligibility against the fresh block**,
    abandoning anything no longer `versionUnknown`. Without that a mod resolved
    exactly while the batch ran is silently *downgraded* to a guess, inside a
    pass nobody watches per-mod. A test walks all four resolved tiers.
  - **The plan comes from `visibleModsProvider`** — what the grid renders — not
    from the wider unfiltered view, because the action rewrites every mod it
    covers and its number must describe what is on screen. The knock-on: its
    count and the `!` toggle's count answer different questions and may differ,
    agreeing whenever needs-attention is the only filter.
  Two general lessons this item produced, both filed below: `ModsScreen`'s
  rescan guard is a **silent-staleness trap** for every future field on
  `ModInfo`, and **a control that hides itself by returning an empty box leaves
  its gaps behind** — the caller has to omit it.

### M3 — Updating

Goal: the payoff feature. Needs §2 + §3 + §5 from M1/M2.

- [x] **§4 (detection)** — manual update check, per-mod and whole-library.
  `services/update_check.dart` is the pure comparator (origin block + mod page →
  one verdict), `services/bulk_update_check.dart` the pass over `Mod/Multi`; the
  surfaces are the toolbar button, a right-click entry, a blue mark in the card's
  status slot and `screens/dialogs/mod_update_dialog.dart`.
  [`docs/update-checks.md`](docs/update-checks.md) owns it.
  What a future change here must not undo:
  - **A different *variant* is not a newer version.** `Mod/<id>/Updates` carries
    `_aFileRowIds` — the files an author released together — which is the
    author's own statement that two files are siblings rather than successors. A
    second rule covers what release groups cannot: two still-offered files
    stamped with the same `_sVersion` are the same version. Both can only turn a
    flag **off**, neither survives the installed file being archived, and absent
    data suppresses nothing.
  - **Do not extend that to suppressing an unlabelled candidate against a
    labelled install.** It would clear the last variant-shaped false positive
    and also silence an author who labelled one release and not the next — a
    false "up to date", which is the one failure this feature cannot afford.
    Filed below.
  - **An ignore is a date, not a file id** (`origin.updates_dismissed_until`), so
    it expires by itself when something newer is published, and it stores the
    date of the thing dismissed rather than "now" so nothing published mid-check
    is swallowed unseen.
  - **`UpdateCheck.newerFiles` carries every candidate**, and the dialog marks
    which one it would pick *and on what grounds* — "matches your variant"
    against "newest published" are different claims and must not render alike.
  - **The dialog has two entry points and they have different state.** Opened
    from a card badge it never fetches a profile, so anything re-derived from a
    fetched page silently no-ops there.
  Measured live on a real 17-mod library: one request, 982 ms. One dead id in
  the batch costs 9 requests and still answers every other mod, where without
  the halving all seventeen come back unreachable.
- [x] **§4 (applying)** — changelog display, backup/rollback, §4.1's overwrite
  path, its patch detection, and §4.2's backups.
  `services/update_apply/` holds the mechanism (`UpdateApplier` for the I/O and
  the ordering; `update_layout.dart` and `stale_ini.dart` for the two decisions
  it must not guess at), `services/backup/` the snapshot and its retention, and
  `services/ini_resources.dart` + `services/patch_detection.dart` the patch test.
  [`docs/applying-updates.md`](docs/applying-updates.md) owns it — **its own doc
  rather than a section of `update-checks.md`**, because that doc's scope is
  turning *which remote file is this* into *is there a newer one*, and this is
  filesystem semantics sharing no vocabulary with the comparator. The two meet at
  exactly one point, the Update button.
  Rules a future change here must not undo:
  - **An `.ini` is stale iff every resource it names is a file the incoming
    download ships**, not merely because we did not write it. The broader rule
    offers to delete the `.ini` of a *second mod merged into the same folder* —
    the destruction overwrite exists to prevent, with a dialog in front of it. A
    merged mod names its own files and is kept and *named*; one naming nothing
    checkable is kept without asking.
  - **A folder's `.ini` files are parsed collectively**, and `include` /
    `include_recursive` are themselves references. Reading each in isolation is
    what makes an ordinary mod — resources in one file, overrides in another —
    look broken. (Namespaces are irrelevant here: they rename *sections*, not
    `filename`s.)
  - **The layout fallback is the common path, not the rare one.** `ingest` is
    written by this build alone and the backfill recovers identity, not layout,
    so on a real library it is absent for every mod. Exactly one top-level folder
    maps to the mod folder; anything else **stops and asks**. An applied update
    writes an `ingest`, so the *next* update replays.
  - **A renamed upstream folder is expected, not a mismatch** — `Ellen` →
    `Ellen v2` is routine and unambiguous while there is one folder to pick. It
    cannot be absorbed for a combined install, where three differently-named
    incoming folders give no way to tell which became which and a guess writes a
    mod's textures over its buffers.
  - **Compare with the normalised key, touch the filesystem with the on-disk
    spelling** (`FolderContents.actualPaths`). Comparison paths are lower-cased
    because 3DMigoto is case-insensitive; handing that to `File` means
    `Ellen.ini` never matches on Linux, and authors overwhelmingly ship
    mixed-case names.
  - **`modBackupsProvider` is invalidated before the success check**, so the
    rollback a failed copy points the user at is actually in the menu. A failed
    copy still returns its snapshot; a test makes the copy genuinely fail.
  - **The retention plan reports an irreducible overage rather than forcing it.**
    One 1.2 GB mod is over any sane budget with a single snapshot, and the
    alternative to saying so is leaving the user no rollback.
  Verified against a real published update (`Miyabi Transfer Student` 700727,
  v1.1 → v1.2).
- [x] **§4 + §7** — the bulk "check all" results screen doubles as the bulk
  **resolution** screen (§7.6): per-row identity confirmation and inline version
  pickers.
  `services/bulk_resolution.dart` is the pure half — `(scanned mods, the records
  the check already fetched) → rows`, plus the one composed transform each row is
  written through — and `screens/dialogs/bulk_resolution_dialog.dart` is the
  surface. It costs **no request**: `runBulkUpdateCheck` hands back the
  `Mod/Multi` records it would otherwise discard.
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §7 owns it.
  The confidence-aware half of this line was already covered by §4's comparator
  (`isGuess` caps every verdict at `possiblyOutdated`) and by
  `ModOrigin.allowsUnattendedUpdate`, the auto-update gate M4 still owns. What
  this adds is the other direction: a pass that raises `inferred` to `user`,
  which is the confirmation §7.2 requires before an update may overwrite files.
  Rules a future change here must not undo:
  - **Only a tick, a user-picked file, or a checksum match confirms an
    identity.** The pass's own single-file inference is **pre-ticked** but leaves
    both axes guesses — promoting it would raise a url-parsed guess into the tier
    that lets an update overwrite files, on the one screen where the user can
    visibly decline. That is §7.2's "never-confirmed ≠ safe" inverted.
  - **Nothing is written until Save**, and the intro says so, because the
    controls cannot show it.
  - **The section lists are a cascade, not four independent filters.** `back` has
    to exclude `needsIdentity` or a mod recorded as gone whose page returned
    appears under two headings — reachable, since writing `remote_missing` never
    touches `mod_id_confidence`.
  - **Rows are grouped by their leading question and a mod is listed once**,
    ordered identity → file → gone → back. A section per *question* would list
    nearly every legacy mod twice.
  - **Both doors report `libraryUpdateCountProvider`**, not a view-scoped count,
    and both pass `BulkResolutionPlan.unreachable` — the "N mods couldn't be
    checked" line is the accounting gap the excluded-mods notice exists to close.
  - **A bulk action that flips a filter restores it on cancel**, including the
    nothing-to-do return, and leaves a filter the user had already set alone.
  - It is built from `components/dialog_section.dart`, the same headings and
    theme type sizes the update dialogs use, rather than its own vocabulary.
  Measured on a real 57-mod library, one 111 KB `Mod/Multi` request: at
  `user`/`exact` throughout the planner produces 0 rows in 0.4 ms and the screen
  never opens; the same library reduced to a legacy shape gives 57 rows in
  2.8 ms, 24 with the file already worked out, over 127 ranked candidates.
  **Never applied against a real sidecar** — this library has no unresolved mod
  left, so the screen cannot be reached without degrading one by hand. Verified
  by 28 pure and 14 widget tests.
**M3 is code-complete on Linux.** **Not verified on Windows**, and it matters
more here than in M1: §4.1's busy-file path exists *because* ZZMI holds handles
on Windows, and it has never been hit.

### M4 — Robustness & polish

- [x] **§5** — download queue and multi-download progress. (Resume is M1's; the
  SSL bypass went with M1's transport and needs no revisit.)
  `services/download/download_queue.dart` is the queue, `queue_policy.dart` its
  pure decisions, `DownloadQueueHost` the half with a `BuildContext`,
  `dialogs/install_archive_flow.dart` the install, and `DownloadsButton` /
  `DownloadsPanel` / a pinned progress notification the surfaces. All of it is
  written up in [`docs/downloads.md`](docs/downloads.md) §7–9, which is
  authoritative; only what a *future* item needs is repeated here.
  Constraints this item is built on, all of them still live:
  - **Work that outlives the press cannot be owned by a tab.** The tabs are
    keyed `AnimatedSwitcher` children with no keep-alive, so their
    `BuildContext` dies on a tab switch. The host wraps the switcher, and sits
    **below** the `Navigator` (unlike `NotificationHost`) because `showDialog`
    needs one as an ancestor.
  - **One transfer per file id, everywhere.** Two runs share a `.part` and a
    resume record in one directory and append two streams into a corrupt
    archive. `enqueue` *and* `retry` both check; the foreground update download
    goes through the queue for the same reason.
  - **A foreground job bypasses the cap on the way in.** Its modal barrier
    covers the panel, so a queued one leaves the user unable to reach what they
    would have to cancel. It counts against the cap once running.
  - **Two concurrent transfers, and not for throughput** — node choice is
    deterministic per file, so the cap only stops a degraded node holding up the
    queue behind it. Higher was never measured.
  - **A lazy viewport cannot live inside a `MenuAnchor`.** The menu measures
    through an `IntrinsicWidth` and a `ListView` asserts during layout; it also
    needs its own `ScrollController`, since the menu already has one on the
    `PrimaryScrollController`.
  - **A cancel records no error**, so `DownloadJob.error` means "something went
    wrong" everywhere, and an install failure is a typed `InstallFailure` so the
    panel never calls it a download failure.
  61 tests: 30 pure over the policy, 17 over the queue against a scripted
  transport and a temp directory, 10 over the panel and button, 6 over the host,
  plus 2 in the notification suite for the pinned-eviction rule.
  **Never exercised against the live API**, and that is the gap: two large
  archives arriving while the user browses, and an install running while a second
  transfer is still coming in.
- [x] **§4** — the *checking* half of what this line used to call auto-update:
  an opt-in **update check on launch**, off by default, reporting through one
  notification. `services/launch_update_check.dart` is the pure pair (whether to
  run, whether to speak), `screens/components/launch_update_check_host.dart` the
  host above the tab switcher, and `services/update_check_run.dart` the request
  and merge rule now shared with the toolbar so the two cannot drift.
  [`docs/update-checks.md`](docs/update-checks.md) §5.1 owns it.
  **Applying an update automatically is refused** — see §4 below. The line's
  "global + per-mod" belonged to that half: a per-mod opt-out of *checking* is
  not a useful control, since one `Mod/Multi` request covers the library and
  `tracking: "off"` already silences a mod entirely.
  Three rules a future change must not undo:
  - **Off by default is the safety property**, not a courtesy. "No network on
    launch" is not softened for anyone who has not asked; it is opted out of.
  - **It speaks only when it found updates.** A "nothing new" card every launch
    is noise, and a "couldn't reach N mods" card on every offline start is what
    gets the setting switched off. That does not break §4's "we could not look"
    rule — a silent pass asserts *neither* claim, and the manual check is still
    the one that reports.
  - **It never opens the bulk resolution screen.** A modal over an app the user
    has just opened is the interruption the notification-or-screen split exists
    to avoid; that screen is reachable from the library menu, from the records
    this pass leaves behind.
  One thing the design did not budget for and the decision is worth keeping:
  **the startup moment has to end even when the check was switched off.** Hence
  three states (`wait` / `close` / `run`) rather than a bool — otherwise
  enabling the setting and then favouriting a mod fires a pass at a moment the
  label *when the app starts* does not describe. An unscanned library must
  **not** close it, though, or the commonest ordering there is — the host
  mounts, the scan lands a moment later — skips the check every time.
- [x] **§6** — surface all new settings in the Settings tab. Two new sections,
  **Updates** (the launch check) and **Marketplace** (the content filter, which
  §1 always said belonged here as well as in the toolbar). Both are widgets in
  `screens/components/settings/` with a writer seam, because
  `settings_screen.dart` is already over a thousand lines and because a section
  that reached the real `ApiService` would rewrite the developer's own config in
  a widget test. `SettingsRow` adds the **description** slot the older row has
  no room for — a switch that contacts the network needs a sentence, not a
  label. What the §6 list asked for and did *not* get an entry, each with its
  reason, is in [`docs/configuration.md`](docs/configuration.md) §5.
- [x] **§1** — empty/error/loading/offline states, for the *errors* and the
  *empties*. `services/gamebanana/gb_failure.dart` is the classifier and
  `components/marketplace/gb_state_view.dart` the one surface both screens
  render it through; [`docs/marketplace.md`](docs/marketplace.md) §9 owns it.
  Most of what this line implied turned out to be **already decided** — the
  carousel absent rather than empty, the category panel silent because it fails
  with the listing beside it, the file list's three notices, no per-tile
  thumbnail spinner. Those stay; the doc says so, so the next pass doesn't
  "fix" them. What was genuinely missing:
  - **Four failures were being rendered as two.** A back-off read as
    "Something went wrong" (a bug in the app), and a mod taken down read the
    same way — with a **Try again** button whose every press was guaranteed to
    fail. `canRetry` is withheld on `notFound` and nowhere else, and it lives on
    the classifier because both screens have to give the same answer.
  - **The grid printed `GbException.message`**, which
    `models/gamebanana/gb_exceptions.dart` marks *"Developer-facing detail. Not
    for display"* — server English that cannot be localized. The type now
    forbids it: `GbFailure` carries a kind and nothing else, so there is nowhere
    to put a message even by accident. It goes to `debugPrint`.
  - **Both empty states were dead ends**, despite §1 having locked the
    distinction on the grounds that *"only the second is actionable"*. Each now
    carries the control that acts on it, and the filtered one degrades
    **`hide` → `blur`, never `show`** — the identical rule the resolve dialog
    follows, and the reason is the same: `blur` shows the cards and keeps the
    per-mod click-through, where `show` would silently invert a deliberate
    choice.
  - The detail header read *Loading…* over a message saying the load had failed.
  Two things a later change must not undo: the l10n keys are **literals** in the
  widget's switch rather than built from a stem, because `l10n_keys_test` finds
  keys by scanning `lib/` for single-quoted strings; and the content-filter
  write goes through a `ContentFilterWriter` seam, because `ApiService` builds a
  `ConfigService` against the developer's real `config.json` and a widget test
  pressing that button without one rewrites their own settings.
  **The loading half was scoped out rather than done** — refiled below.

### Later — backlog

Everything under "Additional feature ideas" (paste-URL install, wishlist, feeds,
NSFW filter, profiles, conflict detection, storage view). Pull items forward as
they earn priority.

---

## 1. Marketplace — native GameBanana browser

- [x] Remove the Linux/Windows split in `marketplace_screen.dart` (the
  `_isWebViewSupported => _isWindows` gate, the Linux "open in browser" view, the
  Downloads-folder watcher) in favour of the native browser.
  **Done**, and the `flutter_inappwebview` dependency is dropped with it. Worth
  recording *why* the watcher was never salvageable rather than merely
  platform-specific: it could only observe a file appearing in a folder, so it knew
  no mod id, no file id and no version; it guessed "download finished" by polling
  for a stable file size — a guess about someone else's browser; and any unrelated
  archive the user downloaded was a false positive. Its installs were correctly
  recorded as `imported_archive`, never `downloaded`.
- [x] **Results grid screen**: search box + category/character filters → grid of
  mod cards (thumbnail, name, author, likes/views, category badge).
  **Done.** The category filter is a **vertical panel on the right with expandable
  roots and their icons**, mirroring GameBanana's own layout — *not* the horizontal
  chip strip built first. That strip listed the ~60 children of Character Skins
  inline, so the character you wanted was essentially always off-screen behind a
  horizontal scroll with no cue how far. Children now load on expand, so opening the
  panel costs one request rather than four, and only one root is open at a time
  (two open branches recreate the wall of entries).
  Categories are **fetched, never hardcoded** — GameBanana gains a category with
  every new character, so a local copy is exactly what goes stale.
  One correction applied: the card shows likes / views / **posts**, not
  downloads — `_nDownloadCount` is absent from listing responses entirely, so a
  download count on a card could only ever render a misleading `0`. Also, the badge
  reads the *specific* category (`_aSubCategory`, usually the character — "Ellen
  Joe") rather than the bland root ("Character Skins"); that field was missing from
  the wire model and is now parsed. Both written up in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §5.
- [x] **Mod detail screen**: gallery images, description, author, category, and a
  **file list** (each file = version label + upload date + size + download button).
  **Done**, plus `_sAvResult` verbatim per §2 (a real safety signal, unlike an md5
  match) and an archived-files toggle per §7.6. `_sText` is HTML and is converted to
  markdown through `utils/html_to_markdown.dart`, shared with the editors'
  paste-as-markdown so the two conversions cannot drift.
  - ~~**Default-selection rule**: the download button auto-selects a file **only**
    when there is a single clear highest version and **no competing variants**.~~
    **Correction (applied): the "single clear highest version" half of that
    conjunction is not computable, so the rule reduces to "exactly one file".** The
    *intent* stands untouched — never default when ambiguous — but the mechanism
    assumed comparable versions, and real data says otherwise: `_sVersion` is free-form,
    not semver, and is routinely null on **every** file of a mod with the version
    written into `_sDescription` — the field that is otherwise the variant marker (one
    captured profile: ten files, all `_sVersion: null`, labelled "v3.4", "v3.3", …).
    Upload date is no substitute either: another captured profile publishes a "Main
    file" at 7.7 beside two patchers at 1.0 and three unversioned *demos*, where
    newest-upload picks a demo the moment one is uploaded last. So version and variant
    are not separably readable per file, and any multi-file default is a guess — which
    §"Locked decisions" forbids from driving anything. Implemented in
    `services/gamebanana/file_selection.dart` (pure, tested against both captured
    profiles); the UI says *why* the user must choose instead of showing an inert
    button. Measured consequences are in
    [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §6.
- [x] "Open in browser" escape hatch on each mod (for content we don't render).
  **Done**, via `PlatformService.openUrlInBrowser` — never a `Platform.isX` branch.
- [x] **NSFW / content filter — ours to implement, and not a login problem.**
  Verified anonymously against the live API (§2): adult mods are returned to
  unauthenticated callers like any other, and their files download without a session.
  GameBanana ships the *rendering hint* instead — `_sInitialVisibility` is
  `show` | `warn` | `hide`, with `_aContentRatings` naming the reasons ("Sexual
  Content", "Partial Nudity", …). So dropping the webview costs no access; it just
  moves the filter to us. Honour the hint by default (blur + reveal-on-click for
  `warn`/`hide`, which is what the site itself does) and put the toggle in Settings
  (§6). Previously filed under backlog as though it needed an account.
  **Done**, and the hint mix is not marginal: a live 6-record page returned three
  `show`, one `warn`, two `hide`. Reveal-on-click is per card and deliberately not
  persisted — clicking through one blur is consent for that mod, not a settings
  change. Two API facts that shaped it, now in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §7: listing records **do** carry
  `_sInitialVisibility` (so filtering needs no extra request, and an absent value
  failing closed to `warn` would blur the whole grid rather than un-blur it), but
  they **don't** carry `_aContentRatings` — so a card can flag a mod while only the
  detail view can name "Skimpy Attire".
- [x] "Already installed" indicators on cards & detail, driven by the per-mod
  origin data (see §3). In the **library**, this indicator shares a single status
  slot with the unknown-origin states — see §7.4.
  **The library half is done** (M2's badge, M3's blue update mark, one slot
  each), and so is *"already installed"* on every marketplace surface — the grid
  card, the detail view's notice, the file-row chips, and now the **carousel**,
  which had been the one surface that showed a mod without saying you already
  had it. Its card is a separate widget because `TopSubs` returns its own DTO, so
  the badge wiring never came with it; see
  [`docs/marketplace.md`](docs/marketplace.md) §7 for what its version does
  differently and why — it sits beside the period badge as one `Row`-laid
  cluster rather than in its own corner, and that cluster is inside an
  `IgnorePointer` because the whole card is one tap target with the overlays
  laid over it rather than around it.
  **The line's "update available" half is refused, not pending**, and the slot
  keeps its one branch. Two screens, two questions: the marketplace answers *do
  I have this*, the library answers *is mine current*. Moving the second here
  fails twice — the verdict map is session state and the launch check is off by
  default, so the badge would be blank on a normal launch and blank reads as *no
  update*; and this screen's Download imports a **new folder**, so pressing it
  on a mod you own reports "Nothing imported" or lands a second copy, where
  updating means `applyUpdateFlow`'s snapshot-and-overwrite. Full reasoning in
  [`docs/marketplace.md`](docs/marketplace.md) §7.
- [x] Decide empty/error/loading states and offline behaviour.
  **Done for M1's two screens**; M4's §1 item then took the errors and the
  empties past them, and [`docs/marketplace.md`](docs/marketplace.md) §9 is now
  where all of it lives. Decisions worth keeping: *no results* and *everything on this page was hidden by your
  content filter* are separate empty states, because only the second is actionable
  and showing the wrong one sends the user hunting for a mod that was never there;
  offline gets its own wording rather than a stack-trace-shaped message, since it is
  the most common failure and not a bug; and the category strip stays **silent** on
  error rather than reporting the same outage twice — it fails exactly when the
  listing beside it fails.
  - Consequence of filtering client-side, worth knowing before building on the
    pager: `_nRecordCount` counts **remote** records, so in `hide` mode a page can
    legitimately render far fewer cards than the page count implies.

## 2. GameBanana API layer (the keystone)

> The API itself is now documented in
> [`docs/gamebanana-api.md`](docs/gamebanana-api.md) — endpoints, filters, sorts,
> field meanings, the category tree, and the gotchas. This section is only about
> *our client*; don't duplicate protocol detail here.

- [x] Thin, dedicated API client service — **not** inline in the UI.
  `services/gamebanana/gamebanana_client.dart`, reached only through
  `gameBananaClientProvider`. Nothing outside `services/gamebanana/` builds an
  apiv13 url or touches `HttpTransport`; the only other transport user is
  `ImageFetcher`, which fetches **bytes** and is a deliberate second seam rather
  than a second API path.
  **The stated surface was off by one, and the correction is worth keeping:
  there is no file-list call.** GameBanana returns a mod's files *inside* its
  profile, so `modProfile` already carries them and a `files()` would be a
  second request for data we are handed. That line was written before the API
  was probed.
- [x] Resolve a mod URL **or** id → structured data. `modProfile(int)` returns a
  `GbMod` carrying every field this line asks for: `name`, `submitter`, `images`,
  `text`, `displayCategory`, and `files` with `version`, `description` (the
  variant label — never conflated with the version) and `dateAdded`.
  **The *url* half is not a client method and should not become one.** A url
  becomes an id in `utils/gamebanana_url.dart`, which is pure and therefore
  reachable by the offline origin backfill — the reason it lives there. A
  `modProfileByUrl` wrapper did exist and has been **removed**: every call site
  had already gone to the util directly, leaving five lines with no caller and
  two tests keeping them alive, while making the client look like it had two
  ways in when it has one. The `/dl/` guard it advertised was never its own —
  it belongs to the util, where `test/gamebanana/gamebanana_url_test.dart`
  covers it against five url shapes.
- [x] This same layer powers browsing, metadata auto-fill (§3), and update checks
  (§4), with the surface kept minimal. Verified by the callers: browsing is
  `utils/marketplace_providers.dart` (`browseMods`, `searchMods`, `categories`,
  `topSubs`), autofill is `RemoteModMetadata.fromMod` off `modProfile`, and the
  update check is `services/update_check_run.dart` (`modsMulti`, `modUpdates`).
  **The operational form of "minimal" is one method per endpoint and no method
  that isn't an endpoint** — stated in
  [`docs/app-architecture.md`](docs/app-architecture.md) §4, which is what makes
  a wrapper like the one above visible as surface rather than as convenience.
- [x] **`GameBananaEndpoints.modDownloadPage` built a url nothing requested.**
  Removed, along with its endpoints test. It was earmarked for update checks —
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §"Update checks" calls
  `DownloadPage` *"much cheaper than `ProfilePage` when all you need is did the
  file list change"* — and the check that shipped went elsewhere for two reasons
  that both still hold: `Mod/Multi` batches **50 mods into one request** where
  this is one request per mod, and `Mod/<id>/Updates` carries the `_aFileRowIds`
  grouping without which a variant reads as a newer version.
  **The capture and its parse test stay** (`test/gamebanana/gb_parse_test.dart`,
  `fixtures/gamebanana/download_page_531649.json`). Evidence about an
  undocumented API costs nothing when our own code changes; an unused `Uri`
  builder is upkeep. That split is the point — bringing the endpoint back is four
  lines against a response whose shape is already pinned, including the detail
  that would otherwise bite: it carries **no `_idRow`**, so a caller has to supply
  the mod id.
  Worth stating because the wrong reason to keep it was written down first: it is
  **not** needed for download urls. `ProfilePage` carries `_sDownloadUrl` on every
  file already (`GbFile.downloadUrl`).

### Verified against the live API (probed 2026-08-01, anonymous, no cookies)

The keystone assumption — that a native client can do everything the webview does —
holds. Recorded here so it isn't re-litigated, and so the field names can be coded
against directly. There is no `/apidocs` page; the surface is discoverable only by
probing, which is one more reason to keep our client tiny.

- [x] **Endpoints that do the job.** ~~`GET /apiv11/Game/19567/Subfeed`~~ →
  **`GET /apiv11/Mod/Index?_aFilters[Generic_Game]=19567&_sSort=…&_nPage&_nPerpage`
  (browse)**. Corrected while building the client: `Subfeed` accepts **no filters
  and no sort**, so it cannot satisfy §1's "search box + category/character
  filters" — and the character filter is only expressible as a
  `Generic_Category` over the 60 children of Character Skins (`30305`). `Index`
  is what `docs/gamebanana-api.md` calls the browse workhorse; `_nPerpage` is a
  hard 50 there (`INVALID_PERPAGE` above it, not a silent cap).
  **`GET /apiv11/Mod/Categories?_idGameRow=…|_idCategoryRow=…&_sSort=…`** was
  missing from this list entirely and is a fourth endpoint M1 needs, since it is
  what the category/character filter is built from. It returns a **bare array**
  and *requires* `_sSort` (its own internal default is a value it rejects). One
  knock-on this doc never budgeted: the filter list is therefore a network call,
  so it wants a cached provider ~~plus an offline fallback to the hardcoded
  `utils/zzz_characters.dart` roster~~.
  **Correction (applied): there is no offline fallback, and the hardcoded roster
  cannot be one.** Two independent reasons, recorded so it isn't attempted again.
  (1) That roster carries **no GameBanana category ids**, and `Generic_Category`
  accepts an id and nothing else — `Generic_Name` exists but rejects plain strings —
  so a local name list can only render chips that cannot filter. (2) It would never
  help regardless: the categories request fails exactly when the listing request
  beside it fails, so there is no state where the chips are reachable but results
  aren't. One error state for the screen covers both honestly. A genuinely offline
  character filter would need the fetched id↔name mapping **persisted** — a cache,
  not a static roster. (Live check: still exactly 60 children of `30305`.)
  `GET /apiv11/Util/Search/Results?_sModelName=Mod&_sSearchString=…&_idGameRow=19567`
  (search — the server caps `_nPerpage` at 15 **silently, with no error**, so the
  client doesn't expose the knob at all and reads `_aMetadata._nPerpage` back;
  `_nRecordCount` drives paging). Note search scopes by `_idGameRow` while Index
  scopes by `_aFilters[Generic_Game]` — different spellings, no overlap.
  `GET /apiv11/Mod/<id>/ProfilePage` (everything the detail screen needs, in one call),
  `GET /apiv11/Mod/<id>/Updates` (the author's changelog feed — that's §4's changelog
  display, no scraping required).
- **Downloads are anonymous and unguarded.** `_sDownloadUrl`
  (`gamebanana.com/dl/<fileid>`) 302s to `files.gamebanana.com` and on to a
  `filecacheNN` node, serving real bytes with no session, no referer and no Cloudflare
  challenge. Range requests are honoured (`206 Partial Content`) — which is what makes
  §5's retry/**resume** actually implementable.
- **`ProfilePage` already carries every field the origin block wants**, so §3's
  "auto-populate metadata on install" is one request rather than several. `_aFiles[]`
  → `_idRow` (our `file_id`), `_sFile`, `_nFilesize`, `_tsDateAdded`,
  `_sMd5Checksum` (§7.8 confirmed), and **two strings that must not be conflated**:
  `_sVersion`, a per-file version string separate from the mod-level one, and
  `_sDescription`, the author's free-text label — that's the *variant* marker of
  §1/§3 ("white hair ver", "Full Mod"), not a version. §3's `version` and
  `version_label` map onto them respectively. Mod level → its own `_sVersion`,
  `_tsDateAdded` / `_tsDateUpdated`, `_aTags`, `_aCategory`, `_sText` (description —
  **HTML**, while ours is markdown, so it needs converting on install),
  `_aPreviewMedia` (gallery).
- **Upstream-gone is an explicit field, not just a 404.** `_bIsPrivate`,
  `_bIsTrashed`, `_bIsWithheld` — §7.6's `remote_missing` should read these rather
  than infer from a status code. `_bIsObsolete` is a *different* thing (the author
  flagged it superseded) and needs its own wording.
- **Per-file scan results ship too** — `_sAvResult` (`clean`), `_sAnalysisResult`.
  Worth showing verbatim on the file list: unlike an md5 match it genuinely *is* a
  safety signal (contrast §7.8), and it costs nothing to surface.
- **No documented rate limit.** No `RateLimit-*` or `Retry-After` headers on a
  normal response; responses carry `cache-control: public, max-age=600`. Mirror that
  10-minute TTL in our own cache (§6) and treat backoff as **reactive** (on 429/503)
  rather than budgeted — then measure a burst before shipping §7.6.

## 3. Mod metadata & origin model

Today `ModMetadata` only has a free-form `sourceUrl` (user-editable) and no
version/origin data. Extend the per-mod metadata with an **origin block**,
recorded at install time.

> **Correction (applied):** an earlier draft of this line said "and `ModInfo`".
> It must **not** go there. `docs/metadata-schema.md` §2 is explicit that routing
> a machine-owned field through the runtime view is exactly what makes it
> vulnerable — a later unrelated edit rebuilds the sidecar from `ModInfo` and
> silently erases the block. `ModInfo` gains nothing; §8's hygiene note to add
> origin fields to it is void for the same reason.

The block:

- **Source service** (e.g. `gamebanana`) — future-proofs for other sources.
- **Remote mod id** (GameBanana `_idRow`) — stable handle to re-query; more
  reliable than `sourceUrl`.
- **Installed file id** — GameBanana mods have multiple files; track *which*.
- **Installed version string + file/version label** (e.g. "white hair ver").
- **Downloaded date** — fallback comparator + UI ("added N ago"); ties into
  existing `sort_mode: added`.
- **Archive hash** — detect real changes vs same-version re-upload; enables
  dedup / "already have this". Recorded for **every** ingested archive, not only
  in-app downloads, since GameBanana publishes a per-file md5 we can match against
  — see §7.8 for what it can and cannot be used for.
- Locally-imported mods (drag/drop) simply have **no origin block** and show
  no update info — manual import keeps working unchanged. They are not an error
  state: how they surface, and how a user can opt one into tracking, is §7.
- **`source_url` stays user-facing and mod-page-only.** Never write machine
  handles or `/dl/<fileid>` links into it — the origin block owns those. The
  resolve dialog (§7.5) may *accept* a pasted `/dl/` link, but it stores the
  resolved ids in the origin block and normalizes `source_url` to the mod page.
- **Record the ingest shape, not just the file.** One archive does **not** map to
  one mod folder: `_installArchive` → `resolveImportSelection()` lets the user install
  several top-level folders as separate mods (`importMods`) *or* merge them into one
  (`importCombinedMod`). The origin block has to record what was actually done —
  which top-level folders were taken, and whether they were combined — or an update
  can't reproduce the install, and N sidecars end up sharing one `file_id` and one
  `archive_md5` with nothing tying them together. Add an `ingest` block (§7.2).
  Consequences worth spelling out now: an update acts on the **whole sibling group**
  at once; §7.8's local dedup reports "you already have this as A, B, C" rather than
  three separate hits; and a group whose members were partly deleted is *broken*, not
  updatable — offer a clean reinstall rather than silently re-creating what the user
  removed.
- **An inbound sidecar is untrusted input.**
  [`docs/metadata-schema.md`](docs/metadata-schema.md) §1 already says a sidecar is
  "effectively a public interchange format", and `_copyDirectory()` copies a source
  folder's `.zzz-mod-manager/` in wholesale — so a folder from Discord or a friend can
  arrive carrying **someone else's origin block**, which the round-trip-unknown-keys
  fix will then faithfully preserve. That's a claim of `exact` confidence we never
  made, sitting on the one tier gated for unattended auto-update. **Rule: on any
  ingest we didn't download ourselves (`imported_folder`, `imported_archive`), drop
  the inbound `origin` block entirely** — provenance already tells us it isn't ours.
  Keep the user-facing fields (description, tags, images); those travelling is the
  whole point of sidecars. Cheap, and it must land in M1 *with* the write side.
  **Now load-bearing, not merely prudent.** The round-trip fix shipped, so an
  inbound `origin` block is preserved faithfully instead of being accidentally
  scrubbed by the first metadata edit. The accidental safety net is gone; this
  rule is the only thing left standing between a stranger's sidecar and a claim
  of `exact` confidence. See [`docs/metadata-schema.md`](docs/metadata-schema.md)
  §2.
- [x] **Define what "already installed" means** before §1 renders a badge for it: per
  `mod_id` (this mod is in your library, maybe a different file) or per `file_id`
  (this exact file)? They differ constantly — two skins of one mod are two folders.
  Decision: badge on `mod_id`, and on the detail screen additionally mark *which* rows
  of the file list are installed.
  **Implemented as decided**, and the "differ constantly" claim is now measured
  rather than asserted: two of a real library's 23 mods share a `mod_id` with a
  sibling folder (checked against the live API — `675945` is one mod page whose
  three published files include the two variants installed locally). The badge
  therefore names every matching folder instead of rendering a singular
  "installed".
- **A failed origin write is a state, not a shrug.** `ModMetadataService.write()`
  returns `false` on a read-only folder or an odd network share, and nothing looks at
  the result today. A mod whose origin can't persist would re-resolve forever with no
  explanation — report it once ("couldn't save tracking data for `<mod>` — folder is
  read-only") instead of silently retrying every scan. **Done for the install
  path** (`takeOriginWriteFailures`); the backfill path is a separate open item
  under "Open around the read side".
- Every field above carries a **confidence** — see §7.2 for the tiers and
  what each one is allowed to drive.
- [x] Auto-populate metadata (description, images, tags, character) from the API
  on marketplace install instead of leaving it blank.
  **Done** — see M2's entry above for the shape and
  [`docs/metadata-autofill.md`](docs/metadata-autofill.md) for the rules. Three
  corrections to what this line assumed:
  - **`_aTags` arrives in two different shapes and the client read only one.** A
    listing sends flattened strings (`"Software Used: Blender"`); a
    `ProfilePage` sends objects (`{_sTitle, _sValue}`). `gbStrings` handled only
    the string form, so **a profile's tags parsed as empty** — silently, and
    invisibly, because both captured profile fixtures happen to have no tags at
    all. Fixed (`gbTags`, both shapes normalised to the listing spelling) and
    pinned by a newly captured fixture, `mod_profile_tagged`. Worth noting the
    field was dead until this item: `GbMod.tags` had no reader anywhere.
  - **Tags are not the keyword list this line implies, and are imported
    selectively.** Authors fill both halves freely, so a tag is two loosely
    related fragments — `{"Ellen", "Chained school uniforms"}`, `{"cheongsam",
    "ellen"}` — and the single commonest title is `Software Used`, naming the
    author's toolchain rather than the mod. Measured: **4 of 20 captured records
    carry any tag, and 3 of the 6 distinct values are that family.** They are
    dropped, because `tags` is *structural* here (it drives the toolbar's filter
    chips) so noise costs more than it would in a description.
  - **The character comes from the mod's *category*, which is exact rather than a
    guess.** Under Character Skins the category is the character's full in-world
    name, chosen from a list — and all **60** children resolve to a roster id
    while **none** of the 4 roots or the 22 Bangboo categories falsely matches
    one. A test pins that 60/0 result as a canary. ~~Folder-name detection still
    runs first and still wins (it is per-folder, so it is the only signal that can
    differ between siblings from one archive); the category fills the case names
    cannot answer, `bikini` or `mod v2`.~~ **Reversed** — see "Other issues"
    below: the category is a statement, the folder name is a substring guess, and
    "Zhao Nicole" proved which one to trust. The category is now handed to the
    import and detection only runs where there is no category character.

### Open around the read side (known, deliberately not built)

- [x] **`modsProvider` in `state_providers.dart` is dead and now misleading.**
  Declared as `StateProvider<List<ModInfo>>` and never read or written by
  anything — the flat mod list actually lives inside `charactersProvider`'s "all"
  group. It looked like the obvious home for the library snapshot the read side
  needed, and it is not one: nothing populates it. Left alone rather than fixed as
  a drive-by, but it should either become the real flat list (with `_buildGroups`
  deriving from it) or go.
  **It is the real flat list now** — a derived `Provider` over
  `charactersProvider`, deduplicated by folder id because the grouping is not a
  partition (a mod appears under its character *and* under "all"). Taken as part
  of §4's bulk check, which needed exactly this and would otherwise have added a
  *second* provider beside the dead one, making the confusion worse rather than
  better. **The direction is the opposite of what this item proposed**, and
  deliberately: deriving the flat list from the groups is a ten-line provider,
  where inverting `_buildGroups` to derive the groups from a stored flat list is
  a change to the 2000-line screen that owns the scan. That inversion is *not*
  done and is filed on its own below.
- **Nothing keeps the library list live across a tab switch.** `ModsScreen` is
  a keyed child of an `AnimatedSwitcher` with no keep-alive, so it is disposed on
  every tab change and `initState` re-scans on the way back. The read side works
  around it by taking its own snapshot and invalidating it when the marketplace
  opens — which is correct and cheap, but two independent readers of the same
  library is a shape worth revisiting if a third appears (§7.4's status slot is
  rendered from `charactersProvider`, so it will not need one).
- [x] **A failed origin write is still not surfaced for the *backfill* path.**
  Done, in the shape the item predicted: `takeBackfillWriteFailures()` drains
  from the repository through `ModManagerService`, and `loadMods` reports it —
  reusing the ingest path's own wording, because from the user's side it is one
  fact ("this mod won't be checked for updates, and here is why") and which of
  our two writers hit the read-only folder is our business.
  **It repeats for as long as the problem does**, rather than once per session:
  the mod cannot be checked for updates until the folder is writable, and saying
  so once — possibly during a launch nobody was watching — makes a permanent
  problem look transient.
  That required dropping the retry suppression this path used to have, which
  turned out to be guarding nothing: the walk it avoided measures **0.51 ms per
  mod** against a real 71-mod / 3722-file library, and only failing mods pay it,
  since a successful write stops a mod qualifying. Retrying is also what lets
  the warning stop on its own when the permissions are fixed, with no restart.

### Open around metadata autofill (known, deliberately not built)

- [x] **The install is silent between the download finishing and the result.** The
  quiet window is extract → duplicate check → folder-selection → import →
  autofill: typically ~830 ms, and up to one 20 s per-image timeout when a CDN
  node is degraded (§0 measured one serving at 0.08 MB/s). Filed against the old
  foreground progress dialog, which closed the moment the bytes were in.
  **Answered by M4 §5, not by M4 §1**, and recorded here so it isn't fixed
  twice: the background queue keeps one pinned card across exactly that window,
  reading *Installing…* — `DownloadQueueHost._syncProgressNotification`, driven
  by `QueueProgress.installing` in `queue_policy.dart`, which is true from the
  moment the job leaves the transfer until the install returns. The prediction in
  the original filing was right about the shape of the fix (a phase of the same
  surface, not a spinner bolted onto one step) and wrong about which surface it
  would be.
- [x] **A mod page's tags are now parsed but still shown nowhere.** The detail
  view renders them as a chip row between the metadata and the file list — tags
  describe the mod, so they belong with its facts rather than after the author's
  prose, which on a real profile is several screens down.
  Shown in the **same `"Title: Value"` form the library stores**, because an
  install copies these strings straight onto the mod: a tag has to read
  identically on the page and on the folder it became. Absent rather than empty
  for a mod with none — 4 of 20 captured records carry any.
  It does what the item predicted for the parse: the fixture-driven test walks
  `mod_profile_tagged` through the widget, so the profile shape is
  self-evidently correct rather than only test-correct. Worth knowing for any
  test near it — the page is a lazy `ListView` and a real profile's 16:9
  gallery is ~650px, so anything below the fold has to be scrolled to before it
  exists to `find`.
- [ ] **A truncated gallery doesn't say it was truncated.** `RemoteModMetadata.maxImages`
  is 10 and real galleries reach 26+ (measured), so a mod can quietly arrive with 10
  of its 26 screenshots. The install message names "preview images" without a count
  — deliberately, since the only number available is a *cross-mod file total* rather
  than a gallery length — so nothing currently claims the gallery is complete either.
  What is missing is the other half: a way to say "10 of 26", or to pull the rest from
  the mod page in the edit dialog. Not a silent cap on correctness (the mod page is
  one click away), but the user has no way to know there is more.
- **The install-summary merge rests on an unasserted invariant.**
  `autoTags.addAll(fill.characterTags)` in `_installArchive` is correct only because
  the two maps are disjoint by construction — the autofill assigns a character solely
  when none is set, so folder-name detection and category detection can never both
  claim one mod. Nothing pins that. If the category is ever allowed to *override* a
  name match, the summary would report the category's answer while the sidecar keeps
  the name's, and the two would disagree silently. The wiring has no widget test
  either (it needs `ApiService`'s singletons and a configured library), which is
  acceptable for UI plumbing but is why the invariant is worth writing down.
- [x] **An unwritable folder swallows the autofill too.** Fixed by
  *consolidating* rather than adding the third report the item asked for:
  `ModManagerService.applyRemoteMetadata` folds `RemoteMetadataFill.unwritable`
  into `_originWriteFailures`, so the drain and the message that already exist
  cover it and one read-only folder still produces one card. The drain
  deduplicates, because both writes target the same sidecar and the usual case
  is that a folder fails both.
  **One imprecision is knowingly accepted.** In the rare case where the origin
  write succeeds and only the autofill fails — a folder that turns read-only
  mid-install — the message still says the mod "won't be checked for updates",
  which is then untrue: tracking did save, the description and gallery did not.
  Wording that covered every case exactly would either hedge or lose the
  update-checking consequence, which is the one the user cannot otherwise
  notice. An over-broad warning beats today's silence.
  The producer had no test at all; a read-only sidecar now pins that
  `unwritable` names the mod.

## 4. Mod updating

- [x] **Manual update check** — per-mod and bulk ("check all"). The bulk results
  screen is also the bulk-resolution surface for unknown origins — see §7.6.
  ~~**The check is done; the results *screen* is not.**~~ **Both are done now**
  (see M3 above). The notification did not go away, though, and that is the
  decision worth recording: a check reports through **one** surface and which
  one depends on whether the pass turned up anything to act on beyond the
  badges. Nothing to resolve → the summary notification, because a modal would
  stand between the user and the badges they pressed for. Something to resolve →
  the screen, which states the summary itself. Raising both for one press is how
  a user ends up reading neither.
- [x] Update rule: prioritise version string + version label; fall back to upload
  date / hash. Best-effort suggestion, clearly labelled as such.
  **Done, with one correction that changes the mechanism while keeping the
  intent.** "Version string + version label" cannot be a *same-label* rule on
  its own: authors use `_sDescription` as the variant marker on some pages
  (`Main file`, `Glow demo`) and as the **version** on others (`v3.4`, `v3.3`,
  … — ten current files, none archived). Against the second, a same-label rule
  finds no successor for an installed `v3.0` and reports it **up to date**,
  which is the one failure this feature cannot afford. So the rule is three
  ordered questions, not one: *is your file still offered* (a fact, no version
  involved) → *is there a newer file with the same label* (`updateAvailable`) →
  *is there anything newer at all* (`possiblyOutdated`). The label ranks the
  candidate; it never suppresses the verdict. Measured consequences are in
  [`docs/update-checks.md`](docs/update-checks.md) §3.
  The hash fallback is in and is read-only: a banked `archive_md5` identifies
  the installed file when no `file_id` is recorded, but **the check never writes
  what it learns** — recording it is a resolution, and resolutions belong to
  §7.5's dialog and §7.6's pass, not to asking a question.
- [x] **The update check must clamp `baseline_remote_date` when it compares.**
  A baseline written by the *per-mod* dialog is clamped to the mod's own
  `_tsDateAdded`; one written by the zero-network **bulk** action (§7.5) cannot
  be, because the clamp needs the mod page. So stored baselines are a mix of
  clamped and unclamped, and §4 must not assume otherwise — compare against
  `max(baseline_remote_date, _tsDateAdded)`, using the profile it has already
  fetched. This is the more correct home for the rule regardless: the clamp is a
  fact about the mod page, not about the sidecar. Small, but it has to land with
  the comparator itself, since an unclamped baseline on a hand-copied library
  can predate the mod's existence.
- [x] **Confidence-aware verdicts.** With a guessed installed version, the
  strongest claim available is "possibly outdated" — never a bare version
  comparison. Auto-update is gated to exact confidence only (§7.2).
  **Done**, and one thing this line left implicit is now explicit: the cap
  applies to a guessed **identity** as well as a guessed version. An `inferred`
  `mod_id` came from a free-form field a human typed, so if it names the wrong
  mod every file compared belongs to a mod the user does not own — the verdict
  is no stronger than the weaker of the two axes. It also survives onto a
  *clean* answer: "probably nothing new" is not "nothing new". (The auto-update
  gate itself is M4 and untouched; `ModOrigin.allowsUnattendedUpdate` still owns
  it.)
- [x] **Update badges** on mod cards in the library. **Done**, in the *existing*
  status slot rather than beside it — `modSlotStatus` folds the origin block and
  the session verdict so the card still shows exactly one mark. Blue at the same
  weight as amber, per M2's note that the two must differ by hue rather than
  volume. The **marketplace** card's equivalent is separate and still open (§1).
- **Opt-in auto-update — considered and refused.** Kept as a record so it isn't
  re-proposed; the whole confidence model reads like a runway towards it, and it
  is not one. Written up in
  [`docs/applying-updates.md`](docs/applying-updates.md) §7.
  **The reason is the subject of §4.1.** An update overwrites a live install,
  and this scene has no standard. Everything §4.1 describes is the app doing its
  careful best with folders that are frequently two downloads deep, `.ini` files
  hand-written against a case-insensitive loader, and archives whose layout the
  author changed between releases. When that goes wrong the recovery is a person
  looking at a mod folder and working out what happened — and that person has to
  be **at the keyboard when it lands**, not finding out days later that a mod
  they have since edited was silently replaced.
  Two things that look like mitigations and are not, which is the part worth
  keeping:
  - **Confidence is not one.** `exact` on both axes is a strong claim about
    *which remote file this is*. It says nothing about what the folder holds,
    which is where every hazard in §4.1 lives — a byte-perfect identification of
    the right successor still overwrites a hand-merged second mod.
  - **The snapshot is not one either.** It is unconditional already, on its own
    grounds, and the age floor beating the count cap is there because none of
    the accepted losses announce themselves. A recovery nobody knows to reach
    for is not a substitute for having seen the change happen. (Both of those
    stand unchanged; they were never contingent on this feature.)
  **Checking is a different act and *is* automatable**, because it reads a mod
  page and draws a badge — nothing it does is hard to undo. That half shipped as
  M4's opt-in launch check.
  `ModOrigin.allowsUnattendedUpdate` consequently has no reader in `lib/`; it is
  kept as the one place the "`exact` on both axes" rule is code, and filed below.
- [x] **Changelog display** from GameBanana before updating.
  **Done**, in the update dialog, scoped to releases published *after* the file
  you have — a mod with forty update posts is not offering to tell you about all
  of them, it is offering to tell you what you would be getting. Two shapes,
  complementary rather than alternative: `_aChangeLog` is a categorised bullet
  list and `_sText` is prose, and captured feeds carry each without the other.
  One correction to §2's field list: **`_aChangeLog` is the one object in this
  API whose keys are not Hungarian-prefixed** — bare `text` and `cat`, not
  `_sText` / `_sCat` — so reading it the usual way yields an empty changelog for
  every mod, silently. That is the `_aTags` failure again, and it is pinned by a
  fixture test. Fetched **on demand** when the dialog opened from a card badge,
  because that path deliberately makes no request at all.
- [x] **Backup / rollback** — snapshot the previous version before updating so a
  bad update is one click to revert.
  **Done.** `services/backup/` — `<appData>/backups/<mod>/<id>/{manifest.json,
  files/}`, taken **unconditionally** before every apply and before every
  restore, so a rollback is itself undoable. No snapshot, no write: proceeding
  without one would trade a recoverable failure for an unrecoverable one, and
  overwrite has no aside-folder to fall back on the way a swap would have had.
  `retention.dart` is pure with an injected clock and implements §4.2's ordering
  literally — age floor beats count cap, size-aware budget, newest-per-mod never
  pruned. The rollback is reached from the mod context menu, shown only for mods
  that have a snapshot; that gate is one `readdir` of the backups root for the
  whole library, watched rather than read on demand so the first right-click
  does not answer "no" while the listing starts.
- **Preserving user `.ini` edits across an update — considered and rejected.**
  Kept as a record so it isn't re-proposed. The plan was a conservative merge
  (re-apply only edits matching on `[Section]` + key identifier) plus a
  post-update report of what carried over. Three things sank it, in order of
  weight:
  - **There is no pristine baseline to diff against.** After install,
    `modsPath/<mod>/*.ini` is the author's file *and* every later change to it,
    with nothing marking which is which. So a merge compares
    old-with-edits against new-shipped and reports every **author** change to a
    keybind section as a user conflict.
  - **Recording per-`.ini` hashes at ingest does not fix that**, which was the
    obvious repair. A hash divergence cannot tell a hand-edited keybind from a
    **patch mod applied into the folder** from a hand-merge of two mods — so the
    report's headline would be a guess about *why* the file changed, which is the
    one thing it existed to stop being.
  - **The write side is where every hazard lives.** Putting a key back means
    knowing whether the `.ini` still exists or was renamed, whether the keybind
    still carries the same identifier, whether its other settings still make the
    old key correct, and whether that key now collides with one the new version
    added. Four guesses, and a wrong one writes a broken `.ini` into the folder —
    strictly worse than a key the user retypes in thirty seconds.
  - **The demand side is already met.** A reset keybind is low-harm and
    self-announcing: the keybinds view (`keybinds_dialog.dart`) already renders
    what the key *is now*, and muscle memory surfaces the change on first press.
    The user does not need to be told what they once changed.
  What survives is **read-only**: after an update, list the keybinds parsed out of
  the snapshot ("before this update: Skin = F7"). `IniParserService.parseIniFile`
  already turns a path into `List<KeybindInfo>`, so this is one existing call and a
  list in the post-update summary — no matching, no conflict logic, no write path.
  Ranked below everything in §4.1; drop it if it competes.
  The snapshot above is what actually carries this, and rollback already required
  it on its own grounds.

### Open around the update check (known, deliberately not built)

- [ ] **A mixed folder makes us watch the wrong mod page, and we report it as
  clean.** Live today, not introduced by §4.1. When a folder holds a patch plus the
  base mod it patches, exactly one origin block describes it — and in the common
  ordering (§4.1) that block names the **patch**. So `checkForUpdate()` compares
  against the patch's published files and never looks at the base mod, which can go
  three versions ahead while the card says nothing. That is a clean verdict about a
  page nobody asked about, and §4 already names a false "up to date" as the one
  failure this feature cannot afford.
  - **Applying an update is not the broken part** — overwrite does the right thing
    here, replacing the patch's files and leaving the base mod alone. The damage is
    purely the missed base-mod releases.
  - The detection signal is §4.1's dangling-reference scan: an `.ini` in the tracked
    download that references files it does not ship is precisely the shape of "we are
    tracking the patch, not the mod".
  - **The destination is one folder carrying more than one origin block**, which is a
    `docs/metadata-schema.md` + `docs/origin-tracking.md` change and its own piece of
    work. Named now so §4.1 does not accrete workarounds pointing the other way.
  - **The root cause is upstream of all of it: there is no "install this into that
    mod's folder" operation.** Both install paths refuse a name collision
    (`mod_manager_service.dart:499` skips, `:594` aborts), so every mixed folder in
    existence was assembled by hand in a file manager and we are reduced to inferring
    it afterwards from `.ini` contents. An explicit "apply as a patch to…" install
    would make it a recorded fact at write time, and most of the detective work — and
    the single-origin limitation above — would stop being necessary.
- [x] **A found update cannot be acted on.** The dialog lists the newer files and
  then offers a mod page and a marketplace shortcut, because installing from
  the marketplace creates a **second mod folder** rather than updating the
  first — §4.1's overwrite path does not exist yet. The
  dialog says so in one sentence rather than implying otherwise, which is
  honest but is not the feature. This is §4's "applying" half above, listed
  here too because it is the first thing a user will ask for after seeing a
  blue badge.
  **Done** — the dialog's primary action is now **Update**, and the marketplace
  shortcut is demoted beside it rather than removed (installing a second folder
  is occasionally what someone wants; it is now clearly the other option rather
  than the only one). Two rules govern when the button appears, both about not
  guessing on the user's behalf: **only where a file could actually be named**
  (with the installed file gone and nothing identifiably its successor, the
  honest offer is the mod page), and **an ignored update is still installable**
  (they waved the badge away, not the file, and this dialog is where they come
  to change their mind).
- [x] **The options list has no per-row download**, so choosing a file means
  going to the marketplace and finding it again. ~~`GbFileList` already renders
  exactly those rows *with* download buttons and takes an `onDownload`
  callback — but wiring it here means reaching the download-extract-import
  pipeline, which lives inside `marketplace_screen`'s state rather than in a
  service. Extracting that is the same piece of work the item above needs, and
  doing it once serves both.~~
  **Done, and the correction is what makes it right rather than merely
  convenient: a per-row *download* is the wrong verb here.** Downloading a row
  installs a second mod folder, which is exactly the outcome the item above
  exists to stop. The rows are **tappable to select** instead, and the Update
  button installs the selection over the existing folder. The chip on the chosen
  row then reads `your choice` rather than `matches your variant` or `newest
  published` — those are the app's grounds for its own pick, and reusing them
  for the user's would be taking credit for a decision it did not make.
  What *was* extracted is only the **download** half
  (`dialogs/download_with_progress.dart`), shared with the marketplace. The
  extract-and-import half deliberately stays where it is: the marketplace
  imports an archive as a new mod folder while an update overwrites an existing
  one, and folding those together is what would produce a shared "install" that
  quietly does the wrong one.
- [x] **The marketplace card's "update available" state is refused.** It read as
  small — the verdict needs no request, since `modUpdateChecksProvider` is keyed
  by folder and `InstalledModsIndex.installsOfMod` turns a browsed mod id into
  folders — and being cheap to *draw* is what made it look obvious. Two things
  kill it, and both are about what happens after it is drawn.
  **Blank would read as "no update".** Verdicts are session state and are never
  persisted (deliberately — a restored verdict asserts something about a page
  nobody has looked at since), and the launch check is off by default, so on a
  normal launch the map is empty and every card would show nothing. An indicator
  that is usually absent teaches absence to mean *up to date*. The library
  survives that because the button that fills the map is in its own toolbar; the
  marketplace would be showing the residue of an action taken elsewhere.
  **And the badge has no action behind it.** This screen's Download enqueues an
  install, and `importMods` skips a folder that already exists — so pressing it
  on a mod you own downloads a whole archive to report "Nothing imported", or,
  when the author renamed the folder between versions, quietly lands a second
  copy. Updating is `applyUpdateFlow` (snapshot, overwrite in place, keep name /
  character / favourite / enabled, reconcile keybinds, ask first), which §4.1
  keeps separate from installing on purpose. So the badge alone is a trap, and
  with the action the whole update conversation moves into a browse screen.
  Recorded in [`docs/marketplace.md`](docs/marketplace.md) §7 so the slot's one
  branch is not read as an omission.
- [ ] **"In your library as …" is a dead label.** The opposite direction to the
  refusal above, and the thing actually missing: a mod you already own is named
  on the marketplace card and in the detail view's notice, and neither takes you
  to it. A link to the library entry is useful whether or not anything is out of
  date, needs no check to have run, and is the honest answer to "I already have
  this — what do I do about it?". Wants deciding where it lands the user: the
  Mods tab filtered to that folder, or the folder's own dialog.
- [x] **There is no "has an update" filter.** The `!` toggle enumerates mods
  whose *origin* is incomplete and deliberately ignores update state (its
  meaning would otherwise change every time a check ran). So a 200-mod library
  can be told that 14 mods have updates and then has to find them by scrolling.
  ~~The natural home is a second toggle beside the check button rather than a
  sixth filter~~, and it needs no new decision logic — `UpdateCheck.hasUpdate`
  already answers it.
  **Done, and the correction is the interesting half: a second toggle was
  rejected outright.** Asked for after using it, in exactly the terms this item
  predicted — "128 mods, 3 have an update, you have to search for it". A
  seventh toolbar control that means nothing until a check has run is a
  permanent cost for an occasional state, so the **check button carries both
  jobs**: bare icon runs the check, a count filters the grid to what it found.
  The rule keeping that legible is *the control does the only useful thing
  available*, and the count is the visible signal for which mode it is in — no
  hidden state, and every launch starts in check mode because the results are
  session-scoped. Re-checking moves to a **check again** in the second row,
  which is not a new idiom either: the bulk "assume current" button already
  lives there, and for the same reason.
  Two scopes meet in the one button, deliberately: the *check* is library-wide
  (its badges are drawn on every tab), the *filter* is view-scoped (that is all
  it can narrow). The consequence was raised before building and accepted:
  updates on other character tabs are reachable from "All", not from a tab with
  none of its own.
  Two things the tests had to force out. **The filter switches itself off once
  the library has no updates left** — asked for directly, and the same rule the
  bulk "assume current" action already follows; the subtlety is that it keys on
  the *library* rather than on the view-scoped count beside it, or clicking a
  character tab with none of its own would make the filter evaporate. And the
  second row can now
  carry **three** buttons — but only via a mod identified by a banked archive
  hash, which is the one way a mod can need attention *and* have an update at
  once; a test pumps that at 480px, since that row is where the last overflow
  bug came from.
  Written up in [`docs/update-checks.md`](docs/update-checks.md) §6.
- [x] **`remote_missing` is now *detected* and still never written.**
  `checkForUpdate` returns `sourceGone` from the remote's explicit
  `_bIsPrivate` / `_bIsTrashed` / `_bIsWithheld` flags, and the bulk pass
  returns it for an id the server refuses outright — but nothing persists it to
  the sidecar. Deliberate rather than forgotten: §7.4 currently *silences* the
  status slot for a `remote_missing` mod, so writing the flag today would make
  the mod go quiet permanently with no wording explaining why, which is exactly
  the "silent hole" already filed under §7.5. The two have to land together —
  the state needs its own wording ("source no longer available") before
  anything writes it.
  **Done, and they landed together as this predicted they had to.** The bulk
  resolution screen offers the write, and `ModOriginStatus.sourceGone` is the
  state that makes it safe to accept: a muted **broken link** on the card, told
  apart from the dot and the clock by shape rather than by colour, like the
  other two quiet states. Three decisions came with it.
  - **It is not counted by the "needs attention" filter.** That filter's promise
    is that everything in it can be dealt with, and a private, trashed or
    withheld page cannot be — a count that can never reach zero however much
    work the user does is the one thing that turns a count into noise.
  - **`tracking: "off"` still wins over it**, unchanged: a stale `source_url` is
    exactly why somebody might have declared a mod their own.
  - **The reverse is written too.** A page that answers normally while the block
    says it is gone offers to *clear* the flag, pre-ticked. Without it the first
    write would be permanent in practice, since nothing else ever revisits it —
    and a mod page coming back (unwithheld, un-privated) is an ordinary thing.
- [x] **Verdicts are session state, and that is a decision worth revisiting
  once, not a gap.** Nothing is persisted, so the badges are empty on every
  launch until a check is pressed. That is right on the merits — a verdict
  restored from disk asserts something about a mod page nobody has looked at
  since — but the *user-visible* consequence is that the feature looks off
  until they find the button. The fix if it is ever wanted is a nudge or an
  opt-in check-on-launch, **not** caching the verdict.
  **Done, and exactly as this predicted: the opt-in check-on-launch, with the
  verdicts still never persisted.** The distinction is the whole point — the
  badges are filled in by a *fresh* pass rather than a remembered one, so the
  appearance the complaint asked for is bought without asserting anything
  nobody has checked. Off by default, so a user who never finds the setting
  still gets today's behaviour and no launch traffic. §5.1 of
  [`docs/update-checks.md`](docs/update-checks.md) owns it.
- **The per-mod check fetches a whole `ProfilePage` when `DownloadPage`
  would do.** `Mod/<id>/DownloadPage` returns `_aFiles` + `_aArchivedFiles`
  plus the upstream-gone flags and nothing else — everything the comparator
  reads except `_tsDateAdded` (the baseline clamp) and `_tsDateUpdated`. Not
  taken: the dialog would then need a second request for the two dates, and the
  profile is very often already in the client's ten-minute cache from the
  marketplace. Worth measuring before assuming either way. Note the `Uri`
  builder for that endpoint has since been **removed** as dead surface (§2), so
  acting on this means re-adding it — four lines, against a response shape
  already pinned by `test/gamebanana/gb_parse_test.dart`.
- **The batch bisect could ask the error which id was bad.** A
  `NO_SUCH_RECORD` response names the offending id in `_sErrorMessage`
  (`Record Mod.999999999 doesn't exist`), so a parser could drop it and retry
  once instead of halving. Not taken because it trades a structural recovery
  for a string-format dependency on server English, and the message names only
  the *first* bad id anyway — several dead ids would still need several round
  trips. Revisit only if the request count is ever measured as a problem.
- [ ] **`_buildGroups` still owns the scan, and the flat list is derived from
  it.** `modsProvider` is now real (see the read side's filed item above) but in
  the *opposite* direction from what that item proposed: groups are built by the
  screen and the flat list falls out of them. Inverting it — scan into a flat
  list, derive the character groups — is the tidier shape and is what would let
  the library live outside `ModsScreen`'s lifecycle, which is a third filed item
  ("nothing keeps the library list live across a tab switch"). All three are one
  piece of work whenever it is done.
- [x] **`Mod/<id>/Updates` is read, but only for `_aFileRowIds` and `_sName`.**
  §4's "changelog display before updating" wants `_sText` / `_aChangeLog`, which
  are parsed by nothing. The DTO deliberately stops at what has a reader — the
  `_aTags` bug is what an unread field costs. Belongs with the applying half: a
  changelog is what you read *before pressing update*, and there is nothing to
  press yet.
  **Done**, and the prediction in the last sentence was exactly right: reading
  `_aChangeLog` the way every other field on this API is read yields an empty
  list for every mod, because **it is the one object here whose keys are not
  Hungarian-prefixed** — bare `text` and `cat`, not `_sText` / `_sCat`. Pinned
  by a fixture assertion so it cannot regress silently the way `_aTags` did.
  `_sText` is HTML and goes through the same `htmlToMarkdown` a mod page's
  description does. The two are complementary rather than alternatives: one
  captured feed carries five categorised bullets and prose, another carries
  prose and no bullets at all.
- [x] **The last variant-shaped false positive is not removable by anything the
  author stated, and four candidate rules were measured and rejected.** Filed as
  *resolved* rather than open because the answer is "don't", and the measurement
  behind it is the deliverable — the temptation to fill this gap is strong and
  the next person needs the numbers, not the conclusion.
  Corpus: **300 ZZZ mods**, their current files and their update posts, with
  `_aFileRowIds` as ground truth for "released together". The headline is that
  **only 27% of newer-than file pairs have both files named in a post at all**,
  so the authoritative signal genuinely cannot cover most cases.
  Filename matching is **anti-correlated** (stem-prefix 13/106 vs 38/277;
  stem-equality 0/106 vs 5/277) — GameBanana's random `_xxxxx` suffix makes
  stems unstable, which is exactly the fuzzy-matching trap `origin_resolution`
  already refuses. "Candidate unlabelled while mine is labelled" is a coin flip
  (8/106 vs 6/277). Identical file size never fires.
  Two rules *did* measure well and were rejected on grounds the numbers cannot
  see, which is the part worth keeping:
  - A **1 h co-publication window** agrees with the author's own grouping on
    85/106 known co-releases against 2/277 cross-post pairs, on a flat plateau
    from 15 min to 2 h (cliff at 24 h). Its contribution *over* release groups
    and same-version is 99 pairs, and all 99 rest on "an author does not upload
    twice in a session for two different reasons" — which one hotfix published
    minutes after a broken file breaks, silently. No data can confirm that
    assumption, only fail to contradict it.
  - **"A file that already existed when you installed cannot be an update"** is
    causal, threshold-free, and clears both remaining false positives outright
    (their candidates predate the installs by 11 months and 2 months). It rests
    on `installed_at`, a **proxy** for anything this build did not install — and
    a plain `cp -r` resets every mtime, making the proxy read *late*, after
    which every published file predates it and the feature goes silently quiet.
    That is the hazard §7.3 already names as the reason the proxy uses the
    oldest *contained file* rather than the folder's mtime. Building a
    suppression on that date reintroduces it.
  The line held: **a rule may turn a flag off only if the author stated the
  fact.** Written up in
  [`docs/update-checks.md`](docs/update-checks.md) §3, which is now the place to
  read before proposing a fifth rule.
- **`_bHasFiles` on an update record is unreliable** — it reads `false` on a
  record whose `_aFileRowIds` names two files (measured on `549029`). Nothing
  reads it; noted so nothing starts to.

### Open around applying an update (known, deliberately not built)

- [ ] **A sibling group updates one member at a time, re-downloading the archive
  for each.** One archive can install as several mods, each with its own origin
  block and its own update check, and nothing groups their updates: updating
  three siblings means three full transfers of the same file. §0 measured a
  1.24 GB tail, so this is a real cost rather than a tidiness point. It is not
  *wrong* — each folder is updated correctly — and it is bounded by how rare
  multi-folder archives are, which is why it was filed rather than built. The
  cheap half is a notice ("two other mods came from this archive"); the real fix
  is one download feeding every member of `ingest.sibling_group`. **Note the
  interaction already recorded under auto-update:** one banked hash can mark a
  whole group `exact`, so an unattended update would rewrite all of them at
  once, and *that* path must snapshot the group rather than the folder.
- [ ] **There is no "update all".** The bulk check finds every mod with something
  newer and the filter lists them, and then each one is a dialog. For the 3-of-128
  case that is fine; for a library that has not been updated in months it is not.
  It needs the §7.6 results screen to exist first — a per-row confirmation surface
  is exactly where a bulk apply belongs, and bolting one onto the toolbar instead
  would mean a control that rewrites folders the user never enumerated, which is
  the placement rule the bulk "assume current" button already follows.
  **The prerequisite exists now** (§7.6 shipped) and this is still not built,
  deliberately: that screen currently only ever rewrites *sidecars*, and an
  "update all" on it would download and overwrite mod folders from the same
  button. The two need visibly different weight before they share a surface —
  and each apply already has its own confirmation, its own snapshot and its own
  stale-`.ini` question, none of which collapses into a checkbox.
- [ ] **Total backup size is not surfaced anywhere.** The rollback dialog shows a
  size per snapshot; there is no whole-library figure, so the retention budget
  bounds something invisible. §4.2 always intended this to live in the storage
  view (backlog); `SnapshotService.totalBytes()` exists and has no reader. Worth
  pairing with a "delete all snapshots for this mod" action, which the per-row
  delete currently makes tedious.
- **The retention numbers are not user-configurable**, deliberately for now
  (30 days / 3 per mod / 5 GB). They are the kind of setting that is easy to add
  and hard to remove, and nobody has asked. If they are ever exposed it belongs
  with §6's Settings work, and the age floor has to keep beating the count cap in
  the UI too — a settings screen that presents them as two independent numbers
  would invite exactly the configuration §4.2 argues against.
- [ ] **`ModManagerService._copyDirectory` and `utils/directory_copy.dart` are two
  copies of the same walk.** The update path needed an excluding copy, and the
  private one has a behavioural difference — it follows links, the shared one does
  not — so delegating would change the **import** path's behaviour for symlinked
  content inside an imported folder. Left alone rather than fixed as a drive-by.
  Whoever unifies them has to decide what an import should do with a link, which
  is a real question and not a refactor.
- [ ] **The update flow is silent between the download finishing and the
  confirmation appearing.** Extraction plus two folder walks, with no modal up:
  the same shape as the install path's already-filed quiet window, and the same
  fix (keep the progress dialog open through a "preparing" phase rather than
  bolting a spinner onto one step). Longer than the install's for a big archive,
  because extraction is the slow part and it happens before anything is shown.
- **Cancelling at the update confirmation still costs a full re-download.**
  `archiveConsumed` is set once extraction succeeds and the dialog comes after,
  so backing out deletes the archive. Deliberate — the alternative is keeping
  every declined archive in a folder the user does not manage, and §0 measured a
  1.24 GB tail — but it is a real cost on a slow connection and nobody has been
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
- [ ] **A shipped `ShaderFixes/` is the one leftover class that can stay live**,
  and it is unverified. Shaders are picked up by filename convention rather than
  by `.ini` reference, so a shader the new version stopped shipping is not
  detectable by anything in the patch/stale rules, which are reference-based by
  construction. Recorded in `docs/applying-updates.md` §1 as the known gap.
  Confirming the loader's actual behaviour is the first step; it may turn out to
  be a non-issue.

### 4.1 How an update is actually applied

Everything above is *when* to update. This is the part that touches a live
install, and it's where this codebase's specific hazards live. An update is
**not** a re-run of the import path.

**The mechanism is overwrite — extract to temp, then copy over the live folder.**
Never empty it, never move it, never delete it. Everything below follows from that
one decision, so the reasoning for it comes first.

A mod folder is often **mixed**: it holds files from two downloads, because a *patch
mod* was applied into it. Patches replace rather than add — a patch `.ini` carries the
**same filename** as the mod's own and takes its place, and a patch asset likewise
overwrites one of the mod's files. So a mixed folder looks completely ordinary from
the outside: one `.ini`, every referenced file present, nothing extra.

Replacing such a folder destroys the other download, and the common case is worse
than losing a fix. The ordering that produces it is routine: a page looks like a
normal mod, so it gets installed; the game shows nothing; the user reads the page
properly, finds it is a patch, and drags the base mod's files in around it. The app
now knows that folder as **the patch**. Replace it and what remains is a lone `.ini`
with nothing to apply to — the mod is gone, not merely unfixed. Overwrite in the same
situation copies the new patch file over the old one and touches nothing else, which
is exactly right.

- [x] **Extract to temp, sanity-check, then copy over.** Not "unpack straight onto
  the live folder". The crash-safety worry that made the old swap plan attractive —
  a half-finished extraction leaving a folder holding two versions at once — is
  answered by the temp step, not by the swap, so overwrite keeps that property for
  free. `ArchiveService`
  already extracts to `Directory.systemTemp.createTemp('zzz_archive_extract_')`
  and `ArchiveService.containsIniFile` is the check, so a failed or half-finished
  extraction never touches the installed mod. Only the final copy does, and
  `_copyDirectory` (`mod_manager_service.dart:695`) already has precisely the
  right semantics: `create(recursive: true)` no-ops on an existing directory and
  `File.copy` overwrites, so colliding files are replaced and everything else is
  left alone. The update path is mostly this existing code with one exclusion
  added.
  **Done**, with one departure worth recording: the copy is
  `utils/directory_copy.dart` rather than `ModManagerService._copyDirectory`,
  which is now a **second copy of the same walk**. They differ in one respect —
  the private one follows links, the shared one does not — so unifying them
  changes the *import* path's behaviour and was left alone rather than fixed as
  a drive-by. Filed below.
- [x] **Exclude `.zzz-mod-manager/` from that copy.** This **replaces** the older
  "carry the sidecar across the swap" rule, which only made sense while there was a
  swap to carry it across. The sidecar holds the description, user-imported gallery images, tags and the
  origin block, and a download can legitimately contain a `.zzz-mod-manager/` of
  its own the moment anyone shares a folder they managed with this app — so an
  unfiltered copy overwrites the user's metadata with a stranger's, including the
  origin block that decides which page we check. Note the *install* path already
  handles the inbound-sidecar case deliberately and differently
  (`mod_metadata_repository.dart:237` replaces a stranger's origin block by
  construction while keeping their description and images on purpose); this is the
  update-path equivalent, and it excludes rather than merges because there is
  nothing here we want from the archive.
- [x] **The active link survives by construction — and that removes a whole
  hazard.** The previous plan needed a deactivate → move → reactivate dance
  because moving the folder dangles `saveModsPath/<name>` and
  `_cleanupInvalidLinks()` then prunes it, silently switching the mod off.
  Overwriting never moves the folder, so the link stays valid throughout and
  nothing needs pruning. Deactivation is now only about **open file handles**
  (below), not about link integrity. Still restore the previous active state and
  fire the F10 reload when `autoF10Reload` is on.
- [x] **The folder name never changes.** The new archive's root folder is frequently
  named differently (`Ellen v2`), but `config.json` keys `active_mods`,
  `favorite_mods` and `mod_character_tags` by folder name. Keep the existing name;
  record the new upstream name in the origin block if it's worth showing. Trivially
  satisfied by overwrite, which never names anything.
- [x] **Offer to delete a stale `.ini` when the new version renamed its own.**
  ~~After the copy, any `.ini` we did not just write is a leftover~~, and the loader
  reads *every* `.ini` in the folder — so a v1 file beside a v2 file means
  duplicate hotkeys and settings fighting each other, which presents as "the update
  broke my mod". Default to **delete**, with the reason shown.
  **Correction (applied): "any `.ini` we did not just write" is too broad, and in
  the one direction this whole path exists to avoid.** Under it, updating one of
  two mods a user merged by hand offers — by default — to delete the other one's
  `.ini`; that is the destruction overwrite was chosen to prevent, with a dialog
  in front of it, and it contradicts the "do not clear all `.ini` files" bullet
  three items below, which refuses the same act for the same reason. The intent
  is untouched. The test is now **"does this file describe the content we just
  wrote"**: stale iff every resource it names is a file the incoming download
  ships. An upstream rename satisfies that by construction; a merged second mod
  names its own files and is *kept and named* instead; an `.ini` naming nothing
  checkable is kept without asking, because "we could not tell" is not "safe to
  delete". Implemented in `services/update_apply/stale_ini.dart` (pure), and
  used in **both directions** — a rollback orphans the `.ini` the newer version
  added, which is stale exactly when the snapshot carries everything it names.
  - It fires **only on an upstream rename**, which is uncommon. A patch `.ini`
    shares the mod's filename, so an update overwrites it and it never appears
    here. This is worth stating because the opposite was assumed at one point, and
    it changes the design: this is an occasional prompt, not a routine screen that
    needs a one-click bulk path.
  - The residual cost is honest and small: if that stale file had been patched,
    deleting it drops the patch. Keeping it is worse (two live `.ini` files), and
    the snapshot still holds it.
- [x] ~~**Detect a patch by the files its `.ini` asks for and does not ship.**~~ An
  `.ini` names the resources it needs; if those files are absent from the download,
  it cannot stand alone, so it is a patch expecting a host. This is close to
  definitional rather than heuristic — a patch `.ini` is a *full replacement* for
  the mod's `.ini`, so it references everything the mod needs while shipping none of
  it. Two uses, one implementation:
  **Correction (applied): the headline rule is empirically wrong, and this is
  the largest correction this doc has taken.** It was shipped as written, and
  the very first real update — a freshly downloaded, complete, working mod —
  reported "this download expects 2 file(s) it doesn't include". Two rounds of
  measurement followed, both against real archives.
  - **Round one found a real bug and a real fix, which was not enough.** A
    `[Resource…]` section carrying a `filename` *defines* a resource; the loader
    only opens the file when something says `ref ResourceFoo`. A definition
    nobody references is inert, and authors leave them behind by the dozen
    because they start from a full character template. `Miyabi Transfer Student`
    (700727): **31 declarations, 29 referenced and shipped, and the 2 nobody
    references are the only 2 absent.** So only a *referenced* declaration is a
    requirement. That rule is right, is implemented, and its `.ini` is checked in
    as a fixture — but it fixed one mod, not the rule.
  - **Round two killed the premise.** Over **29 real ZZZ archives** the
    "references a file it does not ship" test scored **1 true positive and 6
    false ones**, and did not flag the one archive in the corpus with "Patch" in
    its name. The reason is structural: a ZZZ character is several components,
    the extraction tools emit an `.ini` covering **all** of them, and an author
    who replaces one component ships that component and nothing else.
    `Remielle combat wings replaced` (701954) is a complete standalone mod whose
    `.ini` references **36** files while the archive contains **8**. *Partial
    mod* is the normal case and the rule could not see the difference.
  - **A ratio cannot rescue it, and this was measured rather than assumed.** The
    six false positives sat at **0%, 2%, 18%, 22%, 32% and 92%** of their
    references present — the entire range — so there is no cutoff to put between
    the populations. Worth recording because "require most of it to be missing"
    is the obvious next idea; it was asked for, built, measured and removed.
  - **The rule that works: a patch ships no content.** At least one `.ini`,
    references that are absent, and **not one referenced resource present**.
    The single real patch in the corpus, `Nicole Casual Wear (Updated Ini's
    3.0)`, is 5.8 KB of five `.ini` files and nothing else — 52 references, 0
    present. Every false positive ships 5–20 of the resources it references. No
    threshold, and it separates the corpus completely. Includes are excluded
    from "present": one `.ini` including another is a patch's own structure, not
    content, and counting it made the `Nicole` archive stop looking like a patch.
  - **The stale-`.ini` rule had the same flaw and took the same fix.** It asked
    whether *every* resource a leftover names is supplied by the incoming
    download; against a template `.ini` that is never true, so it would have
    silently stopped offering to remove a renamed duplicate. It now compares only
    the references the folder **actually satisfies today**.
  All of it is in [`docs/applying-updates.md`](docs/applying-updates.md) §2 with
  the numbers and the per-archive table. The general lesson is the one this
  project keeps relearning: **the rule looked definitional and was not, and only
  pressing the button on a real mod exposed it.** Nothing in the test suite
  could have — every fixture was written by the same person who believed the
  premise.
  The original two uses stand, and both are wired:
  - **At install** — say so up front ("this looks like a patch for another mod")
    instead of letting the user discover it when the game shows nothing.
  - **Before an update** — if the *incoming* download is a patch, the folder we
    are about to write into must be mixed. Warn, and state that only part
    of it is being replaced. This works on the **existing library** with no recorded
    data and no extra request, because the new archive is already in hand. It is
    also the only signal that can notice we are tracking the patch rather than the
    mod — see the filed item in §4 about updates checking the wrong page.
    Note the corrected rule **narrows** this: it fires only for a download that
    brought no content at all, so the mixed-folder inference is now rarer and
    correspondingly stronger.
  - **Limitation, stated because it bounds the whole feature:** this cannot see a
    mixed folder whose *tracked* download is the base mod with a patch applied on
    top. Nothing is missing there, so nothing looks wrong. That direction is
    accepted loss (§4) and is the milder one, since the base mod's update usually
    contains the same fix.
  - **Three ways to get this wrong.** ~~An `.ini` can `include` another and can use
    namespaces, so resolving each file in isolation makes a normal multi-`.ini` mod
    look broken — follow those first.~~ Entries with no `filename` at all are
    run-time buffers, not missing files. And "two `.ini` files sharing no
    resources" is **not** a mixed-folder signal: a single mod bundling three skins
    looks exactly like that.
    **Correction (applied): the first hazard is real and the mechanism named for
    it is not.** A `namespace = …` renames *sections*, so that two mods can both
    define `[ResourceBody]`; it has no bearing on a `filename`, which is always
    relative to the `.ini` that wrote it. What actually makes an ordinary
    multi-`.ini` mod look broken is reading each file **in isolation** — a mod
    that declares its resources in one file and its overrides in another is
    routine. So the rule is that a folder's `.ini` files are parsed
    **collectively**, and `include` / `include_recursive` are themselves
    references, to a file and to a directory respectively. Two more that had to
    be added: **a value that is not a literal path cannot be checked** (a
    `$\ns\slot` variable, a wildcard, an absolute path) and is counted
    separately rather than reported missing; and **paths compare
    case-insensitively on every platform**, because 3DMigoto is a Windows loader
    and authors write `Body.dds` against `body.dds` freely — a case-sensitive
    comparison on Linux would call every such mod a patch.
  - ~~**There is no threshold, and that is deliberate.** One dangling reference is
    enough: a complete mod ships every file its `.ini` opens.~~
    **Void — see the correction above.** "A complete mod ships every file its
    `.ini` opens" is the false premise itself; measured, most ZZZ mods do not.
    There is still no threshold, but for a different reason: the verdict is now
    "the download brought no content", which is a fact about the archive rather
    than a proportion of one. The trade also inverted — a patch that ships one
    new texture is now **not** flagged, and that is accepted, because the six
    false positives it buys back were being printed over live installs.
  - `IniParserService` only understands keybind sections (`_isKeybindSection`),
    so resource parsing is new and went to its **own** unit,
    `services/ini_resources.dart`, rather than into the keybind parser: it
    answers a different question and is pure over text, where the keybind parser
    reads files. `services/patch_scan.dart` is the thin I/O side, shared by both
    install paths so a folder cannot be assessed two different ways.
- [x] **Unused leftovers are acceptable; only `.ini` files are not.** Overwrite
  leaves behind files the new version stopped shipping. For models and textures
  that is wasted space and nothing more, because the loader only touches what an
  `.ini` references. **Do not "solve" it by clearing all `.ini` files before
  copying** — harmless on a folder with one `.ini`, destructive on a folder where
  two are live (two mods merged by hand), and it buys only what the stale-`.ini`
  prompt above already does with the user's consent. One asterisk worth checking
  rather than assuming: shaders are picked up by filename convention from a shader
  directory rather than by reference, so a mod shipping its own `ShaderFixes/` is
  the one file class where a leftover can be live.
  **Done as written, and the asterisk is still an asterisk** — the shader
  convention was not verified against the loader, only recorded in
  `docs/applying-updates.md` §1 as the known gap. It is not blocking: a stale
  shader is the same class of problem as a stale `.ini` and the snapshot covers
  it, but nobody has confirmed the failure mode.
- [ ] **Recording the file list an archive laid down — later, not now.** The
  precise mechanism is to save each download's file list at install and, on update,
  remove exactly those paths before writing the new ones. It needs no guessing and
  it would make the overwritten-patch case detectable. It is **not a prerequisite**:
  the data does not exist for a single currently-installed mod, which is the entire
  library and every mixed folder in it. Reconstructing it by re-downloading the
  *old* archive does not rescue it either — that is a second full transfer (§0:
  22 MB median, 1.24 GB tail), and GameBanana deletes old file ids, so it is
  unavailable exactly for the old mods most likely to have been patched. Add it
  narrowly, alongside or after the above, so installs from that point on get the
  precise path. Self-healing per §7.7.
- [x] **Windows will refuse to overwrite files the game holds open.** ZZMI keeps
  handles on loaded mods, and overwrite runs into this exactly as replace would —
  the deactivate step is no longer needed for link safety (above) but may still be
  needed for this. Either require the game closed, or handle the busy error
  explicitly. **Failing halfway is worse here than under the old swap plan**: a
  partly-copied folder holds some new files and some old, and unlike a swap there
  is no aside-folder to fall back to. The snapshot is the only recovery, which is
  another reason it is taken unconditionally rather than only for auto-update.
  **Done as the second option** — the mod is deactivated for the copy (which is
  now *only* about handles) and a copy that still fails is reported as a failure
  naming the snapshot and telling the user to close the game. **Not verified on
  Windows:** there is no Windows machine in this environment, so the busy-file
  path has never actually been hit.
- [x] **Never re-ask the import questions.** The install path prompts "which folders?
  separate or combined?" (`resolveImportSelection`); an update replays the recorded
  answer from `ingest` (§3). If the new archive's layout no longer matches what was
  recorded, that is a **stop-and-ask**, not a guess.
  **Correction (applied): this describes the rare path, not the common one.**
  `ingest` is written by this build and by nothing else, and §7.3's backfill
  recovers identity and deliberately not layout — so on a real library there is
  no recorded answer for **any** mod. The replay is built and correct, but the
  fallback carries almost all the traffic and had to be designed rather than
  left as an afterthought: exactly one top-level folder maps to the mod folder,
  anything else stops and asks with its own wording ("nothing was recorded"
  rather than "the layout changed" — different facts, and only the second
  implies the author did something). An applied update then *writes* an
  `ingest`, so a mod gains a layout the first time it is updated.
- [ ] Reuse this same path for a **reinstall / repair** action — it's the identical
  operation at the same file id, so it costs nothing extra.
  **Not built**, and still true that it costs nothing extra: `applyUpdateFlow`
  takes a `GbFile` and does not care whether it is newer than what is installed.
  What is missing is a surface — the update dialog only appears with a finding,
  and a repair is wanted precisely when there is none. It wants its own context
  menu entry that fetches the profile and re-applies `origin.file_id`.

### 4.2 Backups — where they live

- [x] **Outside `modsPath`.** A snapshot placed *inside* the mod folder is reachable
  through the active symlink, so ZZMI traverses it and loads the old version's `.ini`
  alongside the new one — duplicate hotkeys and conflicting overrides, which present
  to the user as "the update broke my mod". Snapshots go in `<appData>/backups/<mod>/`.
  **Done**, as `<appData>/backups/<mod>/<id>/{manifest.json, files/}`. The
  manifest sits *beside* `files/` rather than inside it, so a restore copies
  `files/` back wholesale without carrying our bookkeeping into the mod folder.
  The sidecar **is** snapshotted: a rollback that restored the files but kept the
  new origin block would leave the app checking for updates against a file the
  folder no longer holds. `manifest.json` is its own small format and is
  deliberately **not** part of `docs/metadata-schema.md`.
- [x] **Bounded retention.** §7.2 has `inferred` updates *keep* their backup rather
  than pruning it, which grows without limit. Pick a cap (last N per mod, or an age
  limit), and expose total backup size in the storage view (backlog) so it isn't
  invisible disk usage. §0's sizing: the median mod is only ~22 MB, so a generous
  count cap is cheap for most libraries — but the tail reaches 1.24 GB, so the cap
  has to be **size-aware**, not purely count-based, or a handful of big mods quietly
  eats several GB.
  **Done** — 30 days, 3 per mod, 5 GB, in `services/backup/retention.dart` (pure,
  injected clock). Four tiers walked in order, with the newest snapshot of each
  mod in tier 0 and never pruned. Pruning runs after a successful update, which
  is the one moment a snapshot has just been added and already an operation the
  user is waiting on; nothing else triggers it. **The storage-view half is not
  done** — the backups dialog shows a size per snapshot and no total, and there
  is no whole-library figure anywhere. Filed below rather than counted here.
- [x] **Retention has to outlive discovery, which is a stronger constraint than the
  cap.** §4.1 makes the snapshot the recovery route for every loss the update path
  deliberately accepts — reverted keybinds, an overwritten patch, any hand edit. None
  of those announce themselves during the update. They surface the next time the user
  launches the game and finds a hotkey dead or a texture back to default, which is
  plausibly days and several further updates later. So "keep only the newest snapshot
  per mod" throws away exactly the one they will come looking for: the **age floor
  beats the count cap**, and where they conflict, age wins.
  **Done, and implemented literally**: a snapshot beyond the count cap but inside
  the age floor is pruned *only* under size pressure, and only after the ones
  already past both. A test walks six snapshots taken the same afternoon and
  asserts that none is deleted.
- [x] **Restorable from inside the app, or the whole design is paper.** §4 already
  specifies one-click revert; this is the same requirement stated as a dependency,
  because §4.1's accepted-loss decisions are only defensible while the recourse is
  reachable. If restoring means finding `<appData>/backups/` in a file manager, then
  "recoverable from the snapshot" is not a real answer to a user who has just lost a
  mesh patch. There is **no snapshot/backup service in `lib/services/` yet**, so this
  is ahead of us rather than a retrofit — cheaper to design in now.
  **Done.** `screens/dialogs/mod_backups_dialog.dart`, from the mod context menu,
  shown only for mods that have a snapshot. A restore **snapshots first**, so it
  is itself undoable — a user who rolls back the wrong mod, or finds the old
  version was the broken one, is one click from where they were.

## 5. Download manager

- [x] Extract the inline download code out of `marketplace_screen.dart`
  (`_downloadToTemporaryFile` bare `HttpClient`) into a dedicated service.
  **Done in M1** (`services/download/`). The *install* followed it out in M4 —
  see the roadmap item — so `marketplace_screen.dart` now holds only the two
  screens and the choice dialog.
- [x] Queue + progress. **Resume is M1, not M4** — §0 measured the numbers behind
  this; `docs/gamebanana-api.md` §8 has the mechanics. What the service must do:
  - **Resume by re-requesting the original `/dl/<id>` with `Range: bytes=<have>-`.**
    Range survives both redirect hops, so the resolved `filecacheNN` url never needs
    persisting. Send `If-Range` with the stored `ETag`; it's `hex(mtime)-hex(size)`
    and identical across nodes, so a resume landing elsewhere won't restart.
    Expect `206`; treat a `200` as "file changed upstream, start over" and `416` as
    "already complete".
  - **Stall timeout, never a total-duration timeout.** Abort only after N seconds
    with zero bytes. A legitimate download can take ~25 minutes.
  - **Don't retry-storm a slow node.** Node assignment is deterministic per file, so
    reconnecting lands on the same machine; resume from the offset instead.
  - **Backpressure the socket** (`sub.pause(sink.addStream(...))`). Today's
    `sink.add()` is never awaited and the subscription is never paused.
  - Persist enough per download (`file_id`, expected size, ETag, bytes-on-disk) that
    a resume survives an app restart, not just a flaky connection.

  Every bullet above landed in **M1**, in the service. The **queue** on top of it
  is M4's, and its own decisions are in
  [`docs/downloads.md`](docs/downloads.md) §7. One correction to what this list
  assumed: the queue itself is **not** persisted, and deliberately — a queue
  restored from disk would start re-fetching on launch, while the partials on
  disk already are the durable half. Asking for the file again is what resumes
  it.
- [x] Progress UI must suit hour-long transfers: rate + ETA, not just a bar, and
  cancellable throughout. `_nFilesize` exactly equals `Content-Length`, so it's a
  reliable denominator and ~~a preflight disk-space check~~.
  **Done** — the modal dialog in M1, and now `DownloadsPanel`, which shows the
  same three figures per row for several transfers at once and never hides a
  failure behind an auto-clearing row.
  **The preflight disk-space check was never built.** `InsufficientSpaceException`
  exists and nothing raises it; Dart exposes no portable free-space API, so it
  wants a `PlatformService` method. Filed below rather than counted here.
- [x] **Unify the download directory.** Today it's inconsistent (system Downloads
  on Linux vs `<appData>/downloads` for HTTP grabs). **Decision**: incoming
  archives land in **`<appData>/downloads`** and are **deleted after successful
  extraction** — the archive is a throwaway intermediate. Not user-configurable in
  M1; add a config key later only if requested.
  **Done in M1**, and the queue is what makes the "one shared folder" half of
  that decision load-bearing rather than incidental — see the file-id
  de-duplication in the roadmap item above.
- [x] One consistent download → extract → tag → (optionally activate) flow for
  both platforms. **Every** entry point into it (download, drag-drop, file picker)
  hashes the archive on the way through, *before* the archive is deleted — §7.8.
  **Done.** The download half is `DownloadQueue`, the import half
  `install_archive_flow.dart` and the mods tab's own path, and both run
  `confirmArchiveNotDuplicate` and bank the hash.
- [x] Revisit the current SSL-validation bypass on Win/Linux.
  **Done in M1, and this line was already stale when M4 started.**
  `IoDownloadTransport` simply never sets `badCertificateCallback`, so there is
  nothing left to bypass. The consequence recorded in
  [`docs/downloads.md`](docs/downloads.md) §4 stands: the isolate pump builds its
  own transport, so its TLS behaviour is deliberately **untested** rather than
  tested behind a hole in that rule.

### Filed while building the queue

- [x] **Source comments cite a section of this file**, which gets deleted as its
  contents ship — taking the meaning and leaving a dead reference. Every `§` in
  `lib/` now names the doc it belongs to. The figure went inline where the doc
  did not own it (`apply_update_flow.dart` keeps the 1.24 GB directly), and the
  other two point at `docs/origin-tracking.md`.
  The set was not the one this item named: `image_fetcher.dart` had already been
  corrected, and `install_date_proxy.dart` had a bare `§3` nobody had noticed.
  Grep for `§[0-9]` and check each one names a doc — that is the whole check.
- [x] **Prose said "the plan" meaning this file.** Swept: 61 mentions across the
  project, of which **10** deferred to this document and are gone — 6 in `lib/`,
  3 in `test/`, 1 in `docs/origin-tracking.md`. Each states the rule outright or
  names the doc that owns it.
  The other 52 stay and are not the same thing: most are the **data structures**
  called plans (`BulkUpdateCheckPlan`, `RetentionPlan`, the bulk-resolution and
  assume-current plans), and the rest are this file talking about itself. That
  is why it needed reading rather than grepping — `retention.dart`'s "the plan
  says so" looks like a citation and is a `[RetentionPlan]` reference.
  Two of them were worth more than the reference: *"this is a correction to the
  plan"* also broke the no-history rule, which prompted a second sweep for that
  rule across `lib/` and `docs/`. **14 more passages** narrated the code's own
  past — *"used to be"*, *"an earlier version"*, *"was the first attempt"* — and
  each now states the rule, the constraint or the rejected alternative in the
  present tense, keeping the durable half.
  What deliberately stays is the same phrasing about **mods**: "the old version's
  `.ini`", "what the keybind used to be". That is domain vocabulary, not history,
  and a grep cannot tell the two apart.
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
- [x] ~~**The queue's own tests never install anything.**~~ Closed by the
  feedback above: `DownloadQueueHost` takes an `installer` seam, and
  `test/download_queue_host_test.dart` covers the drain loop's one-at-a-time
  guard and the progress card. Still uncovered, and smaller than it was: the
  mapping from an `InstallResult` back to a job state, which needs an installer
  fake per outcome rather than a new seam.

## 6. Config / persistence

- [x] New `config.json` + `SharedPreferences` keys for: download directory (only if
  §5's fixed location is ever made configurable), auto-install-after-download,
  update-check behaviour (manual/auto), auto-update opt-in. (Remember the dual-storage
  pattern: getter/setter **and** the `_saveToFile` / `loadFromFile` map.)
  **Settled: one of the four exists, and the other three should not.**
  `update_check_on_launch` is the "manual/auto" one, off by default. The download
  directory is not configurable at all, so a key would have to come *after*
  making it one; there is no auto-install-after-download behaviour to configure
  (a queued download installs itself, which is the feature, not a setting); and
  auto-update is refused (§4). Each reason is restated in
  [`docs/configuration.md`](docs/configuration.md) §5 so the doc stands alone.
  One thing the dual-storage note does not cover and a bool needs: **read it on
  `containsKey`, never on truthiness.** This is the first key a user can switch
  back *off*, and a load treating a stored `false` as "nothing stored" would
  fall through to the default and re-enable it next launch — a switch that
  cannot be un-switched, with nothing on screen to say why. A test turns it on,
  off, and restarts.
- [x] Key for §1: the **content filter** — whether `warn`/`hide` mods are blurred,
  shown, or omitted. Needed in M1, since it's the first thing a user hits on the
  results grid. **Done in M1**; its Settings-tab entry landed with M4 — see the
  filed item below.
- Keys for §7: the post-upgrade nudge's dismissed flag, and the remote-lookup
  response cache — the latter should honour the API's own `max-age=600` (§2), and
  probably belongs in app-data rather than config.
  Neither is due yet and both are waiting on their feature rather than on the
  key: the nudge (§7.4) is not built, and the client's ten-minute cache is
  in-memory and per session, so there is no persisted cache to configure.
- Key for §4.2: backup retention (count or age), once a cap is chosen. The cap
  is chosen (30 days / 3 per mod / 5 GB) and is deliberately **not** exposed —
  §4.2's own argument is that presenting the age floor and the count cap as two
  independent numbers invites exactly the configuration it rejects. Kept open
  rather than closed, since "if anyone asks" is still the standing answer.

- [x] **The marketplace sort and content filter persist between sessions.**
  `marketplace_sort` (a `GbModSort` **Dart name**, not the `_sSort` wire value — an
  upstream rename must not invalidate saved settings) joins `content_filter` through
  the dual-storage pattern. The sort *preference* is a separate provider from the
  active query's `sort`: the query **reads** it as a starting value rather than
  watching it, since re-creating the query on a preference change would throw away
  the current page and category.
  Also closed a longer-standing gap while here: `ConfigService` had **no tests at
  all**, because a test would have written over the user's real
  `<appData>/config.json`. A `configFile:` seam fixes that, and
  `test/config_service_test.dart` now round-trips through a temp file and asserts
  every key `_saveToFile()` writes is read back by `loadFromFile()` — the
  three-place rule enforced instead of remembered. Verified it catches the mistake:
  deleting one line from the `_saveToFile` map fails two tests.

- [x] **The refresh button re-fetches for real, and shows that it is working.**
  Reported as "no animation, just silence" — but the silence was the smaller half.
  `ref.invalidate` re-ran the provider, the client's 10-minute response cache
  answered from memory, and the byte-identical page came back: **for up to ten
  minutes the button could not do anything at all.** Fixed by routing the action
  through `fetchMarketplaceResults(..., refresh: true)`, which is extracted so the
  provider and the refresh share one request builder; the bypass stays scoped to the
  explicit action, since making every read skip the cache would defeat having one.
  Feedback is a spinning icon with a **minimum duration** — a warm CDN answers in
  tens of milliseconds, so without a floor the icon turns for one frame and the click
  still looks ignored. Disabled while running so presses can't stack, and re-enabled
  on failure (the grid owns the error state). Order matters: the network call happens
  *before* invalidating, so the grid keeps showing the old page instead of flashing a
  spinner over content about to be replaced by something nearly identical.
  Scoped to the results deliberately — the category tree is structural and the
  carousel's windows turn over daily, so neither is what someone pressing refresh
  above the grid is asking about.

- [x] **Marketplace previews stopped re-downloading on every tab switch.** Reported
  as "the images re-fetch and go empty for half a second". The cause was **not** in
  the marketplace: `ImageCache` is bounded by *decoded* bytes (100 MiB) and is shared
  app-wide, and the mods library rendered its covers with **no `cacheWidth`** — so
  they decoded at native size. Measured on the real library: 49 covers = **213 MB
  decoded**, single images at 14 MB, meaning roughly **seven mod cards evicted the
  entire cache**. Opening the Mods tab flushed every marketplace thumbnail; coming
  back re-downloaded them. Fixed by decoding covers at card size (`640` for a 320px
  card) in **both** card render paths — `ModCardWidget` and the inline one in
  `mods_screen.dart` — plus the 56px thumbnail strip in the details dialog. The large
  viewer and the zoomable full-screen view are deliberately left unbounded.
  No second cache was added: the fix was to stop flooding the one that already
  exists. Verified the marketplace side was already doing the right thing —
  **all 20 captured covers carry `_sFile220`**, so the grid fetches the small variant
  rather than the original.
- [x] **The detail gallery loads progressively instead of going blank.** Switching
  preview image left the frame empty for the length of an 800px download, even though
  the strip underneath had already fetched a small copy of that exact image. The hero
  now renders the small one immediately and cross-fades the large one in over it.
  The mechanism worth preserving: the placeholder asks for **exactly the width the
  strip asks for** (one shared `_stripImageWidth` constant), because
  `ResizeImage(NetworkImage(url), width: n)` is precisely what `Image.network`'s
  `cacheWidth` builds — so identical arguments mean an `ImageCache` hit rather than a
  second download. Get that width wrong and the "optimisation" costs a request; a
  test asserts the key equality rather than just that a placeholder exists.
  Skipped when it would resolve to the same file as the target (fading an image into
  itself buys nothing), and the blur treatment still wraps the result — a test covers
  that too, since losing it would un-blur adult content.
  Implemented as **two plain `Image` layers in a `Stack`, with no cross-fade** — the
  small copy underneath, the large one painting straight over it. The stand-in carries
  a **small blur, scaled to how far it is stretched** (half a source block, so 100px
  in an 800px frame gets sigma 4, floored at 1.5): nearest-neighbour blocks read as
  "broken" where a slightly soft image reads as "still loading". Only the stand-in is
  blurred — softening the sharp image would defeat downloading it — and both widths
  are known up front, so the sigma needs no layout pass.
  **Do not reach for `FadeInImage` here.** It was the first attempt and was wrong
  twice: it animates the swap (not wanted), and it hard-codes
  `gaplessPlayback: true` while never resetting its internal `targetLoaded` flag, so
  its *documented* behaviour on a provider change is to keep showing the previously
  loaded image. That made things worse than the original bug — not blank while
  loading but **the wrong image** while loading, with the selected thumbnail and the
  preview disagreeing. A plain `Image` defaults to `gaplessPlayback: false`, which
  clears on a new url and lets the layer beneath show through, so no keys are needed.
  Worth knowing how that slipped through: the first attempt's tests only ever built
  the widget **once**, and a switch is the only thing that exercises the behaviour.
  The tests now pump image A then image B.
- [x] **Gallery navigation: arrows on the preview, and a strip you can drag.**
  Prev/next arrows over the large preview, clamping with a disabled state at each end
  — the same idiom as the "best of" carousel, so the screen has one navigation
  language. Hidden entirely for a single-image mod.
  The thumbnail strip previously moved **only** with shift+scroll, because Flutter's
  desktop `ScrollBehavior` deliberately leaves `PointerDeviceKind.mouse` out of
  `dragDevices`. Adding it back enables click-and-drag, and an always-visible
  `Scrollbar` makes the scrollability discoverable at all — hover-to-reveal is no use
  when the complaint is "I did not know it scrolled".
  **The override is scoped to the strip, not the screen**: the page around it is a
  vertical `ListView` holding selectable description text, and mouse-dragging that
  would fight text selection. A test asserts the override contains exactly one
  scrollable for that reason.
  This closed a real coverage gap — `GbDetailView` had **no tests at all**, which is
  how both earlier gallery bugs reached the user.
  Biggest win is the case with no published `_sFile800`: the hero then falls back to
  the full-resolution original, the slowest download of all.
  - [ ] **Still worth doing: generate thumbnails for local covers on import.**
    `cacheWidth` bounds *memory* only. The files are still stored verbatim (measured:
    3.8 MB PNGs, 2560px wide), so every cold load reads and decodes a full-size
    screenshot from disk. A cached thumbnail beside the original would cut disk reads
    and startup decode cost. New feature, not a bug fix — hence filed rather than
    folded in.

### Filed while surfacing the settings

- [x] **Two widget keys on the Mods tab were built from mutable state, so an
  ordinary action tore the subtree down.** Both are the same mistake: **a key
  answers "is this the same thing?", never "has this thing changed?"**
  - The grid's `AnimatedSwitcher` was keyed
    `character_<index>_<currentSkins.length>`, so importing, deleting or
    retagging a mod played the 500 ms character-switch transition over the whole
    grid — *and* remounted the `AnimationLimiter` inside it, restarting every
    card's staggered scale-in on top. Now keyed on the character **id** (the
    index moves under a stable selection when a group appears or disappears).
  - The card was keyed `mod_<id>_<isActive>`, so every toggle discarded
    `_ModCardWidgetState.isHovered` and the card dropped its hover lift under the
    cursor. Now the folder id alone; the `AnimatedContainer` eases the active
    border in, which is the better rendering of the change anyway.
  `test/mod_card_identity_test.dart` pins the surviving `State` rather than the
  key, and was checked against the old key to confirm it fails. Written up in
  [`docs/library-screen.md`](docs/library-screen.md) §1.
  Worth knowing for anything else on this tab: `loadMods(showLoading: false)` is
  already the norm, `isLoading` is only the first load and the error retry, and
  toggle/rename/edit/delete/favourite all patch the list in place rather than
  rescanning. The re-render was never the rescan — it was the keys.

- [ ] **The auto-tag and F10 sections cannot get a widget test.**
  `_SettingsScreenState.initState` calls `ApiService.getConfig()`, which lazily
  builds a `ConfigService` against the developer's **real**
  `<appData>/config.json`, so mounting the screen in a test would rewrite their
  library paths. Anything extracted to `components/settings/` with a writer seam
  escapes that — `test/settings_sections_test.dart` covers the Updates and
  Marketplace sections on exactly those terms — but the auto-tag section did not
  get the treatment, because its `_buildRequirement` helper is shared with the
  F10 section and moving it would refactor a section nobody has complained
  about. Whoever does it should make that helper a small shared widget first.
  Until then the busy-state fix above is verified by clicking, not by a test.
- [ ] **`isLoading` is one flag doing two jobs, and only one of them is safe.**
  It swaps the whole page body, which unmounts the `AnimationLimiter` and makes
  every section replay its staggered entrance. That is correct for the first
  load and wrong for anything else, and nothing in the code says so except a
  comment on the field. A separate first-load flag — or a limiter that is not
  inside the swapped subtree — would make the mistake unavailable rather than
  merely documented.

- [ ] **Dark mode and auto-F10 are surfaced but do not persist.**
  `isDarkModeProvider` and `autoF10ReloadProvider` are plain `StateProvider`s
  written by their Settings switches and by nothing else, so both reset on every
  launch. `config.json` even carries a `theme` key — written by `_saveToFile`,
  read back by `loadFromFile`, and **read by no UI at all**, so the value is
  round-tripped and then ignored. Not folded into §6's work: those two are
  already *surfaced*, which is what §6 was about, and persisting them is a
  separate three-place change each plus a decision about what `theme` should
  hold now that it stores `'dark-blue'` rather than a boolean.
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

- [x] **Featured "best of" carousel on the unfiltered view.** Not in the original
  plan; asked for after using the browser. It turns out the API has a dedicated
  endpoint for exactly this — **`Game/<id>/TopSubs`**, undocumented and found by
  probing route names, returning 3 mods × 7 windows (today, week, month, 3month,
  6month, year, alltime) each tagged with `_sPeriod`. Worth recording that this is
  **not synthesisable** from `Mod/Index`: there is no date-window filter and every
  like count elsewhere is a lifetime total, so "best of this week" has no other
  source. Its entry shape is its own (finished image urls rather than the
  `_aPreviewMedia` ladder, no `_aSubCategory`), so it gets its own DTO rather than
  being forced into `GbMod`. Shown only on the "All" view, since a fixed game-wide
  list stops describing what the user is looking at once they filter. Note the
  content skew: **20 of 21 captured entries are `warn`/`hide`**, so the carousel has
  to collapse rather than render an empty frame — covered by a test.
  Documented in [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §3.1.
  Presented as a **real carousel** — one large card at a time, arrows to step, the
  cover full-bleed with the title and period badge layered over it. The first
  attempt was a horizontally scrolling strip of small tiles showing all 21 at once,
  which is a different thing entirely; noted because the tests had to be rewritten
  around "one card visible", and that assertion is now what keeps it a carousel.
  Arrows **clamp rather than wrap**: a disabled arrow states where the list ends,
  where looping back to the start reads as a glitch.
  **Auto-advances every 6s, paused while the pointer is over it.** Three decisions
  worth keeping: auto-advance **wraps** where the arrows clamp (clamping would stop
  it dead at the last card, which is not "auto"); the dwell **restarts on every**
  page change whatever caused it, so a card reached with an arrow isn't shown for a
  sliver of an interval; and the interval is an **injectable widget parameter** —
  tests must pass `null`, because an auto-advancing widget makes `pumpAndSettle`
  walk the carousel forward while it settles, so any "the first card is showing"
  assertion would silently race a timer. A `hasClients` guard on the tick is
  load-bearing rather than defensive: when the content filter hides everything the
  `PageView` is gone while the timer keeps firing.
  It **scrolls away with the grid rather than being pinned**, which is why the grid
  is a `SliverGrid` inside a shared `CustomScrollView` rather than a `GridView`: two
  nested scrollables would either fight or need the carousel at a fixed height, and
  neither scrolls naturally. The carousel sits outside the results' loading/error
  branch so it doesn't flicker in and out with the listing it loads independently
  of. The **pager stays pinned** below the scroll view — paging is navigation, and
  hunting for it at the bottom of a long grid gets worse the longer the page is.
- **We cannot reproduce GameBanana's default ordering, and users will compare.**
  The site defaults to its own "ripe" ranking, which **neither API exposes**: every
  plausible `_sSort` alias is rejected, and the legacy Core API — authoritative,
  since it enumerates its own sorts — offers only `id`, `name`, `udate`. This is not
  academic: it is how the gap was found. A mod submitted in May but updated the same
  day sat 3rd on the site and **>420 mods deep** under our original
  `Generic_Newest` default, which reads as "the marketplace is missing mods".
  ~~Mitigated by defaulting to `Generic_LatestModified` (that mod lands on page 1)~~
  — **the default is `Generic_Newest` again**, by request, now that the sort choice
  persists: the default only decides a *fresh install*, so the cost of the wrong one
  dropped sharply. "Recently updated" is one click away and remembered thereafter.
  The orderings still differ from the site's. Options if it matters later: use
  `Game/<id>/Subfeed`
  for the unfiltered view (it matches the site closely — but accepts no filters and
  no sort, so it cannot be the only path), or accept the difference and say so in the
  UI. Written up in [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §4. Partly
  softened by the `TopSubs` carousel above, which covers the "what's hot" case the
  site's default ordering was serving — but the *listing* order still differs.
  - **Correction to how that was originally concluded.** An earlier note here said
    the legacy Core API's self-describing `AllowedSorts` "settled" it. That was
    overstated: the Core API enumerates *its own* surface, and apiv11 accepts seven
    sorts that appear in no such list. It is corroboration, not proof — apiv11 has
    no discovery endpoint, so the claim rests on rejected guesses. Worth keeping in
    mind before treating any Core API absence as authoritative for apiv11.
- **Unrecognised top-level query params are silently ignored by apiv11.** Only
  `_aFilters[…]` keys and `_sSort` values are validated; a bogus `_sPeriod`,
  `_sRange` etc. returns `200` with unchanged results. So a successful response is
  **not** evidence a parameter works — five invented period params all "succeeded"
  while doing nothing. Any future probing must diff the results, not the status code.
- [x] **`Generic_Newest` vs `Generic_LatestModified` affects §4's update check too.**
  `_tsDateAdded` is first-published and `_tsDateUpdated` is the real content update —
  §4's date-fallback comparator must use the latter. Noted here because the same
  confusion already cost one bug in the browse view.
  **Applied.** The date fallback reads `_tsDateUpdated`, and a test pins the
  third field it must *not* read: `_tsDateModified` is bumped by cosmetic edits,
  so a mod whose only later timestamp is that one stays "up to date". Note where
  `_tsDateAdded` is still correct and load-bearing — it is the mod's **creation**
  date, which is what the `assumed_latest` baseline clamps to.

- [x] **The content filter has no Settings-tab entry.** The key and the decision logic
  shipped with M1, and the control lives in the marketplace toolbar where it is first
  needed — but §1 said "put the toggle in Settings (§6)" and that half is not done.
  Belongs with M4's "surface all new settings in the Settings tab"; noted here so it
  isn't assumed shipped because the *key* is.
  **Done**, and the two homes are deliberate rather than a duplication to clean
  up later: the toolbar is where a user *meets* the filter, beside the grid it
  acts on, and Settings is where anyone looks for a preference they set once.
  Both write `content_filter` and both read `contentFilterProvider`, so they
  cannot disagree. The shapes differ on purpose — an icon menu is enough beside
  the thing it filters, where a settings list has to name the current value
  without being hovered, so this one is a dropdown.
- [x] **Three marketplace l10n keys are dead and predate M1.** All three are
  gone, and the hunch in this item was right: `install_7zip_missing` *should*
  have been reachable, and what it was hiding is a real failure.
  **A missing 7-Zip was reported as a broken archive.** `_extractWith7Zip`
  returned a hardcoded Ukrainian sentence saying to install it,
  `extractFailureMessage` dropped that string on the floor by design (it is
  untranslated tool output), and the user got *"Couldn't extract the archive —
  the file is still at …, so you can extract it by hand"*. For a `.rar` on a
  machine without 7-Zip that is the opposite of the truth: the download is fine
  and the fix is to install a tool, where the wording says the app has done all
  it can.
  Fixed with a typed reason — `ExtractFailure.missingSevenZip` / `.other` on
  `ArchiveExtractionResult` — so the UI branches on the *kind* of failure while
  the message string stays diagnostics-only, which was the right rule and the
  wrong classification. New `extract_no_7zip_title`/`_body` replace
  `install_7zip_missing`, whose one-sentence shape does not fit the
  title-and-body API. The other two keys had no home and are simply deleted.
  Three hardcoded Ukrainian strings in `ArchiveService` went to English on the
  way past.
- [ ] **The grid blanks itself on every page turn, and that was nobody's decision.**
  `results.when(loading:)` replaces the whole grid with a centred spinner
  whenever the *query* changes — page, sort, category, search — but not when the
  same query is refreshed. The asymmetry is a Riverpod default rather than a
  choice: `AsyncValue.when` takes `skipLoadingOnRefresh: true` and
  `skipLoadingOnReload: false` (`riverpod-2.6.1/lib/src/common.dart:719`), so
  `ref.invalidate` keeps the previous page on screen and a dependency change
  throws it away. Worth recording because the codebase already has the reasoning
  and applied it to one path only: `refreshMarketplaceResults` goes to the
  trouble of fetching *before* invalidating expressly to avoid "flashing a
  spinner over content that is about to be replaced by something nearly
  identical". Split out of M4 §1 rather than folded into it because the fix is a
  design choice and not a flag — retaining the previous grid means it has to be
  visibly *being replaced* (dimmed, non-interactive, under a progress bar) or it
  reads as page 2's content under page 2's label, and the scroll offset then has
  to be reset when the new page lands, which the blanking was accidentally
  providing.
- [ ] **The results grid has no infinite scroll and no result-count display.** Paging
  is prev/next with "Page N of M", which is honest but tedious across 866 pages. Also
  worth showing `_nRecordCount` so the user knows the search narrowed anything.
  Deliberately plain per M1; revisit with M4's polish.
- **Images are fetched with `Image.network` and cached only in memory.** Fine and
  measured-adequate for a browsing session — Flutter's `ImageCache` de-duplicates and
  holds decoded frames — but thumbnails are re-fetched from scratch after a restart. No
  dependency was added for this on purpose; revisit only if it is ever observed to be
  slow rather than assumed to be.

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
| **Which remote mod is this?** (identity) | **Often yes.** `source_url` already exists and is user-editable; parsing `gamebanana.com/mods/<id>` recovers identity for free. Now measured, and the estimate was if anything low: **23 of 23** mods in a real library, since the edit dialog is where people paste the mod page. |
| **Which file/version is installed?** | **Almost never.** The archive is deleted after extraction (§5), so GameBanana's per-file md5 has nothing local left to match against. |

### 7.2 Confidence-tiered origin block

- Extend the §3 origin block with a confidence per axis, plus honest markers
  for derived values:

```jsonc
"origin": {
  "source": "gamebanana",
  "mod_id": 123456,
  "mod_id_confidence": "exact" | "user" | "inferred",
  "file_id": null,
  "version": null,
  "version_label": null,
  "version_confidence": "exact" | "user" | "assumed_latest" | "unknown",
  "provenance": "downloaded" | "imported_archive" | "imported_folder",
  "ingest": {                         // how the archive became folders — §3
    "mode": "separate",               // "separate" | "combined"
    "folders": ["Ellen Swimsuit"],    // top-level folders the user chose to install
    "sibling_group": null             // shared id when one file produced several mods
  },
  "installed_at": "…",
  "installed_at_is_proxy": true,      // derived from file mtimes, not observed
  "baseline_remote_date": "…",        // only for assumed_latest
  "archive_md5": null,                // any ingested archive — see §7.8
  "tracking": "auto" | "off",         // "off" = user declared this local
  "remote_missing": false             // 404 / private / trashed upstream
}
```

- **Confidence and provenance are separate axes.** Confidence measures *how
  sure we are*; provenance records *where the mod came from*. They came apart the
  moment a hand-imported archive could be matched exactly (§7.8), so a tier named
  after a source (the old `installed`) would be actively misleading in the UI for
  a mod the user dragged in themselves.
- Tiers, and what each one may drive:
  - **`exact`** — we know precisely which file this is: we downloaded it, or its
    archive md5 matched GameBanana's published checksum. The only tier at which
    the app stops hedging: an uncapped verdict ("an update **is** available"
    rather than "possibly outdated"). It is **not** a licence to write
    unattended — nothing does, see §4.
  - **`user`** — the user told us. Trusted; manual updates with a normal confirm.
  - **`inferred`** — we guessed from local data (URL parse, name match, single
    unambiguous remote file). May badge and suggest; every update through it is
    manual, is labelled a guess, and **keeps** its backup rather than pruning it.
  - **`assumed_latest`** — "I don't know what I have, I got it around then."
    Compares against `baseline_remote_date` only.
  - **`unknown`** — nothing.
- **Never-confirmed ≠ safe.** An `inferred` identity came from a free-form
  text field a human typed — it may be a wrong paste, a collection link, a Drive
  link, or a different mod entirely. It must be confirmed once (§7.6) before any
  update is allowed to overwrite files.

### 7.3 Offline backfill (schema v1 → v2)

**Shipped.** Documented in [`docs/origin-tracking.md`](docs/origin-tracking.md)
§3, which is now authoritative for how it behaves. Kept here for the reasoning.

> **The "schema v1 → v2" in the heading oversells it.** Only a mod that actually
> gets an origin block is stamped v2; a legacy sidecar with no GameBanana url
> stays v1 forever, correctly, per the don't-litter rule. So this is not a
> library-wide format migration and `schema_version` is **not** a swept marker —
> a `1` means only "no origin block has ever been written here". Don't read it
> as "the backfill hasn't seen this mod yet"; it has, and found nothing.

Hooks into the existing lazy per-mod migration in
`ModMetadataRepository.loadOrMigrate()` (this doc said
`ModManagerService._loadOrMigrateMetadata()`; that method has since moved and
been renamed). Strictly local: scans run offline on every launch.

> **Correction (applied): it is a *sibling* of the legacy migration, not an
> extension of it** — "the same pattern already used for the legacy character
> tag and app-data images" is the wrong mental model and costs a wrong turn.
> `loadOrMigrate` **returns early the moment a sidecar exists**, and the legacy
> path it falls through to is the one where there is *no* sidecar. But
> `source_url` only exists **inside** the sidecar. So the legacy branch can
> never have a url to parse, and a backfill chained onto it would be dead code
> that fires zero times. The backfill belongs on the *early-return* branch — the
> mods that already have a sidecar.

- [x] Parse `source_url` for `gamebanana.com/mods/<id>` → `mod_id` at `inferred`.
  Highest-yield recovery by far. `/dl/<fileid>` is **not** handled here (per §3
  that field is mod-page-only, and resolving a file id needs the API anyway).
- [x] `installed_at` = **oldest file mtime in the mod folder**, with
  `installed_at_is_proxy: true`. Folder mtime/ctime are both bumped by `.ini`
  edits, so they skew *later* than the true install and would hide updates; the
  oldest contained file is the earliest defensible proxy.
  One refinement found while building it: **our own `.zzz-mod-manager/` is
  excluded from the walk.** It can't drag the minimum earlier, but a mod folder
  holding nothing else would report *our* sidecar's write time as an install
  date — a confident-looking number that means nothing.
  - **How good that proxy is depends on how the mod got there**, and the two cases
    are far apart. Imported *through the app*: good — `_extractZip` writes fresh
    files and `_copyDirectory` then copies via `File.copy`, which doesn't carry
    timestamps over, so mtimes land at roughly import time. Placed in `modsPath`
    *by hand* (`cp -p`, the user's own 7-Zip run, a synced folder): the author's
    build timestamps survive, and the proxy can read *years* early.
  - Consequence for the "assume current" bulk action (§7.5), which sets
    `baseline_remote_date = installed_at`: on a hand-built legacy library it can flag
    nearly the whole library as possibly-updated on first run. Technically "erring
    early", but a wall of false positives is its own kind of broken. Clamp the
    baseline (no earlier than the mod's upstream `_tsDateAdded`, ~~or than the app's
    first-run date~~), and state in the confirmation how many mods it is about to flag.
    **Correction (applied, and both halves of that sentence needed one.)** The
    confirmation states the count, as asked. The clamp does not happen, and
    neither proposed source works for a *bulk* action:
    - `_tsDateAdded` is on the mod page, and this action's whole value is that it
      makes **no requests**. So the bulk pass writes an unclamped baseline and the
      update check has to clamp when it compares — which is the better place for
      it anyway, since the clamp is a fact about the mod page rather than about
      the sidecar. Filed as its own item under §4; the confirmation states the
      risk in the meantime.
    - **The app's first-run date is not a floor at all, and using one would be a
      bug.** The app scans a `modsPath` the user may have been managing by hand
      for years, so a mod legitimately predates the app's first run. Clamping to
      it would push baselines *forward* and hide real updates — the opposite
      failure from the one this bullet is guarding against, and the worse of the
      two. (Nothing records a first-run date either, so it would also have to be
      invented as "today" for every existing install, clamping every baseline to
      now and making the action a no-op. `ConfigService` *does* hold a `first_run`
      key, so grepping for one finds a hit — but it is a **bool**, not a
      timestamp, so there is no date there either.)
    - Worth noting how much the clamp buys even when it is available, since this
      bullet reads as though it prevents the wall of false positives: every file
      a mod publishes is at or after the mod's own creation date, so clamping to
      that date only ever excludes the *original* file. It is a sanity clamp
      against "your install is older than the mod itself", not a false-positive
      filter. Checked rather than assumed, since it rests on `_tsDateAdded`
      meaning "first published": **32 files across the three captured profiles,
      none published before its own mod.**
  - Side benefit, **not taken** — the date is now recorded but nothing reads it;
    filed below as its own item rather than counted as part of this one.
- [x] Nothing found → **write no origin block at all.** Absence means untracked;
  re-sniffing costs one string parse. Preserves the existing "don't litter every
  mod folder with empty sidecars" rule — a user who never opens the marketplace
  should see no new files. Only an explicit user decision (`tracking: "off"`)
  causes a write.
- **Version sniffing from local files** (folder-name `_v2` tokens,
  `; version` comments in `.ini`, README lines): **hint only, never written.**
  Mods embed ZZMI/game versions and author-side numbering that are
  indistinguishable from mod versions, and a wrong stored version is worse than
  none. Surface detected tokens in the resolve dialog to help the user choose.

#### Open around the backfill (known, deliberately not built)

- [x] **`ModSort.added` still sorts by scan order.** It sorts by
  `origin.installed_at` now, newest first — `utils/mod_sorting.dart`, pure, so
  the undated case can be tested directly. The label went from *Default* to
  *Recently added*, which it had no right to be called before.
  **The undated majority is what shapes it.** A library that never had a
  `source_url` pasted into it has no origin block anywhere, and those mods go
  **last in the order they arrived**, not shuffled and not alphabetised: their
  scan order is the only thing describing them, and "recently added" is a claim
  we cannot make about a mod we cannot date.
  That is also why it partitions rather than passing `List.sort` a comparator
  returning 0 for undated pairs — **Dart's sort is not stable**, so equal
  elements are free to be reordered on every scan and the undated majority
  would shuffle under the user for nothing. Equal *dates* break ties by name for
  the same reason: one archive installing as several mods gives them the same
  timestamp to the second.
  A **proxy** date sorts alongside a real one. It is the oldest file mtime and
  can read years early, but demoting it would drop most of a legacy library into
  the tail, which is the state the backfill exists to get out of.
- [x] **Nothing writes `source_url` on install — only the edit dialog does.**
  Verified: `edit_mod_dialog.dart` is the field's sole write site, so a mod
  downloaded through today's marketplace gets neither a remote id (the webview
  yields a CDN url) nor a url the backfill could derive one from. The backfill
  therefore rescues the *legacy* library while leaving fresh downloads
  untracked, which is the opposite of the intuition. §1 fixes this properly by
  supplying the id at ingest; until then, consider having the marketplace record
  the mod-page url it already knows.
  **Resolved by the proper fix, not the workaround.** §1 now supplies `mod_id` at
  `exact` directly, so the interim idea of recording a url to re-derive an id from is
  moot and was deliberately not built — `source_url` stays a purely user-facing field
  per §3. This leaves a documented asymmetry rather than a gap: a fresh download has a
  `mod_id` and no `source_url`, while a backfilled legacy mod has a `source_url` and a
  derived `mod_id`. **Anything wanting "a link to the mod page" must build it from
  `origin.mod_id`** rather than expecting `source_url` to be set — filed as its own
  item below, since nothing does that yet.
- **A backfilled sibling group can't be reconstructed, and two mods sharing a
  `mod_id` must not be read as one.** `origin.ingest.sibling_group` is what makes
  §4's "an update acts on the whole sibling group at once" work, and nothing on
  disk records that two folders came from one archive — so the backfill leaves it
  null, honestly. But mods sharing a `mod_id` are *common*: two occurrences in a
  real 23-mod library (two variants of one mod, installed as separate folders).
  §4 and §7.6 must treat "same `mod_id`, no group" as **independent mods that
  happen to share a page**, not as a group to rewrite together.
- [ ] **A mod resolved by *search* gets no "open mod page" link.** `openModLink`
  (`utils/url_utils.dart`) reads `mod.sourceUrl` and nothing else, so a mod whose
  origin block knows the page but whose `source_url` is empty has no way to reach
  it. That is now a narrow set rather than "every downloaded mod": an install
  writes `source_url` through the autofill
  (`mod_metadata_repository.dart`), and the backfill derives `mod_id` *from*
  `source_url`, so both of those routes leave one behind. What does not is the
  resolve dialog — neither it nor `origin_resolution.dart` touches `sourceUrl`
  at all, so picking a mod out of its search box records `mod_id` at `user` and
  leaves the link empty. Either that path should normalise `source_url` to the
  mod page, or `openModLink` should fall back to `origin.mod_id`.
- [x] **Re-decide the `ModInfo` origin ban in M2 rather than inheriting it.**
  §3's correction says the origin block must not go on `ModInfo`, because a
  later unrelated edit would rebuild the sidecar from the runtime view and erase
  it. That was true when written — and the prerequisite that shipped since has
  made it unreachable: `save()` calls `replaceUserFields()` on the copy read
  from disk, `origin` is carried from there, and there is no parameter through
  which a `ModInfo` field could reach it. Meanwhile `_buildModInfo` reads every
  sidecar and then discards the block, so §7.4's status slot and §7.6's badges —
  both rendered from `ModInfo` — would have to re-read all 80 sidecars to draw
  data the scan already held. Weigh that cost against the ban deliberately; a
  **read-only** field carrying an already-parsed value is not the hazard the ban
  was written for. Note §8's related hygiene note is still void for its own
  separate reason (`ModInfo` must not gain `toJson`/`fromJson`).
  **Re-decided: the ban is lifted for a read-only `origin` field, and kept for
  everything else.** The reasoning above held up exactly as written — the hazard
  was a *mechanism* (`save()` rebuilding the sidecar from the runtime view) and
  that mechanism no longer exists, since `save()` and `setCharacter()` both call
  `replaceUserFields()` on the copy read from disk and it takes no `origin`
  parameter. There is no route in, and a test asserts it: saving a `ModInfo`
  carrying a forged block at `exact` confidence leaves the file untouched. What
  tipped the balance is the cost the ban implied — every badge re-reading every
  sidecar to redraw what the scan had just parsed and discarded.
  Written up in [`docs/metadata-schema.md`](docs/metadata-schema.md) §3, which is
  now authoritative. `toJson`/`fromJson` on `ModInfo` stay banned for their own
  unrelated reason.

### 7.4 Visual status — one slot, three states

- [x] The mod card gets a **single status slot**, not stacking badges. The data it
  needs is now in hand: `ModInfo` carries the origin block (see §7.3's re-decided
  ban), so the slot reads `mod.origin` and costs no I/O at all. It renders
  exactly one of:
  **Done**, and the "costs no I/O" claim held — the slot is a pure fold of a
  field the scan already parsed. Placement is **bottom-left of the cover**, the
  one corner the card had free, at a constant footprint across states so
  resolving a mod doesn't reflow the artwork. One correction applied, see the
  `remote_missing` note below the list.
  - **Amber / actionable** — identity known, version unknown. We can query for
    updates but can't judge them, and one click fixes it. Tooltip: "installed
    version unknown — click to set". Opens §7.5.
  - **Muted neutral dot** — untracked (no identity). Informational, never
    alarming: most of a legacy library looks like this, and badging it loudly
    trains the user to ignore the slot entirely.
  - **Accent / update available** — the §4 state. Must be clearly distinct from
    amber, or the two read as the same thing.
  - **Muted clock — tracked by date only** (`assumed_latest`, and `inferred`
    when something starts writing it). **Added after using it**, and the
    complaint that produced it is worth keeping: "you cannot differentiate
    between a mod which has its identity/tracking filled out, and one where you
    just marked the current date". Both rendered nothing, so a 17-mod library in
    which 7 were properly pinned down could not be told apart without opening 17
    dialogs — and the bulk action above is what creates that state ten at a
    time. Quiet rather than amber because nothing is wrong: settling for a date
    is a legitimate answer, and re-ambering it would undo the action's whole
    point. Three decisions behind it, all in
    [`docs/origin-tracking.md`](docs/origin-tracking.md) §4: it marks the
    **weak** state rather than the strong one (marking "properly linked" grows
    to cover every card and becomes permanent noise, where these shrink as the
    user does the work); it is distinguished from the muted dot by **shape, not
    colour**, which also survives colourblindness; and it is **shown but not
    counted** by the "needs attention" filter, or the bulk action's count would
    never drop and its marks would merely change shape.
  - Nothing at all for fully-known origins and `tracking: "off"`.
  - **Correction (applied): `remote_missing` also renders nothing**, and the
    list above never said what to do with it. The amber state's entire offer is
    "click to set the version", which means reading a mod page that is private,
    trashed or withheld — offering an action that cannot complete is worse than
    staying quiet. Nothing writes the flag today, so nothing is hidden by this
    yet; §7.6 is what will set it, and it wants its own wording rather than one
    of the three states here. Filed below as its own item.
- [x] **"Needs attention" filter** in the mods toolbar, alongside the tag filters.
  A status dot is spatial; a library of 80 mods needs the state to be
  *enumerable* before anyone can act on it in bulk.
  **Done**, and it carries a **count** and hides itself at zero: the answer is
  usually either nothing or most of the library, and both are worth knowing
  before pressing rather than after landing on an empty grid.
  **Correction (applied): it keeps the muted state as well as the amber one.**
  The badge and the filter answer different questions — the badge asks how loudly
  a card should speak, where an untracked mod is deliberately quiet, while the
  filter asks what the user could act on, and the resolve dialog acts on an
  untracked mod perfectly well (seeded with the folder name). Excluding them
  would leave a legacy library with an empty filter and no way to enumerate the
  mods the filter exists to enumerate. What untracked mods still get no access to
  is *bulk* resolution — that rule (§7.6) is about fuzzy name matching being
  unsafe to rubber-stamp, not about which mods are listed here.
- [ ] One-time dismissible nudge after the upgrade ("N mods aren't tracked for
  updates"), re-openable from Settings. Not a modal wizard. **Not built** — the
  toolbar's count is a passive version of the same fact and was enough to ship
  the filter, but it only appears once the user is already looking at the Mods
  tab toolbar. Still worth doing; still needs the dismissed flag from §6.

### 7.5 Per-mod resolve dialog

One job: bind this folder to a remote mod + file. Reuses widgets §1 already
builds (search result cards, the file list). Entry points: the status slot, the
mod context menu, and the edit-mod dialog.

- [x] **Identify** — prefilled from the `source_url`-derived id; otherwise a
  search box seeded with the folder name, ~~or a pasted URL (a `/dl/` link is
  accepted here and resolved via the API)~~. Confirming sets `user` confidence.
  **Done**, with one correction. **A pasted `/dl/` link cannot be resolved via
  the API — by either API.** Probed exhaustively against the live surface
  (2026-08-08) because accepting one is an obvious thing to want:
  `apiv11 File/<id>` returns the file record in full — name, size, date, md5,
  AV verdict, even `_aArchiveFileTree` — and **carries no owning mod anywhere**;
  `File/Multi` rejects `_aSubmission` / `_aMod` / `_idModRow` / `_aOwner` as
  `UNKNOWN_PROPERTY`; a File's `_sProfileUrl` comes back as the broken
  `https://gamebanana.com//<id>`; and the legacy Core API's self-describing
  `AllowedFields` for `File` offers nothing better than another file-id url
  (`/mmdl/<id>`). The *intent* stands — don't dead-end someone who pastes one —
  so the dialog recognises the link and says why it can't work, instead of
  searching for the url as though it were a mod name. A **mod page** url still
  resolves directly and skips the search entirely. Written up in
  [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §6.
  Worth knowing for §7.6: a `/dl/` link *is* usable once the mod is known, since
  the file id can be matched against that mod's `_aFiles`/`_aArchivedFiles` — not
  built here, filed below.
- [x] **Pick the file** — skipped entirely when a **banked archive md5** (§7.8)
  matches one of the remote files: that's exact, so just show what it resolved to.
  Otherwise the remote file list, ranked by local hints: exact folder-name ↔
  archive-name match first, then upload date nearest `installed_at`; preselect when
  there is exactly one file. Always show *why* a row is suggested ("matches your
  folder name") — no silent magic.
  **Done**, in `services/origin_resolution.dart`, tested against both captured
  profiles. Two refinements the data forced:
  - **"nearest `installed_at`" is the newest file that already *existed*,** not
    the nearest in absolute terms. A file uploaded after the install cannot be
    the installed one, so absolute distance can name a file that did not yet
    exist. The rule came from that reasoning rather than from the data — worth
    being precise about, because the first write-up here claimed the fixture
    disproved absolute distance and the arithmetic did not support it. It can:
    against `mod_profile_531649`, an install at **15:00** on 2026-05-08 has
    nearest-distance picking v7.5 (56 min after) over v7.4 (151 min before),
    where existed-first picks v7.4. That is the *only* window in this fixture
    that separates them — at 13:00 or 14:00 both rules agree — and it is what
    the test now uses.
  - **The hash-matched row is preselected but the picker is not hidden.** The
    rows stay so the user can see what it resolved to and disagree; what changes
    is that they no longer have to decide. Folder-name matches are *shown with
    their reason and left unselected* — a suggestion informs, it does not drive.
- [x] **Two first-class escape hatches**, both one click:
  - *"I don't know which"* → `assumed_latest`, `baseline_remote_date =
    installed_at`. Don't flag anything uploaded before the install; do flag
    anything after. Requires zero knowledge from the user.
  - *"Not from GameBanana / it's my own"* → `tracking: "off"`; the status slot
    goes quiet permanently.
  **Done**, and "one click" turned out to be load-bearing in a way the plan
  didn't budget for: a captured profile lists **fourteen** files, so both lists
  in the dialog are height-bounded and scroll inside themselves — otherwise the
  hatches slide off the bottom and stop being escape hatches. §7.3's baseline
  clamp is applied (no earlier than the mod's own `_tsDateAdded`), and the "I
  don't know which" row is *disabled with a reason* when no install date can be
  derived at all, since `assumed_latest` without a baseline compares against
  nothing. `tracking: "off"` is reachable with no identity at all — for a legacy
  library it is often the correct answer, so it cannot be gated behind finding a
  mod page first — and it deliberately **keeps** the remote id, so turning
  tracking back on is an undo rather than a second trip through the dialog.
- [x] **Zero-network "assume current" bulk action** — apply `assumed_latest` to
  every tracked-but-versionless mod at once, no API calls. Probably the highest
  value-per-line item here: it turns a dead 50-mod library into a working
  update-notification system immediately, with an honest caveat instead of a
  fabricated version string.
  **Done** — see the M2 entry above for the shape and measurements, and
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §6 for the four rules.
  Three things the plan didn't spell out, decided while building it:
  - **It is offered only while the "needs attention" filter is on.** The filter
    is what makes the state enumerable; this rewrites everything on that list,
    so requiring the enumeration first means the user has seen what they are
    acting on. It also keeps a control that can do nothing out of a toolbar that
    already carries five.
  - **Nothing is probed for a missing install date**, unlike the per-mod dialog.
    Every path that can derive one from a folder walk has already run one, so a
    tracked mod still missing the field is one whose walk found no files —
    re-walking returns null again. Those are reported as skipped rather than
    dropped quietly, which is why the plan has three groups and not two.
  - **The filter switches itself off when the run leaves nothing behind.**
    Otherwise the reward for pressing the button is an empty grid. Decided from
    the plan (no untracked, no undatable, no failures) rather than from the
    rescan, which is asynchronous and owned by the screen above.
- [x] Free add-on from the same API response: an **"also fill in missing
  metadata"** checkbox (description, images, tags, character) for bare legacy
  imports. §3 wants this on install anyway.
  **Done**, and it was exactly the UI work the note below predicted — no new
  decision logic, the same `applyRemoteMetadata` call the install path uses.
  Off by default and **best-effort**: it runs after the origin write and cannot
  turn a successful resolve into a failed one, because the tracking data is what
  the user came to set and a slow CDN node fetching a gallery is not a reason to
  report failure.
  **The machinery for this now exists** and needs no new decision logic:
  `ModManagerService.applyRemoteMetadata(modNames, RemoteModMetadata.fromMod(profile))`
  takes any list of mods, and its fill-absence-never-displace rule is exactly what a
  legacy mod wants. What is missing is only the checkbox and the profile fetch — so
  this is UI work, not a second implementation. See
  [`docs/metadata-autofill.md`](docs/metadata-autofill.md).

- [x] **The dialog states what is already recorded**, before offering to change
  it. Not in the original plan and only obvious from using it: the dialog read
  `mod_id` to know what to fetch and `installed_at` to rank files, and **never
  read `file_id`, `version_confidence` or `baseline_remote_date` at all** — so
  it could not answer the one question its own title asks, and a mod resolved
  months ago opened identical to one never touched, with no row selected.
  **Done.** `services/origin_summary.dart` is the pure fold (what each tier is
  allowed to *sound* like is the risky part, not the layout); the dialog shows
  two lines inside the identity card and an **on record** chip on the row the
  block names, and preselects that row. Written up in
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §5.
  Three things the implementation forced, each worth keeping:
  - **Preselection was labelled, not removed.** The first idea was "never
    preselect unless it is the recorded file", but the ambiguity is *what put
    this row here*, not *that a row is here* — so every selected row now carries
    a chip saying which, and the hash-match and single-file preselects survive.
  - **It exposed a real confidence bug.** Picking a row records `user` unless a
    hash matched, so re-confirming a file we *downloaded* demoted it from
    `exact` — the tier that gates unattended updates. Harmless while nothing
    preselected the recorded row; with the fix above, pressing Save was enough.
    `pickFile` now never lowers a tier on a re-pick, while still raising
    `inferred` → `user`, which is the confirmation that tier waits for. No
    changelog entry: introduced and fixed inside one unreleased change.
  - **A second panel broke the escape-hatch rule, and the tests caught it.** A
    bordered box of its own cost ~40px and pushed "I don't know which" and "not
    from GameBanana" below the fold — the one thing §7.5 says must never happen.
    Folded into the identity card instead, and the file picker's height came
    down 280 → 230 to pay for it: anything new in this dialog is paid for by the
    list that scrolls, never by the hatches, which have nowhere to go.

#### Open around the resolve dialog (known, deliberately not built)

- **A "tracked by date only" filter, if the card marker turns out not to be
  enough.** The new muted clock makes the state visible but not *enumerable* —
  deliberately, since it is out of the "needs attention" count. At 17 mods
  seeing them is enough; at 80 it may not be, and the natural home is a second
  row on the `!` toggle rather than a sixth toolbar control. Filed rather than
  built, to see whether it is actually wanted.
- [x] **`remote_missing` has no visible state, and now silences the slot.** §7.4's
  three states have no room for "the mod page is gone", so `modOriginStatus`
  treats the flag like `tracking: "off"` and renders nothing — correct today,
  since nothing writes the flag, but it becomes a silent hole the moment §7.6
  does. That state needs its own wording ("source no longer available"), and it
  must stay distinct from `_bIsObsolete`, which means the mod still exists and its
  author flagged it superseded.
  **Done**, with §7.6 and necessarily in the same change — see §4's filed item
  above for the three decisions. The `_bIsObsolete` distinction is untouched:
  that flag still rides alongside a verdict and never becomes a slot state.
- [ ] **A `/dl/` link could still pick the *file*, once the mod is known.** The
  identity step rejects one honestly (see above), but the file step has the mod's
  `_aFiles` + `_aArchivedFiles` in hand, so a pasted file id is a direct row match
  costing no request. Small, and it turns a dead end into a shortcut for exactly
  the user who has the download link but not the page.
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
  sites and let the workaround go. Filed rather than done: changing that
  signature is a change to the per-mod dialog's behaviour, which is outside this
  item.
- [ ] **Two local-side write seams now exist, with the same signature.**
  `ResolveOriginGateway.writeOrigin` and `BulkOriginWriter`
  (`dialogs/assume_current_dialog.dart`) both wrap
  `ApiService.updateModOrigin` for the same reason — a widget test that touched
  the real `ApiService` would rewrite the developer's `<appData>/config.json` —
  and both spell that rationale out. One shared typedef would stop them
  drifting. Small, and it belongs with the item above, since fixing
  `updateOrigin`'s return type has to touch both anyway.
  **Still two of that signature, now three call sites**: the bulk resolution
  screen imports `BulkOriginWriter` rather than declaring a third, so the drift
  did not get worse — but it now lives in `assume_current_dialog.dart` and is
  used by two other files, which is the wrong home for it. And the bool-return
  conflation the item above describes is worked around a *second* time there, in
  the same shape (wrap the transform, notice the decline at the call site). Two
  workarounds for one missing result type is the point at which the durable fix
  is cheaper than the next copy.
  **A third seam of the same shape but a different signature** is
  `ContentFilterWriter` (`components/settings/marketplace_section.dart`, reused
  by the marketplace's filtered-empty state). It writes a setting rather than an
  origin block, so unifying it with these two would be forcing one typedef over
  two different writes — but it is the same rationale spelled out a third time,
  which is the thing worth noticing.
- [x] **Ukrainian plurals are 1-vs-many, and the language has three forms.**
  Fixed as the item proposed — one selector keyed on the locale
  (`l10n/plural_rules.dart`), reached through `loc.plural(base, count)`, and no
  call site picks a suffix any more. Five copies of the same
  `count == 1 ? '_single' : '_plural'` helper went with it.
  `_few` is **optional**: most Ukrainian strings phrase the count as
  "модів: {count}", which no numeral affects, so a missing `_few` falls back to
  `_plural` rather than rendering a raw key — eleven strings needed one.
  **The fix exposed a second bug the two-form rule was hiding, and it is the
  more interesting half.** `_single` is not "exactly one": Ukrainian reaches it
  at **1, 21, 31, 101** — every count ending in 1 but not 11. So nineteen uk
  strings that hardcoded "1 мод", or said "цей мод" ("this mod") with no count
  at all, were about to start reporting the wrong number at 21 rather than
  merely the wrong case at 2. All nineteen now interpolate `{count}`, and a test
  pins the rule: in a three-form locale, a `_single` whose `_plural` names a
  count must name one too. English is unaffected and untouched — there `_single`
  really is only ever 1, which is exactly why the trap is invisible from it.
  **Worth a native review.** The `_few` wordings and the reworded singulars are
  my grammar, not a translator's; they are right about *form* (nominative plural
  at 2–4, singular agreement at 21) but a native speaker may phrase them better.
- [x] **Two constants hold the string `gamebanana`.** `AppConstants.gameBananaSourceName`
  is gone and its two call sites use `gameBananaSource`, which is the one that
  had a reason to exist: it sits beside the url parser that produces the mod id
  it accompanies, in `utils/` where offline code reaches it without the API
  client. Four write sites now, one spelling.
- [ ] **The resolve dialog cannot be reached from the edit-mod dialog.** §7.5
  names three entry points; the status slot and the context menu are wired, the
  edit dialog is not. That is the dialog where `source_url` is shown and edited,
  so it is where a user most plausibly notices the binding is wrong.
- [x] **A keybind edit doesn't refresh the grid either — same guard, same
  shape.** Confirmed by reading the path rather than by clicking, and it is the
  full chain: the dialog writes the `.ini`, calls
  `ApiService.invalidateKeybinds`, and `onSaved` runs `loadMods`, which
  re-parses correctly — and then `modGroupsChanged` discards the whole result
  because `keybinds` was not in its field list.
  **The reason for the omission was real and is now gone.** `KeybindInfo` had no
  value equality, so comparing re-parsed instances reported a change on every
  scan and would have turned the guard off entirely. It has `==`/`hashCode` now,
  compared order-independently on `keys` (a `LinkedHashMap` ordered by where the
  lines sit in the file, which is not part of what a binding is), and the guard
  compares keybinds like everything else. The enrichment is stable: nothing in
  `KeybindInfo` is derived from the clock, a counter or the filesystem, so the
  same `.ini` parses equal every time.
  Both directions are pinned, which is the point — one test fails if the
  comparison goes away (the bug returns) and a different one fails if the value
  equality does (the guard fires every scan).
- [x] **The rescan guard's field list is a silent-staleness trap in general.**
  `ModInfo` has `==`/`hashCode` over all twelve fields now and `modChanged` is
  `before != after`, so a field is covered by being a field. The list had caught
  two out — `origin`, then `keybinds` — each leaving a surface rendering
  yesterday's data with nothing thrown.
  Safe to add because nothing keyed on identity: no `Set<ModInfo>`, no
  `Map<ModInfo, …>`, and every `contains`/`remove` in the codebase works on
  `mod.id`.
  The one hand-written list that remains is in the **test**, and it is
  self-maintaining: it reads `ModInfo`'s constructor and fails naming any field
  it has no equality case for.
- [ ] **`CharacterInfo.keybinds` is never written, and one widget renders it.**
  Found while fixing the guard above. `enrichCharactersWithKeybinds` sets
  keybinds on each `ModInfo` and carries the group through with
  `character.copyWith(skins: …)`, so the group-level field keeps whatever it had
  — and nothing anywhere constructs a `CharacterInfo` with one. It is therefore
  permanently null, which makes
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

- **Bulk acts only on precise handles (`mod_id`).** Fuzzy identity matching is
  always one-at-a-time and user-confirmed (§7.5's search box). Rationale: a mass
  fuzzy name-match that a user rubber-stamps can bind a folder to an unrelated
  mod — and then an "update" overwrites their mod with a different mod's files.
  Folder names in the wild (`Ellen final FIXED v2`, `bikini`, `mod`) are exactly
  where fuzzy matching is least reliable. **Untracked mods therefore get no bulk
  feature at all.**
  **Implemented as written.** A mod with no `mod_id` gets no row, and the screen
  says how many were excluded for that reason — "eleven mods" out of a library of
  fifty reads as though it covered the library unless the rest are accounted for.
- [x] **It's a confirmation pass, not a search pass.** Per row: local folder name
  + cover on the left, remote mod name + thumbnail on the right, ✓/✗. A glance
  test that cheaply upgrades `inferred` → `user`, which is exactly what §7.2
  requires before any overwrite.
  **Done, and the ✓ is a checkbox that starts *unticked* while every other answer
  on the row starts ticked.** The asymmetry is the point: a file the pass
  inferred and a page the API itself reports as gone are statements the app can
  defend from the response in hand, where an identity is the one thing only the
  user can settle. Pre-ticking it would turn the glance test into the rubber
  stamp the bullet above exists to prevent. A *confirm all* shortcut sits above
  the list, which is a second press after the rows are on screen rather than a
  default.
  **Correction (applied): there is no remote thumbnail, and there cannot be
  one.** `Mod/Multi` **rejects `_sInitialVisibility` as an unknown property**, so
  a bulk response can carry a mod's cover but never its content rating — and
  rendering an unblurred adult cover in the library tab to make a name
  comparison prettier is not a trade worth making. The obvious substitute was
  measured and fails: apiv13 publishes a server-pixelated `_sFileNNNSfw` copy
  only for `warn`/`hide` mods, so its presence looks like a rating flag, and mod
  `541825` is `hide` with `{Skimpy Attire, Full Nudity}` and carries no `Sfw`
  key in a listing, a profile *or* a `Multi` response. (That also corrects
  `docs/gamebanana-api.md` §7, which claimed the correlation was exact; it holds
  across 150 recent listing records — 70 `hide` + 18 `warn`, 0 mismatches, and
  the "(30)/(7)" figures it quoted were simply wrong — and not in general.) The
  glance test is therefore **name to name**, plus a link to the mod page on every
  row. That is what catches the realistic failure, which is a wrong paste: the
  two names then disagree completely. The local cover went with it — without a
  remote half to compare against it is decoration, and a 57-row list wants
  compact rows.
- [x] **Per-row auto-resolution** from the file list + banked hash + proxy date:
  - *Banked archive md5 matches a remote file* → resolved at `exact`, no question
    asked. Cheapest and strongest outcome; try this first on every row (§7.8).
  - *1 file, uploaded before install* → almost certainly what they have. Write
    `file_id`/`version` at **`inferred`** without asking, then show a summary of
    what was filled in **with an undo**. Safe because `inferred` never drives
    auto-update and always renders as a guess.
  - *1 file, uploaded after install* → they hold an older, now-removed file.
    Version stays unknown and "probably outdated" is the correct verdict — **unless
    `_aArchivedFiles` resolves it**, see the next bullet.
  - *Multiple files* → genuinely ambiguous: inline version picker on the row.
  - *Upstream gone* → set `remote_missing` from the explicit fields `_bIsPrivate` /
    `_bIsTrashed` / `_bIsWithheld` (a 404 is only the crudest case), stop retrying,
    show "source no longer available". `_bIsObsolete` is **not** this state: the mod
    still exists and its author flagged it superseded — say that instead.
  **Done, every branch, and the tiers are as written** — `exact` for a hash
  match, `inferred` for the single-file inference, `user` for a row the person
  picked out of the inline picker themselves. Measured: on the developer's real
  library reduced to legacy shape, **24 of 57 rows arrive pre-answered** and 33
  get a picker.
  ~~**write without asking, then show a summary with an undo**~~ —
  **correction (applied): nothing is written until Apply.** Two things argue
  against the undo. The control that gets the user here says *check for updates*
  and nothing about rewriting sidecars; and the placement rule the bulk "assume
  current" button established is that a bulk rewrite acts only on a set the user
  has **seen**. A pre-ticked row costs one glance and one press, where an undo
  costs noticing a summary nobody asked for — so the safe inferences arrive
  ticked and Apply is the consent.
  **Correction (applied): the second bullet's date test is not decoration, and
  dropping it inverts the rule.** "1 file, uploaded *before* install" is written
  as a likelihood; it is actually a *precondition*, because the complement is not
  merely weaker evidence. A mod whose only file was published **after** the
  install is a mod whose original file was deleted outright, so the single thing
  on the page is provably not what the user has — recording it would invent a
  version and then report the mod as up to date, which §4 names as the one
  failure this feature cannot afford. It is pinned by a test in both directions,
  as is the case with no install date at all.
  A **folder-name match is deliberately not** in the pre-ticked set, though it
  ranks first in the picker with its reason shown. The rule is §7.5's and it is
  unchanged here: a suggestion informs, it never drives.
- [x] **Match against `_aArchivedFiles`, not just `_aFiles`.** `ProfilePage` returns
  superseded files too, each with its own `_idRow`, `_tsDateAdded` and
  `_sMd5Checksum`. That measurably improves resolution: a banked hash (§7.8) can hit a
  file that's no longer offered, pinning the installed version at `exact` for exactly
  the "you have an old one" case that would otherwise stay unknown — and it supplies
  date-ranked candidates for the picker. Same response, no extra request.
  **Done, and on this path it needs no code of its own**: `Mod/Multi` folds the
  two lists into `_aFiles`, so the ranking is handed `GbMod.allFiles` and
  `_bIsArchived` is what tells them apart. Measured on the real library, 127
  candidates across 57 rows — the archived ones are most of that.
- [x] Bounded, cancellable request queue with progress and backoff on rate limits;
  cache responses so re-running is cheap (honour the API's own 10-minute `max-age`).
  Never runs without an explicit press — no network on launch.
  - Build it on **`Mod/Multi?_csvRowIds=…&_csvProperties=…`**, which returns many
    mods' chosen fields — `_aFiles` included — in a single request. An 80-mod library
    becomes a couple of calls rather than 80, which changes this from "a queue that
    needs careful throttling" into "two requests and a progress bar".
    **Built, by §4's bulk check — reuse it rather than re-deriving it.** Three
    corrections to what this bullet assumes, all measured against the live API
    and written up in [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §3:
    **`_aArchivedFiles` is not a requestable property here** (it is rejected as
    `UNKNOWN_PROPERTY`), which costs nothing because **`_aFiles` on this
    endpoint is the union of current and archived files** — 14 entries against a
    profile's 6 + 8, told apart by `_bIsArchived`, which is therefore the
    authority rather than which key an entry arrived under. And **one
    unrecognised id fails the whole batch** with a `400` naming only the first
    offender, which a library of `inferred` ids will hit; `runBulkUpdateCheck`
    recovers by halving, and the guard that keeps that bounded is checking
    *which field* `_aErrorData` names.
    **Reused rather than re-derived, as instructed** — `runBulkUpdateCheck` now
    returns the records it was already keeping for its own phase two, and the
    resolution screen is built from those. So the "queue with progress and
    backoff" this bullet budgeted for never had to exist: it is one request the
    user already pressed for, and the fourth correction is that there is nothing
    left here to build.

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
- [x] **The screen has one entry point and no way back.** It is built from a
  fresh response and discarded with the dialog, so cancelling — or closing it by
  accident — means pressing check again. That is deliberate rather than
  overlooked: keeping the rows would mean caching a mod page and answering
  questions about a library state nobody has re-read. But there is no second
  door, and the toolbar has no room for one.
  **Filed as a known limit and reported as a bug within the hour, which is the
  correct verdict on it.** Both halves of the reasoning above were wrong. The
  records are worth keeping — `modUpdateRecordsProvider` is session state beside
  the verdicts, under the same never-persisted rule, so they can be no older
  than the session and the rows are re-derived from the *current* library rather
  than cached. And "the toolbar has no room" was a statement about a toolbar
  that needed rebuilding: the second door is a menu entry, and the menu replaced
  two conditional buttons and un-overloaded a third, so the control count went
  *down*. Worth keeping as a pattern — **"there is nowhere to put it" is a claim
  about the layout, not about the feature.**
- [ ] **Untracked mods are listed as a count and nothing more.** The bulk rule
  forbids acting on them, which is right, but the screen could still offer to
  open the per-mod dialog for each in turn rather than leaving the user to find
  them through the "needs attention" filter afterwards. Small, and it is the one
  place the two surfaces could hand off to each other.
- **There is no "I don't know which" per row.** The ambiguous rows get a
  picker or nothing; the `assumed_latest` escape hatch exists per mod (§7.5) and
  in bulk (§6 of the origin doc), but not *here*, where the user is already
  looking at the list. It would need its own column and its own wording, and it
  overlaps a button that already exists — filed rather than guessed at.
- **The card cannot say "the mod page is still a guess".** `modOriginStatus`
  keys on the *version* confidence once an identity exists, so a mod at
  `inferred`/`inferred` renders the same muted clock as one the user resolved to
  a date on purpose. Pre-existing — the backfill has always produced `inferred`
  identities — but this screen makes the state reachable in bulk, since ticking
  only the pre-ticked file answer now leaves exactly that pair. A fourth slot
  state is the wrong fix (the slot has one mark by rule); the honest options are
  the tooltip saying so, or the resolve dialog's existing "worked out from the
  source link — not confirmed" line being enough.
- **The character header still holds four global controls.** Auto-F10,
  refresh, F10 reload and Single/Multi sit at the right of a block titled
  *Characters*, which is where they ended up because there was room rather than
  because they belong. The toolbar rebuild deliberately stopped short of them:
  they are not library *bulk* actions, and moving them into the same menu would
  mix "rescan the folder" with "rewrite 24 sidecars". Whether the header's right
  side should become an explicit action bar is a separate question, and it is
  the last place in this tab where placement is accidental.

### 7.7 Self-healing (why none of this has to be perfect)

- Any mod whose **identity** is known becomes fully known the first time it
  updates *through* us — the download writes an `exact` origin block. So
  version-unknown is a one-time speed bump per mod, and the heuristics only need
  to get identity right. This is what justifies keeping the guessing conservative
  and the UI light instead of building a heavyweight migration wizard.

### 7.8 Archive hashing — hash every ingest, not just downloads

GameBanana publishes an md5 per file (`_sMd5Checksum` in `_aFiles`). So hashing a
*manually supplied* archive — not only ones we downloaded — can identify the exact
file the user has, which is the one path to exactness for hand-imported mods.

- [x] **Hash every archive we ingest**, from any path: in-app download, drag-drop,
  file picker. **Done** in `ArchiveService.extractArchive`, the one point both
  format branches meet with the file in hand.
  *Correction to the original cost claim:* "no second pass" holds only for `.zip`,
  where `_extractZip` already has the bytes in memory. `.rar`/`.7z` are extracted
  by shelling out, so their bytes never enter Dart and there is nothing to
  piggyback on — which is also precisely why the hash is taken in `extractArchive`
  rather than in the zip decoder, where it would have silently covered zips only.
  Honest cost: **free on download** (hashed in-stream, passed in as `knownMd5`),
  **one extra streamed read on manual import**.
- **Hash before the archive is deleted** (§5 discards it after extraction).
  The hash is the cheap 32-char residue that survives that deletion — it cannot be
  recovered later, because zip output isn't reproducible from extracted files.
- **Bank now, cash in at resolution.** A hash alone never yields *identity* —
  GameBanana has no reverse-hash lookup. It's a file-level discriminator that pays
  off once identity is known: on resolution (§7.5) or in the bulk pass (§7.6),
  compare the banked hash against that mod's file list. A hit sets `file_id` +
  `version` at `exact` confidence and skips the "which file?" picker entirely.
  Compare against **`_aArchivedFiles` as well as `_aFiles`** — an old install matches
  a superseded file more often than the current one (§7.6).
  ~~**Half of this shipped with the read side, and it is the *display* half only.**~~
  **Both halves have shipped for the per-mod path.** The detail view's file list
  marks a row whose published md5 matches a banked one — including archived rows,
  same lookup — and the resolve dialog now **writes** the upgrade: a banked-hash
  match preselects that row, is labelled "byte-identical to your archive", and
  saving it records `file_id` / `version` / `version_label` at `exact`. Two
  caveats stand. The *bulk* pass (§7.6) still doesn't exist, so this only fires
  one mod at a time. And it fires for very few mods in practice: a real 23-mod
  library banks **no** `archive_md5` at all, because the hash is recorded at
  ingest and cannot be recovered from extracted files — so this pays off for mods
  installed by this build onward, not for the legacy library it would help most.
- [x] **Bonus, purely local:** match a new import's hash against already-banked
  ones → "you already have this as `<folder>`". No network, no GameBanana.
  **Done**, as a gate both ingest paths run before installing
  (`confirmArchiveNotDuplicate`) — the marketplace's download-and-install and the
  mods tab's drag-drop / file-picker import. Per archive rather than per drop:
  recognising one archive in a multi-archive drop says nothing about the others,
  so declining skips that archive's folders and leaves the rest alone. It is a
  question, not a refusal — the same archive legitimately becomes a second folder,
  and re-installing is how a user repairs one they broke.
  Two things found while wiring it. The check runs **after extraction**, since
  that is where the hash exists for a manually supplied archive; nothing is in the
  library yet, so the cost of declining is a discarded temp dir. And the gate
  *created* a reachable path through a shape that had been safe by accident: the
  mods tab's `folderPaths.isEmpty` early return sits before the temp-cleanup
  closure is even declared, which was fine only because extracted folders and
  importable folders were previously the same set. Declining every archive in a
  drop breaks that, so the closure moved above the return, and that branch now
  stays silent instead of reporting "no mod folders found" — a different and false
  claim. No changelog entry: introduced and fixed inside one unreleased change.

Known limits — worth writing down so nothing is built to depend on this:

- **Moderate hit rate.** An untouched GameBanana zip matches. Anything
  re-zipped — a user who unpacked and repacked it, or an archive passed around via
  Discord — never matches, because any repack changes the md5 even when the
  contents are byte-identical. Treat it as a **bonus fast-path, never load-bearing**.
- **A miss costs nothing.** The field is null-or-exact: no match means we learn
  nothing and fall through to the normal guess path (§7.5). False negatives are
  common by design; false positives are not a realistic accident.
- **`archive_md5` is a matching key, never an integrity or authenticity claim.**
  No "✓ verified" checkmark, no shield icon. The honest phrasing is "byte-identical
  to file X on the mod page". md5 is in this design *only* because it's what
  GameBanana publishes; it is cryptographically broken, so a deliberate collision
  is constructible. That gains an attacker nothing **as long as** a match is never
  presented as trust: it sets a version label, skips no security check (there is
  none), and doesn't change what gets extracted — the user already supplied that
  file. If real integrity is ever wanted, add sha256 alongside rather than
  reinterpreting this field.

## 8. Code hygiene in the metadata layer

Small, agreed, low-risk. **No separate milestone** — do each one alongside the M1
work that already opens the same file, so they cost nothing extra.

- [x] **Delete `ModInfo.toJson()` / `ModInfo.fromJson()`**
  (`models/character_info.dart`). Dead everywhere, tests included — `ModInfo` is a
  runtime view, never a storage format. They're not merely inert: someone fixing
  the save path could reach for `ModInfo.toJson()` assuming it's the sidecar
  format, which would write absolute image paths plus per-install state
  (`is_active`, `is_favorite`, `keybinds`) into a file that must stay portable and
  intrinsic-only. *Do it while adding the origin fields to `ModInfo` (§3).*
- [x] **Wire up `ModMetadata.isEmpty` instead of leaving it unused.** Replace the
  parallel `hasLegacyData` bool in `ModManagerService._loadOrMigrateMetadata()`
  with `!metadata.isEmpty`. Verified equivalent: in that constructor
  `description`/`source_url`/`tags` are always empty, so the two agree in every
  case, including the empty-string one. Behaviour-preserving, removes a redundant
  flag, and makes the existing test
  (`test/mod_metadata_service_test.dart:38`) cover a real code path instead of an
  unused method. *Do it while adding the backfill to that same function (§7.3).*

## 9. Cross-cutting work (easy to forget, not optional)

- **Localization is a per-screen tax.** Every surface here needs keys in **both**
  `assets/l10n/en.json` and `uk.json`: ~~§1's two screens,~~ §7.4's status slot and
  tooltips, §7.5's resolve dialog, §7.6's bulk screen, §4's post-update report. It's
  the most repetitive cost in the plan and it currently appears in no milestone —
  budget it per milestone instead of discovering it at the end. The confidence wording
  in particular ("possibly outdated", "matches your folder name") is user-facing copy
  that has to be translated, not English interpolated into a string.
  **§1's share is paid**: 42 new keys in both locales, 14 webview-era keys removed, en
  and uk verified key-for-key identical. The tax estimate was accurate — this was the
  single most repetitive part of the work. A check worth reusing for the remaining
  screens: extract every `loc.t('…')` literal from `lib/` and diff it against both JSON
  files in each direction, which catches both a missing translation and a key left
  behind by deleted UI (it found one: `marketplace.search`, orphaned when the search
  button became submit-on-enter).
  **M2's read side added 10 keys** in both locales — the two badges, the two
  per-row markers with their tooltips, and the duplicate-archive dialog. Confirms
  the estimate again: the wording *is* the work here, since "installed" and
  "byte-identical to" are the whole distinction between a record and a hash match.
  **The metadata autofill added 4 more** — one sentence plus the three field nouns it
  lists, kept as separate keys rather than an interpolated English list so the nouns
  are actually translated.
  **The bulk "assume current" action added 12** — a button label and the
  confirmation's eleven. Same observation a third time: the eleven are almost
  entirely *caveat* copy (what is not being invented, why a date can read early,
  why untracked mods are excluded), which is the difference between a bulk
  rewrite the user consented to and one they clicked through.
  **§4's update check added 32** — two card tooltips, a context-menu entry, a
  toolbar tooltip, and the update dialog's 28. The pattern holds a fifth time,
  and more starkly: **eight of the twenty-eight are the eight verdicts**, and getting
  those wordings right *is* the feature — "an update is available" and "possibly
  outdated" are the whole confidence model rendered as two sentences, and the
  caveat under them ("a best guess, not a guarantee — GameBanana publishes no
  comparable version numbers") is what stops a heuristic reading as a fact.
  **§7.4 and §7.5 added 26** — two tooltips, a context-menu entry, a toolbar
  tooltip and the resolve dialog's 22. The estimate holds again, and the same
  observation as before: the *wording* is the work. Four of those keys are the
  match reasons ("byte-identical to your archive", "newest file that existed when
  you installed this"), which are the whole difference between a ranked list the
  user can argue with and one they have to trust — and they are confidence copy,
  so they have to be translated rather than interpolated.
  **§7.6's bulk resolution screen added 27** — one card tooltip and the
  screen's 26. The observation holds a seventh time and the split is starker
  here than anywhere: **six of the 26 are the *why* line under a checkbox** —
  what "worked out from a link" means, what "the page is gone" means, why
  untracked mods are absent — and those six are the whole difference between a
  list of ticks somebody rubber-stamps and one they can disagree with. The
  subtitle carries the other load-bearing sentence, *nothing is saved until you
  press Apply*, which is a promise rather than a label.
  **M4's launch check and Settings sections added 7** — the smallest share yet,
  and the observation still holds: **two of the seven are the switch's
  description**, and that sentence is the feature's whole safety property. It
  has to say that the app contacts GameBanana at startup (the cost, not the
  benefit) *and* that nothing is downloaded or installed, because a switch a
  user could read as consenting to automatic updates would promise something
  §4 deliberately refuses.
  **M4 §1's empty and error states added 10.** The pattern is by now a rule
  rather than an observation: **six of the ten are the second line**, the one
  saying what to do — and one of those six exists to say the opposite, that
  nothing will bring a removed mod back. That is the sentence standing in for
  the retry button the screen deliberately withholds, so it carries the whole
  weight of the decision. The other four are the actions themselves, and they
  are labels only because the state above them already did the explaining.
- **Name the tests, because the risky parts are pure functions.** The pieces most
  likely to be quietly wrong need no network and no UI: `source_url` → `mod_id`
  parsing (§7.3); the confidence state machine and what each tier permits (§7.2); the
  dangling-`.ini`-reference scan (§4.1), which decides whether a folder is warned about
  before being written to at
  all; hash → file matching across `_aFiles` + `_aArchivedFiles`
  (§7.6 — the *lookup* half is now covered by `test/installed_mods_index_test.dart`,
  including that a file-id match and a hash match stay distinguishable; the half
  that writes `exact` confidence from a hit is now `origin_resolution_test.dart`,
  which ranks against both captured profiles); and
  the sidecar unknown-key round-trip (M1). Fixtures beat mocks — a couple
  of real `ProfilePage` responses checked into `test/` keep the client honest when the
  API shifts under it.
  **The fixtures-beat-mocks call paid off concretely in §1**, and it is worth saying how,
  because it argues for keeping the habit: the file-selection rule was *designed* around
  what two real captured profiles do (ten files with `_sVersion: null`; a main file
  beside patchers and demos), and those same fixtures are now the tests. A
  hand-written mock would have encoded the assumption the plan started with — tidy
  `_sVersion` strings to compare — and the rule would have shipped confidently wrong.
  Suite is 793 tests, all offline. §4's share is the pattern once more and it
  changed the design rather than confirming it: the comparator was *written*
  against two real captured profiles that disagree about what `_sDescription`
  means, and the second of them is what killed the same-label rule the plan
  proposed — a hand-written fixture with tidy version strings would have made
  that rule look obviously correct. Two canaries came out of it: that
  `Mod/Multi` folds archived files into `_aFiles` (six current out of fourteen,
  matching the profile's six exactly), and that `_tsDateModified` never drives a
  verdict. The §7.4/§7.5 share is the pattern once more,
  and it is where the "nearest install date" rule's *only* discriminating case
  lives: an install at 15:00 on 2026-05-08 is the one window in
  `mod_profile_531649` where nearest-absolute-distance and
  newest-that-already-existed disagree. Real timestamps are what make a case like
  that findable at all — a hand-written fixture would have had round numbers and
  the two rules would have agreed everywhere.
  It also forced a seam that was worth having anyway
  (`ResolveOriginGateway`): the dialog reaches `ApiService`, which builds a
  `ConfigService` against the developer's **real** `<appData>/config.json`, so
  mounting it in a test without one would have clobbered their library paths.
  The autofill's share is the pattern working again:
  its two pure units are tested against real captured profiles, and the two rules most
  likely to be quietly wrong are pinned as *canaries* rather than examples — that all
  60 live character categories map to a roster id and none of the 4 roots do, and that
  a profile's tags parse at all (the shape difference that had silently returned empty).
  Add for §1: the content-filter matrix (including that
  an unrecognised setting degrades to `blur`), and that listing fixtures carry
  `_sInitialVisibility` at all — that last one is a canary, since if the field ever
  disappears upstream the filter silently blurs the entire grid.
- **One seam for offline tests.** Keep HTTP behind a single injectable interface
  in §2, or every test above needs a network to run. Done — `HttpTransport`, with
  `ImageFetcher` as the one deliberate second seam for bytes.

---

## Additional feature ideas (backlog — not yet committed)

### Acquisition
- [ ] **Paste-a-URL-to-install** — drop a GameBanana link → fetch + install + tag
  automatically.
- [ ] **Wishlist / bookmarks** for mods.
- [ ] **Trending / by-character feeds** in the browser.
- *(NSFW / content filtering moved to §1 — it needs no account, so it's a normal
  part of the browser rather than a someday feature.)*

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

---

# Other issues

- [x] Installing mods from the marketplace still goes through the same file-text based character recognition even though we have access to the correct character in the marketplace (no need to recognize the name in the file)
  - This happened when I installed "Zhao Nicole" from the marketplace (its a Zhao skin) and it landed under Nicole
  - **Fixed.** The category character is now passed *into* the import
    (`importMods(knownCharacters:)` / `importCombinedMod(knownCharacter:)`) and
    replaces name detection for those folders. It could not be fixed in the
    autofill that runs after the import: that rule is *fill absence*, and
    detection had already filled the slot. An unassigned value still falls back
    to detection, so a mod filed under `Other/Misc` keeps working.
    `test/import_known_character_test.dart`.
- [x] Going from the marketplace index page to the detail page and back reset how far
  you had scrolled.
  - **Fixed.** The two views are an `IndexedStack` rather than a conditional, so
    the grid is never disposed and keeps its real scroll offset — no remembered
    number to restore against a grid that may have changed height. The detail
    slot stays empty while unused, because its per-mod state *must* reset.
- [x] The detail page did not show the initial release date.
  - **Fixed.** Released and updated are now two separate lines from their own
    fields. The old `dateUpdated ?? dateAdded` fallback was worse than missing:
    `_tsDateUpdated` is null until a mod is actually updated, so it labelled a
    first release as an update.

---

## Packaging

- [x] **The AUR package declared none of the tools the app shells out to.**
  `depends` was `gtk3`/`glib2`/`libx11`, so installing `zzz-mod-manager-git`
  gave an app that could not extract `.rar` or `.7z` mods — most of GameBanana —
  and could not open a mod page or folder. Now `depends` adds **`7zip`** (the
  current Arch package; `p7zip` is the older independent port, and the app's own
  docs named it) and **`xdg-utils`**, with `xdotool` / `ydotool` / `wmctrl` as
  `optdepends` for F10 auto-reload, which is genuinely optional. `.SRCINFO`
  regenerated for everything but `pkgver`, which the release skill says to leave.
- [x] **The portable builds ship their own extractor now.** `ArchiveService`
  looks beside `Platform.resolvedExecutable` — and in a `tools/` beside it —
  before falling back to PATH, with the filenames on
  `PlatformService.bundledSevenZipNames` rather than a `Platform.isX` branch.
  Both CI workflows fetch the binary and **fail the build if it cannot report
  `Rar5`**, so the packaging cannot silently regress to shipping nothing.
  No pub package covers this: `archive` has the 7z *codec* but not the
  container and no RAR, `rar` skips Linux and Windows entirely, and `unrar` is
  RAR-only.
  Two details worth keeping, both of which the obvious choice gets wrong:
  - **Never `7za`.** 7-Zip's own readme calls it "reduced formats support", and
    RAR is among what it drops — so it would find a binary, run it, and decline
    the one format the bundle exists for. Windows needs the **`7z.exe` +
    `7z.dll` pair** from `7z<ver>-x64.exe`, not `7za.exe` from "7-Zip Extra".
  - **Linux takes `7zzs`, the statically linked build.** A portable tarball
    runs against a libstdc++ it cannot know, which is what a dynamic binary
    cannot promise. It is 3.6 MB against `7zz`'s 2.9 MB.
  The versions are **pinned** in both workflows because 7-zip.org serves each
  build at its own `/a/` URL with no "latest" alias — bumping them is a
  deliberate act. 7-Zip's `License.txt` ships beside the binary; it is LGPL.
  **Not verified from a built artifact.** The Linux fetch was run by hand and
  the binary confirmed to list `Rar5`; the Windows step and the installer's
  `[Files]` entries have not been exercised.
- [x] **`scripts/f10_reload.py` was unreachable, and is deleted.** Dead three
  times over, which is why installing it was the wrong fix. It sat behind
  `if (!success)` at the end of `reloadMods`, and method 1 — writing
  `.reload_signal` into the mods folder — sets `success` before it, so the
  branch never ran on any machine. Even reached, it resolved against
  `Directory.current.path`, and the PKGBUILD never installed the file. And what
  it did was reimplement methods 1 and 2 in Python. Both READMEs documented
  running it by hand from `/opt/zzz-mod-manager/scripts/`, a path that never
  existed.
- [ ] **Does a signal file actually reload anything?** Found while deleting the
  above and left open because it needs knowledge of ZZMI, not of this code.
  `reloadMods` returns `true` as soon as `_createReloadSignalFile` writes
  `.reload_signal` / `.mod_timestamp` into the mods folder, which essentially
  always succeeds — so `mods_screen.dart` reports **"Mods reloaded — F10 was
  sent to the running game"** even when `xdotool` is absent and no key was sent.
  If 3DMigoto watches for those files the return value is honest and there is
  nothing to fix; if it does not, then methods 1 and 2 write litter on every
  press and the success message is a lie. `optdepends` makes running without
  `xdotool` more likely, not less.

## Planned: rethink the whole UI

- [ ] Redesign the entire UI from scratch. Until that happens, leave UI layout
  and polish bugs alone — the fix would be thrown away.

Waiting on it:

- [ ] A marketplace file row overflows at 2× text scale. The scan chip and
  Download button can't shrink. Seen at 530px and 600px window widths.
