import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/directory_copy.dart';
import '../../utils/directory_size.dart';
import '../../utils/path_helper.dart';
import '../log/logger.dart';
import '../platform_service_factory.dart';
import 'retention.dart';

final Logger _log = Logger('snapshot');

/// Pre-update snapshots of a mod folder, and the way back from a bad update.
///
/// ## They live outside `modsPath`, and that is not a preference
///
/// A snapshot placed *inside* the mod folder is reachable through the active
/// symlink, so the game's loader walks into it and reads the old version's
/// `.ini` alongside the new one — duplicate hotkeys and conflicting overrides,
/// which present to the user as "the update broke my mod". They go in
/// `<appData>/backups/<mod>/<id>/` instead.
///
/// ## Every apply snapshots, unconditionally
///
/// The update path deliberately accepts losses it cannot distinguish from
/// intended changes — a rebound keybind reverted by a shipped `.ini`, a patch
/// overwritten by the mod it patches, any hand edit. Each of those is defensible
/// **only** while the recourse exists, so the snapshot is not a setting and not
/// an opt-in. It is also the only recovery from a half-finished copy: overwrite
/// has no aside-folder to fall back on the way a swap would.
///
/// ## Layout
///
/// ```
/// <appData>/backups/
///   a1b2c3d4e5f60718293a4b5c6d7e8f90/    ← the mod's uid, never its name
///     20260809-142530-000/
///       manifest.json     ← what this is, taken when, of what version
///       files/            ← the mod folder, verbatim, sidecar included
/// ```
///
/// The manifest sits beside `files/` rather than inside it so a restore can copy
/// `files/` back wholesale without carrying our bookkeeping into the mod. The
/// sidecar **is** included: a rollback that restored the files but kept the new
/// origin block would leave the app checking for updates against a file the
/// folder no longer holds.
///
/// ## Keyed by the mod's uid, and that is the whole design
///
/// A group named after the mod **folder** is stranded by any rename the app
/// does not perform — a rename in a file manager runs no hook, so every
/// rollback point for that mod becomes unreachable *and* exempt from pruning,
/// because retention protects each group's newest entry forever. Keyed by the
/// uid in the folder's own sidecar (`services/mod_uid.dart`), a rename is a
/// non-event however it happens.
///
/// It also makes reclaiming the space possible at all: a group whose uid no
/// folder claims is **unambiguously** a deleted mod, where a group whose *name*
/// nothing matches might be a mod the user renamed and still wants.
///
/// The cost is a directory nobody can read by eye. Each snapshot's manifest
/// carries the name the mod had when it was taken, which is what a screen
/// shows; the path is for the machine.
class SnapshotService {
  /// [freeSpace] is the free-space seam `ArchiveService.extractArchive` and `DownloadService` take, for the preflight in [take]; the platform's answer by default.
  /// [deleteTree] removes a snapshot's directory once its manifest is gone; a recursive delete by default, injected by a test that needs it to stop part-way.
  SnapshotService({
    String? rootPath,
    this.policy = RetentionPolicy.standard,
    Future<int?> Function(String path)? freeSpace,
    Future<void> Function(Directory dir)? deleteTree,
  })  : _rootPath = rootPath,
        _freeSpace = freeSpace,
        _deleteTree = deleteTree ?? _deleteRecursively;

  final String? _rootPath;
  final RetentionPolicy policy;
  final Future<void> Function(Directory dir) _deleteTree;

  static Future<void> _deleteRecursively(Directory dir) => dir.delete(recursive: true);
  final Future<int?> Function(String path)? _freeSpace;

  /// `<appData>/backups`, or an injected path in tests.
  String get rootPath => _rootPath ?? path.join(PathHelper.getAppDataPath(), 'backups');

  Directory get _root => Directory(rootPath);

  Directory _groupDir(String modUid) => Directory(path.join(rootPath, modUid));

  /// Copies [modFolder] into a new snapshot, or says why nothing was written.
  ///
  /// A failure here is the caller's cue to **stop**, not to carry on unprotected: there is no other way back from an overwrite.
  /// [modUid] is which group this belongs to — the mod's identity, not its name ([ModUid]). [modName] is recorded in the manifest as what the mod was called at the time, for a screen to show.
  ///
  /// **Refused before copying when the folder provably will not fit** in the backups volume ([SnapshotAttempt.noRoom]), against two real numbers as the unpack's check is: an unknown free space copies anyway.
  /// A copy that fails part-way deletes the directory it made, so no partial snapshot is ever the newest of its mod.
  Future<SnapshotAttempt> take({
    required String modName,
    required String modUid,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async {
    Directory? dir;
    try {
      if (!await modFolder.exists()) return const SnapshotAttempt.failed();

      final noRoom = await _spaceShortfall(modFolder);
      if (noRoom != null) {
        _log.warning('refused for space', fields: {
          'mod': modName,
          'required': noRoom.requiredBytes,
          'available': noRoom.availableBytes,
        });
        return SnapshotAttempt.refused(noRoom);
      }

      final takenAt = now ?? DateTime.now();
      dir = await _createSnapshotDir(modUid, takenAt);
      final files = Directory(path.join(dir.path, 'files'));

      final written = await copyDirectory(modFolder, files);

      final snapshot = ModSnapshot(
        modName: modName,
        modUid: modUid,
        id: path.basename(dir.path),
        takenAt: takenAt,
        sizeBytes: written.fold(0, (sum, file) => sum + file.bytes),
        fileCount: written.length,
        reason: reason,
        version: version,
        versionLabel: versionLabel,
        directory: dir,
      );
      // Written last: its presence is what marks the copy as whole ([_read]).
      await File(path.join(dir.path, _manifestName))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(snapshot.toJson()));
      return SnapshotAttempt.taken(snapshot);
    } catch (e) {
      // **Critical, and the only place that earns it.** The applier's contract
      // is that no update is written without a snapshot first; this is the
      // moment that contract breaks, and the user's folder is about to be
      // overwritten with no way back.
      _log.critical('could not take a snapshot',
          error: e, fields: {'mod': modName});
      await _discard(modUid, dir);
      return const SnapshotAttempt.failed();
    }
  }

  /// Every snapshot of one mod, newest first.
  ///
  /// Keyed by the mod's uid, so this answers for the folder whatever it is
  /// called today. **Empty for a null uid**, which is a mod nothing has ever
  /// had to remember — it cannot have snapshots, because there was no identity
  /// to file them under.
  Future<List<ModSnapshot>> list(String? modUid) async {
    if (modUid == null || modUid.isEmpty) return const [];
    final dir = _groupDir(modUid);
    if (!await dir.exists()) return const [];
    final snapshots = <ModSnapshot>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final snapshot = await _read(modUid, entity);
        if (snapshot != null) snapshots.add(snapshot);
      }
    } catch (e) {
      _log.warning('could not list snapshots',
          error: e, fields: {'uid': modUid});
    }
    snapshots.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return snapshots;
  }

  /// The mod **uids** that have at least one snapshot.
  ///
  /// One `readdir` and no manifests: the directory names *are* the answer. It is
  /// what the context menu asks before offering a rollback, so it has to stay
  /// cheaper than the thing it is gating — and it stays that cheap under uid
  /// keying, because the comparison moves from a mod's name to its uid and the
  /// scan already carries both.
  Future<Set<String>> uidsWithSnapshots() async {
    try {
      if (!await _root.exists()) return const <String>{};
      final uids = <String>{};
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is Directory) uids.add(path.basename(entity.path));
      }
      return uids;
    } catch (e) {
      _log.warning('could not list backup folders', error: e);
      return const <String>{};
    }
  }

  /// Every snapshot of every mod, including groups no folder claims any more.
  Future<List<ModSnapshot>> listAll() async {
    if (!await _root.exists()) return const [];
    final all = <ModSnapshot>[];
    try {
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        all.addAll(await list(path.basename(entity.path)));
      }
    } catch (e) {
      _log.warning('could not list snapshots', error: e);
    }
    return all;
  }

  /// Writes a snapshot's `files/` back over [modFolder].
  ///
  /// A copy, not a replacement: the caller removes what the newer version added afterwards,
  /// so a copy that fails part-way has deleted nothing.
  Future<bool> restoreInto(ModSnapshot snapshot, Directory modFolder) async {
    try {
      final files = Directory(path.join(snapshot.directory.path, 'files'));
      if (!await files.exists()) return false;
      if (!await modFolder.exists()) await modFolder.create(recursive: true);
      await copyDirectory(files, modFolder);
      return true;
    } catch (e) {
      _log.error('could not restore a snapshot', error: e, fields: {
        'mod': snapshot.modName,
        'snapshot': snapshot.id,
      });
      return false;
    }
  }

  Future<bool> delete(ModSnapshot snapshot) async {
    try {
      await _deleteSnapshotDir(snapshot.directory);
      await _deleteGroupIfEmpty(snapshot.modUid);
      return true;
    } catch (e) {
      _log.warning('could not delete a snapshot',
          error: e, fields: {'snapshot': snapshot.id});
      return false;
    }
  }

  /// Removes **every** snapshot of one mod, for a mod that is being deleted.
  ///
  /// Not part of retention: the budget's job is to keep the newest way back for
  /// each mod alive, and this is the one case where there is no mod left to
  /// have a way back to. True when nothing of the group remains, including when
  /// there was nothing there to begin with.
  Future<bool> deleteGroup(String modUid) async {
    if (modUid.isEmpty) return false;
    final dir = _groupDir(modUid);
    try {
      if (!await dir.exists()) return true;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) await _deleteSnapshotDir(entity);
      }
      await dir.delete(recursive: true);
      return true;
    } catch (e) {
      // Wasted space, not a failed delete: the mod itself is already gone by
      // the time this runs, and saying otherwise would report a failure the
      // user cannot act on.
      _log.warning('could not remove a deleted mod\'s saved versions',
          error: e, fields: {'uid': modUid});
      return false;
    }
  }

  /// Applies [policy] across every mod. Returns the plan it carried out, so the
  /// caller can report an over-budget remainder rather than pretend it pruned.
  Future<RetentionPlan> prune() async {
    final snapshots = await listAll();
    final byRef = {for (final s in snapshots) s.ref: s};
    final plan = planRetention(
      snapshots.map((s) => s.ref).toList(),
      policy: policy,
    );
    for (final ref in plan.prune) {
      final snapshot = byRef[ref];
      if (snapshot != null) await delete(snapshot);
    }
    return plan;
  }

  Future<int> totalBytes() async {
    var total = 0;
    for (final snapshot in await listAll()) {
      total += snapshot.sizeBytes;
    }
    return total;
  }

  // ------------------------------------------------------------------ private

  static const String _manifestName = 'manifest.json';

  /// `20260809-142530-000`, with the trailing counter resolving the collision
  /// two snapshots taken in the same second would otherwise have. Sortable as a
  /// string, which is what makes the directory listing readable by hand.
  Future<Directory> _createSnapshotDir(String modUid, DateTime takenAt) async {
    final t = takenAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    for (var i = 0; i < 1000; i++) {
      final dir = Directory(
        path.join(rootPath, modUid, '$stamp-${i.toString().padLeft(3, '0')}'),
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        return dir;
      }
    }
    throw StateError('could not allocate a snapshot directory for $modUid');
  }

  /// Deletes one snapshot's directory, its manifest first, so a delete stopped part-way leaves a directory [_read] does not list rather than a manifest beside half its files.
  Future<void> _deleteSnapshotDir(Directory dir) async {
    if (!await dir.exists()) return;
    final manifest = File(path.join(dir.path, _manifestName));
    if (await manifest.exists()) await manifest.delete();
    await _deleteTree(dir);
  }

  /// Leaves no empty group directory behind: it would otherwise read as a mod with snapshots in [uidsWithSnapshots].
  Future<void> _deleteGroupIfEmpty(String modUid) async {
    final groupDir = _groupDir(modUid);
    if (await groupDir.exists() && await groupDir.list().isEmpty) {
      await groupDir.delete();
    }
  }

  /// Deletes what a failed [take] made. Never throws: the failure being reported is the capture's.
  Future<void> _discard(String modUid, Directory? dir) async {
    try {
      if (dir != null) await _deleteSnapshotDir(dir);
      await _deleteGroupIfEmpty(modUid);
    } catch (e) {
      _log.warning('could not delete an unfinished snapshot',
          error: e, fields: {'uid': modUid, 'snapshot': dir?.path});
    }
  }

  /// A refusal when [modFolder] provably will not fit in the backups volume, or null to carry on: an unknown free space, an empty folder, or room.
  ///
  /// The free space is asked first, so an unknown one costs no walk. A walk that could not read everything still refuses when what it did read is over the free space, since the copy needs at least that.
  Future<SnapshotNoRoom?> _spaceShortfall(Directory modFolder) async {
    final freeSpace = _freeSpace ?? PlatformServiceFactory.getInstance().freeSpaceBytes;
    final available = await freeSpace(await _nearestExisting(rootPath));
    if (available == null) return null;
    final needed = (await measureDirectory(modFolder.path)).bytes;
    if (needed <= available) return null;
    return SnapshotNoRoom(requiredBytes: needed, availableBytes: available);
  }

  /// [dirPath], or its nearest ancestor that exists: free space is asked of a path that exists, and `backups/` is made by the first snapshot.
  static Future<String> _nearestExisting(String dirPath) async {
    var current = dirPath;
    while (!await Directory(current).exists()) {
      final parent = path.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return current;
  }

  /// A directory with no manifest is not a snapshot: [take] writes the manifest after the copy and a delete removes it first, so its absence means a copy that never finished or a delete that did not, and a restore from it would delete every file it is missing.
  Future<ModSnapshot?> _read(String modUid, Directory dir) async {
    final files = Directory(path.join(dir.path, 'files'));
    if (!await files.exists()) return null;
    final manifest = File(path.join(dir.path, _manifestName));
    if (!await manifest.exists()) return null;
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // A corrupt manifest must not hide the files it describes: the snapshot
      // is still restorable, and a rollback the user cannot reach is the one
      // failure this whole service exists to prevent.
    }
    return ModSnapshot.fromManifest(
      modUid: modUid,
      id: path.basename(dir.path),
      directory: dir,
      json: json,
      // Falls back to a real walk when the manifest gives no size, so retention still bounds it.
      fallbackSize: json == null ? await _directorySize(files) : 0,
      fallbackTakenAt: await dir.stat().then((s) => s.modified),
    );
  }

  /// Best effort — a size we could not read is reported as what we could, which
  /// is what retention wants: a snapshot that measures short still counts
  /// towards the budget instead of being treated as free.
  Future<int> _directorySize(Directory dir) async =>
      (await measureDirectory(dir.path)).bytes;
}

/// What [SnapshotService.take] came to: a snapshot, or none, and when the reason is space, the figures.
class SnapshotAttempt {
  const SnapshotAttempt.taken(ModSnapshot this.snapshot) : noRoom = null;
  const SnapshotAttempt.refused(SnapshotNoRoom this.noRoom) : snapshot = null;
  const SnapshotAttempt.failed()
      : snapshot = null,
        noRoom = null;

  final ModSnapshot? snapshot;

  /// Set when the snapshot was refused before copying because it would not fit.
  final SnapshotNoRoom? noRoom;
}

/// A snapshot refused for space: what the mod folder holds and what the backups volume has free, in bytes. The words are the caller's.
class SnapshotNoRoom {
  const SnapshotNoRoom({required this.requiredBytes, required this.availableBytes});

  final int requiredBytes;
  final int availableBytes;
}

/// Why a snapshot was taken. Shown in the restore list, because "before the
/// update" and "before rolling back" are things a user needs to tell apart when
/// there are two of them from the same afternoon.
enum SnapshotReason {
  beforeUpdate,
  beforeRestore,

  /// A patch was taken back out of the folder. Its own reason rather than
  /// [beforeUpdate], because a rollback list that called this "before an update"
  /// would send a user looking for a version change that never happened.
  beforePatchRemoval;

  static SnapshotReason parse(Object? raw) => switch (raw) {
        'before_restore' => SnapshotReason.beforeRestore,
        'before_patch_removal' => SnapshotReason.beforePatchRemoval,
        _ => SnapshotReason.beforeUpdate,
      };

  String get wire => switch (this) {
        SnapshotReason.beforeUpdate => 'before_update',
        SnapshotReason.beforeRestore => 'before_restore',
        SnapshotReason.beforePatchRemoval => 'before_patch_removal',
      };
}

/// One snapshot on disk.
class ModSnapshot {
  const ModSnapshot({
    required this.modName,
    required this.modUid,
    required this.id,
    required this.takenAt,
    required this.sizeBytes,
    required this.directory,
    this.fileCount = 0,
    this.reason = SnapshotReason.beforeUpdate,
    this.version,
    this.versionLabel,
  });

  /// **What the mod was called when this was taken**, and nothing more.
  ///
  /// Informational since the store keyed by [modUid]: it is what a screen shows
  /// for a group whose folder has since been renamed, and it is empty for a
  /// snapshot whose manifest could not be read. Never used to find anything.
  final String modName;

  /// Which mod this is a snapshot **of** — the identity in its sidecar, which
  /// is also the directory this group lives in.
  final String modUid;

  final String id;
  final DateTime takenAt;
  final int sizeBytes;
  final int fileCount;
  final SnapshotReason reason;

  /// What the mod *was* when this was taken, from the origin block. Both may be
  /// null — most of a legacy library records neither — which is why the restore
  /// list leads with the date.
  final String? version;
  final String? versionLabel;

  final Directory directory;

  SnapshotRef get ref => SnapshotRef(
        modUid: modUid,
        id: id,
        takenAt: takenAt,
        sizeBytes: sizeBytes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mod': modName,
        'mod_uid': modUid,
        'taken_at': takenAt.toUtc().toIso8601String(),
        'size_bytes': sizeBytes,
        'file_count': fileCount,
        'reason': reason.wire,
        if (version != null) 'version': version,
        if (versionLabel != null) 'version_label': versionLabel,
      };

  /// [modUid] is the group's directory, which is the authority on which mod
  /// this belongs to — the manifest's copy is read only for the *name*, and a
  /// manifest that cannot be read costs a display string rather than the
  /// snapshot.
  static ModSnapshot fromManifest({
    required String modUid,
    required String id,
    required Directory directory,
    required Map<String, dynamic>? json,
    required int fallbackSize,
    required DateTime fallbackTakenAt,
  }) {
    DateTime? parsed;
    if (json?['taken_at'] case final String raw) {
      parsed = DateTime.tryParse(raw)?.toLocal();
    }
    return ModSnapshot(
      modName: json?['mod'] is String ? json!['mod'] as String : '',
      modUid: modUid,
      id: id,
      directory: directory,
      takenAt: parsed ?? fallbackTakenAt,
      sizeBytes: json?['size_bytes'] is int
          ? json!['size_bytes'] as int
          : fallbackSize,
      fileCount: json?['file_count'] is int ? json!['file_count'] as int : 0,
      reason: SnapshotReason.parse(json?['reason']),
      version: json?['version'] is String ? json!['version'] as String : null,
      versionLabel: json?['version_label'] is String
          ? json!['version_label'] as String
          : null,
    );
  }
}
