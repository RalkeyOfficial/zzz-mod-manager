# BUGS & TODO

Planning + backlog for the mod-downloading / marketplace / update overhaul.
This is a **pre-planning document** — it captures *what* we want to build and the
decisions made so far, not *how* to implement it. Items are grouped by area.

---

## Locked decisions

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
  download → extract → auto-tag. Single fixed flow, no queue/resume yet.
- [ ] **§3 (write side)** — record the origin block at install time (source,
  remote mod id, file id, version string + label, date, hash). *Written now,
  read in M2.* Critical: installs before this ship with no origin block and can
  never show update info.
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

### M3 — Updating

Goal: the payoff feature. Needs §2 + §3 + §5 from M1/M2.

- [ ] **§4** — manual update check (per-mod + bulk), version-string+label rule,
  update badges, changelog display, backup/rollback, preserve user edits.

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
  driven by the per-mod origin data (see §3).
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
- [ ] **File hash** — detect real changes vs same-version re-upload; enables dedup
  / "already have this".
- [ ] Locally-imported mods (drag/drop) simply have **no origin block** and show
  no update info — manual import keeps working unchanged.
- [ ] Auto-populate metadata (description, images, tags, character) from the API
  on marketplace install instead of leaving it blank.

## 4. Mod updating

- [ ] **Manual update check** — per-mod and bulk ("check all").
- [ ] Update rule: prioritise version string + version label; fall back to upload
  date / hash. Best-effort suggestion, clearly labelled as such.
- [ ] **Update badges** on mod cards in the library.
- [ ] **Opt-in auto-update** (global and/or per-mod), with notification.
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
  both platforms.
- [ ] Revisit the current SSL-validation bypass on Win/Linux.

## 6. Config / persistence

- [ ] New `config.json` + `SharedPreferences` keys for: download directory,
  auto-install-after-download, update-check behaviour (manual/auto), auto-update
  opt-in. (Remember the dual-storage pattern: getter/setter **and** the
  `_saveToFile` / `loadFromFile` map.)

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
