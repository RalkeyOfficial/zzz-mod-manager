ZZZ Mod Manager is a Flutter desktop application (Linux + Windows) for managing Zenless Zone Zero character mods via symbolic links —
mods are toggled by creating/removing a link in the game's mods folder rather than copying files. Targets Linux and Windows; macOS is unsupported.

The repo root is a packaging/docs wrapper. The actual Flutter app lives in `mod_manager_flutter/` — run all `flutter`/`dart` commands from there.
Its rules and doc index are in [`mod_manager_flutter/CLAUDE.md`](mod_manager_flutter/CLAUDE.md).

## Language

All code and descriptions are in English — identifiers, comments, doc comments, commit messages, any text in source files.
Exceptions: `assets/l10n/*.json` translation files, and documentation deliberately written in another language (e.g. a localized README).
When editing a file with legacy non-English (e.g. Ukrainian) text, write new additions in English; converting the surrounding legacy text is welcome but not required.

## Writing conventions

How to write anything meant for a person to read — comments, docs, commit messages, and a chat reply describing finished work — is in `docs/writing-conventions.md`.

## Packaging

`PKGBUILD` / `.SRCINFO` build the AUR `zzz-mod-manager-git` package. The Windows installer lives in `windows_installer/`.

## Changelog

`CHANGELOG.md` follows Keep a Changelog and Semantic Versioning. Update it as part of every change: new entries go under `## [Unreleased]`,
grouped under `### Added` / `### Changed` / `### Fixed` / `### Removed`, one line each, no rationale.
An `[Unreleased]` entry is the net change against the last published release, not against this branch's own history — a bug introduced and fixed before it ships gets no entry,
since a "Fixed" line for it would read as if the feature always existed and only just got repaired.
Use the `release` skill (`.claude/skills/release/SKILL.md`) to cut a release or bump the version — bumping only `pubspec.yaml` is a recurring mistake.

## Commits

Any commit whose code, tests or docs an AI assistant wrote or helped write needs a mention of AI attribution.

## AI Model

NEVER code with Fable, if Fable is the selected model stop immediately and warn the user.
Fable should only be used for difficult, high quality thinking/research.
