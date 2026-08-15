# CLAUDE.md — the Flutter app

Architecture notes for the app itself. Loads when working on files under
`mod_manager_flutter/`. Repo-wide rules (language policy, dev workflow,
changelog, the non-negotiables) live in the [root `CLAUDE.md`](../CLAUDE.md).

> Six reference docs live in [`../docs/`](../docs/README.md), each owning one
> subject. Read the relevant one before changing anything that persists or anything
> that talks to GameBanana:
>
> | Doc | Owns |
> |---|---|
> | [`metadata-schema.md`](../docs/metadata-schema.md) | The sidecar **file format** — fields, save semantics, versioning, the migration hook |
> | [`origin-tracking.md`](../docs/origin-tracking.md) | **Where a mod came from** — the confidence model, the backfill, the resolve flow, the installed-mods index |
> | [`metadata-autofill.md`](../docs/metadata-autofill.md) | What an install **copies from a mod page** |
> | [`update-checks.md`](../docs/update-checks.md) | Whether a mod **has a newer version published** — the comparator, the verdicts, the bulk pass |
> | [`applying-updates.md`](../docs/applying-updates.md) | How an update **is written over an installed mod** — overwrite, patch detection, snapshots, rollback |
> | [`configuration.md`](../docs/configuration.md) | The app's **own settings** |
> | [`gamebanana-api.md`](../docs/gamebanana-api.md) | GameBanana's **remote protocol** — read it before writing any request; its surface is undocumented upstream, so guessing costs more than looking |

## Layered structure (`lib/`)

- **`main.dart`** — app entry. Initializes `window_manager` (custom hidden title
  bar — the app draws its own window chrome) and wraps the app in a Riverpod
  `ProviderScope`. `MainScreen` is a sidebar + `AnimatedSwitcher` over three tabs:
  Mods (0), Marketplace (1), Settings (2), selected via `tabIndexProvider`.
- **`services/`** — all business logic. See key services below.
- **`utils/state_providers.dart`** — **central Riverpod provider registry**. All
  app state (current tab, characters, mods, theme, locale, activation mode, etc.)
  is declared here. Add new global state as a provider here, not ad-hoc.
- **`utils/markdown_style.dart`** — the one definition of how rendered markdown
  looks (`buildMarkdownStyleSheet` plus the `MarkdownScale` tokens it derives
  from). Every description surface goes through `utils/markdown_description.dart`,
  which builds from it, so a second style sheet anywhere is a bug. Note the
  library's own quirks it works around: a `hr` builder is ignored (the widget
  overwrites it, so the rule is shaped entirely by `horizontalRuleDecoration`),
  `fitContent` must be `false` or every block shrink-wraps to its text, and a
  fenced block reuses the inline `code` style — including its chip background —
  unless a `syntaxHighlighter` cancels it. Vertical rhythm is also split in two
  on purpose: `blockSpacing` is the gap between *any* two blocks, while
  `pPadding` tops paragraphs up to a full blank line apart. `<br><br>` (how
  GameBanana writes a paragraph break) must look like the empty line a browser
  shows, and a run of blank lines keeps its height instead of collapsing —
  markdown would otherwise flatten `<br>`×6 to the same break as `<br>`×2.
- **`core/constants.dart`** — `AppConstants`, including `appVersion`, the single
  source for everything that *says* the version (UI badge, GameBanana User-Agent).

## Service layer and the platform abstraction

The most important architectural decision is the **platform abstraction**:

- `ApiService` (static facade) — the single entry point screens use **for local
  mod operations**. Lazily initializes and holds singletons of `ConfigService`
  and `ModManagerService`. Screens call `ApiService.toggleMod(...)`, `getMods()`,
  etc. Despite the name it makes **no network calls** — remote work belongs to
  the GameBanana layer below, which is reached through a Riverpod provider
  instead precisely because a static singleton can't take an injected transport.
- `ModManagerService` — core mod logic: scans the mods folder, creates/removes
  links, tracks active mods, imports mods, auto-detects characters, reads keybinds.
- `PlatformService` (abstract) — defines platform-specific operations: symlink
  creation/removal, sending F10 to the game, app-data paths, dependency checks.
  - `PlatformServiceFactory.getInstance()` returns the singleton implementation:
    `LinuxPlatformService` (real symlinks + xdotool/ydotool for F10) or
    `WindowsPlatformService` (junctions + win32 SendInput). **Never branch on
    `Platform.isX` for these operations in business logic — add a method to
    `PlatformService` and implement it in both subclasses.**
- `ConfigService` — persistence. **Dual storage**: writes through both
  `SharedPreferences` and a JSON `config.json` in the app-data dir. Adding a
  setting means the getter/setter, the `_saveToFile()` map **and** the
  `loadFromFile()` parse — see [`../docs/configuration.md`](../docs/configuration.md),
  which also covers the `configFile:` test seam.
- `InstalledModsIndex` (`services/installed_mods_index.dart`) — pure read model
  over an already-scanned `List<ModInfo>`, answering "do I already have this
  remote mod / file?" by `mod_id`, `file_id` and `archive_md5`. Reached through
  `installedModsIndexProvider`, which takes its own library snapshot rather than
  deriving from `charactersProvider`: the tabs are keyed children of an
  `AnimatedSwitcher` with no keep-alive, so `ModsScreen` is *disposed* while the
  marketplace is up and that list goes stale exactly when the badges are visible.
  The marketplace invalidates it on open and after each install. See
  `../docs/origin-tracking.md` §8 for what it can and cannot answer — notably that
  file-level knowledge is absent for any library that predates the origin block.
- `modOriginStatus()` (`services/origin_status.dart`) — pure `ModOrigin?` → the
  **one** thing a library card's status slot may render: amber "version
  unknown", a muted clock for a version recorded only as a guess, a muted dot
  for "untracked", or nothing. One rule covers all four — *the slot speaks
  whenever tracking is less than complete, and how loudly depends on how cheaply
  the user can act*. The mods toolbar's "needs attention" filter is built from
  the same function, and `modNeedsAttention()` is where the two deliberately
  come apart: a recorded guess is **shown but not counted**, or the bulk "assume
  current" action's count would never drop. See `../docs/origin-tracking.md` §4
  for that, for why `tracking: "off"` and `remote_missing` both silence the
  slot, and for why the weak state is marked rather than the strong one.
- `summarizeOrigin()` (`services/origin_summary.dart`) — pure `ModOrigin?` → the
  two lines the resolve dialog shows about what is **already** recorded. Split
  out because the risk is not the fold but the strength of the claim: the same
  two fields describe "you downloaded this" and "we guessed it from a link you
  pasted", and flattening them would tell the user their guesses are facts in
  the one dialog they open to find out which is which.
- `checkForUpdate()` (`services/update_check.dart`) — pure (origin block, mod
  page) → one verdict. Separate from any request because the hard part is not
  fetching but *how strongly the answer may be stated*: GameBanana publishes no
  orderable version, so `updateAvailable` is reserved for two provable cases (the
  installed file has been archived, or a newer file wears the same variant label)
  and everything else folds to `possiblyOutdated`. A guessed identity or a guessed
  file caps the verdict on its own. `services/bulk_update_check.dart` is the
  whole-library pass over `Mod/Multi`, with the fetch injected — including the
  batch-halving recovery `Mod/Multi` forces, since one unrecognised id fails the
  request for the other forty-nine. See `../docs/update-checks.md` for the
  measurements behind the comparator, and for why a false "possibly outdated" is
  the failure worth choosing.
  **The accuracy comes from two suppressions, not from tuning the guesses.**
  `ReleaseGroups` (from `Mod/<id>/Updates`'s `_aFileRowIds`) is the author's own
  statement that two files shipped together, so they are variants and never
  successors; and two still-offered files stamped with the same `_sVersion` are
  the same version. Both can only ever turn a flag *off*, neither can change the
  verdict once the installed file is archived, and absent data suppresses
  nothing. That direction is the whole safety argument — a rule that could turn
  a flag *on* would be inventing an update. They differ in reach: the
  same-version rule is confined to the still-offered branch, while release
  groups also filter which file gets *named* against an archived install, since
  a sibling shipped alongside it is the old build of the other variant and
  cannot be its replacement.
  The bulk pass fetches release feeds **only for mods that flagged**: one request
  per mod would undo what `Mod/Multi` buys, and a group can only help where there
  is a flag to remove.
- **`services/update_apply/` — writing a newer download over an installed mod.**
  Read [`../docs/applying-updates.md`](../docs/applying-updates.md) before touching
  any of it; the reasoning is longer than the code. `UpdateApplier` does the I/O and
  the ordering (deactivate for open handles → snapshot → copy → resolve leftovers →
  reactivate) and every decision is in a pure unit beside it: `update_layout.dart`
  replays the recorded `ingest` and **stops and asks** rather than guessing,
  `stale_ini.dart` decides which orphaned `.ini` describes the content just written,
  and `../patch_detection.dart` over `../ini_resources.dart` answers whether a
  download can stand on its own. The mechanism is **overwrite** — a mod folder often
  holds a second download, and replacing it destroys that; in the common ordering it
  destroys the mod itself. `ModActivationPort` is the seam, for the reason every
  dialog-facing seam here exists: `ApiService` builds a `ConfigService` against the
  developer's real `config.json`.
- **`services/backup/` — the snapshot that makes all of the above defensible.**
  `SnapshotService` writes `<appData>/backups/<mod>/<id>/{manifest.json, files/}`,
  outside `modsPath` because anything inside a mod folder is reachable through the
  active symlink and the loader would read the old `.ini` alongside the new one.
  **No snapshot, no write** — the update path accepts losses it cannot distinguish
  from intended changes, and every one of those is defensible only while the recourse
  exists. `retention.dart` is pure with an injected clock: the **age floor beats the
  count cap**, the budget is size-aware because the mod tail reaches 1.24 GB, and the
  newest snapshot of a mod is never pruned — an irreducible overage is *reported*
  rather than forced.
- `services/folder_contents.dart` — the one walk of a mod-shaped folder, producing
  the normalised path sets those pure units compare. `.zzz-mod-manager/` is excluded
  throughout: a sidecar image counted as a shipped resource would make a patch look
  complete.
- `services/origin_resolution.dart` — pure decision logic behind the resolve
  dialog: ranking a mod's published files against what is known locally (banked
  archive hash → folder name → newest file that already existed at install
  time), and the four transforms that produce the new origin block. Two rules
  it exists to enforce: a *suggestion* is never preselected (only a hash match
  and a single-file mod are), and confirming an identity raises it to `user`
  while nothing but a checksum match ever reaches `exact`.
- `planMetadataAutofill()` (`services/metadata_autofill.dart`) — pure
  (existing sidecar, what the mod page offers) → what may be written, and
  `services/gamebanana/remote_mod_metadata.dart` for the `GbMod` → domain half.
  One rule, and it is a safety rule rather than a courtesy: **fill absence, never
  displace.** A mod folder can arrive carrying somebody else's sidecar, whose
  user-facing fields this format deliberately keeps, so "already set" usually
  means "the author wrote this". Applied by
  `ModMetadataRepository.applyRemoteMetadata()`, which is also where the "fetch
  each image once even when the archive became five mods" and "re-read before
  writing" parts live. See `../docs/metadata-autofill.md` for the measurements
  behind the four decisions inside it (why the character comes from the
  *category*, why `Software Used` tags are dropped, why a shipped `Preview.png`
  keeps the cover slot, and why the gallery is capped at ten).
- `IniParserService` — parses mod `.ini` files into keybinds.
- `ArchiveService` — extracts imported `.zip` (in-process via `archive` package)
  and `.rar`/`.7z` (shells out to an external `7z`/`7za`/`7zr` binary, which must
  be installed on the system).
- `F10ReloadService` / `f10_reload.py` — auto-reload support (sends F10 to the
  running game so it picks up mod changes).

### The GameBanana layer (`services/gamebanana/`, `services/http/`)

Read-only client for GameBanana's `apiv13` — browse, search, mod detail,
category tree. Read [`../docs/gamebanana-api.md`](../docs/gamebanana-api.md)
before touching it; the remote surface is undocumented upstream, so guessing
costs more than looking.

- `GameBananaClient` — the only public entry point, reached via
  `gameBananaClientProvider` in `state_providers.dart` (never construct one in a
  widget: the response cache is meant to be shared). **JSON GETs only** — file
  downloads need streamed bodies, `Range` resume and socket backpressure, and
  belong to a separate downloader with its own client.
- `HttpTransport` (`services/http/`) — **the single seam** between our network
  code and the outside world for JSON, with `PackageHttpTransport` over
  `package:http` as the real implementation. Every GameBanana test injects a fake
  through it and runs with no network; if a test here ever needs connectivity, the
  seam is in the wrong place. Note `http.Client` exposes no
  `badCertificateCallback`, so the old inline download code's blanket SSL bypass
  cannot be inherited here.
  - `ImageFetcher` (`services/http/image_fetcher.dart`) is a **second, tiny**
    seam beside it rather than a `bytes` method on it: `HttpTransport.body` is a
    decoded `String` precisely because everything above it is JSON, and widening
    that interface would put a binary body on the one type every GameBanana test
    fakes. It is not the file downloader either — that exists for
    hundred-megabyte archives and earns its ranges, resume and backpressure,
    where a preview image is ~115–310 KB and wants a plain GET with a timeout.
    `fetch` returns **null** on any failure, because every caller's answer is
    "skip this image": a gallery one short beats an install that reports failure
    after the mod is already in place.
- `GameBananaEndpoints` — pure `Uri` builders, kept separate so request shapes
  can be asserted with no transport. Browse is built on `Mod/Index` (not
  `Subfeed`, which supports neither filters nor sort).
- `GameBananaResponseCache` — in-memory, keyed by full `Uri`, TTL taken from the
  server's own `cache-control: max-age` when one is sent — **apiv13 sends none**, so
  in practice the 10-minute default is ours rather than the server's, inherited from
  what apiv11 used to advertise. Injected clock. **A
  user-initiated refresh has to be able to bypass it**: re-issuing the same request
  otherwise answers from memory and hands back the byte-identical page for up to ten
  minutes — a refresh control that cannot refresh. Keep the bypass scoped to that
  explicit action; making every read skip the cache defeats the point of having one.
- `GameBananaErrorMapper` — status + body → typed `GbException`. Backoff is
  **reactive** (429/503 only); a 400 is never retried, since it means our url is
  wrong.
- `models/gamebanana/` — `Gb`-prefixed **wire DTOs**, one type per file. They
  are not domain models; `ModInfo`/`ModMetadata` are ours. `GbMod` is
  deliberately lenient because Index, ProfilePage and Multi return three
  different subsets of the same object: `idRow` is the only required field, and
  **null means "not in this response", never "zero"** (notably `files == null`
  is "not requested" while `[]` is "none published").
- `utils/gamebanana_url.dart` — pure `source_url` → mod-id parsing, kept outside
  the client because the offline metadata backfill runs it during a normal scan
  with no network. A `/dl/<id>` link is a *file* id and correctly yields null.
- `content_filter.dart` — pure (visibility hint, user setting) → show / blur /
  omit. The API filters nothing itself, so **this is the entire NSFW filter**.
  Default is `blur` (reveal on click), which is what the site does and the only
  value that is wrong in neither direction: `show` would un-blur adult content on
  a corrupt setting, `hide` would silently empty the grid. `ContentFilterMode.parse`
  degrades anything unrecognised to `blur` for that reason. Applied to
  already-fetched records, so toggling it re-filters without a request — and the
  pager therefore counts *remote* records, not visible ones.
- `file_selection.dart` — pure default-download-selection rule. Preselects a file
  **only when the mod publishes exactly one**; anything else returns no default
  with a reason the UI shows. That is not laziness: `../docs/gamebanana-api.md` §6
  measured that `_sVersion` is routinely null on *every* file with the version
  written into `_sDescription` (the variant field), and that a mod's current files
  are often a main file plus patchers plus demos. There is no orderable version and
  no reliable "main file" marker, so any multi-file default would be a guess — and
  guesses may inform, never drive.

### The marketplace screens (`screens/components/marketplace/`)

A **native** GameBanana browser, identical on both platforms, replacing an
embedded webview on Windows and an open-your-real-browser-plus-Downloads-watcher
fallback on Linux. Two screens only — results grid and mod detail; everything else
GameBanana hosts is reached via "open in browser".

- State lives in `utils/marketplace_providers.dart`, not the central
  `state_providers.dart` registry: it is one screen's browsing session rather than
  app-wide state. The content filter *is* app-wide and stays in the registry,
  hydrated from config in `ApiService.initialize`.
- Browse and search are **separate modes** because they are separate endpoints with
  different capabilities — search takes text but supports neither category filter
  nor sort, so the sort control is disabled rather than silently ignored.
- **This is where remote identity reaches the origin block.** The webview could only
  intercept a CDN url, so every origin block it wrote had both confidences at
  `unknown`; a native download knows mod id, file id, version and variant label
  before the first byte and writes them at `exact`. See
  `../docs/origin-tracking.md` §2 for every route that writes a block and the tier
  each one may claim.
- **It is also where a mod stops arriving blank.** After the import,
  `_installArchive` hands the profile to `applyRemoteMetadata`, which fills the
  description, gallery and tags the install would otherwise leave empty.
  - **The character is the exception: it is passed *into* the import.** The mod
    page's category is the author's own filing, while folder-name detection is a
    substring guess, and they disagree exactly where it hurts — a Zhao skin
    published as `Zhao Nicole` detects as Nicole, since the longest matching term
    wins. It cannot be corrected afterwards, because the autofill's one rule is
    *fill absence* and detection has already filled the slot — so
    `importMods`/`importCombinedMod` take `knownCharacters`/`knownCharacter` and
    skip detection for those folders. An unassigned value falls back to
    detection, which is what keeps a mod filed under `Other/Misc` working. The
    autofill still assigns the character on the paths nobody told, notably the
    resolve dialog. See `../docs/metadata-autofill.md`.
- **The two views are an `IndexedStack`, not a conditional.** Swapping them meant
  disposing the browse view, and with it the scroll offset of a grid the user may
  have scrolled a long way down — so opening a mod and pressing back always landed
  them back at the top. Keeping it mounted keeps the *real* offset rather than a
  remembered number, which is the only version that survives the grid being a
  different height than when it was left (a content-filter change, a badge
  appearing). The detail slot is deliberately the one that stays empty while
  unused: `GbDetailView` holds per-mod state (gallery index, reveal, archived
  files) that must reset between mods, and it is keyed by mod id for the same
  reason. Note `IndexedStack` hides a child from painting, hit-testing and
  semantics but **not** from focus traversal, hence the `ExcludeFocus` around the
  grid — without it, tabbing on the detail view walks into an off-screen search box.
- **`ref.invalidate` cannot be called from `initState`, unlike the rest of `ref`.**
  `MarketplaceScreen` re-snapshots the library when it opens, and that call lives in
  `didChangeDependencies` behind a once-per-`State` flag. `WidgetRef.invalidate`
  resolves its container with `listen: true`, which registers an inherited-widget
  dependency — forbidden during `initState`, and it throws for every mount, taking
  the whole tab down. `read`, `refresh` and `listenManual` use `listen: false`
  specifically so they *can* be called there; `invalidate` does not, and nothing in
  its signature says so. `didChangeDependencies` still runs before the first build,
  so nothing observes a stale snapshot. Covered by `test/marketplace_screen_test.dart`.
- **It is also the first place that *reads* it.** Cards and the detail view badge
  mods already in the library, file rows mark the one you installed, and both
  ingest paths run `confirmArchiveNotDuplicate` (`dialogs/duplicate_archive_dialog.dart`)
  before installing an archive whose hash is already banked. The badge is keyed on
  the mod and the row marker on the file, because those are different questions with
  very different availability — see `../docs/origin-tracking.md` §8.
- **`GbModCard` has one status slot.** `_statusSlot` returns at most one badge,
  never a stack — the same rule the library card follows, since a card that can
  show three things at once shows none of them. **"Update available" belongs in
  that method** as a second branch when it lands, so precedence between the two
  states is one decision in one place rather than a second badge elsewhere on the
  card. It renders a **filled** pill top-right, opposite `obsolete` and above the
  reveal overlay (owning a mod is not adult content, so it must read before the
  blur is lifted).
  - The alternative was built and lost a side-by-side comparison: a full-width
    strip along the bottom of the cover. Recorded so it isn't re-proposed as an
    obvious improvement. The two put the emphasis in different places — the strip
    was noticeable through *shape* and paid by covering a slice of artwork; the
    pill is noticeable through *fill*, which is the whole reason `_badge` has a
    `filled` mode, and occludes almost nothing.
  - **"You already have this" is `primary` everywhere** — the card badge, the
    detail view's notice, the file-row chips — so it doesn't change hue between
    screens. The consequence for M3 is worth knowing in advance: "update available"
    has to differ by **hue at similar weight** rather than by being the louder of
    the two, and `tertiary` is already spoken for by the `obsolete` badge.
- `_sText` is HTML while every description this app renders is markdown, so it goes
  through `utils/html_to_markdown.dart` — shared with the description editors'
  paste-as-markdown so the two can't drift.
- **The grid sets `mainAxisExtent`, not `childAspectRatio`, and `GbModCard`'s cover
  is an `Expanded`.** These two go together and are load-bearing. An aspect ratio
  makes the tile *shorter as it gets narrower* while the text block under the cover
  needs a constant height, so the card overflowed its bottom below ~179px wide —
  and tile width ranges over roughly 150–300px with window and sidebar state. A
  fixed tile height decouples them: the text always gets its room and the cover
  absorbs the remainder, which also survives the OS text scale growing the title.
  Covered by `test/gb_mod_card_test.dart` across the whole width range.

Widget tests here need `test/support/localized_harness.dart` rather than a plain
`MaterialApp`. `AppLocalizations.delegate` loads its JSON from the asset bundle
asynchronously, and **`pumpAndSettle` does not wait for real async I/O** — it returns
once no frames are scheduled, which is long before a bundle read finishes. The
result is a `Localizations` that renders an empty box forever with *no exception*, so
every `find` returns nothing and every "did it overflow?" assertion passes
vacuously. The harness preloads via `runAsync` and injects a `SynchronousFuture`;
call `expectBuilt(...)` after pumping so that failure mode can never be silent again.

### The library's origin surfaces (`components/mod_status_slot.dart`, `dialogs/resolve_origin_dialog.dart`)

What the *library* side does with the origin block. The rules about states and
about what each answer may write are in `../docs/origin-tracking.md` §4–§5; what
follows is only what is specific to these widgets.

- **A rescan only reaches the grid if `modGroupsChanged()` says so**
  (`utils/mod_group_diff.dart`). A scan runs after every toggle, rename, edit and
  import, so `ModsScreen` guards `charactersProvider` behind a field-by-field
  comparison to avoid rebuilding the whole grid each time. **That list is
  hand-written, and anything `ModInfo` gains that any surface renders has to be
  added to it.** It has already failed once exactly this way: `origin` was
  missing from it, so resolving a mod wrote the sidecar correctly, the rescan
  re-read it correctly, the guard said "unchanged", and the amber mark stayed on
  the card until the user switched tabs. Nothing threw. `origin` is now compared
  through `ModOrigin`'s value equality — which is why that model has `==` at all
  — so new *origin* fields are covered automatically; nothing else on `ModInfo`
  is.
- **`ModStatusSlot` sits bottom-left of the cover**, the one corner
  `ModCardWidget` had free (top-left is details, top-right the enable switch,
  bottom-right the source link and favourite). It keeps a constant footprint
  across states so resolving a mod doesn't reflow the artwork under it, and it
  uses a literal amber rather than a scheme colour — the card paints its palette
  over *artwork*, so a themed colour would be the only thing on it that moved.
  Passing no `onResolveOrigin` hides it, which is what the drag-feedback copy of
  the card wants.
  **The two muted states are told apart by shape, not colour** — a dot for
  untracked, a clock for a version recorded only as a guess. Two muted colours
  at 9–15px are indistinguishable, and stay so for anyone colourblind.
- **The toolbar toggle carries a count and hides itself at zero.** The answer is
  usually either nothing or most of the library, and both are worth knowing
  before pressing rather than after landing on an empty grid.
- **The update-check button is one control doing two jobs**: a bare icon runs
  the check, a count filters the grid to what it found. A seventh toolbar
  control was rejected for it — the rule that keeps the overload legible is
  *the control does the only useful thing available*, and the count is the
  visible signal for which mode it is in. The cost is that re-checking moves to
  **check again** in the second row, beside the bulk "assume current" button and
  for the same reason. Two scopes meet there deliberately: the *check* covers
  the whole library (its badges are drawn on every tab, so scoping it to one
  would leave the rest looking checked-and-clean), while the *filter* covers the
  current view (that is all it can narrow). Its results are session state
  (`modUpdateChecksProvider`) and never persisted — a verdict restored from disk
  asserts something about a mod page nobody has looked at since.
- **`modSlotStatus()` is where the card's one slot is decided**, folding the
  origin block together with the session verdict, so precedence between "you have
  not sorted this mod out" and "this mod has an update" is one decision in one
  place. The short-circuit that silences the slot is narrowly `tracking: "off"`
  and `remote_missing`, **not** every route to `none`: a mod recorded at `exact`
  also folds to `none` and is precisely the mod best placed to have a *confirmed*
  update.
- **The bulk "assume current" button appears only once that filter is on**
  (`services/bulk_assume_current.dart`, `dialogs/assume_current_dialog.dart`).
  The filter is what turns the state from a dot on a card into a list, and this
  action rewrites every mod on that list — so requiring the enumeration first
  means the user has seen what they are about to act on. Its plan comes from
  `visibleModsProvider`, the list the grid renders, **not** from the wider list
  the `!` toggle counts: the two come apart as soon as a second filter is
  active, and a control that rewrites more mods than it displays is exactly what
  this placement exists to prevent. See `../docs/origin-tracking.md` §6 for the
  four rules it enforces, notably that eligibility is re-checked against the
  sidecar as freshly read — so a batch can't downgrade a mod resolved while it
  ran, and a decline is reported as a decline rather than as a read-only folder.
- **The update dialog's primary action now writes to disk**, through
  `dialogs/apply_update_flow.dart`. The orchestration is at the widget layer because
  it is a conversation — download, show what is about to happen, write only on
  consent — while every decision it rests on is in `services/update_apply/`.
  `dialogs/update_confirm_dialog.dart` is the last screen before a live install is
  touched, and everything on it is something that cannot be said afterwards: the
  snapshot, the accepted keybind loss, a patch-shaped download, and the one question
  it asks. It offers **no way to proceed** against an unreconcilable layout — an
  "install anyway" there would invite the user to guess where the app refused to.
  `dialogs/mod_backups_dialog.dart` is the rollback, reachable from the context menu
  only for mods that have a snapshot (`modBackupsProvider`, one readdir for the whole
  library).
- **`components/dialog_section.dart` is where the update flow's dialogs get their
  shape and their type sizes.** They were written as loose `Text` widgets with
  hardcoded 10–12px sizes, and both complaints that produced were the same
  complaint: nothing marked where one idea ended and the next began, and none of it
  was readable. Sizes now come from the theme — `bodyLarge` (16) for anything meant
  to be read, `bodyMedium` (14) for the line explaining it, `titleMedium` for a
  heading — and a group of facts always arrives under a heading saying what the group
  is for. `DialogNotice(emphasis: true)` is the one "read this" state and uses the
  same literal amber as the card's status slot, so it means the same thing wherever
  it appears; **at most one per view**, or it stops being emphasis.
- **The update dialog's release notes are an accordion.** The first version dropped
  them into the middle of the dialog with no boundary and no way to close them, so an
  author's three paragraphs pushed the verdict off the top of a scroll view nobody had
  asked to grow. The header doubles as the section divider and as the thing that
  *fetches* on the badge path, so one gesture does both.
- **`dialogs/download_with_progress.dart` is shared with the marketplace.** Only the
  *download*, deliberately: the marketplace imports an archive as a new mod folder
  while an update overwrites an existing one, and folding those together is what
  would produce a shared "install" that quietly does the wrong one.
- **In the resolve dialog the content filter degrades `hide` to `blur`, never to
  `omit`.** Dropping a flagged mod from a search the user is running to identify
  a mod they *already own* would make that mod permanently unresolvable, with no
  hint as to why.
- **Both lists in the dialog are height-bounded and scroll inside themselves**,
  so the two escape hatches underneath stay one click away. Not hypothetical: a
  captured profile publishes six current files beside eight archived ones, and
  every one is a row. The file list's bound came down from 280 to 230 when the
  identity card grew its "currently tracked" lines — anything new in this dialog
  is paid for by the picker, which scrolls, never by the hatches, which have
  nowhere to go. A test taps them at the minimum window size for that reason.
- **The dialog states what is already recorded before offering to change it**,
  and preselects the recorded file rather than leaving the answer invisible.
  Every selected row carries a chip naming what put it there, so "on record" and
  "our best guess" cannot be confused — the ambiguity worth removing is *what
  selected this*, not *that something is selected*. `_hasSomethingToSave` asks
  the write path (`OriginResolution.pickFile`) whether the result would differ
  rather than re-deriving the rule, because the interesting cases are not
  obvious: re-picking an `inferred` row looks like a no-op but is the
  confirmation that tier waits for.
- **`ResolveOriginGateway` is the local-side seam.** Calling `ApiService`
  straight from a dialog is this codebase's convention (delete, rename and edit
  all do) and the default keeps it — but `ApiService` lazily builds a
  `ConfigService` that writes the developer's **real** `<appData>/config.json`,
  so a widget test that merely mounted this dialog would clobber their library
  paths and favourites.

### Notifications (`utils/notifications.dart`, `components/notification_overlay.dart`)

Everything the app tells the user in passing. **Never call `ScaffoldMessenger`
here** — `context.notify.success(…)` / `.info` / `.warning` / `.error` is the one
way to raise a message, and `grep showSnackBar lib/` returning nothing is the
check that it stayed that way.

- **Why it is not Material's snackbar.** Two reasons, and the second is the one
  that cannot be styled away. A `ScaffoldMessenger` shows **one bar at a time and
  queues the rest**, so an install with three things to say showed them in
  sequence, each replacing the last across the bottom of the window — the
  headline was on screen only until the queue advanced. And the bar lives
  *inside* the `Scaffold`, so a modal dialog's barrier covers it, which is where
  a large share of these messages are raised from (rename, delete, keybinds, the
  whole update flow).
- **The host is mounted in `MaterialApp.builder`, above the `Navigator`.** That
  is what puts a notification over a dialog. It is also why the close button
  carries a **semantic label rather than a `Tooltip`**: a tooltip needs an
  `Overlay` ancestor, and this layer is a *sibling* of the navigator, so one
  throws "No Overlay widget found" the first time anything is raised.
- **The queue holds no timers; the card owns the clock.** The auto-dismiss timer
  has to stop while the stack is being read — a message that disappears
  mid-sentence is the complaint this replaced — and only the widget knows where
  the pointer is. `NotificationCenter` therefore stays a synchronous list, and
  its tests assert about a list rather than about elapsed time.
- **Hovering holds the whole stack, not the card under the pointer.** "Is the
  pointer here" is one fact, owned by `NotificationOverlay` and passed down as
  `paused`, with a single `MouseRegion` around the column — which also covers the
  gaps between cards, so travelling from one notification to the next never
  counts as leaving. Per-card pausing was the first version and is wrong twice
  over: the fourth message expires while the pointer rests on the first, and the
  stack reflows out from under the pointer as it goes. A notification raised
  *while* the pointer is already there arrives held, and leaving **restarts the
  full duration** rather than resuming the remainder.
- **A notification says one thing, and it is the thing the user was waiting
  for.** The install confirmation is the case that taught this: it used to carry
  the auto-tags and a list of the metadata fields copied off the mod page under
  a headline, so the one fact being waited for — the mod arrived — was the
  hardest line on it to find, and all the rest was the app narrating its own
  bookkeeping about work whose result is on the card a second later. What a
  caller genuinely cannot drop is what the user must *act* on (no `.ini`, a
  patch-shaped download, a sidecar that could not be written), and that goes
  beside the success as its own **warning** rather than as body text under it —
  a broken install must not be reported in the same colour as a clean one.
  Title-plus-body is for the rare message with two real levels, not for padding
  one out.
- **Severity is the only thing a call site decides.** Colour, icon and duration
  are derived from it in one place. They used to be chosen per call site from
  whatever was nearest — `Colors.red` here, `colorScheme.error` there,
  `Colors.orange` for a warning in one file and nothing in the next — so the same
  kind of event looked different depending on which screen raised it.
- **A notification can wait for a condition instead of a clock.** `pinned(…)`
  raises one with no duration and hands back a `NotificationHandle`; `update()`
  rewrites it in place (same id, so the same card, same position, no re-entry
  animation) and `dismiss()` removes it. That is how the drag-a-mod-onto-a-
  character flow reports itself: one notification held open across the write and
  the rescan, rather than a one-second "saving…" bar immediately replaced by a
  "saved" one that claimed the work was over before it was. A pinned
  notification still has its close button — nothing this app puts on screen may
  be un-dismissable.
- **The handle is safe to hold past the end.** The user can close any
  notification at any moment, so `update`/`dismiss` on one that is gone do
  nothing rather than throw.
- Re-raising an identical (severity, title, message) **moves it down and
  restarts its clock** instead of stacking a duplicate; the stack is capped at
  `kMaxVisibleNotifications` and drops the *oldest*, since a burst is usually one
  action reporting several things and the last line concludes it.
- `context.notify` resolves through `ProviderScope.containerOf(listen: false)`,
  so it is legal in `initState`, in a dialog builder, and in a plain function
  that was handed a context. **Capture it in a local before an `await`** and the
  report survives the widget being disposed — which is why several `mounted`
  checks that existed only to protect a `ScaffoldMessenger.of(context)` lookup
  are gone.
- Widget tests get the host from `test/support/localized_harness.dart`, which
  mounts it exactly as `main.dart` does. A test that needs to read state back
  must pass its `ProviderContainer` as `pumpLocalized(container:)` rather than
  nesting an `UncontrolledProviderScope` **below** `home` — a nested container is
  a second, invisible queue, and the assertion would run against an empty
  screen.

### The download layer (`services/download/`)

Fetches mod archives into `<appData>/downloads`, resumably. Separate from the
JSON client above because it needs streamed bodies, byte ranges and socket
backpressure — `../docs/gamebanana-api.md` §8 has the measurements that shape it.

- `DownloadService` — reached via `downloadServiceProvider`. Returns a
  `DownloadHandle` (progress stream, `done` future, `cancel()`). **Every
  *decision* lives here**; only the pump below does not.
- **The socket→disk pump runs on a spawned isolate, and that is the difference
  between 3 MB/s and 17 MB/s.** On the root isolate the event loop *is* the
  Flutter engine's UI task runner, and every socket read event costs ~2.3 ms
  there. Chunks arrive as ~8158-byte TLS records — not something we choose, and
  not something a slow consumer makes larger — so `8158 B ÷ 2.7 ms ≈ 3.0 MB/s`
  is a hard ceiling regardless of the network. Our own callback is ~1% of wall
  clock, so there is nothing to optimise inside it. Ruled out by
  measurement and not worth re-investigating: the backpressure pauses, in-stream
  md5, debug-vs-release, the filesystem, the `User-Agent`, frame rendering and
  the UI layer. Windows is expected to behave the same way — same engine
  architecture — but that is **inferred, not measured**.
  - **Quote the two numbers separately, because they measure different things.**
    Release build, real CDN, four arms interleaved with the order rotated, six
    rounds on the 27 MB test file (mod `700727`, file `1777422`):

    | arm | body only | ms/chunk |
    |---|---|---|
    | `DownloadService`, **root isolate** | 2.84–2.97 MB/s | **2.62–2.74** |
    | bare read-and-write loop, spawned | 12.5–16.2 MB/s | 0.48–0.62 |
    | the same plus md5 and the flush brake | 8.9–16.6 MB/s | 0.47–0.87 |
    | `DownloadService`, **spawned** | 8.5–14.2 MB/s | 0.55–0.91 |

    Three things to read off it. The root-isolate row is *pinned* — six samples
    inside 0.13 MB/s while every spawned row swings by a factor of two — and that
    consistency, not the absolute figure, is what identifies a fixed scheduling
    cost rather than a slow network. The three spawned rows **overlap
    completely**, so neither the in-stream md5 nor the backpressure brake nor the
    rest of the service costs anything measurable; a single bad sample from any
    of them is the node, and pooling fewer than ~5 rounds will mislead you.
    And ~5× is the honest figure for the **transfer**.
  - **End to end a user sees less than that, and the difference is not ours.**
    Every arm above also paid a rock-steady **0.73–0.98 s of setup** — DNS plus
    three TLS handshakes across GameBanana's two redirect hops, before a byte
    moves. On the 27 MB median-ish mod that turns ~14.5 MB/s of transfer into
    ~10 MB/s of wall clock, i.e. ~3.9× rather than ~5×; on the 1.24 GB tail file
    it rounds to nothing. Every figure in the table above is **body only**, timed
    from the first byte — comparing one against a wall-clock figure is comparing
    two different quantities, which is how this section first got written wrong.
  - `DownloadPump` / `PumpSession` is the seam. Two phase, because the service
    must judge status and headers with `ResumePolicy` **before** a byte is
    written. `IsolateDownloadPump` is production (one short-lived worker per
    connection, which builds its own `IoDownloadTransport` so there is no second
    HTTP config to drift); `InlineDownloadPump` is what every test gets through
    the `transport:` argument, and the fallback if a spawn ever fails.
  - **The worker owns the file writes, and reports a counter.** Forwarding chunks
    over the port would pay the very ~2.3 ms cost being escaped, so it would be
    an elaborate way to change nothing — while still looking correct, because the
    file and the md5 would come out right. Progress is posted every 200 ms.
  - Consequently the stall timer resets only on an **increase**: the worker's
    timer fires whether or not anything moved. It is also stopped on `bodyEnded`,
    *before* the final flush — flushing a gigabyte takes real time, and a
    download that already finished must not be able to time out.
  - **Considered and rejected: batching into ~1 MB blocks in the worker** while
    keeping the file I/O on the main isolate. It would capture most of the win
    (~1240 events × 2.3 ms ≈ 2.9 s on a 1.24 GB file) for far less surgery. It
    loses on one point, and it is decisive: it replaces `sub.pause(sink.flush())`
    — a proven mechanism whose backpressure reaches the socket — with a
    hand-rolled credit window between two isolates, whose failure mode is the
    invisible one described below.
- `DownloadTransport` / `IoDownloadTransport` — the network seam under the pump,
  and the app's only remaining `dart:io HttpClient`. Two settings are
  load-bearing: `autoUncompress = false` (or `Content-Length` and every range
  offset lies), and the deliberate **absence** of `badCertificateCallback`.
  Because the worker constructs its own, the isolate path cannot be pointed at a
  self-signed server — so its TLS behaviour is deliberately untested rather than
  tested behind a hole in that rule.
- `resume_policy.dart` — pure, and where the subtle bugs live. In particular a
  `200` answering a ranged request means *restart*: appending it would
  concatenate two copies into a corrupt archive that still looks plausible.
- **The timeout is a stall timeout, never a total duration.** A legitimate
  transfer over a degraded CDN node runs ~25 minutes and must be allowed to. The
  progress UI is built for the same reality: a rate and an ETA rather than just a
  bar, cancellable and resumable throughout.
- **Backpressure is load-bearing, and its failure mode is invisible on fast
  storage.** A reader that pipes the response body to disk without awaiting the
  write and without pausing the subscription buffers whatever the disk can't keep
  up with. Measured against local disk at 20 MB/s it made no difference — peak RSS
  identical at 217 MB either way — but against a deliberately slow consumer the two
  diverged (+57 MB vs +15 MB above baseline). With files reaching 1.24 GB and CDN
  nodes that serve at 0.08 MB/s, that is a real exposure on slow or contended
  storage. It now lives inside `pump_body.dart`'s `pumpResponseToFile`, which
  **both** pumps call — but a shared function is only half the guard. Teardown,
  error fidelity and report cadence differ between them and sit outside it, so
  `test/download/pump_contract_test.dart` runs one body against both against a
  loopback `HttpServer`. That is the mechanism; the shared function is the hope.
  (It has already earned its keep: an `IOSink` refuses a second `flush()` while
  the backpressure one is still in flight, and only the inline arm hit it.)
- `services/archive_hash.dart` — md5 for archive fingerprinting. Free during a
  download (hashed in-stream), one extra read on manual import. A **matching
  key, never an integrity claim** — never render a match as "verified".

## How mods work (the core flow)

Two configured paths drive everything: **`modsPath`** (where mod folders live,
the library) and **`saveModsPath`** (the game's mods folder where links go).
Activating a mod = create a link `saveModsPath/<mod>` → `modsPath/<mod>`;
deactivating = remove the link. `ModManagerService._cleanupInvalidLinks()` runs on
scan to prune links whose source no longer exists. **Single vs Multi mode**
(`activationModeProvider`): in Single mode, activating a skin auto-deactivates
the character's other active skins (see `ApiService.toggleModForCharacter`).

Character auto-tagging: mod folders are matched to characters via a hardcoded
`characterAliases` map duplicated in `_detectCharacterFromName` and
`_findCharacterInText` in `mod_manager_service.dart` — **update both copies** when
adding characters. The canonical character roster also lives in
`utils/zzz_characters.dart`.

## Localization

Custom JSON-based i18n (not ARB/gen-l10n). Strings live in
`assets/l10n/en.json` and `uk.json` as nested objects. Look up with
`context.loc.t('navigation.mods')` (dotted key path). `localeProvider` holds the
active locale; supported locales are English and Ukrainian.

> Note: much of the codebase still has legacy Ukrainian comments and hardcoded
> strings. Per the Language rule in the root `CLAUDE.md`, write all new/edited
> code and comments in English regardless of the surrounding language (a bulk
> translation of the existing legacy text is not being done right now).

## App-data locations

`PathHelper.getAppDataPath()`: Linux `~/.local/share/zzz-mod-manager`,
Windows `%APPDATA%\zzz-mod-manager`. Holds `config.json` and `mod_images/`.
