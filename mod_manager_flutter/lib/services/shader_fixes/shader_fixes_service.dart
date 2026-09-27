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

  /// Mods that switched on using shader files already in the folder with the
  /// same bytes, which stay there when the mod is off.
  static Stream<ShaderAdoption> get adoptions => _adoptions.stream;
  static final StreamController<ShaderAdoption> _adoptions = StreamController.broadcast();

  /// Reports that [mod] adopted [count] files. Called once the mod is actually on.
  static void announceAdopted(String mod, int count) => _adoptions.add(ShaderAdoption(mod, count));

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
  /// shader folder to copy to, or a target holds different bytes. Files already
  /// there with the same bytes are held rather than copied. The caller
  /// [announce]s the copies and [announceAdopted]s the adoptions once the mod is on.
  Future<ShaderPlacementResult> place({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
  }) => _serialised(() async {
        final ready = await _prepare(modDir: modDir, uid: uid, mod: mod, saveModsPath: saveModsPath);
        if (ready == null) return const ShaderPlacementResult(copied: 0, adopted: 0);

        final placed = <ShaderEntry>[];
        try {
          for (final copy in ready.plan.copy) {
            final from = File(p.join(ready.part.path, copy.source.path));
            final to = File(p.join(ready.folder, copy.source.path));
            await to.parent.create(recursive: true);
            await copyKeepingTime(from, to.path);
            placed.add(copy.entry);
            _files.info('shader file placed', fields: {'mod': mod, 'file': to.path});
          }
        } finally {
          // Recorded even when a copy failed partway, so what did land is held
          // and the caller's undo takes it back out.
          final added = [...ready.plan.held, ...placed];
          if (added.isNotEmpty) await _writeRecord(ready.record.apply(added: added));
        }
        if (ready.plan.adopted > 0) {
          _log.info('shader files already present, adopted',
              fields: {'mod': mod, 'files': ready.plan.adopted});
        }
        return ShaderPlacementResult(copied: placed.length, adopted: ready.plan.adopted);
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
    final listing = await _listFolder(folder);
    final onDisk = <String, String?>{};
    for (final source in sources) {
      final key = ShaderFixesRecord.keyOf(source.path);
      if (listing[key] case final actual?) {
        onDisk[key] = await md5OfFile(File(p.join(folder, actual)));
      }
    }
    final plan = planShaderPlacement(
      uid: uid,
      mod: mod,
      folder: folder,
      sources: sources,
      onDisk: onDisk,
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

  /// Lets go of the shader files the mod [uid] holds, in whichever shader folder
  /// each is, deleting those nobody else holds. Returns the files left in place
  /// because they changed after they were placed.
  ///
  /// [announce] is false when undoing a placement whose mod never came on, so the
  /// restart notice does not name it. A file that could not be deleted stays held,
  /// so the next disable retries it; [retryFailed] is false when the mod is being
  /// deleted, since nothing could ever let go of it after that.
  Future<List<String>> remove({
    required String uid,
    required String mod,
    bool announce = true,
    bool retryFailed = true,
  }) => _serialised(() async {
        var record = await _readRecord();
        final folders = record.heldBy(uid).map((entry) => entry.folder).toSet();
        final changed = <String>[];
        var deletedAny = false;

        for (final folder in folders) {
          // With the folder gone there is nothing to take back out; the record is
          // kept so the files are removed if it returns.
          if (!await Directory(folder).exists()) continue;

          final listing = await _listFolder(folder);
          final onDisk = <String, String?>{};
          for (final entry in record.heldBy(uid).where((entry) => entry.folder == folder)) {
            for (final key in [ShaderFixesRecord.keyOf(entry.path), ?cacheBinFor(entry.path)]) {
              if (listing[key] case final actual?) {
                onDisk[key] = await md5OfFile(File(p.join(folder, actual)));
              }
            }
            if (!listing.containsKey(ShaderFixesRecord.keyOf(entry.path))) {
              for (final copy in launcherCopiesOf(entry.path, listing.keys)) {
                onDisk[copy] = await md5OfFile(File(p.join(folder, listing[copy]!)));
              }
            }
          }

          final plan = planShaderRemoval(uid: uid, folder: folder, record: record, onDisk: onDisk);
          final emptied = <String>{};
          final deleted = <ShaderEntry>[];
          for (final key in plan.delete) {
            final file = File(p.join(folder, listing[key]!));
            try {
              await file.delete();
              if (!plan.launcherCopies.contains(key)) deletedAny = true;
              if (plan.forgetOnDelete[key] case final entry?) deleted.add(entry);
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
          final dropped = retryFailed ? deleted : plan.forgetOnDelete.values;
          record = record.apply(removed: [...plan.forget, ...dropped], added: plan.update);
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

/// What [ShaderFixesService.place] did: files copied in, and files already there
/// with the same bytes that the mod now uses and that stay when it is off.
class ShaderPlacementResult {
  const ShaderPlacementResult({required this.copied, required this.adopted});
  final int copied;
  final int adopted;
}

/// A mod that switched on using [count] files already in the shader folder.
class ShaderAdoption {
  const ShaderAdoption(this.mod, this.count);
  final String mod;
  final int count;
}

class _Prepared {
  const _Prepared(this.part, this.folder, this.record, this.plan);
  final Directory part;
  final String folder;
  final ShaderFixesRecord record;
  final ShaderCopyPlan plan;
}
