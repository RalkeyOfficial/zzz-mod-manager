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
  code and the outside world, with `PackageHttpTransport` over `package:http` as
  the real implementation. Every GameBanana test injects a fake through it and
  runs with no network; if a test here ever needs connectivity, the seam is in
  the wrong place. Note `http.Client` exposes no `badCertificateCallback`, so
  the old inline download code's blanket SSL bypass cannot be inherited here.
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
  `../docs/metadata-schema.md` §5.
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
