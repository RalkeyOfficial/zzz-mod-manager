import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import '../models/keybind_info.dart';
import '../models/mod_metadata.dart';
import '../core/constants.dart';
import '../utils/path_helper.dart';
import '../utils/state_providers.dart';
import '../utils/zzz_characters.dart';
import 'config_service.dart';
import 'mod_metadata_service.dart';
import 'platform_service.dart';
import 'platform_service_factory.dart';
import 'ini_parser_service.dart';

/// Головний сервіс для керування модами через symbolic links
class ModManagerService {
  final ConfigService _configService;
  final PlatformService _platformService;
  final ProviderContainer _container;
  final IniParserService _iniParser;
  final ModMetadataService _metadataService;

  /// Parsed keybinds cached per mod id. Keybinds only change when the user
  /// edits one (or edits the .ini externally), so caching avoids re-parsing
  /// every mod's .ini files on every reload — a metadata edit no longer pays
  /// for a full keybind rescan. Invalidated per-mod on keybind edits and
  /// cleared wholesale on a manual refresh.
  final Map<String, List<KeybindInfo>> _keybindCache = {};

  ModManagerService(this._configService, this._container)
      : _platformService = PlatformServiceFactory.getInstance(),
        _iniParser = IniParserService(),
        _metadataService = ModMetadataService();

  String? get modsPath => _configService.modsPath;
  String? get saveModsPath => _configService.saveModsPath;

  Future<(bool, String)> validatePaths() async {
    final mods = modsPath;
    final saveMods = saveModsPath;

    if (mods == null || mods.isEmpty || saveMods == null || saveMods.isEmpty) {
      return (false, 'Шляхи не налаштовані. Будь ласка, налаштуйте їх у Налаштуваннях.');
    }

    final modsDir = Directory(mods);
    if (!await modsDir.exists()) {
      return (false, 'Папка з модами не існує: $mods');
    }

    final saveModsDir = Directory(saveMods);
    if (await saveModsDir.exists()) {
      final stat = await saveModsDir.stat();
      if (stat.type != FileSystemEntityType.directory) {
        return (false, 'Шлях для links існує але не є папкою: $saveMods');
      }
    }

    return (true, '');
  }

  Future<List<String>> scanMods() async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) return [];

      final modsDir = Directory(modsPath!);
      if (!await modsDir.exists()) return [];

      final mods = <String>[];
      await for (final entity in modsDir.list()) {
        if (entity is Directory) {
          final name = path.basename(entity.path);
          if (!name.startsWith('.') && !name.startsWith('__')) {
            mods.add(name);
          }
        }
      }

      return mods;
    } catch (e) {
      return [];
    }
  }

  Future<List<ModInfo>> getModsInfo() async {
    try {
      final modNames = await scanMods();
      final modsInfo = <ModInfo>[];
      final favoriteSet = _configService.favoriteMods.toSet();

      // Очищуємо символічні посилання на неіснуючі моди
      await _cleanupInvalidLinks();

      for (final modName in modNames) {
        final isActive = await isModActive(modName);
        final modFolder = path.join(modsPath!, modName);

        // Load the in-folder metadata sidecar, migrating legacy storage
        // (config char tag + app-data image) into it on first encounter.
        final metadata = await _loadOrMigrateMetadata(modName, modFolder);

        // Resolve the gallery to absolute paths, dropping any that no longer
        // exist. Fall back to a shipped preview image (Preview.png, etc.).
        final images = <String>[];
        for (final rel in metadata.images) {
          final abs = path.join(modFolder, rel);
          if (await File(abs).exists()) images.add(abs);
        }
        if (images.isEmpty) {
          final preview = await _findModImage(modName);
          if (preview != null) images.add(preview);
        }

        final characterId = canonicalCharacterId(
          (metadata.characterId != null && metadata.characterId!.isNotEmpty)
              ? metadata.characterId!
              : (_configService.modCharacterTags[modName] ?? 'unknown'),
        );

        modsInfo.add(
          ModInfo(
            id: modName,
            name: modName,
            characterId: characterId,
            isActive: isActive,
            imagePath: images.isNotEmpty ? images.first : null,
            description: metadata.description,
            sourceUrl: metadata.sourceUrl,
            tags: metadata.tags,
            images: images,
            isFavorite: favoriteSet.contains(modName),
          ),
        );
      }

      return modsInfo;
    } catch (e) {
      return [];
    }
  }

  /// Loads a mod's metadata sidecar. If none exists yet, migrates legacy
  /// storage (character tag from config.json, pasted image from the app-data
  /// `mod_images/` dir) into the mod folder and writes the sidecar once.
  /// Best-effort: if the folder can't be written, returns the resolved values
  /// in memory so the app still works.
  Future<ModMetadata> _loadOrMigrateMetadata(String modName, String modFolder) async {
    final existing = await _metadataService.read(modFolder);
    if (existing != null) return existing;

    // No sidecar yet — gather legacy data to migrate.
    final legacyChar = _configService.modCharacterTags[modName];
    String? migratedImageRel;
    try {
      final legacyImage = File(path.join(PathHelper.getModImagesPath(), '$modName.png'));
      if (await legacyImage.exists()) {
        migratedImageRel = await _metadataService.importImageFile(modFolder, legacyImage.path);
      }
    } catch (e) {
      // Ignore: app-data image is optional.
    }

    final hasLegacyData = (legacyChar != null && legacyChar.isNotEmpty) || migratedImageRel != null;
    final metadata = ModMetadata(
      characterId: legacyChar,
      images: migratedImageRel != null ? [migratedImageRel] : const [],
    );

    // Only persist when there is something to preserve, so we don't litter
    // every mod folder with empty sidecars.
    if (hasLegacyData) {
      await _metadataService.write(modFolder, metadata);
    }
    return metadata;
  }

  /// Persists editable metadata for a mod into its in-folder sidecar. Image
  /// paths on [mod] that live inside the mod folder are stored relative; paths
  /// outside it are ignored (use [ModMetadataService.importImageFile] first).
  Future<bool> saveModMetadata(ModInfo mod) async {
    try {
      if (modsPath == null) return false;
      final modFolder = path.join(modsPath!, mod.id);

      final relImages = <String>[];
      for (final abs in mod.images) {
        final rel = path.relative(abs, from: modFolder);
        if (!rel.startsWith('..') && !path.isAbsolute(rel)) relImages.add(rel);
      }

      // Build the sidecar directly from the mod so emptied fields (e.g. a
      // cleared URL) are actually removed, rather than copyWith keeping the old
      // value. ModInfo carries every metadata field, so this is a full save.
      final existing = await _metadataService.read(modFolder);
      String? orNull(String? v) => (v == null || v.isEmpty) ? null : v;
      final metadata = ModMetadata(
        schemaVersion: existing?.schemaVersion ?? ModMetadata.currentSchemaVersion,
        description: orNull(mod.description),
        sourceUrl: orNull(mod.sourceUrl),
        tags: mod.tags,
        characterId: (mod.characterId.isEmpty || mod.characterId == 'unknown')
            ? null
            : mod.characterId,
        images: relImages,
      );
      return await _metadataService.write(modFolder, metadata);
    } catch (e) {
      print('ModManagerService: failed to save metadata for ${mod.id}: $e');
      return false;
    }
  }

  /// Sets a mod's character assignment in the in-folder sidecar (rename-safe),
  /// and mirrors it into config.json for backward compatibility.
  Future<bool> setModCharacter(String modName, String characterId) async {
    try {
      // Keep the legacy config copy in sync so older code paths still work.
      await _configService.setModCharacterTag(modName, characterId);

      if (modsPath == null) return false;
      final modFolder = path.join(modsPath!, modName);
      final existing = await _metadataService.read(modFolder) ?? const ModMetadata();
      return await _metadataService.write(
        modFolder,
        existing.copyWith(characterId: characterId),
      );
    } catch (e) {
      print('ModManagerService: failed to set character for $modName: $e');
      return false;
    }
  }

  ModMetadataService get metadataService => _metadataService;

  /// Видаляє символічні посилання на моди, які більше не існують
  Future<void> _cleanupInvalidLinks() async {
    try {
      if (saveModsPath == null) return;

      final saveModsDir = Directory(saveModsPath!);
      if (!await saveModsDir.exists()) return;

      final modNames = await scanMods();
      final validModNames = Set<String>.from(modNames);

      await for (final entity in saveModsDir.list()) {
        if (entity is Link) {
          final linkName = path.basename(entity.path);
          
          // Якщо мод більше не існує в папці модів - видаляємо символічне посилання
          if (!validModNames.contains(linkName)) {
            try {
              await entity.delete();
              await _configService.removeActiveMod(linkName);
            } catch (e) {
              // Ігноруємо помилки при видаленні
            }
          }
        }
      }
    } catch (e) {
      // Ігноруємо помилки
    }
  }

  Future<bool> isModActive(String modName) async {
    try {
      if (saveModsPath == null) return false;

      final linkPath = path.join(saveModsPath!, modName);
      final exists = await FileSystemEntity.type(linkPath) != FileSystemEntityType.notFound;
      if (!exists) return false;

      // Використовуємо platformService для перевірки
      return await _platformService.isModLink(linkPath);
    } catch (e) {
      return false;
    }
  }

  Future<bool> activateMod(String modName) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) return false;

      final srcPath = path.join(modsPath!, modName);
      final dstPath = path.join(saveModsPath!, modName);

      final srcDir = Directory(srcPath);
      if (!await srcDir.exists()) return false;

      final saveModsDir = Directory(saveModsPath!);
      if (!await saveModsDir.exists()) {
        await saveModsDir.create(recursive: true);
      }

      // Використовуємо platformService для створення link
      final success = await _platformService.createModLink(srcPath, dstPath);
      if (!success) {
        print('ModManagerService: Не вдалося створити link для $modName');
        return false;
      }

      await _configService.addActiveMod(modName);

      // Автоматично перезавантажуємо моди після активації (якщо увімкнено)
      final autoF10Enabled = _container.read(autoF10ReloadProvider);
      if (autoF10Enabled) {
        await _platformService.sendF10ToGame();
      }

      return true;
    } catch (e) {
      print('ModManagerService: Помилка активації мода: $e');
      return false;
    }
  }

  Future<bool> deactivateMod(String modName) async {
    try {
      if (saveModsPath == null) return false;

      final linkPath = path.join(saveModsPath!, modName);
      final exists = await FileSystemEntity.type(linkPath) != FileSystemEntityType.notFound;
      if (!exists) return false;

      // Використовуємо platformService для видалення link
      final success = await _platformService.removeModLink(linkPath);
      if (!success) {
        print('ModManagerService: Не вдалося видалити link для $modName');
        return false;
      }

      await _configService.removeActiveMod(modName);

      // Автоматично перезавантажуємо моди після деактивації (якщо увімкнено)
      final autoF10Enabled = _container.read(autoF10ReloadProvider);
      if (autoF10Enabled) {
        await _platformService.sendF10ToGame();
      }

      return true;
    } catch (e) {
      print('ModManagerService: Помилка деактивації мода: $e');
      return false;
    }
  }

  Future<bool> toggleMod(String modName) async {
    final isActive = await isModActive(modName);
    return isActive ? await deactivateMod(modName) : await activateMod(modName);
  }

  /// Renames a mod's folder and migrates everything keyed to its name: the
  /// active symlink (if active) and the per-mod config (active/favorite/tag).
  /// The in-folder metadata travels with the folder, so it needs no migration.
  /// Returns false on collision or any failure.
  Future<bool> renameMod(String oldName, String newName) async {
    try {
      if (modsPath == null) return false;
      if (newName == oldName) return true;

      final oldDir = Directory(path.join(modsPath!, oldName));
      if (!await oldDir.exists()) return false;

      final newPath = path.join(modsPath!, newName);
      if (await FileSystemEntity.type(newPath) !=
          FileSystemEntityType.notFound) {
        return false; // a file/folder with the new name already exists
      }

      final wasActive = await isModActive(oldName);
      // Remove the old link first so renaming the source folder doesn't leave a
      // dangling link in the game's mods folder.
      if (wasActive && saveModsPath != null) {
        await _platformService.removeModLink(
          path.join(saveModsPath!, oldName),
        );
      }

      await oldDir.rename(newPath);

      if (wasActive && saveModsPath != null) {
        await _platformService.createModLink(
          newPath,
          path.join(saveModsPath!, newName),
        );
      }

      await _configService.migrateModName(oldName, newName);
      invalidateKeybinds(oldName);
      return true;
    } catch (e) {
      print('ModManagerService: Помилка перейменування мода "$oldName": $e');
      return false;
    }
  }

  /// Permanently deletes a mod: removes its active link (if any), deletes the
  /// on-disk folder with all its files, and clears its config state
  /// (active/favorite/category). The in-folder metadata is destroyed with the
  /// folder. Returns false if the mod folder is missing or on any failure.
  Future<bool> deleteMod(String modName) async {
    try {
      if (modsPath == null) return false;

      final modDir = Directory(path.join(modsPath!, modName));
      if (!await modDir.exists()) return false;

      // Remove the active link first so we don't leave a dangling link in the
      // game's mods folder once the source folder is gone.
      if (saveModsPath != null && await isModActive(modName)) {
        await _platformService.removeModLink(
          path.join(saveModsPath!, modName),
        );
      }

      await modDir.delete(recursive: true);

      await _configService.removeActiveMod(modName);
      await _configService.removeFavoriteMod(modName);
      await _configService.removeModCharacterTag(modName);
      invalidateKeybinds(modName);
      return true;
    } catch (e) {
      print('ModManagerService: Помилка видалення мода "$modName": $e');
      return false;
    }
  }

  /// Opens a mod's folder in the system file manager. Returns false if the mod
  /// folder is missing or the file manager could not be launched.
  Future<bool> openModFolder(String modName) async {
    if (modsPath == null) return false;
    final modDir = Directory(path.join(modsPath!, modName));
    if (!await modDir.exists()) return false;
    return await _platformService.openFolderInFileManager(modDir.path);
  }

  Future<String?> _findModImage(String modName) async {
    try {
      final modPath = path.join(modsPath!, modName);
      final modDir = Directory(modPath);
      if (!await modDir.exists()) return null;

      for (final imageName in AppConstants.imageFileNames) {
        final imagePath = path.join(modPath, imageName);
        final imageFile = File(imagePath);
        if (await imageFile.exists()) return imagePath;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Ручне перезавантаження модів (натискання F10)
  Future<bool> reloadMods() async {
    return await _platformService.sendF10ToGame();
  }

  /// Показує інструкції налаштування F10 сервісу
  void showF10SetupInstructions() {
    _platformService.showSetupInstructions();
  }

  /// Встановлює залежності для F10 сервісу
  Future<void> installF10Dependencies() async {
    await _platformService.checkDependencies();
  }

  Future<void> _safeRemove(String filePath) async {
    try {
      // Використовуємо platformService для видалення links
      final isLink = await _platformService.isModLink(filePath);
      
      if (isLink) {
        await _platformService.removeModLink(filePath);
        return;
      }
      
      // Якщо це не link, видаляємо звичайним способом
      final entity = await FileSystemEntity.type(filePath);
      if (entity == FileSystemEntityType.directory) {
        await Directory(filePath).delete(recursive: true);
      } else if (entity == FileSystemEntityType.file) {
        await File(filePath).delete();
      }
    } catch (e) {
      print('ModManagerService: Помилка _safeRemove: $e');
    }
  }

  /// Імпортує нові моди з вказаних папок
  /// Повертає список імпортованих модів та їх автоматично визначених тегів персонажів.
  ///
  /// [detectionHints] зіставляє шлях вихідної папки з додатковою назвою для
  /// визначення персонажа (зазвичай — ім'я архіву, з якого розпаковано папку).
  /// Часто персонаж є в імені .zip/.rar, а не у внутрішній папці (або навпаки),
  /// тож скануємо обидві назви.
  Future<(List<String>, Map<String, String>)> importMods(
    List<String> folderPaths, {
    Map<String, String>? detectionHints,
  }) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) return (<String>[], <String, String>{});

      final importedMods = <String>[];
      final autoTags = <String, String>{};
      final modsDir = Directory(modsPath!);

      if (!await modsDir.exists()) {
        await modsDir.create(recursive: true);
      }

      for (final folderPath in folderPaths) {
        final sourceDir = Directory(folderPath);
        if (!await sourceDir.exists()) continue;

        final modName = path.basename(folderPath);
        final targetPath = path.join(modsPath!, modName);
        final targetDir = Directory(targetPath);

        // Якщо мод вже існує, пропускаємо
        if (await targetDir.exists()) {
          continue;
        }

        // Копіюємо папку з модом
        await _copyDirectory(sourceDir, targetDir);
        importedMods.add(modName);

        // Автоматично визначаємо тег персонажа і одразу зберігаємо його в
        // sidecar (+ config mirror), щоб завантажені моди отримали постійну
        // категорію, яка переживає перейменування — а не лише косметичне
        // визначення під час відображення.
        final hint = detectionHints?[folderPath];
        final detectedChar = _detectCharacterFromName(
          modName,
          extraNames: [if (hint != null && hint.isNotEmpty) hint],
        );
        if (detectedChar != null) {
          await setModCharacter(modName, detectedChar);
          autoTags[modName] = detectedChar;
        }
      }

      return (importedMods, autoTags);
    } catch (e) {
      return (<String>[], <String, String>{});
    }
  }

  /// Визначає персонажа за назвами моду — спершу за назвою папки, далі за
  /// [extraNames] (зазвичай ім'я архіву). Раніше метод також сканував вміст
  /// .ini файлів та імена підпапок, але назви персонажів там не стандартизовані
  /// (випадкові коментарі, назви клавіш тощо), тож це давало хибні збіги —
  /// зокрема підрядок "norma" у "NormalMap" чіпляв Норму. Назви файлів/папок —
  /// найнадійніший сигнал, тому визначаємо лише за ними.
  String? _detectCharacterFromName(String modName, {List<String> extraNames = const []}) {
    for (final name in [modName, ...extraNames]) {
      final detected = detectCharacterId(name);
      if (detected != null) return detected;
    }
    print('ModManager: Не вдалося визначити персонажа для "$modName"');
    return null;
  }

  /// Автоматично визначає та встановлює теги для всіх модів
  /// Повертає кількість модів з визначеними тегами
  Future<Map<String, String>> autoTagAllMods() async {
    try {
      final modNames = await scanMods();
      final autoTags = <String, String>{};

      for (final modName in modNames) {
        // Skip mods that already have a character. The in-folder sidecar wins
        // (so a shared mod's tag isn't clobbered), then the legacy config tag.
        final modFolder = path.join(modsPath!, modName);
        final existingMeta = await _metadataService.read(modFolder);
        final existingTag = (existingMeta?.characterId != null && existingMeta!.characterId!.isNotEmpty)
            ? existingMeta.characterId
            : _configService.modCharacterTags[modName];
        if (existingTag != null && existingTag != 'unknown') {
          continue;
        }

        // Автоматично визначаємо тег з назви
        final detectedChar = _detectCharacterFromName(modName);
        if (detectedChar != null) {
          // Writes the in-folder sidecar and mirrors to config.json.
          await setModCharacter(modName, detectedChar);
          autoTags[modName] = detectedChar;
        }
      }

      return autoTags;
    } catch (e) {
      return {};
    }
  }

  /// Рекурсивно копіює директорію
  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    
    await for (final entity in source.list(recursive: false)) {
      if (entity is Directory) {
        final newDirectory = Directory(path.join(
          destination.path,
          path.basename(entity.path),
        ));
        await _copyDirectory(entity, newDirectory);
      } else if (entity is File) {
        final newFile = File(path.join(
          destination.path,
          path.basename(entity.path),
        ));
        await entity.copy(newFile.path);
      }
    }
  }

  /// Зчитує keybinds для конкретного персонажа (моду)
  /// characterId - назва папки персонажа в modsPath
  Future<CharacterKeybinds?> getCharacterKeybinds(String characterId) async {
    try {
      if (modsPath == null) return null;

      final characterPath = path.join(modsPath!, characterId);
      final characterDir = Directory(characterPath);
      
      if (!await characterDir.exists()) return null;

      return await _iniParser.parseCharacterDirectory(characterId, characterPath);
    } catch (e) {
      print('ModManagerService: Помилка зчитування keybinds для $characterId: $e');
      return null;
    }
  }

  /// Зчитує keybinds для всіх персонажів в modsPath
  /// Повертає мапу characterId -> CharacterKeybinds
  Future<Map<String, CharacterKeybinds>> getAllCharactersKeybinds() async {
    try {
      if (modsPath == null) return {};
      
      return await _iniParser.parseAllCharacters(modsPath!);
    } catch (e) {
      print('ModManagerService: Помилка зчитування keybinds для всіх персонажів: $e');
      return {};
    }
  }

  /// Завантажує keybinds для конкретного моду
  /// modId - назва папки моду в modsPath
  Future<List<KeybindInfo>?> getModKeybinds(String modId) async {
    final cached = _keybindCache[modId];
    if (cached != null) return cached;
    try {
      if (modsPath == null) return null;
      final modPath = path.join(modsPath!, modId);
      final keybindsData = await _iniParser.parseCharacterDirectory(modId, modPath);
      // Cache even an empty result so mods without keybinds aren't re-scanned.
      final keybinds = keybindsData?.keybinds ?? <KeybindInfo>[];
      _keybindCache[modId] = keybinds;
      return keybinds;
    } catch (e) {
      return null;
    }
  }

  /// Drops a single mod's cached keybinds (call after editing its .ini).
  void invalidateKeybinds(String modId) => _keybindCache.remove(modId);

  /// Clears all cached keybinds (e.g. on a manual refresh, to pick up .ini
  /// files changed outside the app).
  void clearKeybindCache() => _keybindCache.clear();

  /// Оновлює інформацію про персонажів, додаючи keybinds до модів
  /// Приймає список персонажів і додає keybinds до кожного моду.
  /// Keybinds are cached per mod, so a mod that appears in several groups
  /// (Favorites / ALL / its character) is parsed at most once.
  Future<List<CharacterInfo>> enrichCharactersWithKeybinds(
    List<CharacterInfo> characters,
  ) async {
    try {
      final updatedCharacters = <CharacterInfo>[];

      for (final character in characters) {
        final updatedMods = <ModInfo>[];

        for (final mod in character.skins) {
          final keybinds = await getModKeybinds(mod.id);
          if (keybinds != null && keybinds.isNotEmpty) {
            updatedMods.add(mod.copyWith(keybinds: keybinds));
          } else {
            updatedMods.add(mod);
          }
        }

        updatedCharacters.add(character.copyWith(skins: updatedMods));
      }

      return updatedCharacters;
    } catch (e) {
      return characters;
    }
  }
}
