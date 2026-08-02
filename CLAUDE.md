# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZZZ Mod Manager is a Flutter desktop application (Linux + Windows) for managing
Zenless Zone Zero character mods via **symbolic links** — mods are toggled by
creating/removing a link in the game's mods folder rather than copying files.
Targets Linux (primary) and Windows; macOS is explicitly unsupported.

> The repo root is a packaging/docs wrapper. **The actual Flutter app lives in
> `mod_manager_flutter/`** — run all `flutter`/`dart` commands from there.
> Its architecture is documented in
> [`mod_manager_flutter/CLAUDE.md`](mod_manager_flutter/CLAUDE.md), which loads
> automatically when working on files under that directory.

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

All `flutter`/`dart` commands run from `mod_manager_flutter/`, where the standard
invocations (`flutter pub get`, `run -d linux`, `build linux --release`,
`analyze`, `test`) work as usual. Lint rules come from `analysis_options.yaml`
(flutter_lints).

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
and [Semantic Versioning](https://semver.org). **Update it as part of every
change**: new entries go under the top `## [Unreleased]` section, grouped under
`### Added` / `### Changed` / `### Fixed` / `### Removed`, one line each (two at
most), describing behaviour and intent rather than implementation detail.

For cutting a release or bumping the version, use the **`release` skill**
(`.claude/skills/release/SKILL.md`) — it holds the release steps and every file
that carries the version string. Bumping only `pubspec.yaml` is a recurring
mistake.

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

The app's internal architecture — layered structure of `lib/`, the service layer
and platform abstraction, the GameBanana and download layers, how mods work,
localization, app-data paths — lives in
[`mod_manager_flutter/CLAUDE.md`](mod_manager_flutter/CLAUDE.md).

### Non-negotiables

Repeated here so they are never missed, even before opening the app source:

- **Never branch on `Platform.isX`** for platform-specific behaviour in business
  logic — add a method to `PlatformService` and implement it in both
  `LinuxPlatformService` and `WindowsPlatformService`.
- The `characterAliases` map is **duplicated** in `_detectCharacterFromName` and
  `_findCharacterInText` (`mod_manager_service.dart`) — **update both copies**
  when adding characters.
- An archive md5 match is a **matching key, never an integrity claim** — never
  render a match as "verified".
- Download timeouts are **stall timeouts, never a total duration** — a legitimate
  transfer over a degraded CDN node runs ~25 minutes and must be allowed to.
