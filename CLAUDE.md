# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZZZ Mod Manager is a Flutter desktop application (Linux + Windows) for managing
Zenless Zone Zero character mods via **symbolic links** — mods are toggled by
creating/removing a link in the game's mods folder rather than copying files.
Targets Linux (primary) and Windows; macOS is explicitly unsupported.

> The repo root is a packaging/docs wrapper. **The actual Flutter app lives in
> `mod_manager_flutter/`** — run all `flutter`/`dart` commands from there.

## Language

**All code and descriptions must be in English** — it's the universal language.
This covers identifiers, comments, doc comments, commit messages, and any text
in source files. The **only** exceptions are:

- **l10n/i18n translation files** (`assets/l10n/*.json`), which hold the
  translated user-facing strings by design;
- **documentation deliberately written in another language** (e.g. a localized
  README).

When editing a file that has legacy non-English (e.g. Ukrainian) comments or
strings, write your additions in English; converting the surrounding legacy text
to English as you touch it is welcome but not required.

## Commands

All commands run from `mod_manager_flutter/`:

```bash
flutter pub get                          # Install dependencies
flutter run -d linux                     # Run in dev (or -d windows)
flutter build linux --release            # Release build → build/linux/x64/release/bundle/
flutter build windows --release          # Windows release build
flutter analyze                          # Lint (flutter_lints, see analysis_options.yaml)
flutter test                             # Run all tests
flutter test test/widget_test.dart       # Run a single test file
```

Packaging: `PKGBUILD` / `.SRCINFO` build the AUR `zzz-mod-manager-git` package.
Windows installer lives in `windows_installer/`.

## Development workflow

**Do not rebuild for every change.** Launch once with `flutter run -d linux` from
`mod_manager_flutter/`, then push edits into the running app via hot reload. Use
`flutter build` only for packaging/release, never for dev iteration.

In an active `flutter run` session (same terminal):

- **`r` — hot reload** (keeps app state). Sufficient for widget/UI edits, including
  the localization strings and dialog layouts.
- **`R` — hot restart** (resets state). Needed for changes to `main()`, Riverpod
  providers, model classes (`ModInfo`, `KeybindInfo`), and `static`/top-level fields.
- **Full relaunch** for: new/changed assets in `pubspec.yaml` (e.g. l10n JSON, images),
  added packages, or native/plugin changes (`window_manager`, etc.).

Codebase-specific gotchas:

- Parsed keybinds (`IniParserService`) are produced during a folder scan and cached in
  provider state. After editing the parser, hot **restart** (`R`) and re-trigger a scan —
  `r` alone won't re-parse.
- Mod metadata/scan logic lives in services held as singletons via `ApiService`; changes
  there generally need `R`.

`flutter doctor`: only the **Flutter** and **Linux toolchain** sections matter for this
project. The **Android toolchain** and **Chrome/web** ✗ marks are expected and safe to
ignore — this app targets Linux/Windows desktop only, not Android or web.

System dependencies (Linux dev): the C++ toolchain (`clang`, `cmake`, `ninja`,
`pkg-config`) + `gtk3` for building; `7z`/`7za`/`7zr` (p7zip) for archive imports; and
`xdotool` (X11) or `ydotool` (Wayland) for the F10 auto-reload feature.

Clipboard HTML (for paste-as-markdown) is read natively: on Linux via the GTK
clipboard in the runner (`linux/runner/my_application.cc`, channel
`mod_manager/clipboard`), on Windows via `pasteboard`. No external CLI tool.

## Changelog (keep up to date)

`CHANGELOG.md` (repo root) follows [Keep a Changelog](https://keepachangelog.com)
and [Semantic Versioning](https://semver.org). Update it as part of every change:

- New entries go under the top `## [Unreleased]` section, grouped under
  `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- Versions are newest-first (top → down). Headers carry no `v` prefix:
  `## [Unreleased]`, `## [2.0.1] - YYYY-MM-DD`, `## [1.0.0] - 2025-10-01`.
- Keep each entry to **one line where possible, two at most** (the optional
  second line being e.g. the bug it fixed). Describe behaviour/intent, not
  implementation detail.
- The version number only goes up **after** the latest version is released on
  GitHub. On release: rename `## [Unreleased]` to `## [x.y.z] - <date>`, bump
  `pubspec.yaml` `version:` to match, tag the commit, then add a fresh empty
  `## [Unreleased]` at the top. Patch = fixes, minor = features, major =
  breaking.

### Bumping the version (all the spots)

The `x.y.z` version string lives in **several** files — updating only
`pubspec.yaml` is a recurring mistake. On every bump, update **all** of these:

- `mod_manager_flutter/pubspec.yaml` — `version: x.y.z+N`
- `mod_manager_flutter/lib/core/constants.dart` — `AppConstants.appVersion`.
  Single source for everything that *says* the version: the UI badge in
  `main.dart` and the `User-Agent` sent to GameBanana both read it, so this is
  the only Dart file to touch.
- `windows_installer/setup.iss` — `#define MyAppVersion "x.y.z"`
- `BUILD_WINDOWS_GUIDE.md` — the example `-Version`, output filenames
  (`…-Portable-x.y.z.zip`, `…-Setup-x.y.z.exe`), and `git tag vx.y.z`
- `CHANGELOG.md` — per the release step above

**Leave alone** (auto-generated or historical): `PKGBUILD` / `.SRCINFO` (git
`pkgver` like `r6.967f969`), `pubspec.lock`, `linux/flutter/ephemeral/…`, and
any older `## [x.y.z]` changelog entries.

Verify with:
`grep -rn "<old-version>" . | grep -v build/ | grep -v .git/` — every remaining
hit should be an intentional one (historical changelog / dependency / generated).

## Architecture

> Developer documentation lives in **`docs/`** — start at
> [`docs/README.md`](docs/README.md). In particular,
> [`docs/metadata-schema.md`](docs/metadata-schema.md) is the authoritative
> reference for the on-disk formats (per-mod `metadata.json` sidecar,
> `config.json`, schema versioning and the migration hook). Read it before
> changing anything that persists.
> [`docs/gamebanana-api.md`](docs/gamebanana-api.md) is the equivalent reference for
> the **remote** side — which of GameBanana's two APIs to use and why, browsing /
> filtering / sorting, what every field means, NSFW handling, downloads, and the
> category tree. Read it before writing any request; its surface is undocumented
> upstream, so guessing costs more than looking. New developer docs go in `docs/`,
> not the repo root.

### Layered structure (`lib/`)

- **`main.dart`** — app entry. Initializes `window_manager` (custom hidden title
  bar — the app draws its own window chrome) and wraps the app in a Riverpod
  `ProviderScope`. `MainScreen` is a sidebar + `AnimatedSwitcher` over three tabs:
  Mods (0), Marketplace (1), Settings (2), selected via `tabIndexProvider`.
- **`screens/`** — one file per tab plus `welcome_screen.dart` (first-run setup)
  and `screens/components/` (reusable widgets like mod cards, character list).
- **`services/`** — all business logic. See key services below.
- **`utils/state_providers.dart`** — **central Riverpod provider registry**. All
  app state (current tab, characters, mods, theme, locale, activation mode, etc.)
  is declared here. Add new global state as a provider here, not ad-hoc.
- **`models/`** — `character_info.dart` (`CharacterInfo`, `ModInfo`),
  `keybind_info.dart` (`CharacterKeybinds`, `KeybindInfo`).
- **`core/constants.dart`** — `AppConstants`: all UI dimensions, colors,
  animation/debounce durations, window sizes, and image filename candidates.

### Service layer and the platform abstraction

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

#### The GameBanana layer (`services/gamebanana/`, `services/http/`)

Read-only client for GameBanana's `apiv11` — browse, search, mod detail,
category tree. Read [`docs/gamebanana-api.md`](docs/gamebanana-api.md) before
touching it; the remote surface is undocumented upstream, so guessing costs more
than looking.

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

#### The download layer (`services/download/`)

Fetches mod archives into `<appData>/downloads`, resumably. Separate from the
JSON client above because it needs streamed bodies, byte ranges and socket
backpressure — `docs/gamebanana-api.md` §8 has the measurements that shape it.

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

### How mods work (the core flow)

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

### Localization

Custom JSON-based i18n (not ARB/gen-l10n). Strings live in
`assets/l10n/en.json` and `uk.json` as nested objects. Look up with
`context.loc.t('navigation.mods')` (dotted key path). `localeProvider` holds the
active locale; supported locales are English and Ukrainian.

> Note: much of the codebase still has legacy Ukrainian comments and hardcoded
> strings. Per the [Language](#language) rule, write all new/edited code and
> comments in English regardless of the surrounding language (a bulk translation
> of the existing legacy text is not being done right now).

### App-data locations

`PathHelper.getAppDataPath()`: Linux `~/.local/share/zzz-mod-manager`,
Windows `%APPDATA%\zzz-mod-manager`. Holds `config.json` and `mod_images/`.

### Marketplace

`marketplace_screen.dart` embeds GameBanana (`gamebanana.com/games/19567`) via
`flutter_inappwebview` for in-app mod browsing/downloading. On Windows the
WebView platform is explicitly set in `main()`.
