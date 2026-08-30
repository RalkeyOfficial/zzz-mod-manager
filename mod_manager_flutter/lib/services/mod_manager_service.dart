import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/character_info.dart';
import '../models/mod_origin.dart';
import '../models/mod_origin_seed.dart';
import '../models/keybind_info.dart';
import '../utils/shipped_preview.dart';
import '../utils/state_providers.dart';
import '../utils/zzz_characters.dart';
import 'config_service.dart';
import 'gamebanana/remote_mod_metadata.dart';
import 'ingest_origin_builder.dart';
import 'metadata_autofill.dart';
import 'mod_metadata_repository.dart';
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
  final ModMetadataRepository _metadata;

  /// Builds origin blocks at ingest. Pure and injectable so the group/mode
  /// decisions are testable without a configured library.
  final IngestOriginBuilder _originBuilder = IngestOriginBuilder();

  /// Parsed keybinds cached per mod id. Keybinds only change when the user
  /// edits one (or edits the .ini externally), so caching avoids re-parsing
  /// every mod's .ini files on every reload — a metadata edit no longer pays
  /// for a full keybind rescan. Invalidated per-mod on keybind edits and
  /// cleared wholesale on a manual refresh.
  final Map<String, List<KeybindInfo>> _keybindCache = {};

  ModManagerService(this._configService, this._container)
      : _platformService = PlatformServiceFactory.getInstance(),
        _iniParser = IniParserService(),
        // modsPath is read through a closure, not captured by value: the user
        // can repoint the library in Settings at any time.
        _metadata = ModMetadataRepository(
          _configService,
          modsPath: () => _configService.modsPath,
        );

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

      // Очищуємо символічні посилання на неіснуючі моди. Reuse the scan above
      // instead of enumerating the mods dir a second time.
      await _cleanupInvalidLinks(modNames);

      // Resolve every mod concurrently — each mod's work (link stat, sidecar
      // read, image existence checks) is independent I/O, so a serial loop
      // over N mods was the main cost of the post-action rescan.
      modsInfo.addAll(
        await Future.wait(
          modNames.map((modName) => _buildModInfo(modName, favoriteSet)),
        ),
      );

      return modsInfo;
    } catch (e) {
      return [];
    }
  }

  /// Builds a single [ModInfo] from disk (active state, metadata sidecar,
  /// gallery/preview image). Factored out of [getModsInfo] so the whole set can
  /// be resolved with `Future.wait`.
  Future<ModInfo> _buildModInfo(String modName, Set<String> favoriteSet) async {
    final isActive = await isModActive(modName);
    final modFolder = path.join(modsPath!, modName);

    // Load the in-folder metadata sidecar, migrating legacy storage
    // (config char tag + app-data image) into it on first encounter.
    final metadata = await _metadata.loadOrMigrate(modName, modFolder);

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
          : (_configService.modCharacterTags[modName] ?? unknownCharacterId),
    );

    return ModInfo(
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
      // The sidecar was already read and parsed above, so carrying the origin
      // block into the runtime view costs nothing. It is read-only there: the
      // save path rebuilds the sidecar from the copy on disk, never from here.
      origin: metadata.origin,
    );
  }

  /// Persists editable metadata for a mod into its in-folder sidecar.
  /// The rules live in [ModMetadataRepository]; this is the public entry point.
  Future<bool> saveModMetadata(ModInfo mod) => _metadata.save(mod);

  /// Sets a mod's character assignment in the in-folder sidecar (rename-safe),
  /// and mirrors it into config.json for backward compatibility.
  Future<bool> setModCharacter(String modName, String characterId) =>
      _metadata.setCharacter(modName, characterId);

  /// Fills the blanks in freshly-installed mods' metadata from the mod page they
  /// came from. Rules and I/O both live in [ModMetadataRepository]; this is the
  /// public entry point, like [saveModMetadata].
  ///
  /// A folder it could not write joins [takeOriginWriteFailures] rather than
  /// getting a report of its own. Both writes target the same sidecar, so the
  /// usual case is that both fail and one message covers them — and a second
  /// card naming the same read-only folder is the noise this avoids.
  Future<RemoteMetadataFill> applyRemoteMetadata(
    Iterable<String> modNames,
    RemoteModMetadata remote,
  ) async {
    final fill = await _metadata.applyRemoteMetadata(modNames, remote);
    _originWriteFailures.addAll(fill.unwritable);
    return fill;
  }

  /// Amends an existing mod's origin block — the resolve dialog's write path.
  /// Rules and re-read-before-write both live in [ModMetadataRepository].
  Future<bool> updateModOrigin(
    String modName,
    ModOrigin? Function(ModOrigin? current) update,
  ) =>
      _metadata.updateOrigin(modName, update);

  /// The oldest file mtime inside a mod folder, as an install-date proxy for a
  /// mod that has no recorded install date. See [ModMetadataRepository].
  Future<DateTime?> installDateProxy(String modName) =>
      _metadata.installDateProxy(modName);

  ModMetadataService get metadataService => _metadata.service;

  /// Видаляє символічні посилання на моди, які більше не існують
  Future<void> _cleanupInvalidLinks(List<String> modNames) async {
    try {
      if (saveModsPath == null) return;

      final saveModsDir = Directory(saveModsPath!);
      if (!await saveModsDir.exists()) return;

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

  /// The author-shipped preview image (`Preview.png`, …) for a mod, if any.
  ///
  /// Shared with the marketplace metadata autofill through
  /// [findShippedPreview] — both need the same answer, and the autofill needs it
  /// so a remote gallery never displaces an author's own preview.
  Future<String?> _findModImage(String modName) async {
    try {
      return await findShippedPreview(path.join(modsPath!, modName));
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
  /// [originSeeds] maps a **source folder path** to what the caller knew about
  /// where it came from, in the same shape as [detectionHints] and for the same
  /// reason: one call can mix folders from several archives with folders the
  /// user dragged in, so provenance has to be per-folder rather than per-call.
  /// [knownCharacters] maps a source folder path to a character the caller was
  /// **told**, rather than one to guess at — in practice the mod page's own
  /// category. It replaces name detection for that folder instead of feeding
  /// it: guessing from a name is what this exists to avoid, and the two
  /// genuinely disagree (a Zhao skin named "Zhao Nicole" reads as Nicole,
  /// because the longest matching term wins). Same map shape as the two above,
  /// for the same reason. An unassigned value falls back to detection, so a mod
  /// filed under a non-character category still gets its name read.
  Future<(List<String>, Map<String, String>)> importMods(
    List<String> folderPaths, {
    Map<String, String>? detectionHints,
    Map<String, ModOriginSeed>? originSeeds,
    Map<String, String>? knownCharacters,
  }) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) return (<String>[], <String, String>{});

      final importedMods = <String>[];
      final autoTags = <String, String>{};
      // Kept so the origin pass below can name the folder each mod came out of.
      final sourceOf = <String, String>{};
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
        sourceOf[modName] = folderPath;

        // Автоматично визначаємо тег персонажа і одразу зберігаємо його в
        // sidecar (+ config mirror), щоб завантажені моди отримали постійну
        // категорію, яка переживає перейменування — а не лише косметичне
        // визначення під час відображення.
        final hint = detectionHints?[folderPath];
        final known = knownCharacters?[folderPath];
        final detectedChar = isUnassignedCharacterId(known)
            ? _detectCharacterFromName(
                modName,
                extraNames: [if (hint != null && hint.isNotEmpty) hint],
              )
            : known;
        if (detectedChar != null) {
          await setModCharacter(modName, detectedChar);
          autoTags[modName] = detectedChar;
        }
      }

      // After the copy loop, deliberately: duplicates are skipped above, so
      // generating a group id up front would leave a stale group-of-one behind
      // whenever N-1 folders already existed.
      final group = _originBuilder.siblingGroupFor(importedMods.length);
      for (final modName in importedMods) {
        final seed = originSeeds?[sourceOf[modName]];
        if (seed == null) continue;
        await _recordOrigin(
          modName,
          _originBuilder.separate(
            seed: seed,
            sourceFolder: sourceOf[modName]!,
            siblingGroup: group,
          ),
        );
      }

      return (importedMods, autoTags);
    } catch (e) {
      return (<String>[], <String, String>{});
    }
  }

  /// Mods whose origin block could not be written, drained by the UI.
  ///
  /// Draining is what makes the report happen **once**: nothing re-attempts the
  /// write, because origin is recorded at ingest and never during a scan, so a
  /// failure that stayed in this list would have no second chance to be shown.
  final List<String> _originWriteFailures = [];

  /// Deduplicated: the origin write and the autofill target the same sidecar,
  /// so one read-only folder lands here twice and must be named once.
  List<String> takeOriginWriteFailures() {
    final failures = _originWriteFailures.toSet().toList();
    _originWriteFailures.clear();
    return failures;
  }

  /// The same question for the **scan-time backfill**, which has its own
  /// failures because it writes from a different place. Rules and I/O live in
  /// [ModMetadataRepository]; this is the public entry point.
  List<String> takeBackfillWriteFailures() =>
      _metadata.takeBackfillWriteFailures();

  Future<void> _recordOrigin(String modName, ModOrigin origin) async {
    final ok = await _metadata.recordOrigin(modName, origin);
    if (!ok) {
      print('ModManagerService: could not record origin for $modName');
      _originWriteFailures.add(modName);
    }
  }

  /// Installs [folderPaths] as subfolders of a single new mod named [modName]
  /// (e.g. a mod plus a dependency folder that must sit beside it). The whole
  /// `<modName>` folder is what gets activated. Returns ([modName] on success,
  /// otherwise the empty list, plus any auto-detected character tag) — the same
  /// shape as [importMods] so callers can share result handling.
  ///
  /// [origin] describes where the merged folders came from. Scalar rather than
  /// a map because this produces exactly one mod — and for the same reason it
  /// never carries a sibling group. [knownCharacter] is the same fact
  /// `importMods` takes per folder: a character the caller was told rather than
  /// one to guess at, replacing name detection when it is set.
  Future<(List<String>, Map<String, String>)> importCombinedMod(
    List<String> folderPaths,
    String modName, {
    String? detectionHint,
    ModOriginSeed? origin,
    String? knownCharacter,
  }) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) return (<String>[], <String, String>{});

      final modsDir = Directory(modsPath!);
      if (!await modsDir.exists()) {
        await modsDir.create(recursive: true);
      }

      final targetPath = path.join(modsPath!, modName);
      final targetDir = Directory(targetPath);
      // Existing mod with this name — treat as a duplicate (nothing installed).
      if (await targetDir.exists()) {
        return (<String>[], <String, String>{});
      }
      await targetDir.create(recursive: true);

      var copied = 0;
      final copiedFolders = <String>[];
      for (final folderPath in folderPaths) {
        final sourceDir = Directory(folderPath);
        if (!await sourceDir.exists()) continue;
        await _copyDirectory(
          sourceDir,
          Directory(path.join(targetPath, path.basename(folderPath))),
        );
        copiedFolders.add(folderPath);
        copied++;
      }

      // Nothing usable was copied — roll back the empty mod folder.
      if (copied == 0) {
        try {
          await targetDir.delete(recursive: true);
        } catch (_) {}
        return (<String>[], <String, String>{});
      }

      if (origin != null) {
        await _recordOrigin(
          modName,
          _originBuilder.combined(seed: origin, sourceFolders: copiedFolders),
        );
      }

      final autoTags = <String, String>{};
      final detectedChar = isUnassignedCharacterId(knownCharacter)
          ? _detectCharacterFromName(
              modName,
              extraNames: [
                if (detectionHint != null && detectionHint.isNotEmpty)
                  detectionHint,
              ],
            )
          : knownCharacter;
      if (detectedChar != null) {
        await setModCharacter(modName, detectedChar);
        autoTags[modName] = detectedChar;
      }

      return (<String>[modName], autoTags);
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
        final existingMeta = await _metadata.read(modFolder);
        final existingTag = (existingMeta?.characterId != null && existingMeta!.characterId!.isNotEmpty)
            ? existingMeta.characterId
            : _configService.modCharacterTags[modName];
        if (!isUnassignedCharacterId(existingTag)) {
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
      // Warm the cache for every distinct mod once, concurrently. A mod can
      // appear in several groups (Favorites / ALL / its character); parsing
      // each unique folder's .ini files in parallel — rather than serially per
      // skin occurrence — is what keeps the enrich step off the critical path.
      final uniqueIds = <String>{
        for (final character in characters)
          for (final mod in character.skins) mod.id,
      };
      await Future.wait(uniqueIds.map(getModKeybinds));

      final updatedCharacters = <CharacterInfo>[];
      for (final character in characters) {
        final updatedMods = <ModInfo>[];
        for (final mod in character.skins) {
          // Cache hit after the warm-up above.
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
