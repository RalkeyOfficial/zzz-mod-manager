import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../models/keybind_info.dart';
import 'ini_key_editor.dart';
import 'log/logger.dart';

final Logger _log = Logger('ini');

/// Крос-платформний сервіс для парсингу INI файлів
/// Працює як на Windows, так і на Linux
class IniParserService {
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
  ///
  /// [modFolder], when given, is what each section's [KeybindInfo.file] is made relative to. A section's
  /// [KeybindInfo.occurrence] counts every section header of its name in the file, key sections or not, so it names
  /// the same section the key editor finds.
  Future<List<KeybindInfo>> parseIniFile(String filePath, {String? modFolder}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return [];
      }

      final relative = modFolder == null ? null : p.posix.joinAll(p.split(p.relative(filePath, from: modFolder)));
      final lines = await file.readAsLines();
      final keybinds = <KeybindInfo>[];
      final seen = <String, int>{};
      String? currentSection;
      var currentOccurrence = 0;
      final currentKeys = <String, String>{};

      void finishSection() {
        final section = currentSection;
        if (section != null && currentKeys.isNotEmpty && _isKeybindSection(section)) {
          keybinds.add(KeybindInfo(
            section: section,
            keys: Map.from(currentKeys),
            file: relative,
            occurrence: currentOccurrence,
          ));
        }
        currentKeys.clear();
      }

      for (var line in lines) {
        // Видаляємо пробіли на початку та в кінці
        line = line.trim();

        // Пропускаємо порожні рядки та коментарі
        if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
          continue;
        }

        // Перевіряємо чи це секція
        final section = IniLine.sectionName(line);
        if (section != null) {
          finishSection();
          currentSection = section;
          currentOccurrence = seen.update(section.toLowerCase(), (n) => n + 1, ifAbsent: () => 0);
          continue;
        }

        // Перевіряємо чи це пара ключ=значення
        final keyValueMatch = _keyValueRegex.firstMatch(line);
        if (keyValueMatch != null && currentSection != null) {
          final key = keyValueMatch.group(1)?.trim() ?? '';
          final value = IniLine.splitComment(keyValueMatch.group(2) ?? '').value;

          if (key.isNotEmpty) {
            currentKeys[key] = value;
          }
        }
      }

      // Зберігаємо останню секцію якщо вона була keybind-секцією
      finishSection();

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

  /// The keybinds of [iniFiles], in their order, for a caller that has already listed the folder. [modFolder] makes
  /// each section's file relative to it.
  Future<List<KeybindInfo>> parseIniFiles(List<String> iniFiles, {String? modFolder}) async => [
        for (final iniFile in iniFiles) ...await parseIniFile(iniFile, modFolder: modFolder),
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

      final allKeybinds = await parseIniFiles(iniFiles, modFolder: directoryPath);

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
