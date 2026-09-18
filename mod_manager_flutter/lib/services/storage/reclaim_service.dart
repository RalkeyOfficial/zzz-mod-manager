import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/directory_size.dart';
import '../download/download_paths.dart';
import '../log/logger.dart';
import '../mod_metadata_service.dart';
import 'reclaim_plan.dart';
import 'storage_roots.dart';
import 'storage_scanner.dart';

final Logger _log = Logger('storage');

/// What one target came to.
class ReclaimTargetResult {
  const ReclaimTargetResult({
    required this.target,
    required this.freedBytes,
    required this.removedCount,
    required this.skippedCount,
    this.refusal,
  });

  final ReclaimTarget target;
  final int freedBytes;
  final int removedCount;
  final int skippedCount;

  /// Non-null when the whole target was refused, and why. The UI names it:
  /// a sweep that silently did less than it offered is worse than one that
  /// did nothing.
  final ReclaimSkipReason? refusal;
}

/// What the sweep came to, all told.
class ReclaimOutcome {
  const ReclaimOutcome({required this.targets, this.freeSpaceDelta});

  static const ReclaimOutcome nothing =
      ReclaimOutcome(targets: <ReclaimTargetResult>[]);

  final List<ReclaimTargetResult> targets;

  /// Free space measured after minus before, when both could be read.
  ///
  /// Reported in preference to [freedBytes] because it is the number the user
  /// can verify. The two disagree on any compressed, sparse or copy-on-write
  /// volume, where the sum of file lengths is not what the filesystem gets
  /// back — which is also why nothing here ever promises a figure in advance.
  final int? freeSpaceDelta;

  int get freedBytes =>
      targets.fold<int>(0, (sum, result) => sum + result.freedBytes);

  int get removedCount =>
      targets.fold<int>(0, (sum, result) => sum + result.removedCount);

  bool get isEmpty => removedCount == 0;

  Iterable<ReclaimTargetResult> get refused =>
      targets.where((result) => result.refusal != null);
}

/// Deletes what [planReclaim] says may go, and nothing else.
///
/// Every seam is a closure rather than a provider, so this file imports no
/// Riverpod and a test drives it with two booleans. [StorageRoots] being
/// injectable is not optional either: the temp root is real, and a test that
/// picked up the production one would sweep the developer's `/tmp`.
class ReclaimService {
  ReclaimService(
    this.roots, {
    required this.downloadsBusy,
    required this.installBusy,
    required this.modNames,
    required this.claimedSnapshotUids,
    DateTime Function()? now,
    Future<int?> Function(String path)? freeSpace,
    this.rules = const ReclaimRules(),
  })  : _now = now ?? DateTime.now,
        _freeSpace = freeSpace;

  final StorageRoots roots;

  /// Whether anything is queued, transferring, or landed and not yet installed.
  final bool Function() downloadsBusy;

  /// Whether an archive is being unpacked or imported — including the drag-in
  /// and file-picker paths, which the download queue knows nothing about.
  final bool Function() installBusy;

  /// The library as it is right now. Null means it could not be read, which is
  /// what stops the legacy-image sweep rather than letting it run against an
  /// empty list and delete everything.
  final Future<Set<String>?> Function() modNames;

  /// The uid of every mod in the library, or null when it could not be read.
  final Future<Set<String>?> Function() claimedSnapshotUids;

  final ReclaimRules rules;

  /// Asked one question only: whether a mod keeps its images in its own
  /// sidecar. One that does no longer reaches the legacy directory, so its copy
  /// there is dead weight; one that does not still needs it.
  final ModMetadataService _metadata = ModMetadataService();
  final DateTime Function() _now;
  final Future<int?> Function(String path)? _freeSpace;

  Future<ReclaimOutcome> run() async {
    final before = await _readFreeSpace();

    final library = await modNames();
    final claimed = await claimedSnapshotUids();
    final inventory = await _gather();
    final reachable = await _reachableLegacyImages(library);

    // Read as late as possible, and again below: the gate is about this moment,
    // not about when the page was drawn.
    final plan = planReclaim(
      inventory,
      now: _now(),
      downloadsBusy: downloadsBusy(),
      installBusy: installBusy(),
      // Both halves have to be readable. A legacy image is reachable only when
      // its mod exists *and* keeps no sidecar, so failing to answer either
      // question leaves the sweep unable to tell dead weight from a user's only
      // copy of a cover.
      libraryReadable: library != null && reachable != null,
      reachableLegacyImages: reachable ?? const <String>{},
      claimedSnapshotUids: claimed,
      currentLogFile: roots.currentLogFile == null
          ? null
          : path.basename(roots.currentLogFile!),
      rules: rules,
    );

    final results = <ReclaimTargetResult>[];
    for (final target in ReclaimTarget.values) {
      results.add(await _apply(target, plan));
    }

    final after = await _readFreeSpace();
    final delta = (before != null && after != null && after > before)
        ? after - before
        : null;

    _log.info('reclaimed disk space', fields: {
      'bytes': results.fold<int>(0, (sum, r) => sum + r.freedBytes),
      'removed': results.fold<int>(0, (sum, r) => sum + r.removedCount),
    });

    return ReclaimOutcome(targets: results, freeSpaceDelta: delta);
  }

  // ------------------------------------------------------------------ private

  Future<ReclaimTargetResult> _apply(
    ReclaimTarget target,
    ReclaimPlan plan,
  ) async {
    final candidates = plan.forTarget(target).toList();
    final skipped =
        plan.skip.where((entry) => entry.candidate.target == target).length;

    // **Re-read the gate immediately before the phase that depends on it.** The
    // plan was made a moment ago and a download can start in that moment; the
    // cost of being wrong here is deleting an archive somebody is installing.
    // Nothing blocks `enqueue` for this — holding up a user's download for
    // housekeeping is the worse trade, and the worst case of losing this race
    // is a re-download.
    if (candidates.isNotEmpty && _gated(target)) {
      return ReclaimTargetResult(
        target: target,
        freedBytes: 0,
        removedCount: 0,
        skippedCount: skipped + candidates.length,
        refusal: downloadsBusy()
            ? ReclaimSkipReason.downloadsActive
            : ReclaimSkipReason.installInProgress,
      );
    }

    var freed = 0;
    var removed = 0;
    var failed = 0;
    for (final candidate in candidates) {
      if (await _delete(candidate)) {
        freed += candidate.bytes;
        removed++;
      } else {
        failed++;
      }
    }

    return ReclaimTargetResult(
      target: target,
      freedBytes: freed,
      removedCount: removed,
      skippedCount: skipped + failed,
      refusal: plan.refusalFor(target),
    );
  }

  bool _gated(ReclaimTarget target) => switch (target) {
        ReclaimTarget.completedArchives ||
        ReclaimTarget.abandonedPartials =>
          downloadsBusy() || installBusy(),
        ReclaimTarget.tempExtracts => installBusy(),
        ReclaimTarget.legacyImages ||
        ReclaimTarget.oldLogs ||
        ReclaimTarget.unclaimedSnapshots =>
          false,
      };

  /// **The file, never a shared directory.** `<appData>/downloads` holds every other archive and every in-flight partial,
  /// so removing the parent would take all of them.
  /// The two directories deleted whole are a temp extraction whose name is ours, and a backup group directly under `backups/`.
  Future<bool> _delete(ReclaimCandidate candidate) async {
    try {
      if (candidate.isDirectory) {
        if (!_isDeletableDirectory(candidate)) return false;
        await Directory(candidate.path).delete(recursive: true);
      } else {
        await File(candidate.path).delete();
      }
      return true;
    } catch (e) {
      // Housekeeping never throws: a file we could not remove is wasted space,
      // not a failure the user can act on.
      _log.debug('could not reclaim a file',
          fields: {'file': candidate.name, 'reason': '$e'});
      return false;
    }
  }

  bool _isDeletableDirectory(ReclaimCandidate candidate) => switch (candidate.target) {
        ReclaimTarget.tempExtracts =>
          path.basename(candidate.path).startsWith(archiveExtractPrefix),
        ReclaimTarget.unclaimedSnapshots =>
          path.equals(path.dirname(candidate.path), roots.backups.path),
        _ => false,
      };

  Future<List<ReclaimCandidate>> _gather() async {
    final inventory = <ReclaimCandidate>[];
    inventory.addAll(await _gatherDownloads());
    inventory.addAll(await _gatherTempExtracts());
    inventory.addAll(await _gatherSnapshotGroups());
    inventory.addAll(await _gatherFlat(
      roots.legacyImages,
      ReclaimTarget.legacyImages,
    ));
    inventory.addAll(await _gatherFlat(roots.logs, ReclaimTarget.oldLogs));
    return inventory;
  }

  Future<List<ReclaimCandidate>> _gatherDownloads() async {
    final all = await _gatherFlat(
      roots.downloads,
      ReclaimTarget.completedArchives,
    );
    final partials = <ReclaimCandidate>[];
    final archives = <ReclaimCandidate>[];
    final byStem = <String, List<ReclaimCandidate>>{};

    for (final candidate in all) {
      final name = candidate.name;
      if (name.endsWith(DownloadPaths.recordSuffix)) {
        byStem
            .putIfAbsent(
                name.substring(
                    0, name.length - DownloadPaths.recordSuffix.length),
                () => <ReclaimCandidate>[])
            .add(candidate);
      } else if (name.endsWith(DownloadPaths.partSuffix)) {
        byStem
            .putIfAbsent(
                name.substring(0, name.length - DownloadPaths.partSuffix.length),
                () => <ReclaimCandidate>[])
            .add(candidate);
      } else {
        archives.add(candidate);
      }
    }

    final cutoff = _now().subtract(DownloadPaths.staleAfter);
    for (final pair in byStem.values) {
      // The same rule `DownloadPaths.sweep` applies at launch: a `.part` with no
      // record or a record with no `.part` is wreckage, and a complete pair
      // nobody has touched for a week is abandoned. Anything newer is a
      // resumable transfer and is left alone even when the gate is open.
      final orphaned = pair.length < 2;
      final stale = pair.every((c) => c.modified.isBefore(cutoff));
      if (!orphaned && !stale) continue;
      partials.addAll(pair.map((c) => ReclaimCandidate(
            target: ReclaimTarget.abandonedPartials,
            path: c.path,
            name: c.name,
            bytes: c.bytes,
            modified: c.modified,
          )));
    }

    return [...archives, ...partials];
  }

  Future<List<ReclaimCandidate>> _gatherTempExtracts() async {
    final found = <ReclaimCandidate>[];
    try {
      if (!await roots.temp.exists()) return found;
      await for (final entity in roots.temp.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = path.basename(entity.path);
        if (!name.startsWith(archiveExtractPrefix)) continue;
        final size = await measureDirectory(entity.path);
        final newest = await newestWriteWithin(entity);
        found.add(ReclaimCandidate(
          target: ReclaimTarget.tempExtracts,
          path: entity.path,
          name: name,
          bytes: size.bytes,
          // Unknown reads as "just now", which keeps it.
          modified: newest ?? _now(),
          isDirectory: true,
        ));
      }
    } catch (e) {
      _log.debug('could not list temp extractions', fields: {'reason': '$e'});
    }
    return found;
  }

  /// One candidate per group directory, named by the uid the planner checks against the library.
  Future<List<ReclaimCandidate>> _gatherSnapshotGroups() async {
    final found = <ReclaimCandidate>[];
    try {
      if (!await roots.backups.exists()) return found;
      await for (final entity in roots.backups.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final size = await measureDirectory(entity.path);
        final newest = await newestWriteWithin(entity);
        found.add(ReclaimCandidate(
          target: ReclaimTarget.unclaimedSnapshots,
          path: entity.path,
          name: path.basename(entity.path),
          bytes: size.bytes,
          modified: newest ?? _now(),
          isDirectory: true,
        ));
      }
    } catch (e) {
      _log.debug('could not list saved versions', fields: {'reason': '$e'});
    }
    return found;
  }

  Future<List<ReclaimCandidate>> _gatherFlat(
    Directory directory,
    ReclaimTarget target,
  ) async {
    final found = <ReclaimCandidate>[];
    try {
      if (!await directory.exists()) return found;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          found.add(ReclaimCandidate(
            target: target,
            path: entity.path,
            name: path.basename(entity.path),
            bytes: stat.size,
            modified: stat.modified,
          ));
        } catch (_) {
          // Cannot measure it, so it is not a candidate.
        }
      }
    } catch (e) {
      _log.debug('could not list a reclaimable folder',
          fields: {'path': directory.path, 'reason': '$e'});
    }
    return found;
  }

  /// Legacy images still doing a job: the mod exists **and** has no sidecar,
  /// which is the only branch that still reads that directory.
  /// Null when the question could not be answered, which the caller turns into
  /// a refusal rather than an empty set — an empty set here would mean "none of
  /// them are reachable", and that deletes the lot.
  Future<Set<String>?> _reachableLegacyImages(Set<String>? library) async {
    final libraryRoot = roots.modsLibrary;
    if (library == null || libraryRoot == null) return null;
    final reachable = <String>{};
    try {
      if (!await roots.legacyImages.exists()) return reachable;
      await for (final entity in roots.legacyImages.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        // The store is keyed by folder name, which is why it accumulates at
        // all: a rename is not an event this app sees.
        final modName = path.basenameWithoutExtension(entity.path);
        if (!library.contains(modName)) continue;
        final folder = path.join(libraryRoot.path, modName);
        if (await _metadata.hasSidecar(folder)) continue;
        reachable.add(name);
      }
    } catch (_) {
      return null;
    }
    return reachable;
  }

  Future<int?> _readFreeSpace() async {
    final probe = _freeSpace;
    if (probe == null) return null;
    try {
      return await probe(roots.appData.path);
    } catch (_) {
      return null;
    }
  }
}
