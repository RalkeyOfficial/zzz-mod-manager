import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/path_helper.dart';
import '../../utils/directory_copy.dart';
import '../archive_hash.dart';
import '../log/logger.dart';
import 'shader_fixes_plan.dart';
import 'zzmi_layout.dart';

final Logger _log = Logger('shaders');
final Logger _files = Logger('fileops');

/// Why a mod's shader files could not be placed. The enable is refused whole.
class ShaderPlacementRefused implements Exception {
  const ShaderPlacementRefused.noShaderFolder(this.mod) : conflicts = const [];
  const ShaderPlacementRefused.conflicts(this.mod, this.conflicts);

  final String mod;

  /// Empty when there is no ZZMI `d3dx.ini` beside the links folder.
  final List<ShaderConflict> conflicts;

  bool get noShaderFolder => conflicts.isEmpty;

  @override
  String toString() => noShaderFolder
      ? 'no d3dx.ini beside the links folder'
      : 'shader files already present: ${conflicts.map((c) => c.path).join(', ')}';
}

/// Copies a mod's `ShaderFixes/` into ZZMI's shader folder on enable and takes
/// it back out on disable (`docs/shader-fixes.md`).
///
/// Copies rather than links: a Windows file symlink needs Developer Mode, and
/// ZZMI writes `.bin` caches next to the sources, which through a link would land
/// in the library. What the app placed is recorded in app data, never in the mod's
/// sidecar, because it is a fact about this install and not about the mod.
class ShaderFixesService {
  ShaderFixesService({String? recordPath}) : _recordPath = recordPath;

  final String? _recordPath;

  String get recordPath =>
      _recordPath ?? p.join(PathHelper.getAppDataPath(), 'shader_fixes.json');

  /// The name of each mod whose placed files just changed, for the notice that
  /// shader changes need a game restart: ZZMI picks up a new replacement on F10
  /// only while hunting is on.
  static Stream<String> get changes => _changes.stream;
  static final StreamController<String> _changes = StreamController.broadcast();

  /// Reports that [mod]'s placed files changed. Called once the mod is actually
  /// on, so a placement undone because its link failed is never announced.
  static void announce(String mod) => _changes.add(mod);

  /// Refusals that happened with nobody pressing anything: a mod that was on
  /// before an update and could not be switched back on after it.
  static Stream<ShaderPlacementRefused> get unattendedRefusals => _unattendedRefusals.stream;
  static final StreamController<ShaderPlacementRefused> _unattendedRefusals = StreamController.broadcast();

  /// Reports [refusal] on [unattendedRefusals].
  static void reportUnattended(ShaderPlacementRefused refusal) => _unattendedRefusals.add(refusal);

  /// Operations run one at a time: each reads the record, changes the folder
  /// and writes the record back.
  Future<void> _queue = Future.value();

  Future<T> _serialised<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The mod's `ShaderFixes/` folder, matched case-insensitively, if it has one.
  static Future<Directory?> shaderPartOf(String modDir) async {
    final dir = Directory(modDir);
    if (!await dir.exists()) return null;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory && p.basename(entity.path).toLowerCase() == 'shaderfixes') {
        return entity;
      }
    }
    return null;
  }

  /// How many files the mod's `ShaderFixes/` holds; zero for a mod without one.
  static Future<int> shaderFileCount(String modDir) async {
    final part = await shaderPartOf(modDir);
    if (part == null) return 0;
    return part.list(recursive: true, followLinks: false).where((e) => e is File).length;
  }

  /// Whether enabling the mod would place its shader files, without copying any.
  ///
  /// Asked before anything else changes, so a Single-mode switch does not turn
  /// the character's other skin off for an enable that is then refused. Throws
  /// what [place] would throw. [uid] is null for a mod that has never needed one,
  /// which therefore placed nothing.
  Future<void> check({
    required String modDir,
    required String? uid,
    required String mod,
    required String saveModsPath,
  }) => _serialised(() async {
        await _prepare(modDir: modDir, uid: uid ?? '', mod: mod, saveModsPath: saveModsPath);
      });

  /// Copies the mod's shader files in. Does nothing for a mod without any.
  ///
  /// Throws [ShaderPlacementRefused] before copying anything when there is no
  /// shader folder to copy to, or a target belongs to another mod or to nobody
  /// the app knows. Returns how many files were copied; the caller [announce]s
  /// them once the mod is on.
  Future<int> place({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
  }) => _serialised(() async {
        final ready = await _prepare(modDir: modDir, uid: uid, mod: mod, saveModsPath: saveModsPath);
        if (ready == null) return 0;

        final placed = <ShaderPlacement>[];
        try {
          for (final source in ready.plan.sources) {
            final from = File(p.join(ready.part.path, source.path));
            final to = File(p.join(ready.folder, source.path));
            await to.parent.create(recursive: true);
            await copyKeepingTime(from, to.path);
            placed.add(ShaderPlacement(
              folder: ready.folder,
              path: source.path,
              uid: uid,
              mod: mod,
              md5: source.md5,
            ));
            _files.info('shader file placed', fields: {'mod': mod, 'file': to.path});
          }
        } finally {
          // Recorded even when a copy failed partway, so what did land is owned
          // and a disable takes it back out.
          if (placed.isNotEmpty) await _writeRecord(ready.record.apply(added: placed));
        }
        return placed.length;
      });

  /// Everything [place] decides before copying, or null for a mod without shader
  /// files. Throws [ShaderPlacementRefused] for an enable that must not happen.
  Future<_Prepared?> _prepare({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
  }) async {
    final part = await shaderPartOf(modDir);
    if (part == null) return null;
    final sources = await _sourcesIn(part);
    if (sources.isEmpty) return null;

    final folder = await findShaderFolder(saveModsPath);
    if (folder == null) throw ShaderPlacementRefused.noShaderFolder(mod);

    final record = await _readRecord();
    final plan = planShaderPlacement(
      uid: uid,
      folder: folder,
      sources: sources,
      existing: (await _listFolder(folder)).keys.toSet(),
      record: record,
    );
    if (plan is ShaderRefusedPlan) {
      _log.warning('shader files refused', fields: {
        'mod': mod,
        'conflicts': plan.conflicts.length,
      });
      throw ShaderPlacementRefused.conflicts(mod, plan.conflicts);
    }
    return _Prepared(part, folder, record, plan as ShaderCopyPlan);
  }

  /// Removes the shader files the mod [uid] placed, from whichever shader folder
  /// each went into. Returns the files left in place because they changed after
  /// they were placed.
  ///
  /// [announce] is false when undoing a placement whose mod never came on, so the
  /// restart notice does not name it.
  Future<List<String>> remove({
    required String uid,
    required String mod,
    bool announce = true,
  }) => _serialised(() async {
        var record = await _readRecord();
        final folders = record.ownedBy(uid).map((placement) => placement.folder).toSet();
        final changed = <String>[];
        var deletedAny = false;

        for (final folder in folders) {
          // With the folder gone there is nothing to take back out; the record is
          // kept so the files are removed if it returns.
          if (!await Directory(folder).exists()) continue;

          final listing = await _listFolder(folder);
          final onDisk = <String, String?>{};
          for (final placement in record.ownedBy(uid).where((placement) => placement.folder == folder)) {
            for (final key in [ShaderFixesRecord.keyOf(placement.path), ?cacheBinFor(placement.path)]) {
              if (listing[key] case final actual?) {
                onDisk[key] = await md5OfFile(File(p.join(folder, actual)));
              }
            }
          }

          final plan = planShaderRemoval(uid: uid, folder: folder, record: record, onDisk: onDisk);
          final emptied = <String>{};
          for (final key in plan.delete) {
            final file = File(p.join(folder, listing[key]!));
            try {
              await file.delete();
              deletedAny = true;
              _files.info('shader file removed', fields: {'mod': mod, 'file': file.path});
              emptied.add(file.parent.path);
            } on FileSystemException catch (error) {
              _log.warning('could not remove shader file', error: error, fields: {'file': file.path});
            }
          }
          await _removeEmptyFolders(emptied, under: folder);
          for (final key in plan.changed) {
            _log.info('shader file changed since placed, left in place',
                fields: {'mod': mod, 'file': p.join(folder, listing[key]!)});
            changed.add(listing[key]!);
          }
          record = record.apply(removed: plan.forget);
        }

        if (folders.isNotEmpty) await _writeRecord(record);
        if (deletedAny && announce) _changes.add(mod);
        return changed;
      });

  /// Every file in [folder], keyed by [ShaderFixesRecord.keyOf], to its spelling
  /// on disk. Listed rather than probed per name: on a case-sensitive filesystem
  /// `exists()` misses a file that differs only in case, which ZZMI under Wine
  /// treats as the same file.
  Future<Map<String, String>> _listFolder(String folder) async {
    final listing = <String, String>{};
    final dir = Directory(folder);
    if (!await dir.exists()) return listing;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: folder).replaceAll(r'\', '/');
      listing[ShaderFixesRecord.keyOf(relative)] = relative;
    }
    return listing;
  }

  /// Every file under [part], relative and `/`-separated, with its md5.
  Future<List<ShaderSource>> _sourcesIn(Directory part) async {
    final sources = <ShaderSource>[];
    await for (final entity in part.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final md5 = await md5OfFile(entity);
      if (md5 == null) continue;
      sources.add(ShaderSource(p.relative(entity.path, from: part.path).replaceAll(r'\', '/'), md5));
    }
    sources.sort((a, b) => a.path.compareTo(b.path));
    return sources;
  }

  /// Removes each folder in [folders] that is now empty, then its parents, up to
  /// but never including [under].
  Future<void> _removeEmptyFolders(Set<String> folders, {required String under}) async {
    final root = p.normalize(under);
    final ordered = folders.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (var current in ordered) {
      while (p.isWithin(root, current)) {
        final dir = Directory(current);
        if (!await dir.exists() || !await dir.list().isEmpty) break;
        await dir.delete();
        current = p.dirname(current);
      }
    }
  }

  Future<ShaderFixesRecord> _readRecord() async {
    final file = File(recordPath);
    try {
      if (!await file.exists()) return ShaderFixesRecord();
      return ShaderFixesRecord.fromJson(jsonDecode(await file.readAsString()));
    } on Object catch (error) {
      _log.warning('shader record unreadable, read as empty', error: error);
      return ShaderFixesRecord();
    }
  }

  /// Written to a temporary file and renamed over, so a crash mid-write leaves
  /// the previous record rather than half of one.
  Future<void> _writeRecord(ShaderFixesRecord record) async {
    final file = File(recordPath);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(record.toJson()));
    await temp.rename(file.path);
  }
}

class _Prepared {
  const _Prepared(this.part, this.folder, this.record, this.plan);
  final Directory part;
  final String folder;
  final ShaderFixesRecord record;
  final ShaderCopyPlan plan;
}
