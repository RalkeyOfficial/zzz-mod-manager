# BUGS & TODO

Planning + backlog for the mod-downloading / marketplace / update overhaul.
This is a **pre-planning document** — it captures *what* we want to build and the
decisions made so far, not *how* to implement it. Items are grouped by area.

> **This file is temporary.** As each area ships, its schema details and rationale
> move into [`docs/`](docs/README.md) — the origin block and confidence model (§3,
> §7) belong in [`docs/metadata-schema.md`](docs/metadata-schema.md). Don't let this
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

- [ ] **§2 (subset)** — GameBanana API client: search, mod profile, file list.
  Only what browsing + install needs; no caching/retry polish yet.
- [ ] **§5 (basic)** — extract the inline download code into a service;
  download → extract → auto-tag. Single fixed flow, no queue/resume yet. Hash the
  archive in-stream on every ingest path (§7.8) — it's unrecoverable afterwards,
  so this has to land with the flow itself even though nothing reads it until M2.
- [ ] **§3 (write side)** — record the origin block at install time (source,
  remote mod id, file id, version string + label, date, hash). *Written now,
  read in M2.* Ships **with the confidence fields from day one** (§7.2) —
  otherwise M1's own format needs migrating later.
- [ ] **§3 (prerequisite)** — make the sidecar **round-trip unknown keys** and
  treat machine-owned fields (`origin`, `schema_version`) as preserved-from-disk
  rather than sourced from `ModInfo`. Must land **before** anything writes an origin
  block: today an unrelated metadata edit would silently erase it, and older builds
  strip keys they don't know. Forward-only fix — see
  [`docs/metadata-schema.md`](docs/metadata-schema.md) §2 and §4.
- [ ] **§7 (offline backfill)** — schema v1 → v2 during the normal scan:
  `source_url` → remote mod id, proxy install date. Local-only, no network, no
  UI. Without this, every pre-existing install is permanently invisible to §4.
- [ ] **§1 (plain)** — results grid + mod detail screens, both platforms; remove
  the `_isWebViewSupported => _isWindows` gate and the Downloads-folder watcher.
- [ ] **§6 (as needed)** — add the download-directory config key.

Exit criteria: on Linux *and* Windows, search a ZZZ mod in-app → open detail →
download → it installs, auto-tags, and carries an origin block.

### M2 — Smart installs (read the origin block)

Goal: make the data recorded in M1 pay off in the UI.

- [ ] **§3 (read side)** — "already installed" detection; file-hash dedup.
- [ ] **§3** — auto-populate metadata (description, images, tags, character) from
  the API on install instead of leaving it blank.
- [ ] **§1** — "already installed" / "update available" indicators on cards + detail.
- [ ] **§7** — the mod-card **status slot** (§7.4), the **"needs attention"**
  filter, and the per-mod **resolve dialog** (§7.5). This is where "the user can
  take action" actually lands; it needs §2's client and §1's file-list widget.
- [ ] **§7** — the zero-network **"assume current"** baseline action (§7.5).

### M3 — Updating

Goal: the payoff feature. Needs §2 + §3 + §5 from M1/M2.

- [ ] **§4** — manual update check (per-mod + bulk), version-string+label rule,
  update badges, changelog display, backup/rollback, preserve user edits.
- [ ] **§4 + §7** — the bulk "check all" results screen doubles as the bulk
  **resolution** screen (§7.6): per-row identity confirmation and inline version
  pickers. Verdict wording and auto-update gating become confidence-aware (§7.2).

### M4 — Robustness & polish

- [ ] **§5** — download queue, progress, retry/resume; revisit SSL bypass.
- [ ] **§4** — opt-in auto-update (global + per-mod) with notification.
- [ ] **§6** — surface all new settings in the Settings tab.
- [ ] **§1** — empty/error/loading/offline states.

### Later — backlog

Everything under "Additional feature ideas" (paste-URL install, wishlist, feeds,
NSFW filter, profiles, conflict detection, storage view). Pull items forward as
they earn priority.

---

## 1. Marketplace — native GameBanana browser

- [ ] Remove the Linux/Windows split in `marketplace_screen.dart` (the
  `_isWebViewSupported => _isWindows` gate, the Linux "open in browser" view, the
  Downloads-folder watcher) in favour of the native browser.
- [ ] **Results grid screen**: search box + category/character filters → grid of
  mod cards (thumbnail, name, author, likes/views, category badge).
- [ ] **Mod detail screen**: gallery images, description, author, category, and a
  **file list** (each file = version label + upload date + size + download button).
  - **Default-selection rule**: the download button auto-selects a file **only**
    when there is a single clear highest version and **no competing variants**.
    When variants exist or the choice is ambiguous, do **not** default — the user
    must pick. This same rule feeds "installed file id" (§3).
- [ ] "Open in browser" escape hatch on each mod (for content we don't render).
- [ ] "Already installed" / "update available" indicators on cards & detail,
  driven by the per-mod origin data (see §3). In the **library**, this indicator
  shares a single status slot with the unknown-origin states — see §7.4.
- [ ] Decide empty/error/loading states and offline behaviour.

## 2. GameBanana API layer (the keystone)

- [ ] Thin, dedicated API client service — **not** inline in the UI. Surface kept
  small and stable: search, mod profile (metadata), and file list.
- [ ] Resolve a mod URL **or** id → structured data: name, author, images,
  description, category, and the list of downloadable files with version labels +
  dates.
- [ ] This same layer powers browsing, metadata auto-fill (§3), and update checks
  (§4). Keep its surface area minimal to limit upkeep when the API changes.

## 3. Mod metadata & origin model

Today `ModMetadata` only has a free-form `sourceUrl` (user-editable) and no
version/origin data. Extend the per-mod metadata (and `ModInfo`) with an
**origin block**, recorded at install time:

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
- [ ] Every field above carries a **confidence** — see §7.2 for the tiers and
  what each one is allowed to drive.
- [ ] Auto-populate metadata (description, images, tags, character) from the API
  on marketplace install instead of leaving it blank.

## 4. Mod updating

- [ ] **Manual update check** — per-mod and bulk ("check all"). The bulk results
  screen is also the bulk-resolution surface for unknown origins — see §7.6.
- [ ] Update rule: prioritise version string + version label; fall back to upload
  date / hash. Best-effort suggestion, clearly labelled as such.
- [ ] **Confidence-aware verdicts.** With a guessed installed version, the
  strongest claim available is "possibly outdated" — never a bare version
  comparison. Auto-update is gated to exact confidence only (§7.2).
- [ ] **Update badges** on mod cards in the library.
- [ ] **Opt-in auto-update** (global and/or per-mod), with notification. Eligible
  only at `exact` confidence (§7.2) — which now includes hash-matched hand-imported
  mods, not just ones we downloaded. **⚠ Needs sign-off:** treating a
  GameBanana-checksum match as equivalent to our own download is the one safety
  policy in §7 that hasn't been explicitly confirmed. The argument for it: the
  match identifies the file with certainty and we extracted that archive
  ourselves, so the folder provably corresponds to it.
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

## 5. Download manager

- [ ] Extract the inline download code out of `marketplace_screen.dart`
  (`_downloadToTemporaryFile` bare `HttpClient`) into a dedicated service.
- [ ] Queue + progress + retry/resume.
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

- [ ] New `config.json` + `SharedPreferences` keys for: download directory,
  auto-install-after-download, update-check behaviour (manual/auto), auto-update
  opt-in. (Remember the dual-storage pattern: getter/setter **and** the
  `_saveToFile` / `loadFromFile` map.)
- [ ] Keys for §7: the post-upgrade nudge's dismissed flag, and the remote-lookup
  response cache (or park the cache in app-data rather than config).

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
| **Which remote mod is this?** (identity) | **Often yes.** `source_url` already exists and is user-editable; parsing `gamebanana.com/mods/<id>` recovers identity for free. |
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

Hooks into the existing lazy per-mod migration in
`ModManagerService._loadOrMigrateMetadata()` — the same pattern already used for
the legacy character tag and app-data images. Strictly local: scans run offline
on every launch.

- [ ] Parse `source_url` for `gamebanana.com/mods/<id>` → `mod_id` at `inferred`.
  Highest-yield recovery by far. `/dl/<fileid>` is **not** handled here (per §3
  that field is mod-page-only, and resolving a file id needs the API anyway).
- [ ] `installed_at` = **oldest file mtime in the mod folder**, with
  `installed_at_is_proxy: true`. Folder mtime/ctime are both bumped by `.ini`
  edits, so they skew *later* than the true install and would hide updates; the
  oldest contained file is the earliest defensible proxy (and extraction often
  preserves the author's own build timestamps).
  - Side benefit: `ModSort.added` (`state_providers.dart:150`) is currently just
    scan order — this finally gives it a real timestamp.
- [ ] Nothing found → **write no origin block at all.** Absence means untracked;
  re-sniffing costs one string parse. Preserves the existing "don't litter every
  mod folder with empty sidecars" rule — a user who never opens the marketplace
  should see no new files. Only an explicit user decision (`tracking: "off"`)
  causes a write.
- [ ] **Version sniffing from local files** (folder-name `_v2` tokens,
  `; version` comments in `.ini`, README lines): **hint only, never written.**
  Mods embed ZZMI/game versions and author-side numbering that are
  indistinguishable from mod versions, and a wrong stored version is worse than
  none. Surface detected tokens in the resolve dialog to help the user choose.

### 7.4 Visual status — one slot, three states

- [ ] The mod card gets a **single status slot**, not stacking badges. It renders
  exactly one of:
  - **Amber / actionable** — identity known, version unknown. We can query for
    updates but can't judge them, and one click fixes it. Tooltip: "installed
    version unknown — click to set". Opens §7.5.
  - **Muted neutral dot** — untracked (no identity). Informational, never
    alarming: most of a legacy library looks like this, and badging it loudly
    trains the user to ignore the slot entirely.
  - **Accent / update available** — the §4 state. Must be clearly distinct from
    amber, or the two read as the same thing.
  - Nothing at all for fully-known origins and `tracking: "off"`.
- [ ] **"Needs attention" filter** in the mods toolbar, alongside the tag filters.
  A status dot is spatial; a library of 80 mods needs the state to be
  *enumerable* before anyone can act on it in bulk.
- [ ] One-time dismissible nudge after the upgrade ("N mods aren't tracked for
  updates"), re-openable from Settings. Not a modal wizard.

### 7.5 Per-mod resolve dialog

One job: bind this folder to a remote mod + file. Reuses widgets §1 already
builds (search result cards, the file list). Entry points: the status slot, the
mod context menu, and the edit-mod dialog.

- [ ] **Identify** — prefilled from the `source_url`-derived id; otherwise a
  search box seeded with the folder name, or a pasted URL (a `/dl/` link is
  accepted here and resolved via the API). Confirming sets `user` confidence.
- [ ] **Pick the file** — skipped entirely when a **banked archive md5** (§7.8)
  matches one of the remote files: that's exact, so just show what it resolved to.
  Otherwise the remote file list, ranked by local hints: exact folder-name ↔
  archive-name match first, then upload date nearest `installed_at`; preselect when
  there is exactly one file. Always show *why* a row is suggested ("matches your
  folder name") — no silent magic.
- [ ] **Two first-class escape hatches**, both one click:
  - *"I don't know which"* → `assumed_latest`, `baseline_remote_date =
    installed_at`. Don't flag anything uploaded before the install; do flag
    anything after. Requires zero knowledge from the user.
  - *"Not from GameBanana / it's my own"* → `tracking: "off"`; the status slot
    goes quiet permanently.
- [ ] **Zero-network "assume current" bulk action** — apply `assumed_latest` to
  every tracked-but-versionless mod at once, no API calls. Probably the highest
  value-per-line item here: it turns a dead 50-mod library into a working
  update-notification system immediately, with an honest caveat instead of a
  fabricated version string.
- [ ] Free add-on from the same API response: an **"also fill in missing
  metadata"** checkbox (description, images, tags, character) for bare legacy
  imports. §3 wants this on install anyway.

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
    Version stays unknown; "probably outdated" is the correct verdict.
  - *Multiple files* → genuinely ambiguous: inline version picker on the row.
  - *404 / private / trashed* → set `remote_missing`, stop retrying, show
    "source no longer available".
- [ ] Bounded, cancellable request queue with progress and backoff on rate limits;
  cache responses so re-running is cheap. Never runs without an explicit press —
  no network on launch.

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

- [ ] **Hash every archive we ingest**, from any path: in-app download, drag-drop,
  file picker. Stream the hash during the read that extraction already performs —
  no second pass, and it works for `.rar`/`.7z` too, since hashing bytes doesn't
  care that an external `7z` does the extracting.
- [ ] **Hash before the archive is deleted** (§5 discards it after extraction).
  The hash is the cheap 32-char residue that survives that deletion — it cannot be
  recovered later, because zip output isn't reproducible from extracted files.
- [ ] **Bank now, cash in at resolution.** A hash alone never yields *identity* —
  GameBanana has no reverse-hash lookup. It's a file-level discriminator that pays
  off once identity is known: on resolution (§7.5) or in the bulk pass (§7.6),
  compare the banked hash against that mod's file list. A hit sets `file_id` +
  `version` at `exact` confidence and skips the "which file?" picker entirely.
- [ ] **Bonus, purely local:** match a new import's hash against already-banked
  ones → "you already have this as `<folder>`". No network, no GameBanana.

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

- [ ] **Delete `ModInfo.toJson()` / `ModInfo.fromJson()`**
  (`models/character_info.dart`). Dead everywhere, tests included — `ModInfo` is a
  runtime view, never a storage format. They're not merely inert: someone fixing
  the save path could reach for `ModInfo.toJson()` assuming it's the sidecar
  format, which would write absolute image paths plus per-install state
  (`is_active`, `is_favorite`, `keybinds`) into a file that must stay portable and
  intrinsic-only. *Do it while adding the origin fields to `ModInfo` (§3).*
- [ ] **Wire up `ModMetadata.isEmpty` instead of leaving it unused.** Replace the
  parallel `hasLegacyData` bool in `ModManagerService._loadOrMigrateMetadata()`
  with `!metadata.isEmpty`. Verified equivalent: in that constructor
  `description`/`source_url`/`tags` are always empty, so the two agree in every
  case, including the empty-string one. Behaviour-preserving, removes a redundant
  flag, and makes the existing test
  (`test/mod_metadata_service_test.dart:38`) cover a real code path instead of an
  unused method. *Do it while adding the backfill to that same function (§7.3).*

---

## Additional feature ideas (backlog — not yet committed)

### Acquisition
- [ ] **Paste-a-URL-to-install** — drop a GameBanana link → fetch + install + tag
  automatically.
- [ ] **Wishlist / bookmarks** for mods.
- [ ] **Trending / by-character feeds** in the browser.
- [ ] **NSFW / content filtering** setting.

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

- [x] **Is the archive hash only for in-app downloads?** No — hash **every**
  ingested archive, including drag-drop. GameBanana publishes a per-file md5, so a
  hand-supplied archive can be matched exactly, which is the only route to
  exactness for manual imports. A modified/re-zipped archive simply never matches
  and costs nothing: the field is null-or-exact. Bonus fast-path, not load-bearing.
  (See §7.8.)
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
