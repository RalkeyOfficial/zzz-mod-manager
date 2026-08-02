---
name: release
description: Cut a release or bump the ZZZ Mod Manager version. Use when changing the x.y.z version string, renaming the CHANGELOG [Unreleased] section, tagging a release, or verifying that every file holding the version was updated. Lists all version-string locations and the CHANGELOG conventions.
---

# Releasing / bumping the version

## CHANGELOG conventions

`CHANGELOG.md` (repo root) follows [Keep a Changelog](https://keepachangelog.com)
and [Semantic Versioning](https://semver.org).

- New entries go under the top `## [Unreleased]` section, grouped under
  `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- Versions are newest-first (top → down). Headers carry no `v` prefix:
  `## [Unreleased]`, `## [2.0.1] - YYYY-MM-DD`, `## [1.0.0] - 2025-10-01`.
- Keep each entry to **one line where possible, two at most** (the optional
  second line being e.g. the bug it fixed). Describe behaviour/intent, not
  implementation detail.

## Release steps

The version number only goes up **after** the latest version is released on
GitHub. On release:

1. Rename `## [Unreleased]` to `## [x.y.z] - <date>`.
2. Bump the version string in **all** the spots below.
3. Tag the commit.
4. Add a fresh empty `## [Unreleased]` at the top.

Patch = fixes, minor = features, major = breaking.

## Every spot that holds the version

Updating only `pubspec.yaml` is a recurring mistake. On every bump, update
**all** of these:

- `mod_manager_flutter/pubspec.yaml` — `version: x.y.z+N`
- `mod_manager_flutter/lib/core/constants.dart` — `AppConstants.appVersion`.
  Single source for everything that *says* the version: the UI badge in
  `main.dart` and the `User-Agent` sent to GameBanana both read it, so this is
  the only Dart file to touch.
- `windows_installer/setup.iss` — `#define MyAppVersion "x.y.z"`
- `BUILD_WINDOWS_GUIDE.md` — the example `-Version`, output filenames
  (`…-Portable-x.y.z.zip`, `…-Setup-x.y.z.exe`), and `git tag vx.y.z`
- `CHANGELOG.md` — per the release steps above

**Leave alone** (auto-generated or historical): `PKGBUILD` / `.SRCINFO` (git
`pkgver` like `r6.967f969`), `pubspec.lock`, `linux/flutter/ephemeral/…`, and
any older `## [x.y.z]` changelog entries.

## Verify

```bash
grep -rn "<old-version>" . | grep -v build/ | grep -v .git/
```

Every remaining hit should be an intentional one (historical changelog /
dependency / generated).
