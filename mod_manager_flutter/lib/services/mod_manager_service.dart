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
import 'shader_fixes/shader_fixes_plan.dart';
import 'shader_fixes/shader_fixes_service.dart';
import 'ini_files_stamp.dart';
import 'ini_parser_service.dart';

/// Головний сервіс для керування модами через symbolic links
final Logger _log = Logger('mods');

/// Anything that changes the filesystem goes under one tag, whoever did it, so
/// "what did this app do to my folders" is a single filter.
final Logger _files = Logger('fileops');

/// A mod's parsed keybinds and the stamp of the `.ini` files they came from.
/// [settled] is [IniFilesStamp.settled] at the time of the parse.
typedef _CachedKeybinds = ({IniFilesStamp stamp, List<KeybindInfo> keys, bool settled});

/// A rename of a mod that is on, refused because ZZMI's Mods folder already has a [name] that is not the mod's own
/// link: a working link into another folder, a folder or a file. Nothing was changed.
class RenameRefused implements Exception {
  const RenameRefused(this.name);
  final String name;

  @override
  String toString() => 'the links folder already has a $name that is not this mod';
}

/// A rename whose folder could not be renamed, such as one holding a file another program has open on Windows.
/// Nothing was changed: the mod keeps its name, and its link if it was on.
class RenameFolderFailed implements Exception {
  const RenameFolderFailed(this.mod, this.error);
  final String mod;
  final Object error;

  @override
  String toString() => 'the folder of $mod could not be renamed: $error';
}

/// A rename of a mod that is on whose link under the new name [name] could not be made in ZZMI's Mods folder.
/// The folder is renamed back, so [mod] keeps its name and its link. When that fails too, [renamed] is true: the
/// mod is [name], and off.
class RenameLinkFailed implements Exception {
  const RenameLinkFailed(this.mod, this.name, {this.renamed = false});
  final String mod;
  final String name;
  final bool renamed;

  @override
  String toString() => 'the link of $mod under the name $name could not be made';
}

/// How a Mod library overlaps ZZMI's Mods folder, where the links go. Any overlap refuses the library.
enum LibraryOverlap {
  /// The library is the links folder by its path: every link there would point at itself.
  same,

  /// The library is the links folder once links are resolved.
  leadsTo,

  /// The library is within the links folder, which ZZMI reads as a whole, so every mod in it loads, on or off. One
  /// below a folder whose name starts with `DISABLED`, in any case, or named so itself, is apart: ZZMI skips it.
  inside,

  /// The links folder is within the library, so it would read as a mod, and turning it on would make a loop.
  contains,
}

/// How [library] overlaps [links], or null when they are apart. Compared by path, and, when both exist, once links
/// are resolved, as a library path that is itself a link into ZZMI's Mods folder is.
Future<LibraryOverlap?> libraryOverlap(String library, String links, {PlatformService? platform}) async {
  final paths = platform ?? PlatformServiceFactory.getInstance();
  final direct = _overlapOf(library, links, paths);
  if (direct != null) return direct;
  try {
    if (!await Directory(library).exists() || !await Directory(links).exists()) return null;
    final resolved = _overlapOf(
      await Directory(library).resolveSymbolicLinks(),
      await Directory(links).resolveSymbolicLinks(),
      paths,
    );
    return resolved == LibraryOverlap.same ? LibraryOverlap.leadsTo : resolved;
  } on FileSystemException {
    return null;
  }
}

LibraryOverlap? _overlapOf(String library, String links, PlatformService paths) {
  if (paths.samePath(library, links)) return LibraryOverlap.same;
  // The platform's own path style, so Windows compares without case as samePath does.
  if (path.isWithin(links, library)) {
    // ZZMI's `exclude_recursive = DISABLED*` skips a folder of that name at any depth, and all below it.
    final skipped = path.split(path.relative(library, from: links)).any((f) => f.toLowerCase().startsWith('disabled'));
    return skipped ? null : LibraryOverlap.inside;
  }
  if (path.isWithin(library, links)) return LibraryOverlap.contains;
  return null;
}

/// Whether [a] and [b] are one folder: the same path, or, when both exist, the same folder once links are resolved,
/// as a library path that is itself a link to ZZMI's Mods folder is.
Future<bool> isSameFolder(String a, String b, {PlatformService? platform}) async {
  final paths = platform ?? PlatformServiceFactory.getInstance();
  if (paths.samePath(a, b)) return true;
  try {
    if (!await Directory(a).exists() || !await Directory(b).exists()) return false;
    return paths.samePath(await Directory(a).resolveSymbolicLinks(), await Directory(b).resolveSymbolicLinks());
  } on FileSystemException {
    return false;
  }
}

class ModManagerService {
  final ConfigService _configService;
  final PlatformService _platformService;
  final IniParserService _iniParser;
  final ModMetadataRepository _metadata;

  /// Builds origin blocks at ingest. Pure and injectable so the group/mode
  /// decisions are testable without a configured library.
  final IngestOriginBuilder _originBuilder = IngestOriginBuilder();

  /// Parsed keybinds per mod, keyed by the mod's full folder path so another
  /// library's same-named mod never shows these keys.
  ///
  /// Each entry holds the [IniFilesStamp] its keys were parsed under, and is
  /// used only while the folder's stamp is still equal to it and settled, so
  /// an `.ini` changed by anything (an editor, an update, a Restore) is parsed
  /// again on the next scan while an unchanged library costs a stat per file.
  final Map<String, _CachedKeybinds> _keybindCache = {};

  /// Only for `deleteMod`: a mod's saved versions go when the mod does.
  final SnapshotService _snapshots;
  final ModUid _uids;

  /// Copies a mod's `ShaderFixes/` into ZZMI's shader folder while it is enabled.
  final ShaderFixesService _shaderFixes;

  /// Free space on the volume an import is about to write to. Injectable
  /// because the real one spawns a `df`, and a test about refusing an import
  /// cannot fill a disk to ask the question.
  final Future<int?> Function(String path) _freeSpace;

  /// [snapshots] and [uids] are defaulted rather than required because they
  /// need no configuration — one reads the folder's own sidecar, the other is
  /// rooted in app-data. They are parameters at all so `deleteMod` can be
  /// tested without reaching the developer's real `<appData>/backups`. [platform] lets a test make links the way
  /// another platform does.
  ModManagerService(
    this._configService, {
    SnapshotService? snapshots,
    ModUid? uids,
    ShaderFixesService? shaderFixes,
    Future<int?> Function(String path)? freeSpace,
    PlatformService? platform,
  })  : _snapshots = snapshots ?? SnapshotService(),
        _uids = uids ?? ModUid(),
        _shaderFixes = shaderFixes ?? ShaderFixesService(),
        _freeSpace =
            freeSpace ?? PlatformServiceFactory.getInstance().freeSpaceBytes,
        _platformService = platform ?? PlatformServiceFactory.getInstance(),
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

  /// A mod's origin block as it is on disk now, rather than as the last scan found it.
  Future<ModOrigin?> readModOrigin(String modName) =>
      _metadata.readOrigin(modName);

  /// The oldest file mtime inside a mod folder, as an install-date proxy for a
  /// mod that has no recorded install date. See [ModMetadataRepository].
  Future<DateTime?> installDateProxy(String modName) =>
      _metadata.installDateProxy(modName);

  ModMetadataService get metadataService => _metadata.service;

  /// Whether the link named after [modName] points at the mod's own folder in the library. A link of that name into
  /// any other folder, or one whose target is gone, reads as off (`docs/library-screen.md` §10).
  Future<bool> isModActive(String modName) async {
    try {
      final links = saveModsPath;
      final library = modsPath;
      if (links == null || library == null) return false;

      final linkPath = path.join(links, modName);
      // Follows the link, so a link whose target is gone reads as not found.
      if (await FileSystemEntity.type(linkPath) == FileSystemEntityType.notFound) return false;
      final target = await _platformService.readModLinkTarget(linkPath);
      if (target == null) return false;

      // The same folder may be reached another way, such as a library path that is itself a link.
      return isSameFolder(target, path.join(library, modName), platform: _platformService);
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

      // The copy whose link this one replaces, such as one in a library the links still point into. Its shader files
      // are taken out once this mod is on, so only one copy's load, unless another link still keeps it on.
      final other = await _otherCopyAt(dstPath, srcPath);
      final freeable = other != null && other.stillOnThrough == null;

      // Shader files go in before the link, so a refusal leaves the mod off.
      String? shaderUid;
      ShaderPlacementResult? shaderFiles;
      List<ShaderEntry>? freed;
      if (await ShaderFixesService.shaderPartOf(srcPath) != null) {
        final uid = await _uids.ensure(srcDir);
        if (uid == null) {
          _log.error('could not activate, no identity for its shader files',
              fields: {'mod': modName});
          return false;
        }
        shaderUid = uid;
        Future<ShaderPlacementResult> place() =>
            // A copy that fails partway lets go of what it took hold of before it throws.
            _shaderFixes.place(modDir: srcPath, uid: uid, mod: modName, saveModsPath: saveModsPath!);
        try {
          shaderFiles = await place();
        } on ShaderPlacementRefused catch (refusal) {
          if (other == null) rethrow;
          if (!freeable) throw refusal.stillOnThrough(other.uid, other.stillOnThrough!);
          // The other copy's files may be what is in the way. Throws the refusal that remains without them, before
          // anything changes; otherwise they go first and come back if this mod does not come on.
          await _shaderFixes.check(
              modDir: srcPath, uid: uid, mod: modName, saveModsPath: saveModsPath!, freeing: other.uid);
          var taken = const <ShaderEntry>[];
          try {
            freed = taken = await _shaderFixes.free(uid: other.uid, mod: modName);
            _log.info('other copy shader files taken out to make room',
                fields: {'mod': modName, 'uid': uid, 'copy': other.folder, 'copyUid': other.uid, 'files': taken.length});
            shaderFiles = await place();
          } catch (_) {
            await _restoreShaderFiles(other, modName, taken);
            rethrow;
          }
        }
      }

      // A link already of that name, such as one whose folder is on an unplugged drive, is replaced in one step, so
      // a link that can't be made leaves it as it was.
      NetworkLinkRefused? networkRefusal;
      bool success;
      try {
        success = await _platformService.createModLink(srcPath, dstPath);
      } on NetworkLinkRefused catch (refusal) {
        networkRefusal = refusal;
        success = false;
      }
      if (!success) {
        // The platform service already logged why; this says which mod the
        // user was trying to switch on when it happened.
        _log.error('could not activate', fields: {'mod': modName});
        if (shaderUid != null && shaderFiles != null) {
          await _shaderFixes.undo(uid: shaderUid, mod: modName, placed: shaderFiles);
        }
        if (freed != null) await _restoreShaderFiles(other!, modName, freed);
        // Thrown once the shader files are back, so the caller can say why.
        if (networkRefusal != null) throw networkRefusal;
        return false;
      }

      await _configService.addActiveMod(modName);
      if (shaderFiles != null) {
        if (shaderFiles.copied > 0 || freed != null) ShaderFixesService.announce(modName);
        if (shaderFiles.adopted > 0) ShaderFixesService.announceAdopted(modName, shaderFiles.adopted);
      }
      if (freeable && freed == null) {
        try {
          await _shaderFixes.remove(uid: other.uid, mod: modName);
        } catch (error, stack) {
          // The mod is on, and the other copy's files stay held in the record for its next disable.
          _log.warning('other copy shader files not taken out',
              error: error, stack: stack, fields: {'mod': modName, 'copy': other.folder, 'copyUid': other.uid});
        }
      }

      return true;
    } on ShaderPlacementRefused catch (refusal) {
      _logRefusal(modName, refusal);
      rethrow;
    } on NetworkLinkRefused {
      rethrow;
    } catch (error, stack) {
      _log.error('could not activate',
          error: error, stack: stack, fields: {'mod': modName});
      return false;
    }
  }

  /// False when the mod is not on. A link of its name into another folder is not its own, so it is left in place.
  Future<bool> deactivateMod(String modName) async {
    try {
      if (saveModsPath == null) return false;

      final linkPath = path.join(saveModsPath!, modName);
      if (!await isModActive(modName)) return false;

      // Використовуємо platformService для видалення link
      final success = await _platformService.removeModLink(linkPath);
      if (!success) {
        _log.error('could not deactivate', fields: {'mod': modName});
        return false;
      }

      await _configService.removeActiveMod(modName);

      await _removeShaderFiles(modName);

      return true;
    } catch (error, stack) {
      _log.error('could not deactivate',
          error: error, stack: stack, fields: {'mod': modName});
      return false;
    }
  }

  /// The other copy of a mod whose link [linkPath] holds: a folder other than [modDir] with an identity of its own.
  /// The identity is read from the folder, or, for one that can't be read, such as one on an unplugged drive, found
  /// by the folder path the shader record keeps. Null for no link, the mod's own, a copy with the same identity,
  /// such as a duplicated folder, since its holds are this mod's too, or one whose identity is found neither way.
  ///
  /// [stillOnThrough] names another working link in the links folder that leads to that copy, which keeps it on
  /// after this link is replaced, so its files are not taken out.
  Future<_OtherCopy?> _otherCopyAt(String linkPath, String modDir) async {
    final target = await _platformService.readModLinkTarget(linkPath);
    if (target == null || _platformService.samePath(target, modDir)) return null;
    try {
      final uid = await _uids.read(Directory(target)) ??
          await _shaderFixes.holderFrom(target, samePath: _platformService.samePath);
      if (uid == null || uid == await _uids.read(Directory(modDir))) return null;
      // Every working link's identity is read, so only for a copy with files to take out.
      final stillOnThrough = await _shaderFixes.holdsAny(uid) ? await _otherLinkTo(uid, target, except: linkPath) : null;
      return (folder: target, uid: uid, stillOnThrough: stillOnThrough);
    } catch (error) {
      _log.warning('could not read the identity of the copy the link points at', error: error, fields: {'link': linkPath});
      return null;
    }
  }

  /// The name of a working link in the links folder, other than [except], that leads to [folder] or to another
  /// folder with the identity [uid], such as one made by hand. Null when there is none.
  Future<String?> _otherLinkTo(String uid, String folder, {required String except}) async {
    final links = saveModsPath;
    if (links == null) return null;
    await for (final entry in Directory(links).list(followLinks: false)) {
      if (_platformService.samePath(entry.path, except) || isTemporaryLinkName(path.basename(entry.path))) continue;
      try {
        final target = await _platformService.readModLinkTarget(entry.path);
        if (target == null) continue;
        // Follows the link, so one whose target is gone reads as not found.
        if (await FileSystemEntity.type(entry.path) == FileSystemEntityType.notFound) continue;
        if (_platformService.samePath(target, folder) || await _uids.read(Directory(target)) == uid) {
          return path.basename(entry.path);
        }
      } catch (error) {
        _log.warning('could not read a link in the links folder', error: error, fields: {'link': entry.path});
      }
    }
    return null;
  }

  /// Puts back the shader files of [other] that [freed] took out to make room for a mod that then did not come on,
  /// every one that can be, and reports those that could not.
  Future<void> _restoreShaderFiles(_OtherCopy other, String modName, List<ShaderEntry> freed) async {
    try {
      final missing = await _shaderFixes.restore(
          modDir: other.folder, uid: other.uid, mod: modName, saveModsPath: saveModsPath!, freed: freed);
      if (missing.isEmpty) return;
      _log.error('other copy shader files not all put back',
          fields: {'mod': modName, 'copy': other.folder, 'copyUid': other.uid, 'files': missing.length});
      ShaderFixesService.reportShortfall(ShaderRestoreShortfall(modName, other.folder, missing));
    } catch (error, stack) {
      _log.error('other copy shader files not put back',
          error: error, stack: stack, fields: {'mod': modName, 'copy': other.folder, 'copyUid': other.uid});
      if (freed.isNotEmpty) {
        ShaderFixesService.reportShortfall(ShaderRestoreShortfall(modName, other.folder, [for (final e in freed) e.path]));
      }
    }
  }

  /// Records the shader files placed from the folder [from] as placed from [to], after the folder moved, and returns
  /// the uids it moved; with [only], just those. Never throws: a stale path only means a copy on an unplugged drive is
  /// not recognised later.
  Future<List<String>> _repointShaderSource(String from, String to, {Iterable<String>? only}) async {
    try {
      return await _shaderFixes.repoint(from: from, to: to, samePath: _platformService.samePath, only: only);
    } catch (error) {
      _log.warning('shader record not updated for the moved folder', error: error, fields: {'from': from, 'to': to});
      return const [];
    }
  }

  void _logRefusal(String modName, ShaderPlacementRefused refusal) => _log.warning('shader files refused', fields: {
        'mod': modName,
        'conflicts': refusal.conflicts.length,
        if (refusal.stillOn != null) 'stillOnThrough': refusal.stillOn!.link,
      });

  /// Takes out the shader files the mod placed. A mod whose folder is gone has
  /// no readable identity, so its files stay until the folder returns.
  Future<void> _removeShaderFiles(String modName) async {
    final mods = modsPath;
    if (mods == null) return;
    final uid = await _uids.read(Directory(path.join(mods, modName)));
    if (uid == null) return;
    await _shaderFixes.remove(uid: uid, mod: modName);
  }

  /// Throws [ShaderPlacementRefused] when enabling [modName] would be refused for
  /// its shader files, and changes nothing either way. Asked before One at a time
  /// turns the character's other mods off. The files of the copy whose link the
  /// enable replaces count as free, since the enable takes them out, unless
  /// another link still keeps that copy on.
  Future<void> checkActivation(String modName) async {
    final mods = modsPath;
    final save = saveModsPath;
    if (mods == null || save == null) return;
    final modDir = path.join(mods, modName);
    if (await ShaderFixesService.shaderPartOf(modDir) == null) return;
    final other = await _otherCopyAt(path.join(save, modName), modDir);
    try {
      await _shaderFixes.check(
        modDir: modDir,
        uid: await _uids.read(Directory(modDir)),
        mod: modName,
        saveModsPath: save,
        freeing: other?.stillOnThrough == null ? other?.uid : null,
      );
    } on ShaderPlacementRefused catch (refusal) {
      final reported = other?.stillOnThrough == null ? refusal : refusal.stillOnThrough(other!.uid, other.stillOnThrough!);
      _logRefusal(modName, reported);
      throw reported;
    }
  }

  /// Points the links into the library at [oldRoot] at the library at [newRoot], after the library folder changed
  /// (`docs/configuration.md`). Returns the names of the mods it could not re-point.
  ///
  /// A link is re-pointed when its target is exactly `<oldRoot>/<its own name>`, live or dead, and
  /// `<newRoot>/<name>` is a folder. A link into the old folder for a mod the new library lacks is left alone. A mod
  /// that fails is logged and returned, and the others still follow. Nothing is re-pointed when [newRoot] overlaps
  /// the links folder ([libraryOverlap]). A mod whose link was refused for leading to a network folder
  /// ([NetworkLinkRefused]) is also added to [networkRefused], so the caller can say why.
  Future<List<String>> relinkLibrary(String oldRoot, String newRoot, {Set<String>? networkRefused}) async {
    final links = saveModsPath;
    if (links == null || links.isEmpty) return const [];
    if (_platformService.samePath(oldRoot, newRoot)) return const [];
    final overlap = await libraryOverlap(newRoot, links, platform: _platformService);
    if (overlap != null) {
      _log.warning('library overlaps the links folder, nothing relinked',
          fields: {'library': newRoot, 'links': links, 'overlap': overlap.name});
      return const [];
    }

    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(links).list(followLinks: false).toList();
    } on PathNotFoundException {
      return const [];
    } catch (error) {
      _log.warning('could not list the links folder', error: error, fields: {'folder': links});
      return const [];
    }

    var relinked = 0;
    final failed = <String>[];
    for (final entry in entries) {
      final name = path.basename(entry.path);
      if (name.startsWith('.') || isTemporaryLinkName(name)) continue;
      try {
        final target = await _platformService.readModLinkTarget(entry.path);
        if (target == null || !_platformService.samePath(target, path.join(oldRoot, name))) continue;
        final folder = path.join(newRoot, name);
        if (!await Directory(folder).exists()) continue;
        if (await _relink(name, entry.path, from: target, to: folder, links: links)) {
          relinked++;
        } else {
          failed.add(name);
        }
      } on NetworkLinkRefused {
        // The platform service logged it; the link is as it was.
        failed.add(name);
        networkRefused?.add(name);
      } catch (error) {
        _log.warning('could not relink', error: error, fields: {'mod': name});
        failed.add(name);
      }
    }
    _log.info('library relinked', fields: {'from': oldRoot, 'to': newRoot, 'relinked': relinked, 'failed': failed.length});
    return failed;
  }

  /// Points the link at [linkPath] from [from] at [to], a copy of mod [name] in the new library.
  ///
  /// A copy with another identity than the old one, or with an old one that can't be read, places its shader files
  /// as enabling does, first, so a refusal leaves the link as it was. Once the link follows, the old copy's shader
  /// files are taken out as turning it off would, when its identity is known and differs, and no other link still
  /// leads to it. An old copy that can't be read, such as one on an unplugged drive, is known by the folder path the
  /// shader record keeps. A copy with the same identity is the same mod moved, and its files are already in place.
  Future<bool> _relink(String name, String linkPath, {required String from, required String to, required String links}) async {
    final previous = await _uids.read(Directory(from)) ??
        await _shaderFixes.holderFrom(from, samePath: _platformService.samePath);
    final current = await _uids.read(Directory(to));
    final moved = previous != null && current == previous;

    String? shaderUid;
    ShaderPlacementResult? shaderFiles;
    if (!moved && await ShaderFixesService.shaderPartOf(to) != null) {
      shaderUid = await _uids.ensure(Directory(to));
      if (shaderUid == null) {
        _log.error('could not relink, no identity for its shader files', fields: {'mod': name});
        return false;
      }
      try {
        // A copy that fails partway lets go of what it took hold of before it throws.
        shaderFiles = await _shaderFixes.place(modDir: to, uid: shaderUid, mod: name, saveModsPath: links);
      } on ShaderPlacementRefused catch (refusal) {
        _log.warning('link left as it was, shader files refused', error: refusal, fields: {'mod': name});
        return false;
      } catch (error, stack) {
        _log.error('could not relink', error: error, stack: stack, fields: {'mod': name});
        return false;
      }
    }

    NetworkLinkRefused? networkRefusal;
    bool replaced;
    try {
      replaced = await _platformService.replaceModLink(linkPath, to);
    } on NetworkLinkRefused catch (refusal) {
      networkRefusal = refusal;
      replaced = false;
    }
    if (!replaced) {
      if (shaderUid != null && shaderFiles != null) {
        await _shaderFixes.undo(uid: shaderUid, mod: name, placed: shaderFiles);
      }
      // Thrown once the shader files are back, so the caller can say why.
      if (networkRefusal != null) throw networkRefusal;
      return false;
    }
    if (shaderFiles != null) {
      if (shaderFiles.copied > 0) ShaderFixesService.announce(name);
      if (shaderFiles.adopted > 0) ShaderFixesService.announceAdopted(name, shaderFiles.adopted);
    }
    try {
      if (moved) {
        await _repointShaderSource(from, to);
      } else if (previous != null && await _shaderFixes.holdsAny(previous)) {
        final stillOnThrough = await _otherLinkTo(previous, from, except: linkPath);
        if (stillOnThrough == null) {
          await _shaderFixes.remove(uid: previous, mod: name);
        } else {
          _log.info('old copy shader files kept, another link still leads to it',
              fields: {'mod': name, 'copy': from, 'copyUid': previous, 'link': stillOnThrough});
        }
      }
    } catch (error, stack) {
      // The link has followed, so the relink stands, and the old copy's files stay held in the record.
      _log.warning('old copy shader files not taken out',
          error: error, stack: stack, fields: {'mod': name, 'copy': from, 'copyUid': previous});
    }
    return true;
  }

  /// Renames a mod's folder and migrates everything keyed to its name: the
  /// active symlink (if active) and the per-mod config (active/favorite/note/tag).
  /// The in-folder metadata travels with the folder, so it needs no migration.
  /// Returns false on collision or any failure.
  ///
  /// For a mod that is on, a dead link of the new name in ZZMI's Mods folder is replaced, and the shader files of the
  /// copy it led to are taken out as turning the mod on over it would. Anything else of that name that is not the
  /// mod's own link throws [RenameRefused] before anything changes. A folder that can't be renamed throws
  /// [RenameFolderFailed], and the mod is as it was, its link included. A link that can't be made under the new name
  /// renames the folder back and throws [RenameLinkFailed]; when the folder can't be renamed back either, the mod is
  /// left off under its new name with its shader files taken out.
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

      // No mod is on without a links folder, so [links] is set wherever it is used.
      final links = saveModsPath ?? '';
      final newLink = path.join(links, newName);
      final wasActive = await isModActive(oldName);
      if (wasActive) await _checkLinkNameFree(newLink, mod: oldName);
      // The copy a dead link of the new name leads to, whose shader files go once this mod's link replaces it, as
      // turning a mod on over it does.
      final other = wasActive ? await _otherCopyAt(newLink, oldDir.path) : null;

      // The folder first, so one that can't be renamed, such as one holding a file open on Windows, leaves the link.
      try {
        await oldDir.rename(newPath);
      } on FileSystemException catch (error) {
        _files.warning('rename failed, the folder could not be renamed', error: error, fields: {'mod': oldName});
        throw RenameFolderFailed(oldName, error);
      }
      final repointed = await _repointShaderSource(oldDir.path, newPath);

      var leftOff = false;
      if (wasActive) {
        // A dead link of the new name is replaced, and the line logged says where it pointed. One that can't be
        // made is left as it was.
        if (!await _linkOrFalse(newPath, newLink)) {
          // Renaming the folder back makes the old link live again, so the mod is as it was.
          try {
            await Directory(newPath).rename(oldDir.path);
          } on FileSystemException catch (error) {
            _files.error('renamed mod left off, its link could not be made and its folder not renamed back',
                error: error, fields: {'mod': newName});
            leftOff = true;
          }
          if (!leftOff) {
            await _repointShaderSource(newPath, oldDir.path, only: repointed);
            _files.warning('rename undone, the link could not be made', fields: {'mod': oldName, 'name': newName});
            throw RenameLinkFailed(oldName, newName);
          }
        } else if (other != null && other.stillOnThrough == null) {
          try {
            await _shaderFixes.remove(uid: other.uid, mod: newName);
          } catch (error, stack) {
            // The mod is on under its new name, and the other copy's files stay held in the record.
            _log.warning('other copy shader files not taken out',
                error: error, stack: stack, fields: {'mod': newName, 'copy': other.folder, 'copyUid': other.uid});
          }
        }
        // The old link points at a folder no longer there, and would turn on a mod given the old name later.
        await _platformService.removeModLink(path.join(links, oldName));
      }

      // The folder has moved, so the rename succeeded either way; what a failed write loses is the mod's state
      // under its new name after a restart (on/off, favourite, note), and that is worth a line.
      if (!await _configService.migrateModName(oldName, newName)) {
        _files.warning('renamed mod state not saved', fields: {'from': oldName, 'to': newName});
      }
      invalidateKeybinds(oldName);
      if (leftOff) {
        // Off with no link, so its shader files come out as turning it off would take them.
        await _configService.removeActiveMod(newName);
        try {
          await _removeShaderFiles(newName);
        } catch (error, stack) {
          _log.warning('renamed mod left off, its shader files not taken out',
              error: error, stack: stack, fields: {'mod': newName});
        }
        throw RenameLinkFailed(oldName, newName, renamed: true);
      }
      return true;
    } on RenameRefused {
      rethrow;
    } on RenameFolderFailed {
      rethrow;
    } on RenameLinkFailed {
      rethrow;
    } catch (error, stack) {
      _files.error('rename failed',
          error: error, stack: stack, fields: {'mod': oldName});
      return false;
    }
  }

  /// [PlatformService.createModLink], with a link refused for leading to a network folder read as not made.
  Future<bool> _linkOrFalse(String source, String linkPath) async {
    try {
      return await _platformService.createModLink(source, linkPath);
    } on NetworkLinkRefused {
      return false;
    }
  }

  /// Throws [RenameRefused] when [linkPath] holds a working link or anything else that is not a link into [mod]'s
  /// own folder. Nothing there, or a dead link, is free.
  Future<void> _checkLinkNameFree(String linkPath, {required String mod}) async {
    if (await FileSystemEntity.type(linkPath, followLinks: false) == FileSystemEntityType.notFound) return;
    final target = await _platformService.readModLinkTarget(linkPath);
    if (target != null) {
      // Follows the link, so a link whose target is gone reads as not found.
      if (await FileSystemEntity.type(linkPath) == FileSystemEntityType.notFound) return;
      if (_platformService.samePath(target, path.join(modsPath!, mod))) return;
    }
    _files.warning('rename refused, the link name is taken', fields: {'mod': mod, 'link': linkPath, 'target': target});
    throw RenameRefused(path.basename(linkPath));
  }

  /// Permanently deletes a mod: removes its active link (if any), deletes the
  /// on-disk folder with all its files, clears its config state
  /// (active/favorite/note/category), and **deletes every saved version of it**. The
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
      if (uid != null) await _shaderFixes.remove(uid: uid, mod: modName, retryFailed: false);

      await modDir.delete(recursive: true);

      await _configService.removeActiveMod(modName);
      await _configService.removeFavoriteMod(modName);
      await _configService.setModNote(modName, '');
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

  /// The keybinds of the mod whose folder in the library is [modId].
  ///
  /// Parsed again unless the cached entry's stamp equals the folder's and is
  /// settled. A folder that cannot be read keeps its cached keys.
  ///
  /// The folder is listed once: the parse reads the files the stamp found.
  Future<List<KeybindInfo>?> getModKeybinds(String modId) async {
    try {
      if (modsPath == null) return null;
      final modPath = path.join(modsPath!, modId);
      final cached = _keybindCache[modPath];

      final before = await IniFilesStamp.take(modPath);
      if (before == null) return cached?.keys ?? <KeybindInfo>[];
      if (cached != null && cached.settled && cached.stamp.matches(before)) {
        return cached.keys;
      }

      final keybinds = await _iniParser.parseIniFiles(before.paths);

      // Stored only when nothing changed during the parse, so keys read
      // before a write are never kept under the stamp of what was written.
      // An `.ini` added meanwhile is not in either stamp, and the next scan's
      // listing finds it.
      final after = await before.restat();
      if (after != null && before.matches(after)) {
        _keybindCache[modPath] = (stamp: before, keys: keybinds, settled: before.settled);
      }
      return keybinds;
    } catch (e) {
      return null;
    }
  }

  /// Drops a single mod's cached keybinds (call after editing its .ini).
  void invalidateKeybinds(String modId) {
    final library = modsPath;
    if (library != null) _keybindCache.remove(path.join(library, modId));
  }

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
      final parsed = await Future.wait(mods.map((mod) => getModKeybinds(mod.id)));

      return [
        for (var i = 0; i < mods.length; i++)
          parsed[i] != null && parsed[i]!.isNotEmpty
              ? mods[i].copyWith(keybinds: parsed[i])
              : mods[i],
      ];
    } catch (e) {
      return mods;
    }
  }
}

/// Another copy of a mod, whose link of the mod's name an enable replaces ([ModManagerService.activateMod]).
typedef _OtherCopy = ({String folder, String uid, String? stillOnThrough});
