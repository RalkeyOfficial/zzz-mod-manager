import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import '../../core/constants.dart';
import '../../utils/directory_size.dart';
import '../backup/snapshot_service.dart';
import '../download/download_paths.dart';
import '../log/log_rotation.dart';
import '../log/logger.dart';
import '../platform_service.dart';
import 'storage_roots.dart';
import 'storage_usage.dart';

final Logger _log = Logger('storage');

/// The prefix `ArchiveService` gives every extraction directory.
const String archiveExtractPrefix = 'zzz_archive_extract_';

/// Measures what the app is storing.
///
/// **No method here throws.** A category that could not be read comes back
/// saying so, because the page has to draw the other five either way and a
/// thrown exception would take the whole screen with it.
class StorageScanner {
  StorageScanner(this.roots, {SnapshotService? snapshots, PlatformService? platform})
      : _snapshots = snapshots,
        _platform = platform;

  final StorageRoots roots;
  final SnapshotService? _snapshots;
  final PlatformService? _platform;

  /// The library walk, kept so [mods] and [sidecars] cost one traversal between
  /// them however they are asked for. Two providers want two halves of one
  /// answer, and walking a multi-gigabyte library twice to give it to them
  /// would be the most expensive thing on the page.
  Future<List<ModFolderSize>?>? _library;

  /// The library's own files: everything under each mod folder **except** its
  /// `.zzz-mod-manager` sidecar, which is [sidecars].
  Future<StorageCategory> mods() async {
    final measured = await _measureLibrary();
    if (measured == null) return _libraryUnavailable(StorageCategoryId.mods);

    final items = <StorageItem>[
      for (final mod in measured)
        StorageItem(
          id: mod.name,
          label: mod.name,
          path: mod.path,
          bytes: mod.ownBytes,
          fileCount: mod.ownFiles,
          kind: mod.isLink ? StorageItemKind.linked : StorageItemKind.modFolder,
        ),
    ];
    return _build(
      StorageCategoryId.mods,
      items,
      unreadable: measured.fold<int>(0, (sum, mod) => sum + mod.ownUnreadable),
      rootPath: roots.modsLibrary?.path,
    );
  }

  /// Covers, descriptions and the files a patch replaced — the per-mod sidecar.
  Future<StorageCategory> sidecars() async {
    final measured = await _measureLibrary();
    if (measured == null) return _libraryUnavailable(StorageCategoryId.sidecars);

    final items = <StorageItem>[
      for (final mod in measured)
        if (mod.sidecarBytes > 0)
          StorageItem(
            id: mod.name,
            label: mod.name,
            path: path.join(mod.path, AppConstants.modMetadataDirName),
            bytes: mod.sidecarBytes,
            fileCount: mod.sidecarFiles,
            kind: StorageItemKind.directory,
          ),
    ];
    return _build(
      StorageCategoryId.sidecars,
      items,
      unreadable:
          measured.fold<int>(0, (sum, mod) => sum + mod.sidecarUnreadable),
      rootPath: roots.modsLibrary?.path,
    );
  }

  /// Saved versions, from the manifests rather than a walk.
  ///
  /// One `readdir` per group plus one small JSON each, against re-walking
  /// gigabytes this app measured itself at capture time. Two things that buys
  /// are the reason it is not a walk: the drill-down's dates, reasons and
  /// version labels come free, and a page open costs milliseconds.
  ///
  /// What it trades: `manifest.json` itself is not counted (hundreds of bytes
  /// per snapshot), and the figure drifts if someone edits `<appData>/backups`
  /// by hand.
  Future<StorageCategory> savedVersions() async {
    final snapshots = _snapshots;
    if (snapshots == null) {
      return const StorageCategory(
        id: StorageCategoryId.savedVersions,
        read: StorageRead.ok,
        bytes: 0,
      );
    }
    try {
      final all = await snapshots.listAll();
      final byMod = <String, List<ModSnapshot>>{};
      for (final snapshot in all) {
        byMod.putIfAbsent(snapshot.modUid, () => <ModSnapshot>[]).add(snapshot);
      }
      final items = <StorageItem>[
        for (final entry in byMod.entries)
          StorageItem(
            id: entry.key,
            // The name the mod had when the newest of them was taken. A group
            // whose folder is gone still has one, which is what makes an
            // orphan nameable rather than a bare uid.
            label: _groupLabel(entry.value),
            path: path.join(roots.backups.path, entry.key),
            bytes: entry.value.fold<int>(0, (sum, s) => sum + s.sizeBytes),
            fileCount: entry.value.length,
            modified: _newest(entry.value),
            kind: StorageItemKind.snapshotGroup,
          ),
      ];
      return _build(
        StorageCategoryId.savedVersions,
        items,
        rootPath: roots.backups.path,
      );
    } catch (e) {
      _log.warning('could not read saved versions', error: e);
      return const StorageCategory(
        id: StorageCategoryId.savedVersions,
        read: StorageRead.unreadable,
        bytes: 0,
      );
    }
  }

  /// Archives waiting to be installed, and partly-fetched ones.
  Future<StorageCategory> downloads() async {
    return _flatDirectory(
      StorageCategoryId.downloads,
      roots.downloads,
      // A directory that was never created is not a problem to report: nothing
      // has been downloaded yet.
      absentIsEmpty: true,
      kindOf: (name) => name.endsWith(DownloadPaths.partSuffix) ||
              name.endsWith(DownloadPaths.recordSuffix)
          ? StorageItemKind.partialDownload
          : StorageItemKind.archive,
    );
  }

  /// This run's log and the ones kept beside it.
  Future<StorageCategory> logs() async {
    return _flatDirectory(
      StorageCategoryId.logs,
      roots.logs,
      absentIsEmpty: true,
      kindOf: (_) => StorageItemKind.file,
    );
  }

  /// What nothing cleans up on its own: images from before the sidecar, and
  /// extraction directories a crash or a finished import left behind.
  Future<StorageCategory> leftovers() async {
    final items = <StorageItem>[];
    var unreadable = 0;

    final legacy = await _flatDirectory(
      StorageCategoryId.leftovers,
      roots.legacyImages,
      absentIsEmpty: true,
      kindOf: (_) => StorageItemKind.file,
      detailKey: 'storage.item.legacy_image',
      cap: 1 << 30,
    );
    items.addAll(legacy.items);
    unreadable += legacy.unreadableCount;

    try {
      if (await roots.temp.exists()) {
        await for (final entity in roots.temp.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final name = path.basename(entity.path);
          if (!name.startsWith(archiveExtractPrefix)) continue;
          final size = await measureDirectory(entity.path);
          items.add(StorageItem(
            id: name,
            label: name,
            path: entity.path,
            bytes: size.bytes,
            fileCount: size.fileCount,
            modified: await newestWriteWithin(entity),
            kind: StorageItemKind.directory,
            // `zzz_archive_extract_7f3a` tells the reader nothing about what it
            // is or why it is safe to remove.
            detailKey: 'storage.item.extraction',
          ));
          unreadable += size.unreadable;
        }
      }
    } catch (e) {
      _log.debug('could not list the temp directory', fields: {'reason': '$e'});
      unreadable++;
    }

    return _build(
      StorageCategoryId.leftovers,
      items,
      unreadable: unreadable,
      rootPath: roots.appData.path,
    );
  }

  /// Free space, one line per place the app writes.
  ///
  /// The library is routinely on another disk, so there is no single number.
  /// Probing a directory that exists matters on Windows, where the API takes a
  /// directory and answers nothing for a path that is not one.
  Future<List<VolumeFreeSpace>> volumes() async {
    final platform = _platform;
    if (platform == null) return const <VolumeFreeSpace>[];

    Future<VolumeFreeSpace?> probe(String label, Directory? dir) async {
      if (dir == null) return null;
      if (!await dir.exists()) return null;
      return VolumeFreeSpace(
        label: label,
        probedPath: dir.path,
        freeBytes: await platform.freeSpaceBytes(dir.path),
      );
    }

    final probed = <VolumeFreeSpace?>[
      await probe('app_data', roots.appData),
      await probe('mods_library', roots.modsLibrary),
      await probe('temp', roots.temp),
    ];
    return collapseVolumes([
      for (final volume in probed)
        if (volume != null) volume,
    ]);
  }

  // ------------------------------------------------------------------ private

  Future<List<ModFolderSize>?> _measureLibrary() {
    final library = roots.modsLibrary;
    if (library == null) return Future.value(null);
    return _library ??= _walkLibrary(library);
  }

  /// Null when there is nothing to walk, which is **not** the same as a walk
  /// that found nothing: a library folder that has been moved or unmounted must
  /// not report `0 B`, because that reads as "your mods are gone".
  Future<List<ModFolderSize>?> _walkLibrary(Directory library) async {
    if (!await library.exists()) return null;
    return Isolate.run(() => measureLibrarySync(library.path));
  }

  StorageCategory _libraryUnavailable(StorageCategoryId id) {
    final library = roots.modsLibrary;
    if (library == null) return StorageCategory.notConfigured(id);
    return StorageCategory.absent(id, library.path);
  }

  /// Every file directly in [directory], with no recursion — the three flat
  /// stores the app keeps are all one level deep.
  Future<StorageCategory> _flatDirectory(
    StorageCategoryId id,
    Directory directory, {
    required StorageItemKind Function(String name) kindOf,
    String? detailKey,
    bool absentIsEmpty = false,
    int cap = 20,
  }) async {
    if (!await directory.exists()) {
      return absentIsEmpty
          ? StorageCategory(
              id: id,
              read: StorageRead.ok,
              bytes: 0,
              rootPath: directory.path,
            )
          : StorageCategory.absent(id, directory.path);
    }

    final items = <StorageItem>[];
    var unreadable = 0;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        try {
          final stat = await entity.stat();
          items.add(StorageItem(
            id: name,
            label: name,
            path: entity.path,
            bytes: stat.size,
            fileCount: 1,
            modified: stat.modified,
            kind: kindOf(name),
            detailKey: detailKey,
          ));
        } catch (_) {
          unreadable++;
        }
      }
    } catch (e) {
      _log.debug('could not list a storage folder',
          fields: {'path': directory.path, 'reason': '$e'});
      return StorageCategory(
        id: id,
        read: StorageRead.unreadable,
        bytes: 0,
        rootPath: directory.path,
      );
    }

    return _build(id, items,
        unreadable: unreadable, rootPath: directory.path, cap: cap);
  }

  StorageCategory _build(
    StorageCategoryId id,
    List<StorageItem> items, {
    int unreadable = 0,
    String? rootPath,
    int cap = 20,
  }) {
    final folded = foldTail(items, cap: cap);
    return StorageCategory(
      id: id,
      read: unreadable > 0 ? StorageRead.partial : StorageRead.ok,
      bytes: items.fold<int>(0, (sum, item) => sum + item.bytes),
      fileCount: items.fold<int>(0, (sum, item) => sum + item.fileCount),
      unreadableCount: unreadable,
      items: folded.items,
      tailBytes: folded.tailBytes,
      tailCount: folded.tailCount,
      rootPath: rootPath,
    );
  }

  static String _groupLabel(List<ModSnapshot> group) {
    final named = [...group]..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    for (final snapshot in named) {
      if (snapshot.modName.isNotEmpty) return snapshot.modName;
    }
    return named.first.modUid;
  }

  static DateTime? _newest(List<ModSnapshot> group) {
    DateTime? newest;
    for (final snapshot in group) {
      if (newest == null || snapshot.takenAt.isAfter(newest)) {
        newest = snapshot.takenAt;
      }
    }
    return newest;
  }
}

/// The newest write **anywhere inside** [directory], not the directory's own
/// timestamp.
///
/// A directory's mtime stops changing once its top-level entries exist, so a
/// deep extraction that is still writing megabytes underneath looks untouched
/// from the outside. Anything that decides an extraction is finished has to ask
/// this question, not `dir.stat()`.
Future<DateTime?> newestWriteWithin(Directory directory) async {
  DateTime? newest;
  try {
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      try {
        final modified = (await entity.stat()).modified;
        if (newest == null || modified.isAfter(newest)) newest = modified;
      } catch (_) {
        // One unreadable entry is not evidence the tree is idle.
        return null;
      }
    }
    newest ??= (await directory.stat()).modified;
  } catch (_) {
    return null;
  }
  return newest;
}

/// What one mod folder holds, split at its sidecar.
class ModFolderSize {
  const ModFolderSize({
    required this.name,
    required this.path,
    required this.ownBytes,
    required this.ownFiles,
    required this.sidecarBytes,
    required this.sidecarFiles,
    required this.ownUnreadable,
    required this.sidecarUnreadable,
    required this.isLink,
  });

  final String name;
  final String path;

  /// The mod's own files — the folder **minus** its sidecar.
  final int ownBytes;
  final int ownFiles;

  final int sidecarBytes;
  final int sidecarFiles;

  /// Entries skipped under the mod's **own** files, sidecar excluded.
  ///
  /// Split from [sidecarUnreadable] because the two halves are separate
  /// categories and a floor belongs to whichever one is actually short. The
  /// whole-folder walk covers the sidecar too, so counting its failures here
  /// would mark Mods as approximate while its figure is exact — and leave the
  /// category that really did under-read reporting a clean total.
  final int ownUnreadable;

  final int sidecarUnreadable;

  /// A mod folder that is a link. Contributes no bytes, and says why rather
  /// than reporting `0 B`, which reads as an empty mod.
  final bool isLink;
}

/// Walks a library once, splitting each mod folder at its sidecar.
///
/// Top-level and synchronous so it can be handed to `Isolate.run` whole: a
/// library of a few hundred thousand files is that many `stat` calls, and doing
/// them on the UI isolate is felt.
List<ModFolderSize> measureLibrarySync(
  String libraryPath, {
  Set<String> excludePaths = const <String>{},
}) {
  final results = <ModFolderSize>[];
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(libraryPath).listSync(followLinks: false);
  } catch (_) {
    return results;
  }

  for (final entry in entries) {
    final name = path.basename(entry.path);
    // The scan skips these, so counting them would describe a library the rest
    // of the app does not believe in.
    if (name.startsWith('.') || name.startsWith('__')) continue;

    if (entry is Link) {
      results.add(ModFolderSize(
        name: name,
        path: entry.path,
        ownBytes: 0,
        ownFiles: 0,
        sidecarBytes: 0,
        sidecarFiles: 0,
        ownUnreadable: 0,
        sidecarUnreadable: 0,
        isLink: true,
      ));
      continue;
    }
    if (entry is! Directory) continue;

    final whole = measureDirectorySync(entry.path, excludePaths: excludePaths);
    final sidecarPath =
        path.join(entry.path, AppConstants.modMetadataDirName);
    final sidecar = Directory(sidecarPath).existsSync()
        ? measureDirectorySync(sidecarPath)
        : DirSize.empty;

    results.add(ModFolderSize(
      name: name,
      path: entry.path,
      // Subtraction, so the two categories are disjoint and their sum is the
      // folder. Clamped at zero: the two walks are moments apart, and a sidecar
      // written in between would otherwise give a mod a negative size.
      ownBytes: _atLeastZero(whole.bytes - sidecar.bytes),
      ownFiles: _atLeastZero(whole.fileCount - sidecar.fileCount),
      sidecarBytes: sidecar.bytes,
      sidecarFiles: sidecar.fileCount,
      // The whole-folder walk hits the sidecar too, so its failures are in both
      // counts; what is left after taking them out is the mod's own.
      ownUnreadable: _atLeastZero(whole.unreadable - sidecar.unreadable),
      sidecarUnreadable: sidecar.unreadable,
      isLink: false,
    ));
  }
  return results;
}

int _atLeastZero(int value) => value < 0 ? 0 : value;

/// Whether [name] is a log file this app wrote.
///
/// Re-exported from the rotation rules so the storage layer has one answer to
/// "ours or the user's" rather than a second copy of the pattern.
bool isOurLogFile(String name) => isLogFileName(name);
