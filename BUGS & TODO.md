# BUGS & TODO

Planning + backlog for the mod-downloading / marketplace / update overhaul.
This is a **pre-planning document** — it captures *what* we want to build and the
decisions made so far, not *how* to implement it. Items are grouped by area.

> **This file is temporary.** As each area ships, its schema details and rationale
> move into [`docs/`](docs/README.md) — the origin block and confidence model (§3,
> §7) belong in [`docs/origin-tracking.md`](docs/origin-tracking.md). Don't let this
> document become the only written explanation of anything.

---

## Locked decisions

- [ ] **Origin data is confidence-tiered, and "unknown" is a real state — not a
  migration to be finished.** Mods that predate the origin block (the whole
  existing library) and every future manual import carry no origin data, so the
  model gets an explicit unknown tier, a visible status, and a resolution flow
  that stays in the UI permanently. Fully planned in **§7**.
- [ ] **Marketplace = native GameBanana browser (not a webview).** One shared
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
  suggest, badge, and prompt — but never overwrite files unattended. Auto-update
  is gated on `exact` confidence, always.
- **Updates must never silently destroy local edits.** Users edit `.ini` keybinds
  and configs inside mod folders. Attempt to preserve those edits and re-apply
  after an update — but treat it as **not foolproof**: keybind identifiers/names
  can change between versions, and keybinds can be added or removed. When
  preservation is uncertain, back up and inform the user rather than overwrite.

---

## Roadmap (prioritized)

The section numbers below (§1–§6) group work by *area*; this roadmap groups the
same work by *when it lands*. Dependency order is largely forced: the API layer
(§2) and origin model (§3) are roots, the download manager (§5) turns finds into
files, the browser (§1) sits on top, and updating (§4) is the payoff that needs
all of them. Decision: **ship a thin vertical slice first** (see M1), then thicken.

### M1 — Thin vertical slice (both platforms) ← lands first

Goal: kill the broken Linux external-browser path and get one real end-to-end
install working identically on Linux and Windows. Deliberately plain — no update
UI, no badges, minimal styling.

- [x] **§0 — the large-download unknown is now measured.** **Done** (2026-08-01);
  full results in [`docs/gamebanana-api.md`](docs/gamebanana-api.md) §8. The rest of
  the contract was already verified there: search, profile, file list and anonymous
  download all work, 30 concurrent requests drew no throttling, and `Mod/Multi` can
  fetch many mods' file lists in **one** request — which shrinks §7.6's bulk pass
  from ~80 requests to a handful and largely retires the rate-limit worry. What the
  spike found:
  - **Resume works, from the `/dl/` link itself.** `Range` survives both redirect
    hops, `ETag` is stable across CDN nodes (so `If-Range` is safe), and we never
    need to persist a resolved CDN url. Verified byte-exact on a 655 MB file with
    three interruptions via curl and four through Dart's `HttpClient`, both matching
    the published `_sMd5Checksum`.
  - **Files reach 1.24 GB, not ~650 MB** — but the median is only 21.9 MB and just
    9.5% exceed 100 MB. The tail is what needs engineering, not the common case.
  - **Throughput is a property of the CDN node and node choice is deterministic per
    file.** A healthy node gives 14–22 MB/s; a degraded one gave 0.83 MB/s falling to
    0.08 MB/s, for every file it served. **Retrying cannot route around it**, and
    parallel connections don't help. Worst observed case: ~25 min for one file.
  - **Consequence — resume moves out of M4 polish and into M1** (below), and the
    download service must use a **stall** timeout (no bytes for N seconds), never a
    total-duration one, or it will cancel legitimate slow downloads.
  - **In-stream md5 costs nothing**, confirming §7.8 is free to do on every ingest.
- [x] **§2 (subset)** — GameBanana API client: search, mod profile, file list.
  Only what browsing + install needs; no caching/retry polish yet.
  **Done.** `GameBananaClient` (`services/gamebanana/`) exposes `browseMods`,
  `searchMods`, `modProfile`, `modProfileByUrl` and `categories`, over an
  injectable `HttpTransport` seam (`services/http/`) so all 132 tests run with no
  network — verified in a namespace with no route out. Wire DTOs live in
  `models/gamebanana/`, one type per file, against 9 real captured fixtures in
  `test/fixtures/gamebanana/`. Two corrections to what this doc assumed, both
  applied — see §2 below: **browse is `Mod/Index`, not `Subfeed`**, and
  **`Mod/Categories` was a missing fourth method**. Caching (the server's own
  10-min `max-age`), reactive 429/503 backoff and in-flight coalescing landed
  with it rather than being deferred — they were a few lines each once the seam
  existed. The mod-page-url parser went to `utils/gamebanana_url.dart` so §7.3
  can use it offline.
- [x] **§5 (basic)** — extract the inline download code into a service;
  download → extract → auto-tag. Single fixed flow, no queue yet — but **resume and
  a stall timeout are in scope for M1**, not deferred: §0 measured 1.24 GB files and
  a CDN node serving at 0.08 MB/s, so a download that survives an interruption is
  table stakes rather than polish. Hash the archive in-stream on every ingest path
  (§7.8) — it's unrecoverable afterwards, so this has to land with the flow itself
  even though nothing reads it until M2.
  **Done.** `services/download/` — resume via `Range`/`If-Range` on the original
  `/dl/` link, stall timeout (never total-duration), socket backpressure,
  cancellation, resume across an app restart, and `<appData>/downloads` as the
  single landing spot. The SSL bypass is gone: `package:http`-style clients aside,
  the new transport simply never sets `badCertificateCallback`. **Blocker found
  and fixed on the way:** `_safeDeleteArchive` deleted `archiveFile.parent`
  *recursively*, which was survivable only while every download had its own temp
  dir — against a shared downloads folder it would have wiped every other archive
  and every in-flight partial on the first use.
- [x] **§3 (write side)** — record the origin block at install time (source,
  remote mod id, file id, version string + label, date, hash). *Written now,
  read in M2.* Ships **with the confidence fields from day one** (§7.2) —
  otherwise M1's own format needs migrating later.
  **Done**, on every ingest path, with the drop-inbound-origin rule enforced by
  construction. Two corrections to what this doc assumed, both applied — see
  below: it ships as **schema v2** and **`ModInfo` gains nothing**. ~~Note the honest
  limit: the webview yields a CDN url and no mod id, so today every block lands with
  both confidences `unknown`.~~ **That limit is now closed** — §1's native browser
  supplies `source`, `mod_id`, `file_id`, `version` and `version_label` before the
  first byte is fetched, so an in-app download writes both confidences at **`exact`**.
  That is the honest tier, not an optimistic one: the user picked this row of this
  mod's file list and we fetched exactly that file id. Manual imports still land at
  `unknown`, correctly — their route to `exact` is an `archive_md5` match at
  resolution time (§7.8), not the install path.
- [x] **§3 (prerequisite)** — make the sidecar **round-trip unknown keys** and
  treat machine-owned fields (`origin`, `schema_version`) as preserved-from-disk
  rather than sourced from `ModInfo`. Must land **before** anything writes an origin
  block: today an unrelated metadata edit would silently erase it, and older builds
  strip keys they don't know. Forward-only fix — see
  [`docs/metadata-schema.md`](docs/metadata-schema.md) §2 and §4.
  **Done.** `ModMetadata.extra` + `knownKeys` round-trip unrecognised keys, and
  `replaceUserFields()` makes preservation structural: adding a machine-owned field
  needs no save-site change, adding a user-editable one is a compile error at every
  save site. Written up in `docs/metadata-schema.md` §2.
- [x] **§7 (offline backfill)** — schema v1 → v2 during the normal scan:
  `source_url` → remote mod id, proxy install date. Local-only, no network, no
  UI. Without this, every pre-existing install is permanently invisible to §4.
  **Done.** `services/origin_backfill.dart` holds the decisions (pure, with the
  one filesystem walk injected as an `InstallDateProbe`);
  `utils/install_date_proxy.dart` is that walk. One correction to what this doc
  assumed, applied — see §7.3: it is a **sibling** of the legacy migration, not
  an extension of it. Measured on a real 23-mod library: **23 of 23 recovered
  identity**, first scan 30 ms including all 23 writes, second scan 7 ms with
  zero writes. Two limits worth knowing before building on it: sibling groups
  are unrecoverable (see §7.3), and the backfill helps the *legacy* library
  only — nothing in the install path writes `source_url`, so a mod downloaded
  through today's marketplace has neither identity nor a url to derive one
  from, and stays untracked until §1 supplies the id at ingest.
- [x] **§1 (plain)** — results grid + mod detail screens, both platforms; remove
  the `_isWebViewSupported => _isWindows` gate and the Downloads-folder watcher.
  **Done.** `screens/components/marketplace/` holds the grid (search, sort,
  root-category + 60-character filter chips, paging) and the detail view (gallery,
  description, file list, "open in browser"). The webview gate, the Linux
  open-in-browser view, the Downloads watcher and `flutter_inappwebview` itself
  are all gone — including the `Platform.isWindows` webview registration in
  `main()`. Verified against the live API: 5194 records / 866 pages, 4 roots + 60
  characters, search capped at 15 as documented, profile → file list → `/dl/<id>`.
  Two corrections to what this doc assumed, both applied — see §1 below: the
  **default-selection rule cannot have a "highest version" branch**, and the
  **category filter has no offline fallback**.
- [x] **§6 (as needed)** — the NSFW/content-filter toggle (§1) is the only new key
  M1 actually needs. *Not* a download-directory key: §5 fixes that to
  `<appData>/downloads` and explicitly defers making it configurable.
  **Done.** `content_filter` (`blur` | `show` | `hide`, default `blur`) through the
  dual-storage pattern, with the decision itself in a pure unit
  (`services/gamebanana/content_filter.dart`). The control sits in the marketplace
  toolbar, where it is first needed; **surfacing it in the Settings tab is still
  open** and filed under §6 below rather than counted here.

Exit criteria: on Linux *and* Windows, search a ZZZ mod in-app → open detail →
download → it installs, auto-tags, and carries an origin block.

**M1 is code-complete.** Verified on Linux end to end against the live API: the grid
renders with character-accurate badges and the blur overlay, the category chips are the
live 4 roots + 60 characters, search pages at the documented cap of 15, and a profile
resolves to a file list whose rows carry real `/dl/<fileid>` urls, sizes, md5s and
`clean` AV results. The origin block now lands at `exact` on both axes.
**Not yet verified on Windows** — there is no Windows machine in this environment. The
implementation is shared with no platform branch (junction-vs-symlink and
`openUrlInBrowser` already go through `PlatformService`), so the risk is low, but the
exit criterion says "Linux *and* Windows" and only one of those was actually run.

### M2 — Smart installs (read the origin block)

Goal: make the data recorded in M1 pay off in the UI.

- [x] **§3 (read side)** — "already installed" detection; file-hash dedup.
  **Done.** `services/installed_mods_index.dart` is the pure read model (mod id /
  file id / archive md5 → mod folders), fed by `installedModsIndexProvider`. The
  origin block now reaches `ModInfo`, so this costs no extra sidecar reads.
  Two corrections applied — see §3 and §7.3: **the `ModInfo` origin ban is lifted
  for a read-only field** (a test pins that nothing can write it back), and **the
  index cannot derive from `charactersProvider`**, which is stale exactly when the
  badges are on screen because `ModsScreen` is disposed. It re-snapshots per
  marketplace open instead: 4 ms warm, 12 ms cold for 23 mods.
  Measured limit worth knowing before building on it: **23 of 23 real mods have a
  `mod_id`, none has a `file_id` or an `archive_md5`.** Mod-level answers work on a
  legacy library today; every file-level one is inert until mods are installed by
  this build or resolved by hand (§7.5), so hash dedup fires for nothing in an
  existing library.
- [x] **§3** — auto-populate metadata (description, images, tags, character) from
  the API on install instead of leaving it blank.
  **Done.** Two pure units — `services/gamebanana/remote_mod_metadata.dart` (what the
  page is worth) and `services/metadata_autofill.dart` (what may be written) — with
  the I/O in `ModMetadataRepository.applyRemoteMetadata()`. One rule governs it and it
  is a safety rule, not a courtesy: **fill absence, never displace.** An inbound
  sidecar's user-facing fields are deliberately kept (§3), so "already set" usually
  means "the author wrote this". Written up in
  [`docs/metadata-autofill.md`](docs/metadata-autofill.md). Measured end to end against
  the live API: 827 ms to fill two sibling mods with the same 8-image gallery — 8
  downloads, 16 files, 882 KB per folder.
  Three corrections to what this doc assumed, all applied — see §2 and §3 below:
  **`_aTags` has two wire shapes and we were reading only one**, **the character comes
  from the *category*, not from names or tags**, and **the images are the only part
  that costs anything, and the cost is not where it was assumed to be**.
- [x] **§1** — "already installed" indicators on cards + detail.
  **Done.** A filled "In library" badge on the card, a notice on the detail view,
  and a per-row marker in the file list. The badge names the *folders* — one mod
  page is often several — and rows separate "installed" (a recorded `file_id`) from
  "you have this" (a hash match), which per §7.8 must never read as verification.
  A full-width cover strip was built as an alternative and lost a side-by-side
  comparison. Design rules, including why a border and a dimmed card were rejected,
  are in [`mod_manager_flutter/CLAUDE.md`](mod_manager_flutter/CLAUDE.md).
  - [x] **"Update available" is not part of this** — needs §4, lands with M3. Same
    slot, and it must differ from "installed" by **hue rather than volume**, since
    that now takes `primary`.
    **Done for the *library* card** (M3 below): a blue mark at the same weight as
    amber, in the same one slot, with precedence folded in `modSlotStatus` so the
    two can never stack. The **marketplace** card's half is *not* done — that is
    `GbModCard._statusSlot`, a different widget answering a different question
    ("does the mod you are browsing have a newer file than the one you own?"),
    and it needs the check to have run for a mod the library index can name.
    Filed as its own item under §1.
- [x] **§7** — the mod-card **status slot** (§7.4), the **"needs attention"**
  filter, and the per-mod **resolve dialog** (§7.5). This is where "the user can
  take action" actually lands; it needs §2's client and §1's file-list widget.
  **Done.** Three pure units carry the decisions —
  `services/origin_status.dart` (the one-slot fold, shared by the badge *and* the
  filter so they cannot disagree), `services/origin_resolution.dart` (candidate
  ranking with a stated reason, plus the four transforms an answer may write) and
  `ModOrigin.boundTo` (what survives a rebind, now one copy shared with the
  offline backfill instead of two). The surfaces are
  `screens/components/mod_status_slot.dart`, a toolbar toggle carrying a live
  count, and `screens/dialogs/resolve_origin_dialog.dart`; the write path is
  `ModMetadataRepository.updateOrigin`, which **amends** rather than replaces and
  re-reads before applying. Written up in
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §5 and §7, now authoritative.
  Two corrections to what this doc assumed, both applied — see §7.4 and §7.5:
  **a `/dl/` link cannot be resolved to a mod by either API**, and **the filter
  covers the muted state too, not only the amber one**. Smoke-tested against the
  real library on Linux: the toolbar reports 16 of the developer's own mods as
  needing attention.
  **Blocker found by using it, not by testing it, and worth recording as a
  pattern.** Saving in the dialog left the amber mark on the card. Everything
  underneath was correct — the sidecar was written, the rescan re-read it — but
  `ModsScreen` guards `charactersProvider` behind a hand-written field-by-field
  comparison, and `origin` had never been added to it (it went onto `ModInfo`
  during M2's read side, where nothing yet depended on the guard seeing it). So
  the guard said "unchanged" and the grid kept rendering the previous `ModInfo`.
  Nothing threw, no test failed, and the whole feature looked broken from the one
  place it is used. Fixed by giving `ModOrigin` real value equality and moving the
  comparison out of the 2000-line screen into `utils/mod_group_diff.dart`, where
  it is now tested — including that removing the `origin` line fails three tests.
  The general lesson is filed below: **that list is a silent-staleness trap for
  every future field on `ModInfo`**, and only `origin` is now self-maintaining.
- [x] **§7** — the zero-network **"assume current"** baseline action (§7.5).
  The **per-mod** half shipped with the dialog above (the "I don't know which
  file" escape hatch, with the §7.3 clamp applied). What was still open is the
  *bulk* action — apply it to every tracked-but-versionless mod at once — and
  the confirmation that states how many mods it is about to flag.
  **Done.** `services/bulk_assume_current.dart` is the pure half (a plan split
  into eligible / untracked / undatable, plus the transform each write goes
  through) and `screens/dialogs/assume_current_dialog.dart` is the confirmation
  and the write loop; the button sits in the mods toolbar and appears **only
  while the "needs attention" filter is on**, so the user has enumerated the
  mods before rewriting them. It acts on exactly the set the count beside it
  describes — the current view, which on "All" is the whole library — because a
  control acting on a different set than the one on screen is the quiet kind of
  wrong. Written up in
  [`docs/origin-tracking.md`](docs/origin-tracking.md) §6.
  Measured against a mirror of the developer's real library: 17 mods with
  sidecars, **10 eligible**, 6 already resolved at `user` and 1 at `exact` from
  the per-mod dialog's own smoke test, 0 untracked and 0 undatable. The whole
  pass including all 10 rewrites is **13 ms**, and re-running it is a 4 ms
  no-op — so there is no progress UI and none is warranted; the button just
  disables while it runs.
  One layout bug found by a test rather than by a user, which is the way round
  this repo has not usually managed: the second toolbar row is `Clear filters`
  and this button, and as a `Row` with a `Spacer` it **overflowed by 126px** at
  the narrow end of the window. Neither label can ellipsise, so a `Row` that
  doesn't fit degrades into a red stripe rather than into anything. It is a
  `Wrap` with `spaceBetween` now — same look while they fit, stacked when they
  don't — and the test pumps the toolbar at 480px with a three-digit count.
  **Verified by pressing it, on the developer's real library.** All 10 eligible
  mods went to `assumed_latest` with `baseline_remote_date == installed_at`, the
  6 at `user` and 1 at `exact` were left alone by the re-check guard, and **no
  `file_id` or `version` was invented on any of them** — identity, hash,
  description and tags all survived. No write failed. On screen the amber marks
  and the toolbar's `!` button both went away (the count reaching zero) and the
  filter cleared itself rather than leaving an empty grid.
  **And pressing it found a bug nothing else would have**, which is the argument
  for doing this every time. With the count at zero the `!` toggle hid itself by
  returning `SizedBox.shrink()` — but both of its 8px spacers stayed, so the
  sort dropdown and the favourites star sat **16px** apart and the row read as a
  button that had failed to render. It predates this work (the toggle shipped
  with §7.4) and was simply unreachable until a library could reach zero. The
  control and its spacer are conditional together now, the shape the tag filter
  already used. Worth generalising: **a control that hides itself by returning
  an empty box leaves its gaps behind** — the caller has to omit it. A test
  measures the gap and was checked against the old code, where it reads 16.
  **Two more corrections came out of review, both to claims this work made about
  itself.**
  - **The plan was built from the wrong list.** It came from
    `currentCharacterSkinsProvider` — the view *before* search, tags and
    favourites — while the grid renders `visibleModsProvider`. Search `ellen`
    with the needs-attention filter on and the grid showed 3 mods while the
    button offered to rewrite 12. The number was still honest (it is what got
    written), but it contradicted the one property the placement argues for.
    Now built from `visibleModsProvider`. The knock-on is worth stating rather
    than hiding: the button's count and the `!` toggle's count may now differ,
    because they answer different questions — what the view *is* showing versus
    what it *could*. They agree whenever needs-attention is the only filter.
  - **A declined write was reported as a read-only folder.** `updateOrigin`
    answers one bare `false` for "unwritable" and "the transform said no", so
    the guard that this whole item is built around surfaced its own correct
    behaviour as a filesystem permission error. Reachable with no concurrency at
    all: press the button, then press it again before the rescan has refreshed
    the plan. The loop wraps the transform to tell the two apart and reports a
    third outcome ("already sorted out"), and the rescan is now unconditional so
    an all-declined run cannot leave the same stale plan on screen. The
    identical conflation in the *per-mod* dialog is pre-existing and filed
    separately below.
  One correction to what this doc assumed, applied — see §7.3: **the clamp
  cannot be applied here at all**, and the fallback this doc proposed for that
  case is unusable. The deferred half is filed as its own item under §4.
  The hazard worth recording, because it is invisible rather than obvious: the
  plan is built from a scan and each write re-reads, so eligibility is
  **re-checked against the fresh block** and abandons anything no longer
  `versionUnknown`. Without that, a mod resolved exactly while the batch ran
  would be silently *downgraded* to a guess, inside a pass nobody is watching
  per-mod. A test walks all four resolved tiers to pin it.

### M3 — Updating

Goal: the payoff feature. Needs §2 + §3 + §5 from M1/M2.

- [x] **§4 (detection)** — manual update check (per-mod + bulk), version-string
  +label rule, update badges.
  **Done.** `services/update_check.dart` is the pure comparator (origin block +
  mod page → one verdict) and `services/bulk_update_check.dart` the
  whole-library pass over `Mod/Multi`; the surfaces are a toolbar button, a
  right-click entry, a blue mark in the card's existing status slot and
  `screens/dialogs/mod_update_dialog.dart`. Written up in
  [`docs/update-checks.md`](docs/update-checks.md), now authoritative.
  §4's clamp item and the `_tsDateUpdated` item below both landed with it.
  **Three corrections to what this doc assumed, all applied — see §4 below:**
  the version+label rule **cannot be a same-label rule alone** (real data makes
  that a silent false "up to date"), `Mod/Multi` **cannot return
  `_aArchivedFiles`** but folds them into `_aFiles` instead, and **one bad id
  fails the whole batch**, which a legacy library of `inferred` ids will hit.
  Measured against the developer's real 17-mod library, live: **one request,
  982 ms**, 15 up to date (8 of them date-only guesses, labelled as such), 0
  confirmed updates and 2 `possiblyOutdated` — both the predicted soft
  false-positive, a mod whose author published a *different variant* after the
  one installed. Injecting one dead id into the same batch cost **9 requests
  and 1490 ms** and still answered every other mod, where without the halving
  all seventeen would have come back unreachable.
  **Two corrections after the first real use, both applied.**
  - **The detection was wrong in a way no amount of label or date comparison
    could fix**, and both live false positives were the same shape: a *different
    variant* published after the installed one (`SFW Variants Only` beside
    `NSFW Variants Included`; four proportion variants in one post). The fix is
    not a better heuristic but a field this doc never mentioned —
    **`Mod/<id>/Updates` carries `_aFileRowIds`, the files an author released
    together**, which is the author's own statement that two files are variants
    rather than successors. A second suppression covers what release groups
    cannot: two still-offered files stamped with the **same `_sVersion`** are
    the same version, which caught a `FULL MOD`/`NSFW MOD` pair posted nine days
    apart in separate updates. Both suppressions can only ever turn a flag
    *off*, neither can change the verdict once the installed file is archived
    (the same-version rule is confined to the still-offered branch; release
    groups still decide which file gets *named*), and
    absent data suppresses nothing. Re-measured on the same library: **4 flags
    before, 2 after**, 5 requests, 226 ms.
    Worth recording what was *not* built, since it is the obvious next step and
    is a trap: suppressing an unlabelled candidate against a labelled install
    would clear the last variant-shaped false positive, and would also silence
    an author who labelled one release and not the next — a false "up to date",
    which is the failure this feature cannot afford. Filed below.
  - **There was no way to ignore an update.** Added
    `origin.updates_dismissed_until` and an "ignore this update" in the dialog:
    a **date** rather than a file id, so it expires by itself the moment
    something newer is published, and written as the date of the thing dismissed
    rather than as "now" so nothing published mid-check is swallowed unseen. The
    verdict is kept and only the badge goes quiet — the dialog is where someone
    goes to change their mind.
  **Two more corrections from pressing it, both reported and both real.**
  - **The label said "Not now", which reads as a deferral.** It is permanent
    until the author publishes something newer, so it says "Ignore this update"
    and the undo says "Stop ignoring it". The confirmation line now also states
    what visibly happened (the mark is gone from the card).
  - **Pressing it appeared to do nothing, and the write had actually
    succeeded** — a shape worth recording because it produced no error
    anywhere. The dismissal was re-derived by re-folding the verdict against a
    fetched mod page, and the dialog **opened from a card badge never fetches
    one**: a verdict is already on record from the bulk pass, so re-asking would
    spend a request to redraw the same sentence. The fold therefore returned
    null, the store call no-opped, and the dialog, the card badge and the
    toolbar count all kept showing the pre-dismissal state. Fixed by flipping
    the flag on the verdict already in hand (`UpdateCheck.asDismissed`).
    The general lesson: **a dialog with two entry points has two states, and
    the cheaper one is the one that ships broken.** The only test covering the
    button used the entry point that fetches, where a profile happens to exist;
    a test now covers the badge path and was checked against the old code,
    where it fails on exactly the symptom reported.
  - **A mod with several new files named one and hid the rest.** Asked for
    directly: *"does it automatically suggest the latest NSFW version even
    though I am on an older SFW version, or does the user get to pick?"* The
    answer measured out better than feared — where the author's labels are
    stable the check already follows *your* variant, and the label match beats
    recency, so an SFW install is offered the new SFW build even though the
    NSFW one is two minutes newer. But when labels drift it names the newest,
    which may be somebody else's variant, and when nothing matches it names
    none. `UpdateCheck.newerFiles` now carries every candidate and the dialog
    lists them, marking the one it would pick **and on what grounds** —
    `matches your variant` against `newest published`, which are different
    claims and must not render alike. Four scenarios are pinned as tests,
    including that an old ignore never carries forward to the next release.
  **Verified against the developer's real library** and by pressing it.
- [ ] **§4 (applying)** — changelog display, backup/rollback, preserve user
  edits. The other half of §4, and the half that touches a live install: §4.1's
  deactivate → swap → reactivate dance, §4.2's backups, and the conservative
  `.ini` merge. Nothing in the app can act on a found update today — the check's
  dialog says so in one sentence and offers the mod page instead.
- [ ] **§4 + §7** — the bulk "check all" results screen doubles as the bulk
  **resolution** screen (§7.6): per-row identity confirmation and inline version
  pickers. Verdict wording and auto-update gating become confidence-aware (§7.2).

### M4 — Robustness & polish

- [ ] **§5** — download queue and multi-download progress; revisit SSL bypass.
  (Resume itself moved to M1 — see §0.)
- [ ] **§4** — opt-in auto-update (global + per-mod) with notification.
- [ ] **§6** — surface all new settings in the Settings tab.
- [ ] **§1** — empty/error/loading/offline states.

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
- [ ] "Already installed" / "update available" indicators on cards & detail,
  driven by the per-mod origin data (see §3). In the **library**, this indicator
  shares a single status slot with the unknown-origin states — see §7.4.
  **The library half is done** (M2's badge, M3's blue update mark, one slot
  each). What is left is the *marketplace* card's "update available" branch —
  `GbModCard._statusSlot`, which answers the mirrored question. Filed under §4.
- [x] Decide empty/error/loading states and offline behaviour.
  **Done for M1's two screens** (M4's item covers polish beyond this). Decisions
  worth keeping: *no results* and *everything on this page was hidden by your
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

- [ ] Thin, dedicated API client service — **not** inline in the UI. Surface kept
  small and stable: search, mod profile (metadata), and file list.
- [ ] Resolve a mod URL **or** id → structured data: name, author, images,
  description, category, and the list of downloadable files with version labels +
  dates.
- [ ] This same layer powers browsing, metadata auto-fill (§3), and update checks
  (§4). Keep its surface area minimal to limit upkeep when the API changes.

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
- [ ] **Downloads are anonymous and unguarded.** `_sDownloadUrl`
  (`gamebanana.com/dl/<fileid>`) 302s to `files.gamebanana.com` and on to a
  `filecacheNN` node, serving real bytes with no session, no referer and no Cloudflare
  challenge. Range requests are honoured (`206 Partial Content`) — which is what makes
  §5's retry/**resume** actually implementable.
- [ ] **`ProfilePage` already carries every field the origin block wants**, so §3's
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
- [ ] **Upstream-gone is an explicit field, not just a 404.** `_bIsPrivate`,
  `_bIsTrashed`, `_bIsWithheld` — §7.6's `remote_missing` should read these rather
  than infer from a status code. `_bIsObsolete` is a *different* thing (the author
  flagged it superseded) and needs its own wording.
- [ ] **Per-file scan results ship too** — `_sAvResult` (`clean`), `_sAnalysisResult`.
  Worth showing verbatim on the file list: unlike an md5 match it genuinely *is* a
  safety signal (contrast §7.8), and it costs nothing to surface.
- [ ] **No documented rate limit.** No `RateLimit-*` or `Retry-After` headers on a
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

- [ ] **Source service** (e.g. `gamebanana`) — future-proofs for other sources.
- [ ] **Remote mod id** (GameBanana `_idRow`) — stable handle to re-query; more
  reliable than `sourceUrl`.
- [ ] **Installed file id** — GameBanana mods have multiple files; track *which*.
- [ ] **Installed version string + file/version label** (e.g. "white hair ver").
- [ ] **Downloaded date** — fallback comparator + UI ("added N ago"); ties into
  existing `sort_mode: added`.
- [ ] **Archive hash** — detect real changes vs same-version re-upload; enables
  dedup / "already have this". Recorded for **every** ingested archive, not only
  in-app downloads, since GameBanana publishes a per-file md5 we can match against
  — see §7.8 for what it can and cannot be used for.
- [ ] Locally-imported mods (drag/drop) simply have **no origin block** and show
  no update info — manual import keeps working unchanged. They are not an error
  state: how they surface, and how a user can opt one into tracking, is §7.
- [ ] **`source_url` stays user-facing and mod-page-only.** Never write machine
  handles or `/dl/<fileid>` links into it — the origin block owns those. The
  resolve dialog (§7.5) may *accept* a pasted `/dl/` link, but it stores the
  resolved ids in the origin block and normalizes `source_url` to the mod page.
- [ ] **Record the ingest shape, not just the file.** One archive does **not** map to
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
- [ ] **An inbound sidecar is untrusted input.**
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
- [ ] **A failed origin write is a state, not a shrug.** `ModMetadataService.write()`
  returns `false` on a read-only folder or an odd network share, and nothing looks at
  the result today. A mod whose origin can't persist would re-resolve forever with no
  explanation — report it once ("couldn't save tracking data for `<mod>` — folder is
  read-only") instead of silently retrying every scan.
- [ ] Every field above carries a **confidence** — see §7.2 for the tiers and
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
    one. A test pins that 60/0 result as a canary. Folder-name detection still
    runs first and still wins (it is per-folder, so it is the only signal that can
    differ between siblings from one archive); the category fills the case names
    cannot answer, `bikini` or `mod v2`.

### Filed by the read side (found while building it, deliberately not built)

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
- [ ] **Nothing keeps the library list live across a tab switch.** `ModsScreen` is
  a keyed child of an `AnimatedSwitcher` with no keep-alive, so it is disposed on
  every tab change and `initState` re-scans on the way back. The read side works
  around it by taking its own snapshot and invalidating it when the marketplace
  opens — which is correct and cheap, but two independent readers of the same
  library is a shape worth revisiting if a third appears (§7.4's status slot is
  rendered from `charactersProvider`, so it will not need one).
- [ ] **A file-list row overflows at a 2× OS text scale**, and has since before any
  of this: at that scale the row's outer layout — the scan-result chip plus the
  Download button, neither of which can shrink — exceeds a minimum-width window on
  its own, with no badges involved. Measured at 530px and 600px, chips or not. The
  *label* half of the row is now safe — it became a `Wrap` when a second chip
  landed there and broke it at 1.3× — so what is left is the trailing controls.
  Filed rather than fixed: making the button shrink or move below the label is a
  layout decision for the row as a whole, not a drive-by.
- [ ] **A failed origin write is still not surfaced for the *backfill* path.** §3
  already files this for ingest, and that half is done — `takeOriginWriteFailures`
  is drained and reported. The scan-time backfill has its own equivalent
  (`_unwritableBackfills`, session-scoped) and nothing shows it, so a mod in a
  read-only folder silently never gains an identity and now silently never gets a
  badge either. Same fix shape, different source.

### Filed by the metadata autofill (found while building it, deliberately not built)

- [ ] **The install is silent between the download finishing and the result.** The
  progress dialog closes the moment the bytes are in, and extract → duplicate check
  → folder-selection → import → autofill all run behind nothing at all. That was
  already the shape before this change, but the autofill lengthens the quiet window:
  typically ~830 ms, and up to one 20 s per-image timeout when a CDN node is
  degraded (§0 measured one serving at 0.08 MB/s). Filed rather than fixed because
  the fix is a decision about the whole install flow — most likely keeping the same
  dialog open through an "installing" phase — not a spinner bolted onto one step.
  Belongs with M4's "empty/error/loading states".
- [ ] **A mod page's tags are now parsed but still shown nowhere.** `GbMod.tags` had
  no reader at all before the autofill, which is why the two-shape parsing bug
  (§3 above) could sit there unnoticed. The autofill stores them on install; the
  detail view still doesn't display them, so a mod you *browse* shows no tags while
  the same mod once *installed* does. Cheap, and it would make the parse
  self-evidently correct instead of only test-correct.
- [ ] **A truncated gallery doesn't say it was truncated.** `RemoteModMetadata.maxImages`
  is 10 and real galleries reach 26+ (measured), so a mod can quietly arrive with 10
  of its 26 screenshots. The install message names "preview images" without a count
  — deliberately, since the only number available is a *cross-mod file total* rather
  than a gallery length — so nothing currently claims the gallery is complete either.
  What is missing is the other half: a way to say "10 of 26", or to pull the rest from
  the mod page in the edit dialog. Not a silent cap on correctness (the mod page is
  one click away), but the user has no way to know there is more.
- [ ] **The install-summary merge rests on an unasserted invariant.**
  `autoTags.addAll(fill.characterTags)` in `_installArchive` is correct only because
  the two maps are disjoint by construction — the autofill assigns a character solely
  when none is set, so folder-name detection and category detection can never both
  claim one mod. Nothing pins that. If the category is ever allowed to *override* a
  name match, the summary would report the category's answer while the sidecar keeps
  the name's, and the two would disagree silently. The wiring has no widget test
  either (it needs `ApiService`'s singletons and a configured library), which is
  acceptable for UI plumbing but is why the invariant is worth writing down.
- [ ] **An unwritable folder swallows the autofill too.**
  `RemoteMetadataFill.unwritable` is returned and only logged, on the same grounds
  as the two items above it: the origin write for the same folder already reports
  the failure, so a second message would be noise. That reasoning stops holding the
  moment the origin write succeeds and this one doesn't (a folder that becomes
  read-only mid-install, an odd network share). Third instance of the same fix
  shape — one place that reports "couldn't write to `<mod>`" for all of them.

## 4. Mod updating

- [x] **Manual update check** — per-mod and bulk ("check all"). The bulk results
  screen is also the bulk-resolution surface for unknown origins — see §7.6.
  **The check is done; the results *screen* is not.** Bulk reports through a
  snackbar and the card badges, which is enough to act on a finding but is not
  the per-row confirmation surface §7.6 describes. That screen stays filed
  there, unchanged.
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
- [ ] **Opt-in auto-update** (global and/or per-mod), with notification. Eligible
  only at `exact` confidence (§7.2) — which includes hash-matched hand-imported mods,
  not just ones we downloaded. **Signed off:** a checksum match and our own download
  are the same epistemic state (the match identifies the file with certainty and we
  extracted that archive ourselves, so the folder provably came from it), and
  re-coupling the gate to `provenance == "downloaded"` would partly undo the
  confidence/provenance split §7.2 deliberately made. The residual risk is a
  base-rate one, not a logical one — people who hand-import are likelier to have
  since edited or merged those folders — and it is carried entirely by the two
  guarantees below, which therefore stop being merely "planned":
  - The §4 snapshot is **unconditional** for auto-update. No snapshot, no unattended
    write — this is the whole reason the sign-off is safe.
  - §4.2's retention cap must not prune a backup before the user could plausibly have
    noticed a bad silent update. An age-based floor beats a pure count cap here.
  - Note the interaction with `ingest` (§3): one banked hash can mark a **sibling
    group** of folders `exact`, so a single auto-update rewrites all of them at once.
    Snapshot the group, not the folder.
- [ ] **Changelog display** from GameBanana before updating.
- [ ] **Backup / rollback** — snapshot the previous version before updating so a
  bad update is one click to revert.
- [ ] **Preserve user edits across updates — conservative merge + report.** Always
  snapshot the old folder first (non-negotiable). Then re-apply **only** edits that
  match confidently (same `[Section]` + same key identifier); leave anything
  uncertain to the new version. Show a post-update **report** of what carried over,
  what changed, and what couldn't be matched — never a silent uncertain merge.
  Not foolproof (identifiers/names can change, keybinds can be added/removed), so
  the report + backup are how the user recovers.

### Filed by the update check (found while building it, deliberately not built)

- [ ] **A found update cannot be acted on.** The dialog lists the newer files and
  then offers a mod page and a marketplace shortcut, because installing from
  the marketplace creates a **second mod folder** rather than replacing the
  first — §4.1's deactivate → swap → reactivate path does not exist yet. The
  dialog says so in one sentence rather than implying otherwise, which is
  honest but is not the feature. This is §4's "applying" half above, listed
  here too because it is the first thing a user will ask for after seeing a
  blue badge.
- [ ] **The options list has no per-row download**, so choosing a file means
  going to the marketplace and finding it again. `GbFileList` already renders
  exactly those rows *with* download buttons and takes an `onDownload`
  callback — but wiring it here means reaching the download-extract-import
  pipeline, which lives inside `marketplace_screen`'s state rather than in a
  service. Extracting that is the same piece of work the item above needs, and
  doing it once serves both.
- [ ] **The marketplace card still has no "update available" state.**
  `GbModCard._statusSlot` gained the "in library" badge in M2 and the app
  `CLAUDE.md` reserves that method's second branch for this. It is a different
  question from the library card's — *does the mod you are browsing publish
  something newer than the folder you own?* — and it needs the installed-mods
  index to name the folder before a verdict can be looked up for it. Small, and
  it closes §1's last unchecked indicator.
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
- [ ] **`remote_missing` is now *detected* and still never written.**
  `checkForUpdate` returns `sourceGone` from the remote's explicit
  `_bIsPrivate` / `_bIsTrashed` / `_bIsWithheld` flags, and the bulk pass
  returns it for an id the server refuses outright — but nothing persists it to
  the sidecar. Deliberate rather than forgotten: §7.4 currently *silences* the
  status slot for a `remote_missing` mod, so writing the flag today would make
  the mod go quiet permanently with no wording explaining why, which is exactly
  the "silent hole" already filed under §7.5. The two have to land together —
  the state needs its own wording ("source no longer available") before
  anything writes it.
- [ ] **Verdicts are session state, and that is a decision worth revisiting
  once, not a gap.** Nothing is persisted, so the badges are empty on every
  launch until a check is pressed. That is right on the merits — a verdict
  restored from disk asserts something about a mod page nobody has looked at
  since — but the *user-visible* consequence is that the feature looks off
  until they find the button. The fix if it is ever wanted is a nudge or an
  opt-in check-on-launch (M4's auto-update territory), **not** caching the
  verdict.
- [ ] **The per-mod check fetches a whole `ProfilePage` when `DownloadPage`
  would do.** `Mod/<id>/DownloadPage` returns `_aFiles` + `_aArchivedFiles`
  plus the upstream-gone flags and nothing else — everything the comparator
  reads except `_tsDateAdded` (the baseline clamp) and `_tsDateUpdated`. Not
  taken: the dialog would then need a second request for the two dates, and the
  profile is very often already in the client's ten-minute cache from the
  marketplace. Worth measuring before assuming either way.
- [ ] **The batch bisect could ask the error which id was bad.** A
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
- [ ] **`Mod/<id>/Updates` is read, but only for `_aFileRowIds` and `_sName`.**
  §4's "changelog display before updating" wants `_sText` / `_aChangeLog`, which
  are parsed by nothing. The DTO deliberately stops at what has a reader — the
  `_aTags` bug is what an unread field costs. Belongs with the applying half: a
  changelog is what you read *before pressing update*, and there is nothing to
  press yet.
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
- [ ] **`_bHasFiles` on an update record is unreliable** — it reads `false` on a
  record whose `_aFileRowIds` names two files (measured on `549029`). Nothing
  reads it; noted so nothing starts to.

### 4.1 How an update is actually applied

Everything above is *when* to update and *what to preserve*. This is the part that
touches a live install, and it's where this codebase's specific hazards live. An
update is **not** a re-run of the import path.

- [ ] **Deactivate → swap → reactivate.** An installed mod is usually *active*, which
  means `saveModsPath/<name>` is a symlink (Linux) or junction (Windows) pointing into
  the very folder being replaced. Replace the folder underneath it and the link
  dangles — then `_cleanupInvalidLinks()` prunes it on the next scan and the mod
  silently switches itself off. `renameMod()`
  (`mod_manager_service.dart:371`) already does the correct dance for exactly this
  reason: remove the link, move the folder, recreate the link. Update follows it,
  restores the previous active state, and fires the F10 reload when `autoF10Reload`
  is on.
- [ ] **The folder name never changes.** The new archive's root folder is frequently
  named differently (`Ellen v2`), but `config.json` keys `active_mods`,
  `favorite_mods` and `mod_character_tags` by folder name. Keep the existing name;
  record the new upstream name in the origin block if it's worth showing.
- [ ] **`.zzz-mod-manager/` survives, always.** The sidecar sits *inside* the folder
  being replaced — description, user-imported gallery images, tags, and the origin
  block we just wrote. Carry the directory across the swap and merge new metadata into
  it. The incoming archive's own sidecar, if it has one, does not win (same untrusted
  -input rule as §3).
- [ ] **Swap, don't overwrite.** Extract to a temp dir, sanity-check it
  (`ArchiveService.containsIniFile`), then move the old folder aside and move the new
  one in. Overwriting in place means a crash or a half-failed extract leaves a folder
  holding two versions at once, with no way to tell which file came from where.
- [ ] **Windows will refuse to delete files the game holds open.** ZZMI keeps handles
  on loaded mods. Either require the game closed for an update, or handle the busy
  error explicitly — failing silently halfway is the worst available outcome.
- [ ] **Never re-ask the import questions.** The install path prompts "which folders?
  separate or combined?" (`resolveImportSelection`); an update replays the recorded
  answer from `ingest` (§3). If the new archive's layout no longer matches what was
  recorded, that is a **stop-and-ask**, not a guess.
- [ ] Reuse this same path for a **reinstall / repair** action — it's the identical
  operation at the same file id, so it costs nothing extra.

### 4.2 Backups — where they live

- [ ] **Outside `modsPath`.** A snapshot placed *inside* the mod folder is reachable
  through the active symlink, so ZZMI traverses it and loads the old version's `.ini`
  alongside the new one — duplicate hotkeys and conflicting overrides, which present
  to the user as "the update broke my mod". Snapshots go in `<appData>/backups/<mod>/`.
- [ ] **Bounded retention.** §7.2 has `inferred` updates *keep* their backup rather
  than pruning it, which grows without limit. Pick a cap (last N per mod, or an age
  limit), and expose total backup size in the storage view (backlog) so it isn't
  invisible disk usage. §0's sizing: the median mod is only ~22 MB, so a generous
  count cap is cheap for most libraries — but the tail reaches 1.24 GB, so the cap
  has to be **size-aware**, not purely count-based, or a handful of big mods quietly
  eats several GB.

## 5. Download manager

- [ ] Extract the inline download code out of `marketplace_screen.dart`
  (`_downloadToTemporaryFile` bare `HttpClient`) into a dedicated service.
- [ ] Queue + progress. **Resume is M1, not M4** — §0 measured the numbers behind
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
- [ ] Progress UI must suit hour-long transfers: rate + ETA, not just a bar, and
  cancellable throughout. `_nFilesize` exactly equals `Content-Length`, so it's a
  reliable denominator and a preflight disk-space check.
- [ ] **Unify the download directory.** Today it's inconsistent (system Downloads
  on Linux vs `<appData>/downloads` for HTTP grabs). **Decision**: incoming
  archives land in **`<appData>/downloads`** and are **deleted after successful
  extraction** — the archive is a throwaway intermediate. Not user-configurable in
  M1; add a config key later only if requested.
- [ ] One consistent download → extract → tag → (optionally activate) flow for
  both platforms. **Every** entry point into it (download, drag-drop, file picker)
  hashes the archive on the way through, *before* the archive is deleted — §7.8.
- [ ] Revisit the current SSL-validation bypass on Win/Linux.

## 6. Config / persistence

- [ ] New `config.json` + `SharedPreferences` keys for: download directory (only if
  §5's fixed location is ever made configurable), auto-install-after-download,
  update-check behaviour (manual/auto), auto-update opt-in. (Remember the dual-storage
  pattern: getter/setter **and** the `_saveToFile` / `loadFromFile` map.)
- [ ] Key for §1: the **content filter** — whether `warn`/`hide` mods are blurred,
  shown, or omitted. Needed in M1, since it's the first thing a user hits on the
  results grid.
- [ ] Keys for §7: the post-upgrade nudge's dismissed flag, and the remote-lookup
  response cache — the latter should honour the API's own `max-age=600` (§2), and
  probably belongs in app-data rather than config.
- [ ] Key for §4.2: backup retention (count or age), once a cap is chosen.

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
- [ ] **We cannot reproduce GameBanana's default ordering, and users will compare.**
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
- [ ] **Unrecognised top-level query params are silently ignored by apiv11.** Only
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

- [ ] **The content filter has no Settings-tab entry.** The key and the decision logic
  shipped with M1, and the control lives in the marketplace toolbar where it is first
  needed — but §1 said "put the toggle in Settings (§6)" and that half is not done.
  Belongs with M4's "surface all new settings in the Settings tab"; noted here so it
  isn't assumed shipped because the *key* is.
- [ ] **Three marketplace l10n keys are dead and predate M1**:
  `download_progress_unknown`, `install_7zip_missing`, `install_extract_failed`. All
  three exist in `en.json`/`uk.json` with no reference anywhere in `lib/`. Left alone
  because they were already dead before this work and deleting a translated string is
  not something to do as a drive-by — but either the messages should be wired up (the
  7-Zip one in particular looks like it *should* be reachable from `ArchiveService`) or
  the keys should go.
- [ ] **The results grid has no infinite scroll and no result-count display.** Paging
  is prev/next with "Page N of M", which is honest but tedious across 866 pages. Also
  worth showing `_nRecordCount` so the user knows the search narrowed anything.
  Deliberately plain per M1; revisit with M4's polish.
- [ ] **Images are fetched with `Image.network` and cached only in memory.** Fine and
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

- [ ] Extend the §3 origin block with a confidence per axis, plus honest markers
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

- [ ] **Confidence and provenance are separate axes.** Confidence measures *how
  sure we are*; provenance records *where the mod came from*. They came apart the
  moment a hand-imported archive could be matched exactly (§7.8), so a tier named
  after a source (the old `installed`) would be actively misleading in the UI for
  a mod the user dragged in themselves.
- [ ] Tiers, and what each one may drive:
  - **`exact`** — we know precisely which file this is: we downloaded it, or its
    archive md5 matched GameBanana's published checksum. The *only* tier eligible
    for unattended auto-update (and see the second gate in §4).
  - **`user`** — the user told us. Trusted; manual updates with a normal confirm.
  - **`inferred`** — we guessed from local data (URL parse, name match, single
    unambiguous remote file). May badge and suggest; every update through it is
    manual, is labelled a guess, and **keeps** its backup rather than pruning it.
  - **`assumed_latest`** — "I don't know what I have, I got it around then."
    Compares against `baseline_remote_date` only.
  - **`unknown`** — nothing.
- [ ] **Never-confirmed ≠ safe.** An `inferred` identity came from a free-form
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
- [ ] **Version sniffing from local files** (folder-name `_v2` tokens,
  `; version` comments in `.ini`, README lines): **hint only, never written.**
  Mods embed ZZMI/game versions and author-side numbering that are
  indistinguishable from mod versions, and a wrong stored version is worse than
  none. Surface detected tokens in the resolve dialog to help the user choose.

#### Filed by the backfill (found while building it, deliberately not built)

- [ ] **`ModSort.added` still sorts by scan order.** `installed_at` now exists on
  every backfilled mod, so the sort finally *can* have a real timestamp — but
  wiring it is UI work and the backfill was scoped local-only. Two things to
  handle when it lands: it visibly reorders existing libraries the first time it
  runs, and it must fall back gracefully for mods with **no** origin block at
  all, which is most of a library that has never had a `source_url` pasted in.
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
- [ ] **A backfilled sibling group can't be reconstructed, and two mods sharing a
  `mod_id` must not be read as one.** `origin.ingest.sibling_group` is what makes
  §4's "an update acts on the whole sibling group at once" work, and nothing on
  disk records that two folders came from one archive — so the backfill leaves it
  null, honestly. But mods sharing a `mod_id` are *common*: two occurrences in a
  real 23-mod library (two variants of one mod, installed as separate folders).
  §4 and §7.6 must treat "same `mod_id`, no group" as **independent mods that
  happen to share a page**, not as a group to rewrite together.
- [ ] **No UI links to a mod's GameBanana page from `origin.mod_id`.** The detail
  screen has "open in browser" for a mod you're *browsing*, but a mod already in the
  library has no equivalent, even when its origin block knows exactly which page it
  came from. The edit dialog shows `source_url`, which a downloaded mod never has (see
  the resolved item above). Cheap and squarely M2's territory, since that's where the
  library starts reading the origin block.
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

#### Filed by the resolve dialog (found while building it, deliberately not built)

- [ ] **A "tracked by date only" filter, if the card marker turns out not to be
  enough.** The new muted clock makes the state visible but not *enumerable* —
  deliberately, since it is out of the "needs attention" count. At 17 mods
  seeing them is enough; at 80 it may not be, and the natural home is a second
  row on the `!` toggle rather than a sixth toolbar control. Filed rather than
  built, to see whether it is actually wanted.
- [ ] **`remote_missing` has no visible state, and now silences the slot.** §7.4's
  three states have no room for "the mod page is gone", so `modOriginStatus`
  treats the flag like `tracking: "off"` and renders nothing — correct today,
  since nothing writes the flag, but it becomes a silent hole the moment §7.6
  does. That state needs its own wording ("source no longer available"), and it
  must stay distinct from `_bIsObsolete`, which means the mod still exists and its
  author flagged it superseded.
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
- [ ] **Ukrainian plurals are 1-vs-many, and the language has three forms.**
  `AppLocalizations.t` has no plural machinery, so counted strings use a
  `_single` / `_plural` key pair chosen in Dart — the pattern
  `mods.import.success_single` established and the bulk action follows. That is
  correct for English and correct for Ukrainian at 1 and at 5+, but **wrong for
  2–4** ("2 модів" should be "2 моди"). Pre-existing and app-wide rather than
  new, but now spread across a dozen more strings. The fix is a small plural
  selector keyed on the locale, not another key per string. A test already pins
  that every `_single` has a `_plural` sibling, which is the half that fails
  silently.
- [ ] **Two constants hold the string `gamebanana`.** `gameBananaSource`
  (`utils/gamebanana_url.dart`, where offline code can reach it) and
  `AppConstants.gameBananaSourceName` (`core/constants.dart`, used by the
  marketplace's ingest seed). They agree today; a typo in either would create a
  silent second, unqueryable service rather than an error — which is the exact
  failure `gameBananaSource`'s doc comment was written to prevent. One of them
  should go.
- [ ] **The resolve dialog cannot be reached from the edit-mod dialog.** §7.5
  names three entry points; the status slot and the context menu are wired, the
  edit dialog is not. That is the dialog where `source_url` is shown and edited,
  so it is where a user most plausibly notices the binding is wrong.
- [ ] **A keybind edit probably doesn't refresh the grid either — same guard,
  same shape.** `modGroupsChanged` deliberately does **not** compare
  `ModInfo.keybinds`, because they are re-parsed from `.ini` on every scan and
  `KeybindInfo` has no value equality, so comparing them would report a change
  every time and switch the guard off entirely. But the keybinds dialog's
  `onSaved` calls `loadMods`, which means an edit whose only effect is on
  keybinds hits exactly the failure the origin block just hit. Not verified by
  clicking, and not fixed here: the fix is value equality on `KeybindInfo` plus a
  decision about whether enrichment produces stable values, which is a keybinds
  question rather than an origin one.
- [ ] **The rescan guard's field list is a silent-staleness trap in general.**
  `origin` is now self-maintaining (it is compared through `ModOrigin.==`), but
  every other field on `ModInfo` is a line someone has to remember to add, and
  forgetting it produces no error — just a surface that renders yesterday's data
  until the tab is switched. The durable fix is value equality on `ModInfo`
  itself, which needs the keybinds question above answered first.
- [ ] **The dialog is per-mod only, by design, and that leaves the two-variant
  case tedious.** Two folders from one mod page are common (measured: two in a
  23-mod library), and each needs its own trip through the dialog even though the
  identity step's answer is identical. §7.6's bulk screen is the proper fix;
  noting it here so it isn't mistaken for something the per-mod dialog should
  grow.

### 7.6 Bulk resolution = §4's "check all" screen

**Decision: no separate migration screen.** Bulk resolution folds into the §4
bulk update-check results list, which already fetches exactly the data needed.
One screen, two jobs, and nothing that goes stale once libraries are migrated.

- [ ] **Bulk acts only on precise handles (`mod_id`).** Fuzzy identity matching is
  always one-at-a-time and user-confirmed (§7.5's search box). Rationale: a mass
  fuzzy name-match that a user rubber-stamps can bind a folder to an unrelated
  mod — and then an "update" overwrites their mod with a different mod's files.
  Folder names in the wild (`Ellen final FIXED v2`, `bikini`, `mod`) are exactly
  where fuzzy matching is least reliable. **Untracked mods therefore get no bulk
  feature at all.**
- [ ] **It's a confirmation pass, not a search pass.** Per row: local folder name
  + cover on the left, remote mod name + thumbnail on the right, ✓/✗. A glance
  test that cheaply upgrades `inferred` → `user`, which is exactly what §7.2
  requires before any overwrite.
- [ ] **Per-row auto-resolution** from the file list + banked hash + proxy date:
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
- [ ] **Match against `_aArchivedFiles`, not just `_aFiles`.** `ProfilePage` returns
  superseded files too, each with its own `_idRow`, `_tsDateAdded` and
  `_sMd5Checksum`. That measurably improves resolution: a banked hash (§7.8) can hit a
  file that's no longer offered, pinning the installed version at `exact` for exactly
  the "you have an old one" case that would otherwise stay unknown — and it supplies
  date-ranked candidates for the picker. Same response, no extra request.
- [ ] Bounded, cancellable request queue with progress and backoff on rate limits;
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

### 7.7 Self-healing (why none of this has to be perfect)

- [ ] Any mod whose **identity** is known becomes fully known the first time it
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
- [ ] **Hash before the archive is deleted** (§5 discards it after extraction).
  The hash is the cheap 32-char residue that survives that deletion — it cannot be
  recovered later, because zip output isn't reproducible from extracted files.
- [ ] **Bank now, cash in at resolution.** A hash alone never yields *identity* —
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

- [ ] **Moderate hit rate.** An untouched GameBanana zip matches. Anything
  re-zipped — a user who unpacked and repacked it, or an archive passed around via
  Discord — never matches, because any repack changes the md5 even when the
  contents are byte-identical. Treat it as a **bonus fast-path, never load-bearing**.
- [ ] **A miss costs nothing.** The field is null-or-exact: no match means we learn
  nothing and fall through to the normal guess path (§7.5). False negatives are
  common by design; false positives are not a realistic accident.
- [ ] **`archive_md5` is a matching key, never an integrity or authenticity claim.**
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

- [ ] **Localization is a per-screen tax.** Every surface here needs keys in **both**
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
- [ ] **Name the tests, because the risky parts are pure functions.** The pieces most
  likely to be quietly wrong need no network and no UI: `source_url` → `mod_id`
  parsing (§7.3); the confidence state machine and what each tier permits (§7.2); the
  `.ini` conservative merge (§4), which is the highest-risk piece in the whole plan
  since it edits user data; hash → file matching across `_aFiles` + `_aArchivedFiles`
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
- [ ] **One seam for offline tests.** Keep HTTP behind a single injectable interface
  in §2, or every test above needs a network to run.

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

## Open questions

*(none open — all resolved below)*

### Resolved

- [x] **Does dropping the webview lose access to gated / NSFW content, and is there
  an API login (OAuth, API key, basic auth) to get it back?** Neither — there's
  nothing to get back. Probed the live API anonymously with no cookies (2026-08-01):
  adult mods appear in the ZZZ subfeed, their `ProfilePage` returns in full including
  `_aFiles` + `_sMd5Checksum`, and `gamebanana.com/dl/<fileid>` serves real bytes
  through two redirects with no session and no challenge. GameBanana ships a
  *rendering hint* (`_sInitialVisibility`, `_aContentRatings`) and trusts the client
  to honour it, so the filter becomes ours to implement — no auth mechanism needed or
  offered. (See §1 and §2.)
- [x] **Is the archive hash only for in-app downloads?** No — hash **every**
  ingested archive, including drag-drop. GameBanana publishes a per-file md5, so a
  hand-supplied archive can be matched exactly, which is the only route to
  exactness for manual imports. A modified/re-zipped archive simply never matches
  and costs nothing: the field is null-or-exact. Bonus fast-path, not load-bearing.
  (See §7.8.)
- [x] **May a GameBanana-checksum match drive unattended auto-update, the same as a
  file we downloaded ourselves?** Yes — signed off. The two are the same epistemic
  state, and gating on provenance instead would partly undo the confidence/provenance
  split. The risk that remains is a base-rate one (hand-importers edit their folders
  more often), and it's absorbed by making the pre-update snapshot unconditional and
  giving backup retention an age floor. (See §4 and §4.2.)
- [x] **Does an md5 match imply the mod is safe?** No, and nothing may present it
  that way. It's a matching key only — md5 is broken, so collisions are
  constructible, which is harmless precisely because a match grants no trust and
  skips no check. (See §7.8.)
- [x] **Confidence tier named after a source?** Renamed `installed` → `exact`, with
  provenance (`downloaded` / `imported_archive` / `imported_folder`) split into its
  own field — a hash-matched hand import is exact without having been downloaded by
  us, so the two axes had to come apart. (See §7.2.)
- [x] **Mods that predate the origin block — smart migration, or let the user
  declare the version?** Both, and neither as a wizard: "origin unknown" becomes a
  permanent modelled state with confidence tiers, an offline backfill fills what it
  can, and a resolve flow stays in the UI. (See §7.)
- [x] **How loud is the "no version" warning?** One status slot per card with three
  distinct states — amber only when it's *actionable* (identity known, version
  unknown), a muted neutral dot for genuinely-local mods, accent for update
  available. Plus a "needs attention" filter so it's enumerable. Badging every
  unversioned mod would amber the whole legacy library and train users to ignore
  it. (See §7.4.)
- [x] **Bulk resolution — a migration screen, or fold it in?** Fold it into §4's
  bulk "check all" results screen; it already fetches the same data. Bulk only
  ever acts on precise `mod_id` handles — **no fuzzy bulk matching for untracked
  mods**, because a rubber-stamped wrong match lets an "update" overwrite a mod
  with an unrelated mod's files. (See §7.6.)
- [x] **Sniff versions out of local files?** Hint only, never written — mods embed
  ZZMI/game versions and author numbering that look identical to mod versions.
  (See §7.3.)
- [x] **May an unambiguous match be written without asking?** Yes, at `inferred`
  confidence with a summary + undo — safe precisely because `inferred` can't drive
  auto-update. (See §7.6.)
- [x] **Baseline date for "assume current"?** Oldest file mtime in the mod folder.
  Errs early → false "update available" rather than silently missed updates, and
  false positives self-correct when the user opens the file list. (See §7.3.)
- [x] **File list with many variants — which is "primary"?** The download button
  auto-selects only when there's a single clear highest version and no competing
  variants; otherwise the user must choose. (See §1.)
- [x] **Download directory** — archives go to `<appData>/downloads`, deleted after
  extraction; not configurable in M1. (See §5.)
- [x] **Keybind-preservation aggressiveness?** Conservative merge + report: always
  back up, re-apply only confidently-matched edits (same section + same key id),
  flag everything else in a post-update report — never a silent uncertain merge.
  (See §4.)
- [x] **Mod profiles in the UI?** Own sidebar tab with a dedicated page + list;
  library-wide active-set load-outs only (not per-mod settings — ZZMI owns that).
  (See backlog.)
