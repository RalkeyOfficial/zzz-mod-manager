import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import '../utils/path_helper.dart';
import 'mod_metadata_repository.dart';

/// Сервіс для роботи з конфігурацією додатку
class ConfigService implements ModCharacterTagStore {
  static const String _keyModsPath = 'mods_path';
  static const String _keySaveModsPath = 'save_mods_path';
  static const String _keyActiveMods = 'active_mods';
  static const String _keyTheme = 'theme';
  static const String _keyLanguage = 'language';
  static const String _keyModCharacterTags = 'mod_character_tags';
  static const String _keyFavoriteMods = 'favorite_mods';
  static const String _keyFirstRun = 'first_run';
  static const String _keySortMode = 'sort_mode';
  static const String _keyContentFilter = 'content_filter';
  static const String _keyMarketplaceSort = 'marketplace_sort';

  final SharedPreferences _prefs;
  File? _configFile;

  /// [configFile] overrides where `config.json` lives.
  ///
  /// Exists so the dual-storage round-trip can be tested against a temp
  /// directory. Without it a test would have to write over the *real*
  /// `<appData>/config.json` — which is both destructive and the reason this class
  /// had no tests at all, despite `_saveToFile` being the documented place people
  /// forget to update (miss it and a setting works all session, then vanishes on
  /// restart, with no error).
  ConfigService(this._prefs, {File? configFile}) {
    if (configFile != null) {
      _configFile = configFile;
      final parent = configFile.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      return;
    }
    _initConfigFile();
  }

  void _initConfigFile() {
    try {
      final appDataPath = PathHelper.getAppDataPath();
      final configPath = path.join(appDataPath, AppConstants.configFileName);
      _configFile = File(configPath);
      
      // Створюємо директорію якщо її немає
      final dir = Directory(appDataPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    } catch (e) {
      // Fallback на поточну директорію для розробки
      final configPath = path.join(Directory.current.path, AppConstants.configFileName);
      _configFile = File(configPath);
    }
  }

  String? get modsPath => _prefs.getString(_keyModsPath);
  String? get saveModsPath => _prefs.getString(_keySaveModsPath);
  List<String> get activeMods => _prefs.getStringList(_keyActiveMods) ?? [];
  List<String> get favoriteMods => _prefs.getStringList(_keyFavoriteMods) ?? [];
  String get theme => _prefs.getString(_keyTheme) ?? 'dark-blue';
  String get language => _prefs.getString(_keyLanguage) ?? 'en';
  String get sortMode => _prefs.getString(_keySortMode) ?? 'added';
  bool get isFirstRun => _prefs.getBool(_keyFirstRun) ?? true;

  /// How the marketplace treats mods GameBanana flags as adult — the wire value
  /// of a `ContentFilterMode` (`blur` | `show` | `hide`).
  ///
  /// Stored as a raw string and parsed by the caller, deliberately: an
  /// unrecognised value must degrade to `blur` rather than fail the read, and
  /// `ContentFilterMode.parse` is where that rule lives. Defaults to `blur`,
  /// which honours GameBanana's own hint.
  String get contentFilter => _prefs.getString(_keyContentFilter) ?? 'blur';

  /// The marketplace browse sort, as a `GbModSort` **name** (not its wire value).
  ///
  /// Empty when never chosen, so the caller applies its own default rather than
  /// this layer having to know what that is. Parsed by `GbModSort.byName`, which
  /// degrades an unrecognised value to null.
  String get marketplaceSort => _prefs.getString(_keyMarketplaceSort) ?? '';
  
  @override
  Map<String, String> get modCharacterTags {
    final json = _prefs.getString(_keyModCharacterTags);
    if (json == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(json));
    } catch (e) {
      return {};
    }
  }

  Future<bool> setModsPath(String path) async {
    try {
      await _prefs.setString(_keyModsPath, path);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setSaveModsPath(String path) async {
    try {
      await _prefs.setString(_keySaveModsPath, path);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setPaths(String modsPath, String saveModsPath) async {
    try {
      await _prefs.setString(_keyModsPath, modsPath);
      await _prefs.setString(_keySaveModsPath, saveModsPath);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> addActiveMod(String modId) async {
    try {
      final mods = activeMods;
      if (!mods.contains(modId)) {
        mods.add(modId);
        await _prefs.setStringList(_keyActiveMods, mods);
        await _saveToFile();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> addFavoriteMod(String modId) async {
    try {
      final mods = favoriteMods;
      if (!mods.contains(modId)) {
        mods.add(modId);
        await _prefs.setStringList(_keyFavoriteMods, mods);
        await _saveToFile();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> removeFavoriteMod(String modId) async {
    try {
      final mods = favoriteMods;
      mods.remove(modId);
      await _prefs.setStringList(_keyFavoriteMods, mods);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> removeActiveMod(String modId) async {
    try {
      final mods = activeMods;
      mods.remove(modId);
      await _prefs.setStringList(_keyActiveMods, mods);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> setModCharacterTag(String modId, String characterId) async {
    try {
      final tags = modCharacterTags;
      tags[modId] = characterId;
      await _prefs.setString(_keyModCharacterTags, jsonEncode(tags));
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> removeModCharacterTag(String modId) async {
    try {
      final tags = modCharacterTags;
      tags.remove(modId);
      await _prefs.setString(_keyModCharacterTags, jsonEncode(tags));
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Migrates all per-mod config keyed by folder name when a mod is renamed
  /// (active_mods, favorite_mods, mod_character_tags). Preserves state so a
  /// renamed mod stays active/favorited/tagged.
  Future<bool> migrateModName(String oldId, String newId) async {
    try {
      final active = activeMods;
      if (active.remove(oldId)) {
        if (!active.contains(newId)) active.add(newId);
        await _prefs.setStringList(_keyActiveMods, active);
      }

      final favorites = favoriteMods;
      if (favorites.remove(oldId)) {
        if (!favorites.contains(newId)) favorites.add(newId);
        await _prefs.setStringList(_keyFavoriteMods, favorites);
      }

      final tags = modCharacterTags;
      if (tags.containsKey(oldId)) {
        tags[newId] = tags.remove(oldId)!;
        await _prefs.setString(_keyModCharacterTags, jsonEncode(tags));
      }

      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Очищає теги для модів, які більше не існують
  Future<void> cleanupInvalidTags(List<String> validModIds) async {
    try {
      final tags = modCharacterTags;
      final keysToRemove = <String>[];
      
      for (final modId in tags.keys) {
        if (!validModIds.contains(modId)) {
          keysToRemove.add(modId);
        }
      }
      
      for (final key in keysToRemove) {
        tags.remove(key);
      }
      
      if (keysToRemove.isNotEmpty) {
        await _prefs.setString(_keyModCharacterTags, jsonEncode(tags));
        await _saveToFile();
      }
    } catch (e) {
      // Ігноруємо помилки
    }
  }

  Future<bool> setTheme(String theme) async {
    try {
      await _prefs.setString(_keyTheme, theme);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setLanguage(String language) async {
    try {
      await _prefs.setString(_keyLanguage, language);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setSortMode(String mode) async {
    try {
      await _prefs.setString(_keySortMode, mode);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setContentFilter(String mode) async {
    try {
      await _prefs.setString(_keyContentFilter, mode);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setMarketplaceSort(String sortName) async {
    try {
      await _prefs.setString(_keyMarketplaceSort, sortName);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setFirstRunComplete() async {
    try {
      await _prefs.setBool(_keyFirstRun, false);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> loadFromFile() async {
    try {
      if (_configFile == null || !await _configFile!.exists()) return false;

      final content = await _configFile!.readAsString();
      final Map<String, dynamic> config = jsonDecode(content);

      if (config.containsKey('mods_path')) {
        await _prefs.setString(_keyModsPath, config['mods_path']);
      }
      if (config.containsKey('save_mods_path')) {
        await _prefs.setString(_keySaveModsPath, config['save_mods_path']);
      }
      if (config.containsKey('active_mods')) {
        final List<String> mods = List<String>.from(config['active_mods']);
        await _prefs.setStringList(_keyActiveMods, mods);
      }
      if (config.containsKey('theme')) {
        await _prefs.setString(_keyTheme, config['theme']);
      }
      if (config.containsKey('language')) {
        await _prefs.setString(_keyLanguage, config['language']);
      }
      if (config.containsKey('sort_mode')) {
        await _prefs.setString(_keySortMode, config['sort_mode']);
      }
      if (config.containsKey('content_filter')) {
        await _prefs.setString(_keyContentFilter, config['content_filter']);
      }
      if (config.containsKey('marketplace_sort')) {
        await _prefs.setString(_keyMarketplaceSort, config['marketplace_sort']);
      }
      if (config.containsKey('mod_character_tags')) {
        await _prefs.setString(_keyModCharacterTags, jsonEncode(config['mod_character_tags']));
      }
      if (config.containsKey('favorite_mods')) {
        final List<String> mods = List<String>.from(config['favorite_mods']);
        await _prefs.setStringList(_keyFavoriteMods, mods);
      }
      if (config.containsKey('first_run')) {
        await _prefs.setBool(_keyFirstRun, config['first_run']);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _saveToFile() async {
    try {
      if (_configFile == null) return false;

      final config = {
        'mods_path': modsPath ?? '',
        'save_mods_path': saveModsPath ?? '',
        'active_mods': activeMods,
        'favorite_mods': favoriteMods,
        'theme': theme,
        'language': language,
        'sort_mode': sortMode,
        'content_filter': contentFilter,
        'marketplace_sort': marketplaceSort,
        'mod_character_tags': modCharacterTags,
        'first_run': false,
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(config);
      await _configFile!.writeAsString(jsonString);

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> clear() async {
    try {
      await _prefs.clear();
      if (_configFile != null && await _configFile!.exists()) {
        await _configFile!.delete();
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}
