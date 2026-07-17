import 'dart:ui';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import 'config_service.dart';
import 'mod_manager_service.dart';
import 'platform_service_factory.dart';

/// API сервіс для роботи з модами
class ApiService {
  static ModManagerService? _modManager;
  static ConfigService? _configService;
  static ProviderContainer? _container;

  static Future<void> initialize({ProviderContainer? container}) async {
    if (_configService == null) {
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
    }

    if (_modManager == null) {
      _modManager = ModManagerService(_configService!, _container!);
    }
  }

  static Future<List<ModInfo>> getMods() async {
    try {
      await initialize();
      return await _modManager!.getModsInfo();
    } catch (e) {
      throw Exception('Помилка отримання модів: $e');
    }
  }

  static Future<bool> toggleMod(String modId) async {
    try {
      await initialize();
      return await _modManager!.toggleMod(modId);
    } catch (e) {
      throw Exception('Помилка переключення моду: $e');
    }
  }

  /// Renames a mod's folder, migrating its active/favorite/category state and
  /// the active link. Returns false on collision or failure.
  static Future<bool> renameMod(String oldName, String newName) async {
    try {
      await initialize();
      return await _modManager!.renameMod(oldName, newName);
    } catch (e) {
      throw Exception('Помилка перейменування моду: $e');
    }
  }

  /// Permanently deletes a mod: its folder, active link, and config state.
  /// Returns false if the mod is missing or on failure.
  static Future<bool> deleteMod(String modId) async {
    try {
      await initialize();
      return await _modManager!.deleteMod(modId);
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

  /// Активує скін для персонажа, автоматично деактивуючи інші скіни цього персонажа
  static Future<bool> toggleModForCharacter(
    String modId, 
    String characterId, 
    List<ModInfo> characterSkins, 
    {bool multiMode = false}
  ) async {
    try {
      await initialize();
      
      // Знаходимо поточний мод
      final currentMod = characterSkins.firstWhere((mod) => mod.id == modId);
      
      // Якщо мод вже активний, просто деактивуємо його
      if (currentMod.isActive) {
        return await _modManager!.deactivateMod(modId);
      }
      
      // У режимі Single - деактивуємо всі інші активні скіни
      if (!multiMode) {
        for (final skin in characterSkins) {
          if (skin.isActive && skin.id != modId) {
            await _modManager!.deactivateMod(skin.id);
          }
        }
      }
      // У режимі Multi - просто додаємо до активних
      
      // Активуємо новий скін
      return await _modManager!.activateMod(modId);
    } catch (e) {
      throw Exception('Помилка переключення моду для персонажа: $e');
    }
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

  static Future<String> updateConfig({
    required String modsPath,
    required String saveModsPath,
  }) async {
    try {
      await initialize();
      await _configService!.setPaths(modsPath, saveModsPath);
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

  static Future<ModManagerService> getModManagerService() async {
    await initialize();
    return _modManager!;
  }

  /// Автоматично визначає та встановлює теги для всіх модів
  static Future<Map<String, String>> autoTagAllMods() async {
    try {
      await initialize();
      return await _modManager!.autoTagAllMods();
    } catch (e) {
      throw Exception('Помилка автотегування: $e');
    }
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
