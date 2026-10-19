import 'dart:ui';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:mod_manager_flutter/core/palette.dart' show AccentChoice;
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/theme_setting.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import 'config_service.dart';
import 'log/log_setup.dart';
import '../models/gamebanana/gb_enums.dart';
import 'gamebanana/content_filter.dart';
import 'mod_manager_service.dart';
import 'platform_service_factory.dart';
import 'shader_fixes/shader_fixes_service.dart';

/// API сервіс для роботи з модами
class ApiService {
  static ModManagerService? _modManager;
  static ConfigService? _configService;
  static ProviderContainer? _container;

  /// Whether building the real services is forbidden — see
  /// [refuseRealLibraryInTests].
  static bool _refuseRealLibrary = false;

  static const String _reachedTheRealLibrary =
      'ApiService reached the real <appData>/config.json from a test. '
      'Mount a library with TempLibrary.create() (test/support/temp_library.dart), '
      'or override the provider this widget reads.';

  static Future<void> initialize({ProviderContainer? container}) async {
    if (_configService == null) {
      if (_refuseRealLibrary) throw StateError(_reachedTheRealLibrary);
      final prefs = await SharedPreferences.getInstance();
      _configService = ConfigService(prefs);
      await _configService!.loadFromFile();
    }

    if (container != null) {
      _container = container;
      final localeCode = _configService?.language ?? 'en';
      _container!
          .read(localeProvider.notifier)
          .state = Locale(localeCode);
      _container!.read(modSortProvider.notifier).state = ModSort.values
          .firstWhere(
            (e) => e.name == _configService!.sortMode,
            orElse: () => ModSort.added,
          );
      // Parsed rather than looked up: an unrecognised stored value has to
      // degrade to `blur`, never to `show`.
      _container!.read(contentFilterProvider.notifier).state =
          ContentFilterMode.parse(_configService!.contentFilter);
      // `byName` returns null for a value this build doesn't know, so a config
      // written by a version offering a different sort falls back rather than
      // failing startup.
      _container!.read(marketplaceSortProvider.notifier).state =
          GbModSort.byName(_configService!.marketplaceSort) ??
              kDefaultMarketplaceSort;
      // Parsed rather than looked up, for the same reason as the filter above:
      // the key predates the setting and holds a palette name in a config any
      // older build wrote.
      _container!.read(themeModeProvider.notifier).state =
          parseThemeMode(_configService!.theme);
      _container!.read(accentProvider.notifier).state =
          AccentChoice.parse(_configService!.accent);
      _container!.read(updateCheckOnLaunchProvider.notifier).state =
          _configService!.updateCheckOnLaunch;
      _container!.read(trackingNudgeDismissedProvider.notifier).state =
          _configService!.trackingNudgeDismissed;
      _container!.read(hideEmptyCharactersProvider.notifier).state = _configService!.hideEmptyCharacters;
      _container!.read(modNotesProvider.notifier).state = _configService!.modNotes;
      _container!.read(oneAtATimeProvider.notifier).state = _configService!.oneAtATime;
      _container!.read(fileLoggingProvider.notifier).state =
          _configService!.fileLogging;
      _container!.read(modsPathProvider.notifier).state =
          _configService!.modsPath ?? '';
      _container!.read(zzmiPathProvider.notifier).state =
          _configService!.zzmiPath ?? '';
      _container!.read(launchTargetProvider.notifier).state =
          _configService!.launchTarget;
      _container!.read(launchArgumentsProvider.notifier).state = _configService!.launchArguments;
      _container!.read(wineRunnerProvider.notifier).state = _configService!.wineRunner;
      _container!.read(winePrefixProvider.notifier).state = _configService!.winePrefix;
      _container!.read(wineUseUmuProvider.notifier).state = _configService!.wineUseUmu;
    }

    _modManager ??= ModManagerService(_configService!);
  }

  /// **Points this facade at a library the caller owns**, so nothing reaches the
  /// real `<appData>/config.json`.
  ///
  /// Everything here is static and [initialize] builds its singletons on first
  /// use — a `ConfigService` over `<appData>/config.json` and a
  /// `ModManagerService` over whatever library that file names. So a test that
  /// runs any flow touching this class rewrites the developer's own library
  /// paths, active-mod list, language and sort order. That is the reason the
  /// dialogs that *write* have no coverage above the service layer, which is
  /// exactly where the confirmation, the rescan and the notification live.
  ///
  /// [config] is a **real** `ConfigService` over a temp directory, not a stub
  /// that does nothing. What these flows do is write files, so a config that
  /// swallowed its writes would remove the only thing worth asserting; the
  /// substitution is *where* it writes, never *whether*. See
  /// `test/support/temp_library.dart`, which builds one and installs it.
  ///
  /// Always paired with [resetForTests] in a tear-down: the fields are static,
  /// so a library left installed outlives the test that made it and the next
  /// test writes into a directory that has been deleted.
  ///
  /// [service] is the caller's own manager, whose shader-fixes record is in its
  /// temp folder. Required: the facade's own default would use the developer's
  /// real `<appData>/shader_fixes.json`.
  @visibleForTesting
  static void useLibraryForTests(ConfigService config, {required ModManagerService service}) {
    _configService = config;
    // Replaced rather than kept: a manager built over the previous test's config
    // still holds that test's temp paths, and `??=` in [initialize] would keep it.
    _modManager = service;
    _container = null;
  }

  /// Forgets an installed test library, so the next caller builds the real one.
  @visibleForTesting
  static void resetForTests() {
    _configService = null;
    _modManager = null;
    _container = null;
  }

  /// **Makes reaching the real library a failure instead of a quiet read.**
  ///
  /// Armed once per test isolate from `test/flutter_test_config.dart`, which
  /// Flutter runs before `main()` in every file under `test/`. From then on
  /// [initialize] throws unless [useLibraryForTests] has installed one.
  ///
  /// It exists because [useLibraryForTests] is opt-in and this is not. Several
  /// providers reach this facade — `installedModsIndexProvider` calls
  /// [getMods], `modManagerServiceProvider` calls [getModManagerService] — so
  /// any widget test that mounts something watching one of those, and does not
  /// know to substitute a library, reads the developer's own `config.json` and
  /// scans their real mod folder. Nothing about that looks like a failure: the
  /// test passes, slowly, against data no other machine has.
  ///
  /// So the rule is enforced where it cannot be forgotten rather than written
  /// down and hoped for. The message names the fix, because the stack trace
  /// points at a provider and not at the missing set-up.
  @visibleForTesting
  static void refuseRealLibraryInTests() {
    _refuseRealLibrary = true;
  }

  static Future<List<ModInfo>> getMods() async {
    try {
      await initialize();
      return await _modManager!.getModsInfo();
    } catch (e) {
      throw Exception('Помилка отримання модів: $e');
    }
  }

  /// Renames a mod's folder, migrating its active/favorite/note/category state and
  /// the active link. Returns false on collision or failure.
  static Future<bool> renameMod(String oldName, String newName) async {
    try {
      await initialize();
      final renamed = await _modManager!.renameMod(oldName, newName);
      // The note moved with the rename; the provider still has it under the old name.
      if (renamed) _container?.read(modNotesProvider.notifier).state = _configService!.modNotes;
      return renamed;
    } catch (e) {
      throw Exception('Помилка перейменування моду: $e');
    }
  }

  /// Permanently deletes a mod: its folder, active link, and config state.
  /// Returns false if the mod is missing or on failure.
  static Future<bool> deleteMod(String modId) async {
    try {
      await initialize();
      final deleted = await _modManager!.deleteMod(modId);
      if (deleted) _container?.read(modNotesProvider.notifier).state = _configService!.modNotes;
      return deleted;
    } catch (e) {
      throw Exception('Помилка видалення моду: $e');
    }
  }

  /// Opens a mod's folder in the system file manager. Returns false on failure.
  static Future<bool> openModFolder(String modId) async {
    try {
      await initialize();
      return await _modManager!.openModFolder(modId);
    } catch (e) {
      throw Exception('Помилка відкриття папки моду: $e');
    }
  }

  /// Reads rich-text HTML from the system clipboard, or null if none. Used to
  /// paste formatted text into the description editors as markdown.
  static Future<String?> getClipboardHtml() async {
    try {
      return await PlatformServiceFactory.getInstance().getClipboardHtml();
    } catch (e) {
      return null;
    }
  }

  /// Turns [modId] on, after turning every mod in [switchOff] off: the enable a character's One at a time switch
  /// asks for (`docs/library-screen.md` §10).
  ///
  /// The dry run comes first, so a refused enable throws [ShaderPlacementRefused] before anything changes. A mod in
  /// [switchOff] that will not turn off stops the enable, rather than leaving two on under a switch that says one.
  ///
  /// False means the enable failed: a link could not be made or removed. Mods in [switchOff] may be off by then, so
  /// the caller reports the failure and reads the disk again.
  static Future<bool> enableMod(String modId, {Iterable<String> switchOff = const []}) async {
    try {
      await initialize();
      await _modManager!.checkActivation(modId);
      for (final other in switchOff) {
        if (!await _modManager!.deactivateMod(other)) return false;
      }
      return await _modManager!.activateMod(modId);
    } on ShaderPlacementRefused {
      rethrow;
    } catch (e) {
      throw Exception('Could not turn the mod on: $e');
    }
  }

  /// False when the link could not be removed.
  static Future<bool> disableMod(String modId) async {
    try {
      await initialize();
      return await _modManager!.deactivateMod(modId);
    } catch (e) {
      throw Exception('Could not turn the mod off: $e');
    }
  }

  /// Saves the note the user wrote on [modId], and publishes it. Empty text removes it.
  static Future<bool> setModNote(String modId, String note) async {
    await initialize();
    final saved = await _configService!.setModNote(modId, note);
    if (saved) _container?.read(modNotesProvider.notifier).state = _configService!.modNotes;
    return saved;
  }

  /// Saves whether turning one of [groupId]'s mods on turns the others off, and publishes it.
  static Future<bool> setOneAtATime(String groupId, bool on) async {
    await initialize();
    final saved = await _configService!.setOneAtATime(groupId, on);
    if (saved) _container?.read(oneAtATimeProvider.notifier).state = _configService!.oneAtATime;
    return saved;
  }

  static Future<String> clearAll() async {
    try {
      await initialize();
      final mods = await _modManager!.getModsInfo();
      int deactivated = 0;

      for (final mod in mods) {
        if (mod.isActive) {
          await _modManager!.deactivateMod(mod.id);
          deactivated++;
        }
      }

      return 'Деактивовано $deactivated модів';
    } catch (e) {
      throw Exception('Помилка очищення: $e');
    }
  }

  static Future<Map<String, String>> getConfig() async {
    try {
      await initialize();
      return {
        'mods_path': _configService!.modsPath ?? '',
        'zzmi_path': _configService!.zzmiPath ?? '',
        'save_mods_path': _configService!.saveModsPath ?? '',
        'language': _configService!.language,
      };
    } catch (e) {
      throw Exception('Помилка отримання конфігурації: $e');
    }
  }

  static Future<void> setLanguage(String languageCode) async {
    await initialize();
    await _configService!.setLanguage(languageCode);
    _container?.read(localeProvider.notifier).state = Locale(languageCode);
  }

  /// Persists the mods sort mode so it is restored on the next launch.
  static Future<void> saveSortMode(ModSort sort) async {
    await initialize();
    await _configService!.setSortMode(sort.name);
  }

  /// Persists the marketplace content filter and applies it immediately.
  static Future<void> setContentFilter(ContentFilterMode mode) async {
    await initialize();
    await _configService!.setContentFilter(mode.wire);
    _container?.read(contentFilterProvider.notifier).state = mode;
  }

  /// Persists the marketplace browse sort so the next launch starts on it.
  ///
  /// Stores the enum `name`, not the GameBanana `_sSort` string — see
  /// `GbModSort.byName`.
  static Future<void> setMarketplaceSort(GbModSort sort) async {
    await initialize();
    await _configService!.setMarketplaceSort(sort.name);
    _container?.read(marketplaceSortProvider.notifier).state = sort;
  }

  /// Persists the theme choice and applies it immediately.
  ///
  /// Stores the `ThemeMode` name, which is what `parseThemeMode` reads back.
  static Future<void> setThemeMode(ThemeMode mode) async {
    await initialize();
    await _configService!.setTheme(mode.name);
    _container?.read(themeModeProvider.notifier).state = mode;
  }

  /// Persists what the Launch game button starts.
  static Future<void> setLaunchTarget(String target) async {
    await initialize();
    await _configService!.setLaunchTarget(target);
    _container?.read(launchTargetProvider.notifier).state = target;
  }

  /// Persists what Launch game passes the launcher. Null goes back to the default.
  static Future<void> setLaunchArguments(String? arguments) async {
    await initialize();
    await _configService!.setLaunchArguments(arguments);
    _container?.read(launchArgumentsProvider.notifier).state = _configService!.launchArguments;
  }

  /// Persists the Wine or Proton that runs the launcher on Linux.
  static Future<void> setWineRunner(String runner) async {
    await initialize();
    await _configService!.setWineRunner(runner);
    _container?.read(wineRunnerProvider.notifier).state = runner;
  }

  /// Persists the Wine prefix the launcher runs in on Linux.
  static Future<void> setWinePrefix(String prefix) async {
    await initialize();
    await _configService!.setWinePrefix(prefix);
    _container?.read(winePrefixProvider.notifier).state = prefix;
  }

  /// Persists whether a Proton runner starts through umu-launcher on Linux.
  static Future<void> setWineUseUmu(bool useUmu) async {
    await initialize();
    await _configService!.setWineUseUmu(useUmu);
    _container?.read(wineUseUmuProvider.notifier).state = useUmu;
  }

  /// Persists the accent and applies it immediately.
  static Future<void> setAccent(AccentChoice accent) async {
    await initialize();
    await _configService!.setAccent(accent.name);
    _container?.read(accentProvider.notifier).state = accent;
  }

  /// Persists whether the update check runs on its own at startup.
  ///
  /// Checking only. Nothing here consents to an update being *applied* — that
  /// stays a thing the user presses, per `docs/applying-updates.md` §7.
  static Future<void> setUpdateCheckOnLaunch(bool enabled) async {
    await initialize();
    await _configService!.setUpdateCheckOnLaunch(enabled);
    _container?.read(updateCheckOnLaunchProvider.notifier).state = enabled;
  }

  /// Persists whether the reminder about mods not set up for update checking has been closed.
  static Future<void> setTrackingNudgeDismissed(bool dismissed) async {
    await initialize();
    await _configService!.setTrackingNudgeDismissed(dismissed);
    _container?.read(trackingNudgeDismissedProvider.notifier).state = dismissed;
  }

  /// Persists whether the Library's character list hides the rows with no mods.
  static Future<void> setHideEmptyCharacters(bool hide) async {
    await initialize();
    await _configService!.setHideEmptyCharacters(hide);
    _container?.read(hideEmptyCharactersProvider.notifier).state = hide;
  }

  /// Persists the setting **and applies it now**, in that order.
  ///
  /// Writing first means a crash between the two leaves the file matching what
  /// the user asked for on the next launch, which is the half that lasts.
  static Future<void> setFileLogging(bool enabled) async {
    await initialize();
    await _configService!.setFileLogging(enabled);
    _container?.read(fileLoggingProvider.notifier).state = enabled;
    applyFileLogging(enabled);
  }

  static Future<String> updateConfig({
    required String modsPath,
    required String zzmiPath,
  }) async {
    try {
      await initialize();
      await _configService!.setPaths(modsPath, zzmiPath);
      // Repointing the library has to reach the providers that derive from it,
      // or the Storage tab keeps measuring the folder that was set at launch.
      _container?.read(modsPathProvider.notifier).state = modsPath;
      _container?.read(zzmiPathProvider.notifier).state = zzmiPath;
      // An unchanged path doesn't rebuild the check, and ZZMI may have been installed into it since.
      _container?.invalidate(zzmiFoundProvider);
      _container?.invalidate(xxmiLauncherProvider);
      return 'Конфігурацію збережено';
    } catch (e) {
      throw Exception('Помилка оновлення конфігурації: $e');
    }
  }

  /// Persists a mod's editable metadata (description, source URL, tags,
  /// character, images) into its in-folder sidecar.
  static Future<bool> updateMod(ModInfo mod) async {
    try {
      await initialize();
      return await _modManager!.saveModMetadata(mod);
    } catch (e) {
      throw Exception('Помилка оновлення моду: $e');
    }
  }

  /// Sets a mod's character assignment (writes the in-folder sidecar and
  /// mirrors to config.json for backward compatibility).
  static Future<bool> setModCharacter(String modId, String characterId) async {
    try {
      await initialize();
      return await _modManager!.setModCharacter(modId, characterId);
    } catch (e) {
      throw Exception('Помилка оновлення персонажа моду: $e');
    }
  }

  /// Drops cached keybinds for a mod (call after editing its .ini).
  static Future<void> invalidateKeybinds(String modId) async {
    await initialize();
    _modManager!.invalidateKeybinds(modId);
  }

  /// Clears all cached keybinds (used by manual refresh).
  static Future<void> clearKeybindCache() async {
    await initialize();
    _modManager!.clearKeybindCache();
  }

  static Future<ConfigService> getConfigService() async {
    await initialize();
    return _configService!;
  }

  /// Builds the service on first use. Widgets read `modManagerServiceProvider`
  /// instead, which is the one place this is called.
  static Future<ModManagerService> getModManagerService() async {
    await initialize();
    return _modManager!;
  }

  /// Перевіряє, чи це перший запуск додатку
  static Future<bool> isFirstRun() async {
    await initialize();
    return _configService!.isFirstRun;
  }

  /// Завершує початкове налаштування
  static Future<void> completeFirstRun() async {
    await initialize();
    await _configService!.setFirstRunComplete();
  }
}
