import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import '../utils/path_helper.dart';
import 'log/logger.dart';
import 'mod_metadata_repository.dart';
import 'shader_fixes/zzmi_layout.dart';

final Logger _log = Logger('config');

/// Сервіс для роботи з конфігурацією додатку
class ConfigService implements ModCharacterTagStore {
  static const String _keyModsPath = 'mods_path';
  static const String _keyZzmiPath = 'zzmi_path';

  /// The links folder as older builds stored it. Written for a downgrade, and read
  /// only when [_keyZzmiPath] is absent.
  static const String _keySaveModsPath = 'save_mods_path';
  static const String _keyActiveMods = 'active_mods';
  static const String _keyTheme = 'theme';
  static const String _keyAccent = 'accent';
  static const String _keyLaunchTarget = 'launch_target';
  static const String _keyLanguage = 'language';
  static const String _keyModCharacterTags = 'mod_character_tags';
  static const String _keyFavoriteMods = 'favorite_mods';
  static const String _keyFirstRun = 'first_run';
  static const String _keySortMode = 'sort_mode';
  static const String _keyContentFilter = 'content_filter';
  static const String _keyMarketplaceSort = 'marketplace_sort';
  static const String _keyUpdateCheckOnLaunch = 'update_check_on_launch';
  static const String _keyTrackingNudgeDismissed = 'tracking_nudge_dismissed';

  /// Mirrored by `services/log/log_setup.dart`, which reads the same key
  /// straight off `config.json` during bootstrap — `SharedPreferences` does not
  /// exist yet at the moment the first line is written.
  static const String _keyFileLogging = 'file_logging';

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

  /// The ZZMI folder, the one holding `d3dx.ini`.
  ///
  /// A config without one reads it as the parent of the legacy `save_mods_path`,
  /// which is the migration: it runs on every read and is written by the next save
  /// (`docs/migrations.md`).
  String? get zzmiPath {
    final stored = _prefs.getString(_keyZzmiPath);
    if (stored != null) return stored;
    final legacy = _prefs.getString(_keySaveModsPath);
    if (legacy == null || legacy.isEmpty) return legacy;
    return path.dirname(path.normalize(legacy));
  }

  String? _linksRoot;
  String? _links;

  /// The links folder, worked out from [zzmiPath] by `linksFolderIn` and cached
  /// until the ZZMI folder is set or loaded again.
  String? get saveModsPath {
    final root = zzmiPath;
    if (root == null || root.isEmpty) return root;
    if (root != _linksRoot) {
      _links = linksFolderIn(root);
      _linksRoot = root;
      final legacy = _prefs.getString(_keyZzmiPath) == null
          ? _prefs.getString(_keySaveModsPath)
          : null;
      if (legacy != null && !path.equals(legacy, _links!)) {
        _log.info('legacy links folder replaced by the ZZMI folder\'s Mods', fields: {
          'from': legacy,
          'to': _links,
        });
      }
    }
    return _links;
  }
  List<String> get activeMods => _prefs.getStringList(_keyActiveMods) ?? [];
  List<String> get favoriteMods => _prefs.getStringList(_keyFavoriteMods) ?? [];
  /// The theme the user picked, as a `ThemeMode` **name** (`light` | `system` |
  /// `dark`).
  ///
  /// Empty when never chosen, so the caller applies its own default rather than
  /// this layer having to know what it is — the same shape as
  /// [marketplaceSort]. Parsed by `parseThemeMode`, which degrades anything
  /// unrecognised to `system`; that tolerance is what lets the key hold the
  /// palette name older builds wrote under it.
  String get theme => _prefs.getString(_keyTheme) ?? '';

  /// The accent, as an `AccentChoice` **name**. Empty when never chosen; `AccentChoice.parse` applies the default.
  String get accent => _prefs.getString(_keyAccent) ?? '';

  /// The file the Launch game button starts. Empty when never chosen.
  String get launchTarget => _prefs.getString(_keyLaunchTarget) ?? '';
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

  /// Whether the whole-library update check runs on its own at startup.
  ///
  /// **Defaults to false, and that is the setting's whole safety property.** The
  /// rule everywhere else is that a check never runs without an explicit press —
  /// no network on launch, ever. This is the one opt-in out of it, so turning it
  /// on has to be a decision the user made rather than one they inherited.
  ///
  /// It governs *checking* only. Nothing in this app writes over an installed mod
  /// without the user present.
  bool get updateCheckOnLaunch =>
      _prefs.getBool(_keyUpdateCheckOnLaunch) ?? false;

  /// Whether the user has closed the reminder that some mods are not set up for update checking.
  bool get trackingNudgeDismissed =>
      _prefs.getBool(_keyTrackingNudgeDismissed) ?? false;

  /// Whether each run writes a log file.
  ///
  /// **Defaults to true, and that is the opposite call from the one above for
  /// the opposite reason.** A startup check reaches the network without being
  /// asked, so it has to be opted into; a log reaches nothing, costs a few
  /// kilobytes, and is worthless if it was switched off on the run that broke.
  /// Turning it off is a privacy choice the user makes deliberately.
  bool get fileLogging => _prefs.getBool(_keyFileLogging) ?? true;


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

  Future<bool> setZzmiPath(String path) async {
    try {
      await _prefs.setString(_keyZzmiPath, path);
      _linksRoot = null;
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setPaths(String modsPath, String zzmiPath) async {
    try {
      await _prefs.setString(_keyModsPath, modsPath);
      await _prefs.setString(_keyZzmiPath, zzmiPath);
      _linksRoot = null;
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

  Future<bool> setAccent(String accent) async {
    try {
      await _prefs.setString(_keyAccent, accent);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setLaunchTarget(String target) async {
    try {
      await _prefs.setString(_keyLaunchTarget, target);
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

  Future<bool> setUpdateCheckOnLaunch(bool enabled) async {
    try {
      await _prefs.setBool(_keyUpdateCheckOnLaunch, enabled);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setTrackingNudgeDismissed(bool dismissed) async {
    try {
      await _prefs.setBool(_keyTrackingNudgeDismissed, dismissed);
      await _saveToFile();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setFileLogging(bool enabled) async {
    try {
      await _prefs.setBool(_keyFileLogging, enabled);
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
      if (config.containsKey('zzmi_path')) {
        await _prefs.setString(_keyZzmiPath, config['zzmi_path']);
      } else if (config.containsKey('save_mods_path')) {
        // An older build wrote this file, so its links folder is the newer answer.
        await _prefs.remove(_keyZzmiPath);
      }
      if (config.containsKey('save_mods_path')) {
        await _prefs.setString(_keySaveModsPath, config['save_mods_path']);
      }
      _linksRoot = null;
      if (config.containsKey('active_mods')) {
        final List<String> mods = List<String>.from(config['active_mods']);
        await _prefs.setStringList(_keyActiveMods, mods);
      }
      if (config.containsKey('theme')) {
        await _prefs.setString(_keyTheme, config['theme']);
      }
      if (config.containsKey('accent')) {
        await _prefs.setString(_keyAccent, config['accent']);
      }
      if (config.containsKey('launch_target')) {
        await _prefs.setString(_keyLaunchTarget, config['launch_target']);
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
      if (config.containsKey('update_check_on_launch')) {
        await _prefs.setBool(
          _keyUpdateCheckOnLaunch,
          config['update_check_on_launch'],
        );
      }
      if (config.containsKey('tracking_nudge_dismissed')) {
        await _prefs.setBool(
          _keyTrackingNudgeDismissed,
          config['tracking_nudge_dismissed'],
        );
      }
      if (config.containsKey('file_logging')) {
        await _prefs.setBool(_keyFileLogging, config['file_logging']);
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
        'zzmi_path': zzmiPath ?? '',
        'save_mods_path': saveModsPath ?? '',
        'active_mods': activeMods,
        'favorite_mods': favoriteMods,
        'theme': theme,
        'accent': accent,
        'launch_target': launchTarget,
        'language': language,
        'sort_mode': sortMode,
        'content_filter': contentFilter,
        'marketplace_sort': marketplaceSort,
        'update_check_on_launch': updateCheckOnLaunch,
        'tracking_nudge_dismissed': trackingNudgeDismissed,
        'file_logging': fileLogging,
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
