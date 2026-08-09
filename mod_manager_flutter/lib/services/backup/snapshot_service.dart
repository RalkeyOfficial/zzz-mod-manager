import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../utils/directory_copy.dart';
import '../../utils/path_helper.dart';
import 'retention.dart';

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
///   <mod folder name>/
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
class SnapshotService {
  SnapshotService({String? rootPath, this.policy = RetentionPolicy.standard})
      : _rootPath = rootPath;

  final String? _rootPath;
  final RetentionPolicy policy;

  /// `<appData>/backups`, or an injected path in tests.
  String get rootPath => _rootPath ?? path.join(PathHelper.getAppDataPath(), 'backups');

  Directory get _root => Directory(rootPath);

  Directory _modDir(String modName) => Directory(path.join(rootPath, modName));

  /// Copies [modFolder] into a new snapshot. Returns null if nothing could be
  /// written — a full disk, a read-only app-data directory.
  ///
  /// A failure here is the caller's cue to **stop**, not to carry on unprotected:
  /// there is no other way back from an overwrite.
  Future<ModSnapshot?> capture({
    required String modName,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async {
    try {
      if (!await modFolder.exists()) return null;
      final takenAt = now ?? DateTime.now();
      final dir = await _createSnapshotDir(modName, takenAt);
      final files = Directory(path.join(dir.path, 'files'));

      final written = await copyDirectory(modFolder, files);
      final size = await _directorySize(files);

      final snapshot = ModSnapshot(
        modName: modName,
        id: path.basename(dir.path),
        takenAt: takenAt,
        sizeBytes: size,
        fileCount: written,
        reason: reason,
        version: version,
        versionLabel: versionLabel,
        directory: dir,
      );
      await File(path.join(dir.path, _manifestName))
          .writeAsString(const JsonEncoder.withIndent('  ').convert(snapshot.toJson()));
      return snapshot;
    } catch (e) {
      print('SnapshotService: could not snapshot $modName: $e');
      return null;
    }
  }

  /// Every snapshot of one mod, newest first.
  Future<List<ModSnapshot>> list(String modName) async {
    final dir = _modDir(modName);
    if (!await dir.exists()) return const [];
    final snapshots = <ModSnapshot>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final snapshot = await _read(modName, entity);
        if (snapshot != null) snapshots.add(snapshot);
      }
    } catch (e) {
      print('SnapshotService: could not list snapshots for $modName: $e');
    }
    snapshots.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return snapshots;
  }

  /// The mod folder names that have at least one snapshot.
  ///
  /// One `readdir` and no manifests: the directory names *are* the answer. It is
  /// what the context menu asks before offering a rollback, so it has to stay
  /// cheaper than the thing it is gating.
  Future<Set<String>> modsWithSnapshots() async {
    try {
      if (!await _root.exists()) return const <String>{};
      final names = <String>{};
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is Directory) names.add(path.basename(entity.path));
      }
      return names;
    } catch (e) {
      print('SnapshotService: could not list backup folders: $e');
      return const <String>{};
    }
  }

  /// Every snapshot of every mod.
  Future<List<ModSnapshot>> listAll() async {
    if (!await _root.exists()) return const [];
    final all = <ModSnapshot>[];
    try {
      await for (final entity in _root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        all.addAll(await list(path.basename(entity.path)));
      }
    } catch (e) {
      print('SnapshotService: could not list snapshots: $e');
    }
    return all;
  }

  /// Writes a snapshot's `files/` back over [modFolder].
  ///
  /// **Overwrite, like the update itself.** Restoring by emptying the folder
  /// first would destroy anything the user added since — the very case the
  /// update path refuses to destroy. What that leaves behind is files the newer
  /// version shipped and the older one did not, which matters for exactly one
  /// file class: an orphaned `.ini` fights the restored one. The caller resolves
  /// that with the same stale-`.ini` rule the update uses, in the opposite
  /// direction.
  Future<bool> restoreInto(ModSnapshot snapshot, Directory modFolder) async {
    try {
      final files = Directory(path.join(snapshot.directory.path, 'files'));
      if (!await files.exists()) return false;
      if (!await modFolder.exists()) await modFolder.create(recursive: true);
      await copyDirectory(files, modFolder);
      return true;
    } catch (e) {
      print('SnapshotService: could not restore ${snapshot.modName}: $e');
      return false;
    }
  }

  Future<bool> delete(ModSnapshot snapshot) async {
    try {
      if (await snapshot.directory.exists()) {
        await snapshot.directory.delete(recursive: true);
      }
      // Leave no empty per-mod directory behind — it would otherwise show up in
      // `listAll` forever as a mod with no snapshots.
      final modDir = _modDir(snapshot.modName);
      if (await modDir.exists() && await modDir.list().isEmpty) {
        await modDir.delete();
      }
      return true;
    } catch (e) {
      print('SnapshotService: could not delete ${snapshot.id}: $e');
      return false;
    }
  }

  /// Applies [policy] across every mod. Returns the plan it carried out, so the
  /// caller can report an over-budget remainder rather than pretend it pruned.
  Future<RetentionPlan> prune({DateTime? now}) async {
    final snapshots = await listAll();
    final byRef = {for (final s in snapshots) s.ref: s};
    final plan = planRetention(
      snapshots.map((s) => s.ref).toList(),
      policy: policy,
      now: now ?? DateTime.now(),
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
  Future<Directory> _createSnapshotDir(String modName, DateTime takenAt) async {
    final t = takenAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    for (var i = 0; i < 1000; i++) {
      final dir = Directory(
        path.join(rootPath, modName, '$stamp-${i.toString().padLeft(3, '0')}'),
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        return dir;
      }
    }
    throw StateError('could not allocate a snapshot directory for $modName');
  }

  Future<ModSnapshot?> _read(String modName, Directory dir) async {
    final files = Directory(path.join(dir.path, 'files'));
    if (!await files.exists()) return null;
    final manifest = File(path.join(dir.path, _manifestName));
    Map<String, dynamic>? json;
    try {
      if (await manifest.exists()) {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map<String, dynamic>) json = decoded;
      }
    } catch (_) {
      // A corrupt manifest must not hide the files it describes: the snapshot
      // is still restorable, and a rollback the user cannot reach is the one
      // failure this whole service exists to prevent.
    }
    return ModSnapshot.fromManifest(
      modName: modName,
      id: path.basename(dir.path),
      directory: dir,
      json: json,
      // Falls back to a real walk when there is no manifest to read a size from,
      // so retention still bounds a directory this app did not write.
      fallbackSize: json == null ? await _directorySize(files) : 0,
      fallbackTakenAt: await dir.stat().then((s) => s.modified),
    );
  }

  Future<int> _directorySize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) total += await entity.length();
      }
    } catch (_) {
      // Best effort — a size we could not read is reported as what we could.
    }
    return total;
  }
}

/// Why a snapshot was taken. Shown in the restore list, because "before the
/// update" and "before rolling back" are things a user needs to tell apart when
/// there are two of them from the same afternoon.
enum SnapshotReason {
  beforeUpdate,
  beforeRestore;

  static SnapshotReason parse(Object? raw) => switch (raw) {
        'before_restore' => SnapshotReason.beforeRestore,
        _ => SnapshotReason.beforeUpdate,
      };

  String get wire => switch (this) {
        SnapshotReason.beforeUpdate => 'before_update',
        SnapshotReason.beforeRestore => 'before_restore',
      };
}

/// One snapshot on disk.
class ModSnapshot {
  const ModSnapshot({
    required this.modName,
    required this.id,
    required this.takenAt,
    required this.sizeBytes,
    required this.directory,
    this.fileCount = 0,
    this.reason = SnapshotReason.beforeUpdate,
    this.version,
    this.versionLabel,
  });

  final String modName;
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
        modName: modName,
        id: id,
        takenAt: takenAt,
        sizeBytes: sizeBytes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mod': modName,
        'taken_at': takenAt.toUtc().toIso8601String(),
        'size_bytes': sizeBytes,
        'file_count': fileCount,
        'reason': reason.wire,
        if (version != null) 'version': version,
        if (versionLabel != null) 'version_label': versionLabel,
      };

  static ModSnapshot fromManifest({
    required String modName,
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
      modName: modName,
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
