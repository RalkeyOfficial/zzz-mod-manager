# CLAUDE.md — the Flutter app

Loads when working on files under `mod_manager_flutter/`. Repo-wide rules (language policy, changelog conventions) live in the [root `CLAUDE.md`](../CLAUDE.md).

This file is rules and pointers only. Every subject below has a doc in [`../docs/`](../docs/README.md) that owns its reasoning — read the relevant one before changing anything it covers.

| Doc | Owns |
|---|---|
| [`app-architecture.md`](../docs/app-architecture.md) | The layers of `lib/` — service layer, platform abstraction, the GameBanana client, markdown rendering |
| [`gamebanana-api.md`](../docs/gamebanana-api.md) | GameBanana's remote protocol. Read before writing any request — the surface is undocumented upstream, so guessing costs more than looking |
| [`downloads.md`](../docs/downloads.md) | Fetching archives — the isolate pump, resume, backpressure, the stall timeout, the background queue |
| [`marketplace.md`](../docs/marketplace.md) | The native browser screens — grid, detail view, what an install does |
| [`library-screen.md`](../docs/library-screen.md) | The Mods tab — card, status slot, toolbar, bulk actions, its dialogs |
| [`notifications.md`](../docs/notifications.md) | What the app tells the user — whether to speak at all, the two levels, the card |
| [`metadata-schema.md`](../docs/metadata-schema.md) | The sidecar file format |
| [`migrations.md`](../docs/migrations.md) | Reading data an older version wrote — every migration and tolerance; there is no `migrations/` folder and it says why |
| [`origin-tracking.md`](../docs/origin-tracking.md) | Where a mod came from — the folder as a stack of downloads, confidence model, backfill, resolve flow |
| [`metadata-autofill.md`](../docs/metadata-autofill.md) | What an install copies from a mod page |
| [`update-checks.md`](../docs/update-checks.md) | Whether a mod has a newer version |
| [`applying-updates.md`](../docs/applying-updates.md) | How an update is written over an installed mod |
| [`patch-destinations.md`](../docs/patch-destinations.md) | Which mod folder a patch goes into — the signals and their measurements; ranked, never narrowed or preselected |
| [`logging.md`](../docs/logging.md) | What the app records about itself — levels, tags, the rotating file, redaction |
| [`mod-reload.md`](../docs/mod-reload.md) | Why the app does not press F10 for you — what was measured, and why the feature is removed rather than fixed |
| [`desktop-integration.md`](../docs/desktop-integration.md) | The window itself — the application id, the desktop entry and the icon that depends on it, and why the title bar is the window manager's |
| [`disk-usage.md`](../docs/disk-usage.md) | What the app is keeping on disk — the Storage tab's categories, apparent size vs free space, the shared directory walk, and what the reclaim may delete |
| [`configuration.md`](../docs/configuration.md) | The app's own settings |

## How mods work

Two configured paths drive everything: `modsPath` (where mod folders live — the library) and `saveModsPath` (the game's mods folder, where links go).
Activating a mod creates a link `saveModsPath/<mod>` → `modsPath/<mod>`; deactivating removes it. `ModManagerService._cleanupInvalidLinks()` runs on scan to prune links whose source is gone.

Single vs Multi mode (`activationModeProvider`): in Single mode, activating a skin auto-deactivates the character's other active skins — see `ApiService.toggleModForCharacter`.

Characters and built-in categories (`cat_ui`, `cat_texture`, `cat_audio`, `cat_misc`) share one id namespace, stored in `ModInfo.characterId`.
Anything resolving a character from an id must handle both, plus the `unknown` placeholder.

## Development workflow

Do not rebuild for every change. Launch once with `flutter run -d linux` from this directory, then push edits into the running app via hot reload.
Use `flutter build` only for packaging/release, never for dev iteration.

In an active `flutter run` session (same terminal):

- `r` — hot reload (keeps app state). Sufficient for widget/UI edits, including localization strings and dialog layouts.
- `R` — hot restart (resets state). Needed for changes to `main()`, Riverpod providers, model classes (`ModInfo`, `KeybindInfo`), and `static`/top-level fields.
- Full relaunch for: new/changed assets in `pubspec.yaml` (l10n JSON, images), added packages, native/plugin changes, and anything under `linux/` (compiled in).

Parsed keybinds (`IniParserService`) are produced during a folder scan and cached in provider state, so after editing the parser hot restart (`R`) and re-scan.
Mod metadata/scan logic lives in services held as singletons via `ApiService`; changes there generally need `R`.

`flutter doctor`: only Flutter and Linux toolchain matter here; the Android toolchain and Chrome/web ✗ marks are expected.

System dependencies (Linux dev): the C++ toolchain (`clang`, `cmake`, `ninja`, `pkg-config`) + `gtk3` for building; and `7z`/`7za`/`7zr` (Arch: `7zip`, not the older `p7zip` port) for archive imports.

Clipboard HTML (paste-as-markdown) is read natively: Linux via the GTK clipboard in the runner (`linux/runner/my_application.cc`, channel `mod_manager/clipboard`), Windows via `pasteboard`. No external CLI tool.

## Rules that must not be missed

Platform
- Never branch on `Platform.isX` for platform-specific behaviour in business logic. Add a method to `PlatformService` and implement it in both `LinuxPlatformService` and `WindowsPlatformService`.

The window — full reasoning in [`desktop-integration.md`](../docs/desktop-integration.md)
- The app draws no title bar. Never set `titleBarStyle: TitleBarStyle.hidden` or `gtk_window_set_decorated(window, FALSE)` — on Wayland it breaks edge resize without undecorating anything. Anything that wants to sit "in the title bar" goes in the sidebar.
- The application id is one string in three places: `APPLICATION_ID` in `linux/CMakeLists.txt`, the `linux/packaging/<id>.desktop` filename, and the installed icon's filename. Keep all three in sync.

Characters
- The `characterAliases` map is duplicated in `_detectCharacterFromName` and `_findCharacterInText` (`mod_manager_service.dart`) — update both copies when adding a character. The canonical roster is `utils/zzz_characters.dart`.
- `assets/characters/<name>.png` is spelled in exactly one place, `CharacterAvatar.assetPathFor`. It returns null when there is no portrait, and that check must run before an `Image` is built.
- Never derive a character from `detectCharacterId(name)` as a fallback — it is a substring guess, and "Zhao Nicole" resolves to Nicole.

Claims the UI may make
- An archive md5 match is a matching key, never an integrity claim — never render a match as "verified".
- An update overwrites a mod folder; it never empties, moves or replaces it, and never writes without a snapshot first. Taking a patch out follows the same rule ([`applying-updates.md`](../docs/applying-updates.md)).
- A mod folder is a stack of downloads (`origin.downloads`, bottom-most first); position is the role, never a separate stored flag ([`origin-tracking.md`](../docs/origin-tracking.md)).
- An `InstalledFileRole` we do not recognise resolves to `replaced`, never `added`.
- A displaced original is renamed, never stored under its real name — files kept in `.zzz-mod-manager/replaced/` take a `.orig` suffix ([`applying-updates.md`](../docs/applying-updates.md) §5).
- No update is applied without the user present. Automatic updating is refused rather than unbuilt; checking is automatable and opt-in ([`applying-updates.md`](../docs/applying-updates.md) §7, [`update-checks.md`](../docs/update-checks.md) §5.1).
- Guesses may inform, never drive. A suggestion is never preselected, and nothing but a checksum match ever reaches `exact`.
- The app never presses F10 for the user — built, measured, removed ([`mod-reload.md`](../docs/mod-reload.md)).

Notifications — full rules in [`notifications.md`](../docs/notifications.md)
- Never call `ScaffoldMessenger`. `context.notify.<severity>(…)` is the only way.
- A change the user can see reports only its failure; a change they cannot see may report its success.
- Every notification is `title` = what happened, `body` = what it happened to. Both required.
- Severity is the only thing a call site decides — colour, icon and duration are derived from it in one place.

Diagnostics — full rules in [`logging.md`](../docs/logging.md)
- Never `print` or `debugPrint`. `final _log = Logger('<tag>')` at the top of the file; `avoid_print` is on and `test/no_prints_test.dart` catches the other one.
- Message says what happened, fields say what it happened to. No interpolated values in the message, and an exception goes in `error:`, never in the string.
- Never pre-censor a path — redaction runs at the sink, on the rendered line.
- Mutations are itemised, reads are summarised: a symlink logs a line, a 71-mod scan logs one.

Timeouts
- Download timeouts are stall timeouts, never a total duration. A legitimate transfer over a degraded CDN node runs ~25 minutes and must be allowed to.

## State

`utils/state_providers.dart` is the central registry — add global state there, not ad-hoc.
One exception: `utils/marketplace_providers.dart` holds the marketplace's browsing session, which is one screen's state rather than the app's.

Widgets and dialogs reach `ModManagerService` through `modManagerServiceProvider`, never `ApiService.getModManagerService` — the provider is the one seam a test overrides.
A flow that outlives its widget reads it through the app's `ProviderContainer`, since a `WidgetRef` throws once its widget is gone.

The library is `libraryProvider` and belongs to no screen. It owns the scan; `modsProvider` is its plain-list view, `installedModsIndexProvider` derives from it, and the Mods tab builds `charactersProvider`'s localized groups from it.
So: whoever changes a mod folder invalidates `libraryProvider`, never only something derived from it — invalidating the index alone rebuilds it from the same cached scan.
One walk of the folder at a time: a `rescan()` during a running scan takes that answer, and a scan never overwrites an edit published while it was walking.
The four tabs are keyed `AnimatedSwitcher` children with no keep-alive, so the inactive tab's `State` is disposed and nothing a tab owns may be the only copy of something another surface needs.
A provider in the root container is not disposed with it, which is how the Storage tab's scan survives a tab switch without a host widget.
A question asked mid-install reads the disk instead — nothing has invalidated anything yet (`test/modal_freshness_test.dart`).

Work that outlives the press that started it must not be owned by a tab. Its `BuildContext` dies on the next tab switch, silently and mid-await.
Mount a host above the switcher instead — `DownloadQueueHost` in `main.dart` is the pattern, and `downloads.md` §8 is why.

## Localization

Custom JSON i18n (not ARB/gen-l10n). Strings live in `assets/l10n/en.json` and `uk.json` as nested objects; look up with `context.loc.t('navigation.mods')`.
`localeProvider` holds the active locale; English and Ukrainian are supported.

A missing key renders as the raw dotted path, with no exception. Both files must stay at exact parity — `test/l10n_keys_test.dart` enforces that, plus `_single`/`_plural` and `_title`/`_body` sibling pairs.
Keys built by interpolation or a ternary are invisible to that test's regex; register their prefix in `interpolatedKeyPrefixes`.

A counted string goes through `loc.plural(base, count)`, never a hand-written `count == 1 ? _single : _plural` — English has two plural forms and Ukrainian three. `l10n/plural_rules.dart` owns the rule.
- `_few` is optional and exists only in `pluralFewLocales`; a locale without one falls back to `_plural`.
- `_single` is not "exactly one" — Ukrainian reaches it at 1, 21, 31, 101, so one whose `_plural` names a count must name one too: "1 mod" or "this mod" is wrong at 21.

Much of the codebase still has legacy Ukrainian comments and strings. Per the root `CLAUDE.md`, write all new and edited code in English regardless.

## Testing

Widget tests need `test/support/localized_harness.dart`, never a plain `MaterialApp`. `AppLocalizations.delegate` loads its JSON from the asset bundle asynchronously, and `pumpAndSettle` does not wait for real async I/O —
it returns once no frames are scheduled, long before a bundle read finishes, so the result renders an empty box forever with no exception and every assertion passes vacuously.
The harness preloads via `runAsync`; call `expectBuilt(...)` after pumping so that failure can never be silent. The same trap applies to `Image.asset`: assert about the `AssetImage`'s `assetName`, never about pixels.

Dialogs that write must take a seam. `ApiService` is static and lazily builds a `ConfigService` against the developer's real `<appData>/config.json`; `test/flutter_test_config.dart` makes that throw, and `test/support/temp_library.dart` installs a real library in a temp directory instead — these flows are the file writes.

Press a handler that touches files with `tapWithIo`: a `testWidgets` body runs in a fake-async zone that never turns the real event loop, so the handler never resumes and its dialog is never built. Only `runAsync` turns it.

## App-data locations

`PathHelper.getAppDataPath()`: Linux `~/.local/share/zzz-mod-manager`, Windows `%APPDATA%\zzz-mod-manager`.
Holds `config.json`, `mod_images/`, `downloads/` and `backups/`.
