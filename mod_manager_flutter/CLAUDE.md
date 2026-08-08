# CLAUDE.md — the Flutter app

Architecture notes for the app itself. Loads when working on files under
`mod_manager_flutter/`. Repo-wide rules (language policy, dev workflow,
changelog, the non-negotiables) live in the [root `CLAUDE.md`](../CLAUDE.md).

> [`../docs/metadata-schema.md`](../docs/metadata-schema.md) is the authoritative
> reference for data about a **mod** (the per-mod `metadata.json` sidecar, its
> `origin` block, schema versioning and the migration hook), and
> [`../docs/configuration.md`](../docs/configuration.md) for the app's **own
> settings** (`config.json`, the dual-storage pattern, adding a setting). Read the
> relevant one before changing anything that persists.
> [`../docs/gamebanana-api.md`](../docs/gamebanana-api.md) is the equivalent
> reference for the **remote** side. Read it before writing any request; its
> surface is undocumented upstream, so guessing costs more than looking.

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
  `../docs/metadata-schema.md` §3 for what it can and cannot answer — notably that
  file-level knowledge is absent for any library that predates the origin block.
- `modOriginStatus()` (`services/origin_status.dart`) — pure `ModOrigin?` → the
  **one** thing a library card's status slot may render: amber "version
  unknown", a muted clock for a version recorded only as a guess, a muted dot
  for "untracked", or nothing. One rule covers all four — *the slot speaks
  whenever tracking is less than complete, and how loudly depends on how cheaply
  the user can act*. The mods toolbar's "needs attention" filter is built from
  the same function, and `modNeedsAttention()` is where the two deliberately
  come apart: a recorded guess is **shown but not counted**, or the bulk "assume
  current" action's count would never drop. See `../docs/metadata-schema.md` §5
  for that, for why `tracking: "off"` and `remote_missing` both silence the
  slot, and for why the weak state is marked rather than the strong one.
- `summarizeOrigin()` (`services/origin_summary.dart`) — pure `ModOrigin?` → the
  two lines the resolve dialog shows about what is **already** recorded. Split
  out because the risk is not the fold but the strength of the claim: the same
  two fields describe "you downloaded this" and "we guessed it from a link you
  pasted", and flattening them would tell the user their guesses are facts in
  the one dialog they open to find out which is which.
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
  writing" parts live. See `../docs/metadata-schema.md` §2 for the measurements
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

Read-only client for GameBanana's `apiv11` — browse, search, mod detail,
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
  server's own `cache-control: max-age` (default 10 min). Injected clock.
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
  `../docs/metadata-schema.md` §2 (the origin block) — this pointed at §5 while
  that section was "Planned changes"; §5 is now the resolve flow.
- **It is also where a mod stops arriving blank.** After the import,
  `_installArchive` hands the profile to `applyRemoteMetadata`, which fills the
  description, gallery, tags and character the install would otherwise leave
  empty. A character recovered from the mod's *category* is reported through the
  same auto-tag line as one recovered from its folder name, because it is the
  same fact from a better source.
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
  very different availability — see `../docs/metadata-schema.md` §3.
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
about what each answer may write are in `../docs/metadata-schema.md` §5; what
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
- **The bulk "assume current" button appears only once that filter is on**
  (`services/bulk_assume_current.dart`, `dialogs/assume_current_dialog.dart`).
  The filter is what turns the state from a dot on a card into a list, and this
  action rewrites every mod on that list — so requiring the enumeration first
  means the user has seen what they are about to act on. Its plan comes from
  `visibleModsProvider`, the list the grid renders, **not** from the wider list
  the `!` toggle counts: the two come apart as soon as a second filter is
  active, and a control that rewrites more mods than it displays is exactly what
  this placement exists to prevent. See `../docs/metadata-schema.md` §5 for the
  four rules it enforces, notably that eligibility is re-checked against the
  sidecar as freshly read — so a batch can't downgrade a mod resolved while it
  ran, and a decline is reported as a decline rather than as a read-only folder.
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

### The download layer (`services/download/`)

Fetches mod archives into `<appData>/downloads`, resumably. Separate from the
JSON client above because it needs streamed bodies, byte ranges and socket
backpressure — `../docs/gamebanana-api.md` §8 has the measurements that shape it.

- `DownloadService` — reached via `downloadServiceProvider`. Returns a
  `DownloadHandle` (progress stream, `done` future, `cancel()`).
- `DownloadTransport` / `IoDownloadTransport` — the seam, and the app's only
  remaining `dart:io HttpClient`. Two settings are load-bearing:
  `autoUncompress = false` (or `Content-Length` and every range offset lies), and
  the deliberate **absence** of `badCertificateCallback`.
- `resume_policy.dart` — pure, and where the subtle bugs live. In particular a
  `200` answering a ranged request means *restart*: appending it would
  concatenate two copies into a corrupt archive that still looks plausible.
- **The timeout is a stall timeout, never a total duration.** A legitimate
  transfer over a degraded CDN node runs ~25 minutes and must be allowed to.
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
