import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../models/keybind_info.dart';
import 'log/logger.dart';

final Logger _log = Logger('ini');

/// Крос-платформний сервіс для парсингу INI файлів
/// Працює як на Windows, так і на Linux
class IniParserService {
  /// Регулярний вираз для знаходження секцій (напр. [keySwap], [KeyUP])
  static final RegExp _sectionRegex = RegExp(r'^\[([^\]]+)\]$');
  
  /// Регулярний вираз для знаходження пар ключ=значення
  static final RegExp _keyValueRegex = RegExp(r'^([^=]+)=(.*)$');
  
  /// Список типових назв секцій з keybinds (case-insensitive)
  static const List<String> keybindSections = [
    'keyswap',
    'keyup',
    'keydown',
    'keyleft',
    'keyright',
    'keypress',
    'keybind',
    'keybinds',
    'hotkey',
    'hotkeys',
  ];

  /// Парсить INI файл і повертає список keybinds
  /// Шукає секції, що містять в назві ключові слова для keybinds
  Future<List<KeybindInfo>> parseIniFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return [];
      }

      final lines = await file.readAsLines();
      final keybinds = <KeybindInfo>[];
      String? currentSection;
      final currentKeys = <String, String>{};

      for (var line in lines) {
        // Видаляємо пробіли на початку та в кінці
        line = line.trim();

        // Пропускаємо порожні рядки та коментарі
        if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
          continue;
        }

        // Перевіряємо чи це секція
        final sectionMatch = _sectionRegex.firstMatch(line);
        if (sectionMatch != null) {
          // Зберігаємо попередню секцію якщо вона була keybind-секцією
          if (currentSection != null && _isKeybindSection(currentSection)) {
            if (currentKeys.isNotEmpty) {
              keybinds.add(KeybindInfo(
                section: currentSection,
                keys: Map.from(currentKeys),
              ));
              currentKeys.clear();
            }
          }

          // Починаємо нову секцію
          currentSection = sectionMatch.group(1);
          continue;
        }

        // Перевіряємо чи це пара ключ=значення
        final keyValueMatch = _keyValueRegex.firstMatch(line);
        if (keyValueMatch != null && currentSection != null) {
          final key = keyValueMatch.group(1)?.trim() ?? '';
          final value = keyValueMatch.group(2)?.trim() ?? '';
          
          if (key.isNotEmpty) {
            currentKeys[key] = value;
          }
        }
      }

      // Зберігаємо останню секцію якщо вона була keybind-секцією
      if (currentSection != null && _isKeybindSection(currentSection)) {
        if (currentKeys.isNotEmpty) {
          keybinds.add(KeybindInfo(
            section: currentSection,
            keys: Map.from(currentKeys),
          ));
        }
      }

      return keybinds;
    } catch (e) {
      _log.warning('could not parse an .ini',
          error: e, fields: {'file': filePath});
      return [];
    }
  }

  /// Перевіряє чи є секція keybind-секцією
  /// Ловить всі секції що починаються з "Key" або містять ключові слова
  bool _isKeybindSection(String sectionName) {
    final lowerSection = sectionName.toLowerCase();
    // Перевіряємо чи секція починається з "key" (наприклад [KeyHair], [KeyLegs])
    if (lowerSection.startsWith('key')) {
      return true;
    }
    // Або містить ключові слова
    return keybindSections.any((keyword) => lowerSection.contains(keyword));
  }

  /// The `.ini` files ZZMI loads from a mod folder, as full paths, sorted by
  /// their path inside it so the keys and the file Change keys writes to are
  /// the same on every scan. Empty when the folder cannot be read.
  Future<List<String>> findIniFiles(String directoryPath) async {
    try {
      return await listLoadedIniFiles(directoryPath);
    } catch (e) {
      return [];
    }
  }

  /// [findIniFiles], but throws when the folder is missing or cannot be
  /// listed, for a caller that must tell "no `.ini` files" from "could not look".
  static Future<List<String>> listLoadedIniFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      throw PathNotFoundException(directoryPath, const OSError('mod folder not found'));
    }

    final found = <({String relative, String path})>[];
    await for (final entity in dir.list(recursive: true)) {
      // Most of a mod is textures and buffers, so the name is checked before the path is split.
      if (entity is! File || !entity.path.toLowerCase().endsWith('.ini')) continue;
      final segments = p.split(p.relative(entity.path, from: directoryPath));
      if (!_isLoadedIni(segments)) continue;
      found.add((relative: segments.join('/'), path: entity.path));
    }
    found.sort((a, b) => a.relative.compareTo(b.relative));
    return [for (final file in found) file.path];
  }

  /// Whether ZZMI loads the file at [segments] below a mod folder.
  ///
  /// ZZMI's `d3dx.ini` sets `exclude_recursive = DISABLED*`, which skips every
  /// file and folder whose name starts with `DISABLED` in any letter case, and
  /// `desktop.ini` is Windows' folder settings, never a mod's. The app's own
  /// folder holds no part of the mod.
  static bool _isLoadedIni(List<String> segments) {
    final name = segments.last.toLowerCase();
    if (!name.endsWith('.ini') || name == 'desktop.ini') return false;
    if (segments.first == AppConstants.modMetadataDirName) return false;
    return !segments.any((segment) => segment.toLowerCase().startsWith('disabled'));
  }

  /// The keybinds of [iniFiles], in their order, for a caller that has already listed the folder.
  Future<List<KeybindInfo>> parseIniFiles(List<String> iniFiles) async => [
        for (final iniFile in iniFiles) ...await parseIniFile(iniFile),
      ];

  /// Парсить всі INI файли в директорії персонажа
  /// Повертає об'єкт CharacterKeybinds з усіма знайденими keybinds
  Future<CharacterKeybinds?> parseCharacterDirectory(
    String characterId,
    String directoryPath,
  ) async {
    try {
      final iniFiles = await findIniFiles(directoryPath);
      if (iniFiles.isEmpty) {
        return null;
      }

      final allKeybinds = await parseIniFiles(iniFiles);

      if (allKeybinds.isEmpty) {
        return null;
      }

      return CharacterKeybinds(
        characterId: characterId,
        keybinds: allKeybinds,
        iniFilePath: iniFiles.first, // Зберігаємо шлях до першого знайденого файлу
      );
    } catch (e) {
      _log.warning('could not scan a folder for .ini files',
          error: e, fields: {'folder': directoryPath});
      return null;
    }
  }
}
