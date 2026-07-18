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

## Architecture

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

- `ApiService` (static facade) — the single entry point screens use. Lazily
  initializes and holds singletons of `ConfigService` and `ModManagerService`.
  Screens call `ApiService.toggleMod(...)`, `getMods()`, etc.
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
