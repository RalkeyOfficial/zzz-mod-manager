# App architecture — the layers of `lib/`

**Scope:** how `mod_manager_flutter/lib/` is put together — the layer boundaries,
the service layer, the platform abstraction, and our GameBanana client.

Not in scope: GameBanana's own wire protocol
([`gamebanana-api.md`](gamebanana-api.md)), or any of the subjects with their own
doc. This file is the map; the rules that must never be missed are in the
[`CLAUDE.md`](../mod_manager_flutter/CLAUDE.md) files.

---

## 1. Layers

- **`main.dart`** — app entry. Initializes `window_manager` (custom hidden title
  bar — the app draws its own window chrome) and wraps the app in a Riverpod
  `ProviderScope`. `MainScreen` is a sidebar + `AnimatedSwitcher` over four tabs:
  Mods (0), Marketplace (1), Storage (2), Settings (3), selected via
  `tabIndexProvider`.
  **The tabs are keyed children with no keep-alive**, so the inactive tab's
  `State` is *disposed* — which is why nothing a tab owns may be the only copy of
  something another surface needs. The library is the case that decided the rule:
  it belongs to `libraryProvider` (§3), not to the Mods tab.
- **`services/`** — all business logic.
- **`utils/state_providers.dart`** — the **central Riverpod provider registry**.
  All app state (current tab, characters, mods, theme, locale, activation mode)
  is declared here. Add new global state here, not ad-hoc.
- **`core/constants.dart`** — `AppConstants`, including `appVersion`, the single
  source for everything that *says* the version (UI badge, GameBanana User-Agent).

## 2. Markdown rendering

`utils/markdown_style.dart` is the one definition of how rendered markdown looks
(`buildMarkdownStyleSheet` plus the `MarkdownScale` tokens it derives from). Every
description surface goes through `utils/markdown_description.dart`, which builds
from it — **a second style sheet anywhere is a bug.**

Library quirks it works around, all of which look like mistakes:

- a `hr` builder is **ignored** (the widget overwrites it), so the rule is shaped
  entirely by `horizontalRuleDecoration`;
- `fitContent` must be `false` or every block shrink-wraps to its text;
- a fenced block reuses the inline `code` style — including its chip background —
  unless a `syntaxHighlighter` cancels it.

Vertical rhythm is split in two on purpose: `blockSpacing` is the gap between *any*
two blocks, while `pPadding` tops paragraphs up to a full blank line apart.
`<br><br>` (how GameBanana writes a paragraph break) must look like the empty line
a browser shows, and a run of blank lines keeps its height instead of collapsing —
markdown would otherwise flatten `<br>`×6 to the same break as `<br>`×2.

## 3. The service layer

- **`ApiService`** (static facade) — the single entry point screens use **for local
  mod operations**. Lazily initializes and holds singletons of `ConfigService` and
  `ModManagerService`. Despite the name it makes **no network calls** — remote work
  belongs to the GameBanana layer, which is reached through a Riverpod provider
  instead precisely because a static singleton can't take an injected transport.
- **`ModManagerService`** — core mod logic: scans the mods folder, creates/removes
  links, tracks active mods, imports mods, auto-detects characters, reads keybinds.
- **`ConfigService`** — persistence. **Dual storage**: writes through both
  `SharedPreferences` and a JSON `config.json`. See
  [`configuration.md`](configuration.md).
- **`IniParserService`** — parses mod `.ini` files into keybinds.
- **`ArchiveService`** — extracts `.zip` in-process (`archive` package) and
  `.rar`/`.7z` by shelling out to `7z`/`7za`/`7zr`, which must be installed.
Nothing here reloads mods in the running game. That is deliberate and
[`mod-reload.md`](mod-reload.md) is why.

### The platform abstraction

The most important architectural decision. `PlatformService` (abstract) defines
symlink creation/removal, app-data paths, the system description for the log
header, free space on a volume, and opening folders and URLs. `PlatformServiceFactory.getInstance()`
returns `LinuxPlatformService` (real symlinks) or `WindowsPlatformService`
(junctions).

**Never branch on `Platform.isX` for these in business logic** — add a method here
and implement it in both subclasses.

### Pure units beside the services

Each is a pure function so its rule can be tested with no I/O, and each has a doc
that owns its reasoning:

| Unit | Answers | Doc |
|---|---|---|
| `installed_mods_index.dart` | do I already have this remote mod/file? | [origin-tracking](origin-tracking.md) §9 |
| `origin_status.dart` | what may the card's status slot render? | [origin-tracking](origin-tracking.md) §4 |
| `origin_summary.dart` | what is already recorded, and how strongly? | [origin-tracking](origin-tracking.md) |
| `origin_resolution.dart` | which published file is probably yours? | [origin-tracking](origin-tracking.md) |
| `bulk_resolution.dart` | the same, over a whole library | [origin-tracking](origin-tracking.md) §7 |
| `update_check.dart` | is there a newer version, and how sure are we? | [update-checks](update-checks.md) |
| `bulk_update_check.dart` | the same, over `Mod/Multi` | [update-checks](update-checks.md) |
| `metadata_autofill.dart` | what may an install copy from a mod page? | [metadata-autofill](metadata-autofill.md) |
| `update_apply/` + `backup/` | how is an update written, and undone? | [applying-updates](applying-updates.md) |
| `folder_contents.dart` | the one walk of a mod-shaped folder | [applying-updates](applying-updates.md) |

### The library is a provider, and the root of everything about it

`libraryProvider` (an `AsyncNotifier` in `state_providers.dart`) owns the scan and
holds its result: every mod, once each, flat. **Everything else about the library
is derived from it** — `modsProvider` is the plain-list view for readers that
cannot await, `installedModsIndexProvider` builds `InstalledModsIndex` over the
same read, and the Mods tab's `charactersProvider` groups are built from it for
the sidebar (localized names, which is why they are written by the screen rather
than derived here).

Three rules follow, and each of them is a bug that has happened:

- **A screen may not own the library.** The Mods tab is disposed while the user is
  anywhere else (§1), so a library kept in its `State` is unrefreshable exactly
  when installs are happening. The patch destination prompt asked such a list
  which folders existed and was told: every one except the mod installed a minute
  earlier.
- **Whoever changes the folder invalidates the library**, and never just something
  derived from it. `ref.invalidate(installedModsIndexProvider)` alone rebuilds the
  index from the same cached scan, which answers for the library as it was.
- **A question asked mid-install reads the disk**, not the provider — the archive
  is being unpacked, so nothing has invalidated anything yet. That is the rule
  `test/modal_freshness_test.dart` pins, and the two readers of it are the patch
  destination prompt and the sibling preview.

A scan is **4 ms warm, 12 ms cold** over a mirror of a real 23-mod / 748-file
library, and building the index over it is **under 1 ms**, so a refresh is not
something to design around.

**An unchanged rescan publishes nothing.** `rescan()` compares what it read with
what it holds (`listEquals` over `ModInfo`'s value equality) and keeps the old
list when they match, which is what stops the grid rebuilding after every toggle,
rename and import. `library-screen.md` §1 is what that guard costs when a field
escapes it.

Two more rules keep that promise true at launch, where the provider is read from
two places within a frame of each other — the bulk update check's plan reads it
from above the tabs, then the Mods tab mounts and asks for a scan of its own:

- **One walk at a time.** A `rescan()` that finds a scan already running takes
  *that* answer rather than starting a second walk of the same folder, and waits
  until it is published — the caller's next act is to read the library, and a
  rescan that returned early would hand the grid an empty list to draw.
- **A scan never overwrites an edit made while it was walking.** A rename or a
  delete publishes what it already knows; a scan that started before it is the
  older answer however late it lands, so it defers to what is there.

`folder_contents.dart` excludes `.zzz-mod-manager/` throughout: a sidecar image
counted as a shipped resource would make a patch look complete.

## 4. The GameBanana client (`services/gamebanana/`, `services/http/`)

Read-only client for `apiv13` — browse, search, mod detail, category tree. Read
[`gamebanana-api.md`](gamebanana-api.md) before writing any request.

- **`GameBananaClient`** — the only public entry point, reached via
  `gameBananaClientProvider` (never construct one in a widget: the response cache
  is meant to be shared). **JSON GETs only** — file downloads belong to
  [`downloads.md`](downloads.md).

  **One method per endpoint, and no method that isn't an endpoint.** The whole
  surface is `browseMods`, `searchMods`, `topSubs`, `modProfile`, `modsMulti`,
  `modUpdates`, `categories` — plus `close`. That is the rule that keeps upkeep
  proportional when the API changes, and two consequences of it are easy to
  misread as gaps:

  - **There is no file-list call.** GameBanana returns a mod's files *inside* its
    profile (`_aFiles` / `_aAlternateFileSources` → `GbMod.files` and
    `archivedFiles`), so `modProfile` already carries them. A separate `files()`
    would be a second request for data we are handed.
  - **There is no by-url call.** A url becomes an id in
    `utils/gamebanana_url.dart` — pure, and therefore reachable by the offline
    origin backfill, which is why it lives there rather than here — and callers
    pass the id. A `modProfileByUrl` convenience wrapper existed and was removed
    once every call site had gone to the util directly; it is the shape this rule
    exists to prevent, since it made the client's surface look like it had two
    ways in when it has one.
- **`HttpTransport`** (`services/http/`) — **the single seam** between our network
  code and the outside world for JSON, with `PackageHttpTransport` as the real
  implementation. Every GameBanana test injects a fake through it and runs with no
  network; if a test here ever needs connectivity, the seam is in the wrong place.
  Note `http.Client` exposes no `badCertificateCallback`, so the old inline
  download code's blanket SSL bypass cannot be inherited here.
  - **`ImageFetcher`** is a **second, tiny** seam beside it rather than a `bytes`
    method on it: `HttpTransport.body` is a decoded `String` precisely because
    everything above it is JSON, and widening that interface would put a binary
    body on the one type every GameBanana test fakes. It is not the file
    downloader either — a preview image is ~115–310 KB and wants a plain GET with a
    timeout. `fetch` returns **null** on any failure, because every caller's answer
    is "skip this image": a gallery one short beats an install that reports failure
    after the mod is already in place.
- **`GameBananaEndpoints`** — pure `Uri` builders, kept separate so request shapes
  can be asserted with no transport. Browse is built on `Mod/Index` (not `Subfeed`,
  which supports neither filters nor sort). **One builder per method above and no
  others**, so the two files stay in step and neither accumulates a url for a
  request nobody makes. `Mod/<id>/DownloadPage` is the one the API offers and this
  app does not use, and the reason is not batching: it returns just the file lists
  and the trashed/withheld flags, so it is missing four of the six fields the
  update comparator reads — and a one-id `Mod/Multi` is both complete and *smaller*
  (measured: 7.7 KB against 8.1 KB). Its captured response and parse test are kept
  (`test/gamebanana/gb_parse_test.dart`) — evidence about an undocumented API costs
  nothing, an unused `Uri` builder does.
- **`GameBananaResponseCache`** — in-memory, keyed by full `Uri`, TTL from the
  server's `cache-control: max-age` when one is sent. **apiv13 sends none**, so the
  10-minute default is ours. Injected clock. **A user-initiated refresh has to be
  able to bypass it** — re-issuing the same request otherwise hands back the
  byte-identical page for ten minutes, i.e. a refresh control that cannot refresh.
  Keep the bypass scoped to that explicit action.
- **`GameBananaErrorMapper`** — status + body → typed `GbException`. Backoff is
  **reactive** (429/503 only); a 400 is never retried, since it means our url is
  wrong.
- **`models/gamebanana/`** — `Gb`-prefixed **wire DTOs**, one type per file. Not
  domain models; `ModInfo`/`ModMetadata` are ours. `GbMod` is deliberately lenient
  because Index, ProfilePage and Multi return three different subsets of the same
  object: `idRow` is the only required field, and **null means "not in this
  response", never "zero"** (`files == null` is "not requested", `[]` is "none
  published").
- **`utils/gamebanana_url.dart`** — pure `source_url` → mod-id parsing, kept
  outside the client because the offline metadata backfill runs it during a normal
  scan with no network. A `/dl/<id>` link is a *file* id and correctly yields null.
- **`content_filter.dart`** — pure (visibility hint, user setting) → show / blur /
  omit. The API filters nothing itself, so **this is the entire NSFW filter**.
  Default is `blur`, the only value wrong in neither direction: `show` would
  un-blur adult content on a corrupt setting, `hide` would silently empty the grid.
  `ContentFilterMode.parse` degrades anything unrecognised to `blur` for that
  reason. Applied to already-fetched records, so toggling re-filters without a
  request — and the pager therefore counts *remote* records, not visible ones.
- **`file_selection.dart`** — preselects a download **only when the mod publishes
  exactly one file**; anything else returns no default with a reason the UI shows.
  Not laziness: [`gamebanana-api.md`](gamebanana-api.md) §6 measured that
  `_sVersion` is routinely null on *every* file with the version written into
  `_sDescription`, and that a mod's current files are often a main file plus
  patchers plus demos. There is no orderable version and no reliable "main file"
  marker, so any multi-file default would be a guess — and guesses may inform,
  never drive.
