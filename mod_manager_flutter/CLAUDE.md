# CLAUDE.md — the Flutter app

Architecture notes for the app itself. Loads when working on files under
`mod_manager_flutter/`. Repo-wide rules (language policy, dev workflow,
changelog, the non-negotiables) live in the [root `CLAUDE.md`](../CLAUDE.md).

> [`../docs/metadata-schema.md`](../docs/metadata-schema.md) is the authoritative
> reference for the on-disk formats (per-mod `metadata.json` sidecar,
> `config.json`, schema versioning and the migration hook). Read it before
> changing anything that persists.
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
  `SharedPreferences` and a JSON `config.json` in the app-data dir. When changing
  a setting, update both the getter and the `_saveToFile()` map.
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
