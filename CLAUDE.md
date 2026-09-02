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

## Write the present tense. Git holds the history.

**No prose anywhere describes how the code got this way.** Not code comments,
not `docs/`, not `BUGS & TODO.md`, not a checked-off item. This applies to every
file except `CHANGELOG.md`, whose whole subject is what changed.

Delete on sight:

- what the code **used to do** — "this used to…", "the old flow…", "previously…",
  "N corrections to what this doc assumed";
- **who or what found something** — "a review found", "reported after the first
  use", "found by pressing it", "verified against the old code";
- **the order things happened in** — "then", "afterwards", "a fifth correction".

Keep the durable half, which is usually already in the same paragraph: the rule,
the constraint, the measurement, the rejected alternative and *why it loses*.
"`<appData>/downloads` is shared, so delete the file and never the directory" is
worth a comment forever. "This used to delete the parent recursively" is a commit
message.

Two things that look like history and are not, so keep them:

- **What is verified and what is not** ("not yet run on Windows") — that is
  current state, and the reader needs it.
- **A hazard that is still live** ("two transfers of one file share a `.part`") —
  the fact is present tense even if a bug is what taught it.

## Report finished work as user experience, never as code

**When you tell me what shipped, describe what I can see, click and test.** Not
the functions added or the files touched — I cannot test a function name. It is
the `CHANGELOG.md` rule applied to the terminal. An identifier appears only where
I would type or read it myself: a menu item, a file on disk, a command.

In this order: **what is different when I use the app** (the screen, the wording,
what it now does); **what did *not* change** where I'd expect it to, since an
omission I find by trying it reads as a bug; **what to test**, as numbered steps
in the running app, including the ones that must produce nothing; then test
counts and analyzer numbers, in a line — evidence, not the report.

State a limit as the behaviour I will meet, never as the reason in the code: "a
patch you dragged in has no mod page, so only the mod it went into is checked for
updates", not "that layer carries a null `mod_id`". The reasoning is not dropped, it
moves — decisions and rejected alternatives still go in `docs/` in full.

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
- **Full relaunch** for: new/changed assets in `pubspec.yaml` (l10n JSON, images),
  added packages, native/plugin changes, and anything under `linux/` (compiled in).

Codebase-specific gotchas:

- Parsed keybinds (`IniParserService`) are produced during a folder scan and cached in
  provider state, so after editing the parser hot **restart** (`R`) and re-scan.
- Mod metadata/scan logic lives in services held as singletons via `ApiService`; changes
  there generally need `R`.

`flutter doctor`: only **Flutter** and **Linux toolchain** matter here; the
**Android toolchain** and **Chrome/web** ✗ marks are expected.

System dependencies (Linux dev): the C++ toolchain (`clang`, `cmake`, `ninja`,
`pkg-config`) + `gtk3` for building; and `7z`/`7za`/`7zr` (Arch: `7zip`, **not**
the older `p7zip` port) for archive imports. Nothing else — the window and input
helpers went with F10 auto-reload ([`docs/mod-reload.md`](docs/mod-reload.md)).

Clipboard HTML (paste-as-markdown) is read natively: Linux via the GTK clipboard
in the runner (`linux/runner/my_application.cc`, channel `mod_manager/clipboard`),
Windows via `pasteboard`. No external CLI tool.

## Changelog (keep up to date)

`CHANGELOG.md` (repo root) follows [Keep a Changelog](https://keepachangelog.com)
and [Semantic Versioning](https://semver.org). **Update it as part of every
change**: new entries go under the top `## [Unreleased]` section, grouped under
`### Added` / `### Changed` / `### Fixed` / `### Removed`. **One line each** —
"the app does x", no rationale. Entries may nest one level to group one feature,
and a sub-bullet is another such line rather than an explanation of its parent.

For cutting a release or bumping the version, use the **`release` skill**
(`.claude/skills/release/SKILL.md`) — it holds the release steps and every file
that carries the version string. Bumping only `pubspec.yaml` is a recurring
mistake.

## Architecture

> Developer documentation lives in **`docs/`** — start at
> [`docs/README.md`](docs/README.md), which indexes it. Read the relevant one
> before changing anything it covers:
>
> | Doc | Owns |
> |---|---|
> | [`app-architecture.md`](docs/app-architecture.md) | The **layers of `lib/`** — service layer, platform abstraction, our GameBanana client |
> | [`gamebanana-api.md`](docs/gamebanana-api.md) | GameBanana's **remote protocol** — which of the two APIs and why, browsing/filtering/sorting, every field, NSFW, downloads, the category tree. Read it before writing any request: the surface is undocumented upstream, so guessing costs more than looking |
> | [`downloads.md`](docs/downloads.md) | **Fetching archives** — the isolate pump, resume, backpressure, the stall timeout, the background queue |
> | [`marketplace.md`](docs/marketplace.md) | The **native browser screens** |
> | [`library-screen.md`](docs/library-screen.md) | The **Mods tab** — card, status slot, toolbar, bulk actions |
> | [`notifications.md`](docs/notifications.md) | **What the app tells the user** — whether to speak, the two levels, the card |
> | [`metadata-schema.md`](docs/metadata-schema.md) | The **file format** of a mod's `metadata.json` sidecar |
> | [`migrations.md`](docs/migrations.md) | **Reading data an older version wrote** — every migration and tolerance, across all three stores. There is no `migrations/` folder and that doc says why |
> | [`origin-tracking.md`](docs/origin-tracking.md) | **Where a mod came from** — the confidence model, the backfill, the resolve flow |
> | [`metadata-autofill.md`](docs/metadata-autofill.md) | What an install **copies from a mod page** |
> | [`update-checks.md`](docs/update-checks.md) | Whether a mod **has a newer version** |
> | [`applying-updates.md`](docs/applying-updates.md) | How an update **is written over an installed mod** |
> | [`patch-destinations.md`](docs/patch-destinations.md) | **Which mod folder a patch goes into** — the signals, what each measures, why the list is ordered and never narrowed |
> | [`configuration.md`](docs/configuration.md) | The app's **own settings** |
> | [`logging.md`](docs/logging.md) | **What the app records about itself** — levels, the rotating file, redaction |
> | [`mod-reload.md`](docs/mod-reload.md) | **Why the app does not press F10 for you** — what was measured, and why the feature is removed rather than fixed |
> | [`desktop-integration.md`](docs/desktop-integration.md) | **The window itself** — the application id, the desktop entry and the icon that depends on it, and why the title bar is the window manager's |
>
> **Each doc owns one subject.** A fact that doesn't fit any of them wants a new
> file, not the nearest existing one — the scope line at the top of each doc is
> what decides. Notably: the remote API doc describes GameBanana's protocol, while
> our client is `app-architecture.md`; and what has shipped lives in `CHANGELOG.md`
> rather than in a status section inside a reference. New developer docs go in
> `docs/`, not the repo root.
>
> **The `CLAUDE.md` files stay under 200 lines and carry only context, rules and
> pointers.** They load on every session, so anything that needs *explaining* —
> a measurement, a rejected alternative, the reasoning behind a rule — goes in a
> doc, with the rule stated here in a line or two.

The app's rules and its index into `docs/` live in
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
- **An update overwrites a mod folder; it never empties, moves or replaces it**, and
  it **never writes without a snapshot first**. A mod folder frequently holds a
  second download (a patch, or a hand-merge) that replacing would destroy — see
  [`docs/applying-updates.md`](docs/applying-updates.md) §1.
- **No update is ever applied without the user present.** Automatic updating is
  *refused*, not unbuilt: overwriting a live install in a scene with no standard
  means the person who has to repair it must be there when it happens. Checking
  is a different act and is opt-in automatable. Confidence is not a licence —
  see [`docs/applying-updates.md`](docs/applying-updates.md) §7.
