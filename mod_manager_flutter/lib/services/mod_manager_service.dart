import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/character_info.dart';
import '../models/installed_file.dart';
import '../models/mod_origin.dart';
import 'patch_store.dart';
import '../models/mod_origin_seed.dart';
import '../models/keybind_info.dart';
import '../utils/directory_copy.dart';
import '../utils/directory_size.dart';
import '../utils/shipped_preview.dart';
import '../utils/zzz_characters.dart';
import 'backup/snapshot_service.dart';
import 'config_service.dart';
import 'gamebanana/remote_mod_metadata.dart';
import 'import_result.dart';
import 'ingest_origin_builder.dart';
import 'log/logger.dart';
import 'metadata_autofill.dart';
import 'mod_metadata_repository.dart';
import 'mod_metadata_service.dart';
import 'mod_uid.dart';
import 'origin_write.dart';
import 'platform_service.dart';
import 'platform_service_factory.dart';
import 'ini_parser_service.dart';

/// Головний сервіс для керування модами через symbolic links
final Logger _log = Logger('mods');

/// Anything that changes the filesystem goes under one tag, whoever did it, so
/// "what did this app do to my folders" is a single filter.
final Logger _files = Logger('fileops');

class ModManagerService {
  final ConfigService _configService;
  final PlatformService _platformService;
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

  /// Only for `deleteMod`: a mod's saved versions go when the mod does.
  final SnapshotService _snapshots;
  final ModUid _uids;

  /// Free space on the volume an import is about to write to. Injectable
  /// because the real one spawns a `df`, and a test about refusing an import
  /// cannot fill a disk to ask the question.
  final Future<int?> Function(String path) _freeSpace;

  /// [snapshots] and [uids] are defaulted rather than required because they
  /// need no configuration — one reads the folder's own sidecar, the other is
  /// rooted in app-data. They are parameters at all so `deleteMod` can be
  /// tested without reaching the developer's real `<appData>/backups`.
  ModManagerService(
    this._configService, {
    SnapshotService? snapshots,
    ModUid? uids,
    Future<int?> Function(String path)? freeSpace,
  })  : _snapshots = snapshots ?? SnapshotService(),
        _uids = uids ?? ModUid(),
        _freeSpace =
            freeSpace ?? PlatformServiceFactory.getInstance().freeSpaceBytes,
        _platformService = PlatformServiceFactory.getInstance(),
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

      // Links whose mod folder is missing are left alone: the folder may be on
      // a drive that is not mounted, and the mod is active again once it returns.

      // Resolve every mod concurrently — each mod's work (link stat, sidecar
      // read, image existence checks) is independent I/O, so a serial loop
      // over N mods was the main cost of the post-action rescan.
      modsInfo.addAll(
        await Future.wait(
          modNames.map((modName) => _buildModInfo(modName, favoriteSet)),
        ),
      );

      // **After the scan, which is what makes it decidable.** Every mod has
      // been read by here, so the legacy image dir can be judged against what
      // actually exists rather than against a name.
      await _metadata.sweepLegacyImages(modNames);

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
      tags: metadata.tags,
      images: images,
      isFavorite: favoriteSet.contains(modName),
      // The sidecar was already read and parsed above, so carrying the origin
      // block into the runtime view costs nothing. It is read-only there: the
      // save path rebuilds the sidecar from the copy on disk, never from here.
      origin: metadata.origin,
      // Same rules, and it is what "does this mod have saved versions?" is
      // answered by — one readdir of `<appData>/backups` compared against this,
      // rather than a sidecar read per right-click.
      uid: metadata.uid,
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
  Future<OriginWriteResult> updateModOrigin(
    String modName,
    ModOrigin? Function(ModOrigin? current) update,
  ) =>
      _metadata.updateOrigin(modName, update);

  /// The oldest file mtime inside a mod folder, as an install-date proxy for a
  /// mod that has no recorded install date. See [ModMetadataRepository].
  Future<DateTime?> installDateProxy(String modName) =>
      _metadata.installDateProxy(modName);

  ModMetadataService get metadataService => _metadata.service;

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
        // The platform service already logged why; this says which mod the
        // user was trying to switch on when it happened.
        _log.error('could not activate', fields: {'mod': modName});
        return false;
      }

      await _configService.addActiveMod(modName);

      return true;
    } catch (error, stack) {
      _log.error('could not activate',
          error: error, stack: stack, fields: {'mod': modName});
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
        _log.error('could not deactivate', fields: {'mod': modName});
        return false;
      }

      await _configService.removeActiveMod(modName);

      return true;
    } catch (error, stack) {
      _log.error('could not deactivate',
          error: error, stack: stack, fields: {'mod': modName});
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
    } catch (error, stack) {
      _files.error('rename failed',
          error: error, stack: stack, fields: {'mod': oldName});
      return false;
    }
  }

  /// Permanently deletes a mod: removes its active link (if any), deletes the
  /// on-disk folder with all its files, clears its config state
  /// (active/favorite/category), and **deletes every saved version of it**. The
  /// in-folder metadata is destroyed with the folder. Returns false if the mod
  /// folder is missing or on any failure.
  ///
  /// The saved versions go with the mod deliberately: keeping gigabytes of a
  /// mod the user has just deleted is a surprise, and nothing would ever offer
  /// them again — the rollback list is per mod, and this mod is gone.
  ///
  /// **The identity is read before the folder is touched**, and that ordering is
  /// the whole trick: the uid lives in the sidecar *inside* the folder being
  /// deleted, so reading it afterwards is impossible and the operation meant to
  /// reclaim the space would be the one that orphaned it forever.
  Future<bool> deleteMod(String modName) async {
    try {
      if (modsPath == null) return false;

      final modDir = Directory(path.join(modsPath!, modName));
      if (!await modDir.exists()) return false;

      // **Before anything is removed.** See above: after the delete there is
      // nowhere left to read this from.
      final uid = await _uids.read(modDir);

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

      // **After the folder, and never gating the delete.** The mod is already
      // gone by here, so a group that could not be removed is wasted space
      // rather than a failure to report — and reporting one would tell the user
      // their delete failed when it did not. A mod with no uid never had a
      // saved version to remove.
      if (uid != null) await _snapshots.deleteGroup(uid);
      return true;
    } catch (error, stack) {
      _files.error('delete failed',
          error: error, stack: stack, fields: {'mod': modName});
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
    } catch (error, stack) {
      _files.warning('could not remove',
          error: error, stack: stack, fields: {'path': filePath});
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
  Future<ImportResult> importMods(
    List<String> folderPaths, {
    Map<String, String>? detectionHints,
    Map<String, ModOriginSeed>? originSeeds,
    Map<String, String>? knownCharacters,
  }) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) {
        return const ImportResult.failed(ImportFailure.libraryNotConfigured);
      }

      // Only the folders that will actually be copied: one the library already
      // has is skipped below, so counting it would refuse an import over space
      // nothing was going to use.
      final toCopy = <String>[];
      for (final folderPath in folderPaths) {
        if (!await Directory(folderPath).exists()) continue;
        final target = Directory(path.join(modsPath!, path.basename(folderPath)));
        if (await target.exists()) continue;
        toCopy.add(folderPath);
      }
      final shortfall = await _spaceShortfall(toCopy);
      if (shortfall != null) return shortfall;

      final importedMods = <String>[];
      final autoTags = <String, String>{};
      // Kept so the origin pass below can name the folder each mod came out of.
      final sourceOf = <String, String>{};
      // And what the copy actually laid down, which only the copy knows.
      final writtenBy = <String, List<InstalledFile>>{};
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
        writtenBy[modName] = await copyDirectory(sourceDir, targetDir);
        // The inbound origin block is dropped, so any displaced originals that
        // came with the folder are bytes nothing can explain.
        await const PatchStore().discardAll(targetDir);
        // **An identity from the moment the folder exists**, whatever created
        // it: a folder dragged off a disk has no origin seed and so never
        // reaches the origin write below, and a mod installed and updated in
        // one session must not wait for a scan to be identifiable. A copied
        // sidecar's uid is not inherited — `discardAll` above is the same
        // rule for the same reason, and the inbound block is dropped too.
        await _uids.assign(targetDir);
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
            files: writtenBy[modName] ?? const <InstalledFile>[],
          ),
        );
      }

      return ImportResult(imported: importedMods, autoTags: autoTags);
    } catch (e) {
      _log.error('import failed', error: e);
      return const ImportResult.failed(ImportFailure.copyFailed);
    }
  }

  /// A refusal when the library volume cannot hold [folderPaths], or null to
  /// carry on.
  ///
  /// **The size is measured rather than estimated**: the files are already on
  /// disk in the temp directory the archive was unpacked into, so this is a
  /// walk of what the copy is about to write, to the byte.
  ///
  /// Null covers three unknowns and all of them proceed — nothing to copy, a
  /// size that could not be read, a free space that could not be read. Refusing
  /// an install that would have fitted leaves the user with a mod they cannot
  /// install and nothing to clear.
  Future<ImportResult?> _spaceShortfall(List<String> folderPaths) async {
    if (folderPaths.isEmpty) return null;

    var required = 0;
    for (final folderPath in folderPaths) {
      final size = await _bytesUnder(Directory(folderPath));
      if (size == null) return null;
      required += size;
    }
    if (required <= 0) return null;

    final available = await _freeSpace(modsPath!);
    if (available == null || required <= available) return null;

    _log.warning('refused for space', fields: {
      'required': required,
      'available': available,
      'folders': folderPaths.length,
    });
    return ImportResult.noSpace(
      requiredBytes: required,
      availableBytes: available,
    );
  }

  /// Every byte under [directory], or null if any of it could not be read.
  ///
  /// **A partial answer is null here, not a smaller number.** This decides
  /// whether an import fits, so a total short by one unreadable folder would
  /// approve a copy that then fills the disk — and running out of space partway
  /// through is the failure the preflight exists to avoid. "I don't know" leaves
  /// the check to skip itself, which is the safe way to be wrong.
  Future<int?> _bytesUnder(Directory directory) async {
    final size = await measureDirectory(directory.path);
    if (size.complete) return size.bytes;
    _files.debug('could not size a folder',
        fields: {'path': directory.path, 'unreadable': size.unreadable});
    return null;
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
      _log.warning('could not record where a mod came from',
          fields: {'mod': modName, 'mod_id': origin.base?.modId});
      _originWriteFailures.add(modName);
    }
  }

  /// Installs [folderPaths] as subfolders of a single new mod named [modName]
  /// (e.g. a mod plus a dependency folder that must sit beside it). The whole
  /// `<modName>` folder is what gets activated. Returns the same
  /// [ImportResult] as [importMods] so callers can share result handling.
  ///
  /// [origin] describes where the merged folders came from. Scalar rather than
  /// a map because this produces exactly one mod — and for the same reason it
  /// never carries a sibling group. [knownCharacter] is the same fact
  /// `importMods` takes per folder: a character the caller was told rather than
  /// one to guess at, replacing name detection when it is set.
  Future<ImportResult> importCombinedMod(
    List<String> folderPaths,
    String modName, {
    String? detectionHint,
    ModOriginSeed? origin,
    String? knownCharacter,
  }) async {
    try {
      final (valid, _) = await validatePaths();
      if (!valid) {
        return const ImportResult.failed(ImportFailure.libraryNotConfigured);
      }

      final modsDir = Directory(modsPath!);
      if (!await modsDir.exists()) {
        await modsDir.create(recursive: true);
      }

      final targetPath = path.join(modsPath!, modName);
      final targetDir = Directory(targetPath);
      // Existing mod with this name — treat as a duplicate (nothing installed).
      if (await targetDir.exists()) {
        return const ImportResult.nothing();
      }

      // Before the folder is created, so a refusal leaves the library exactly
      // as it was.
      final shortfall = await _spaceShortfall(folderPaths);
      if (shortfall != null) return shortfall;

      await targetDir.create(recursive: true);

      var copied = 0;
      final copiedFolders = <String>[];
      final written = <InstalledFile>[];
      for (final folderPath in folderPaths) {
        final sourceDir = Directory(folderPath);
        if (!await sourceDir.exists()) continue;
        final subFolder = path.basename(folderPath);
        written.addAll(installedFilesUnderPrefix(
          await copyDirectory(
            sourceDir,
            Directory(path.join(targetPath, subFolder)),
          ),
          // Each source lands in its own subfolder of the mod, so the copy's
          // paths are relative to that and have to be lifted to the mod root.
          subFolder,
        ));
        copiedFolders.add(folderPath);
        copied++;
      }
      // As above: whatever came with these folders, nothing now says what it is.
      await const PatchStore().discardAll(targetDir);

      // Nothing usable was copied — roll back the empty mod folder.
      if (copied == 0) {
        try {
          await targetDir.delete(recursive: true);
        } catch (_) {}
        return const ImportResult.failed(ImportFailure.nothingUsable);
      }

      if (origin != null) {
        await _recordOrigin(
          modName,
          _originBuilder.combined(
            seed: origin,
            sourceFolders: copiedFolders,
            files: written,
          ),
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

      return ImportResult(imported: [modName], autoTags: autoTags);
    } catch (e) {
      _log.error('combined import failed', error: e);
      return const ImportResult.failed(ImportFailure.copyFailed);
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
    // Debug, not info: this fires for every untagged mod on every scan, and a
    // library with a dozen of them would otherwise bury the scan summary.
    _log.debug('no character detected', fields: {'mod': modName});
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
      _log.warning('could not read keybinds',
          error: e, fields: {'character': characterId});
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
      _log.warning('could not read keybinds for the library', error: e);
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

  /// Adds each mod's parsed keybinds to it, over the flat library list.
  ///
  /// Takes the flat list rather than the character groups because the grouping
  /// is not a partition — a mod appears under its character *and* under "all" —
  /// so a per-group walk parses and rebuilds the same folder several times to
  /// reach the same answer. Every mod here is distinct, so the parse count is
  /// the mod count.
  ///
  /// Returns the list unchanged if the parse fails: keybinds are something a
  /// card *shows*, and a library that renders without them beats no library.
  Future<List<ModInfo>> enrichModsWithKeybinds(List<ModInfo> mods) async {
    try {
      // Parse concurrently rather than awaiting each in turn, which is what
      // keeps the enrich step off the critical path of a scan.
      await Future.wait(mods.map((mod) => getModKeybinds(mod.id)));

      final enriched = <ModInfo>[];
      for (final mod in mods) {
        // Cache hit after the warm-up above.
        final keybinds = await getModKeybinds(mod.id);
        enriched.add(
          keybinds != null && keybinds.isNotEmpty
              ? mod.copyWith(keybinds: keybinds)
              : mod,
        );
      }

      return enriched;
    } catch (e) {
      return mods;
    }
  }
}
