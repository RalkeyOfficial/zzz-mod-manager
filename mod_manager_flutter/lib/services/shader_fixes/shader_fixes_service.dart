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
  const ShaderPlacementRefused.noShaderFolder(this.mod)
      : conflicts = const [],
        stillOn = null;
  const ShaderPlacementRefused.conflicts(this.mod, this.conflicts, {this.stillOn});

  final String mod;

  /// Empty when there is no ZZMI `d3dx.ini` beside the links folder.
  final List<ShaderConflict> conflicts;

  /// Another copy of the mod, whose link of this name the enable would replace, that a link of another name in
  /// ZZMI's Mods folder still keeps on, so its files were not taken out to make room.
  final ({String uid, String link})? stillOn;

  bool get noShaderFolder => conflicts.isEmpty;

  /// This refusal, saying the copy [uid] is still on through [link].
  ShaderPlacementRefused stillOnThrough(String uid, String link) =>
      noShaderFolder ? this : ShaderPlacementRefused.conflicts(mod, conflicts, stillOn: (uid: uid, link: link));

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
  /// [copyFile] copies one file keeping its time; a test passes one that fails partway.
  ShaderFixesService({String? recordPath, Future<void> Function(File source, String target)? copyFile})
      : _recordPath = recordPath,
        _copyFile = copyFile ?? copyKeepingTime;

  final String? _recordPath;
  final Future<void> Function(File source, String target) _copyFile;

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

  /// Another copy's files taken out to make room for a mod that then did not come on, and not all put back.
  static Stream<ShaderRestoreShortfall> get shortfalls => _shortfalls.stream;
  static final StreamController<ShaderRestoreShortfall> _shortfalls = StreamController.broadcast();

  /// Reports [shortfall] on [shortfalls].
  static void reportShortfall(ShaderRestoreShortfall shortfall) => _shortfalls.add(shortfall);

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
  ///
  /// With [freeing], the files [remove] would take out for that uid count as
  /// gone: what an enable that first takes out another copy's files would meet.
  Future<void> check({
    required String modDir,
    required String? uid,
    required String mod,
    required String saveModsPath,
    String? freeing,
  }) => _serialised(() async {
        await _prepare(modDir: modDir, uid: uid ?? '', mod: mod, saveModsPath: saveModsPath, freeing: freeing);
      });

  /// Copies the mod's shader files in. Does nothing for a mod without any.
  ///
  /// Throws [ShaderPlacementRefused] before copying anything when there is no
  /// shader folder to copy to, or a target holds different bytes. Files already
  /// there with the same bytes are held rather than copied. The caller
  /// [announce]s the copies and [announceAdopted]s the adoptions once the mod is on,
  /// or [undo]es the placement when it does not come on.
  ///
  /// A copy that fails partway lets go of what this placement took hold of
  /// before it rethrows, and of nothing [uid] held before it. The file it was
  /// writing when it failed is deleted, being the placement's own and unrecorded.
  Future<ShaderPlacementResult> place({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
  }) => _serialised(() async {
        final ready = await _prepare(modDir: modDir, uid: uid, mod: mod, saveModsPath: saveModsPath);
        if (ready == null) return const ShaderPlacementResult(copied: 0, adopted: 0);
        return _copyIn(ready, uid: uid, mod: mod, modDir: modDir);
      });

  /// Puts back the files of the copy [uid] at [modDir] that [free] took out, for a mod that then did not come on.
  /// Returns the paths of those it could not put back.
  ///
  /// Every file goes back that can, one by one: a target taken since, or one that fails to copy, is skipped and
  /// logged rather than stopping the rest. Nothing the app did not place is overwritten.
  Future<List<String>> restore({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
    required List<ShaderEntry> freed,
  }) => _serialised(() async {
        try {
          final ready = await _prepare(modDir: modDir, uid: uid, mod: mod, saveModsPath: saveModsPath, partial: true);
          if (ready != null) await _copyIn(ready, uid: uid, mod: mod, modDir: modDir, partial: true);
        } catch (error) {
          _log.warning('other copy shader files not put back', error: error, fields: {'mod': mod, 'uid': uid, 'copy': modDir});
        }
        final record = await _readRecord();
        return [
          for (final entry in freed)
            if (record.at(entry.folder, entry.path)?.holders.containsKey(uid) != true) entry.path,
        ];
      });

  /// Copies [ready]'s files in and records them. All or nothing unless [partial]: a copy that fails lets go of
  /// what this placement took hold of and rethrows. With [partial], a file that fails is skipped and the rest go on.
  Future<ShaderPlacementResult> _copyIn(
    _Prepared ready, {
    required String uid,
    required String mod,
    required String modDir,
    bool partial = false,
  }) async {
    final placed = <ShaderEntry>[];
    Object? failure;
    StackTrace? failureStack;
    for (final copy in ready.plan.copy) {
      final from = File(p.join(ready.part.path, copy.source.path));
      final to = File(p.join(ready.folder, copy.source.path));
      var existed = false;
      var writing = false;
      try {
        if (await _throughLink(ready.folder, copy.source.path)) {
          throw FileSystemException('a link is in the way, nothing written through it', to.path);
        }
        await to.parent.create(recursive: true);
        existed = await to.exists();
        writing = true;
        await _copyFile(from, to.path);
        placed.add(copy.entry);
        _files.info('shader file placed', fields: {'mod': mod, 'uid': uid, 'from': modDir, 'file': to.path});
      } catch (error, stack) {
        if (writing) await _discardPartCopy(ready, copy.source.path, uid: uid, mod: mod, existed: existed);
        if (!partial) {
          failure = error;
          failureStack = stack;
          break;
        }
        _log.warning('shader file not put back', error: error, fields: {'mod': mod, 'uid': uid, 'file': to.path});
      }
    }
    for (final skipped in ready.skipped) {
      _log.warning('shader file not put back, its target is taken',
          fields: {'mod': mod, 'uid': uid, 'file': p.join(ready.folder, skipped.path)});
    }
    // Recorded even when a copy failed partway, so what did land is held
    // and the undo below takes it back out.
    final added = [...ready.plan.held, ...placed];
    if (added.isNotEmpty) {
      final record = ready.record.apply(added: added);
      await _writeRecord(failure == null ? record.withSource(uid, modDir) : record);
    }
    final taken = [
      for (final entry in added)
        if (ready.record.at(entry.folder, entry.path)?.holders.containsKey(uid) != true) entry,
    ];
    if (failure != null) {
      await _release(uid: uid, mod: mod, announce: false, only: taken);
      Error.throwWithStackTrace(failure, failureStack!);
    }
    if (ready.plan.adopted > 0) {
      _log.info('shader files already present, adopted',
          fields: {'mod': mod, 'uid': uid, 'files': ready.plan.adopted});
    }
    return ShaderPlacementResult(copied: placed.length, adopted: ready.plan.adopted, taken: taken);
  }

  /// The identity whose files were last placed from [folder], by the path the record keeps, when exactly one
  /// matches. A copy on an unplugged drive has no sidecar to read, and this is how it is still known.
  Future<String?> holderFrom(String folder, {required bool Function(String a, String b) samePath}) =>
      _serialised(() async {
        final record = await _readRecord();
        final matches = {
          for (final source in record.sources.entries)
            if (samePath(source.value, folder)) source.key,
        };
        return matches.length == 1 ? matches.single : null;
      });

  /// Whether [uid] holds any file in the record.
  Future<bool> holdsAny(String uid) => _serialised(() async => (await _readRecord()).heldBy(uid).isNotEmpty);

  /// Records the files placed from [from] as placed from [to], after that folder moved or was renamed, and returns
  /// the uids it moved. With [only], just those uids are moved, so a move undone takes back exactly what it moved.
  Future<List<String>> repoint({
    required String from,
    required String to,
    required bool Function(String a, String b) samePath,
    Iterable<String>? only,
  }) => _serialised(() async {
        var record = await _readRecord();
        final moved = [
          for (final source in record.sources.entries)
            if (samePath(source.value, from) && (only == null || only.contains(source.key))) source.key,
        ];
        if (moved.isEmpty) return moved;
        for (final uid in moved) {
          record = record.withSource(uid, to);
        }
        await _writeRecord(record);
        return moved;
      });

  /// Lets go of what [placed] took hold of, for a placement whose mod did not
  /// come on. Files [uid] held before it stay: they may be another copy's of the
  /// same mod, which is still on.
  Future<void> undo({required String uid, required String mod, required ShaderPlacementResult placed}) {
    if (placed.taken.isEmpty) return Future.value();
    return _serialised(() => _release(uid: uid, mod: mod, announce: false, only: placed.taken));
  }

  /// Deletes the file at [relative] whose copy failed partway, when it is this
  /// placement's own: one that was not there before the copy, or the mod's own
  /// earlier version, once the copy has changed its bytes. Never a file the app
  /// did not place.
  Future<void> _discardPartCopy(
    _Prepared ready,
    String relative, {
    required String uid,
    required String mod,
    required bool existed,
  }) async {
    final file = File(p.join(ready.folder, relative));
    try {
      if (await _throughLink(ready.folder, relative)) return;
      if (!await file.exists()) return;
      if (existed) {
        final entry = ready.record.at(ready.folder, relative);
        if (entry == null || entry.external || !entry.holders.containsKey(uid)) return;
        if (await md5OfFile(file) == entry.md5) return;
      }
      await file.delete();
      _files.info('partly copied shader file removed', fields: {'mod': mod, 'file': file.path});
      await _removeEmptyFolders({file.parent.path}, under: ready.folder);
    } on FileSystemException catch (error) {
      _log.warning('could not remove a partly copied shader file', error: error, fields: {'file': file.path});
    }
  }

  /// Everything [place] decides before copying, or null for a mod without shader
  /// files. Throws [ShaderPlacementRefused] for an enable that must not happen.
  /// With [freeing], plans as if that uid's files had been taken out first. With [partial], a target that would
  /// refuse is skipped instead, and the rest planned.
  Future<_Prepared?> _prepare({
    required String modDir,
    required String uid,
    required String mod,
    required String saveModsPath,
    String? freeing,
    bool partial = false,
  }) async {
    final part = await shaderPartOf(modDir);
    if (part == null) return null;
    final sources = await _sourcesIn(part);
    if (sources.isEmpty) return null;

    final folder = await findShaderFolder(saveModsPath);
    if (folder == null) throw ShaderPlacementRefused.noShaderFolder(mod);

    final record = await _readRecord();
    final listing = await _listFolder(folder);
    var planned = record;
    final freed = <String>{};
    if (freeing != null && freeing != uid) {
      final held = record.heldBy(freeing).where((entry) => entry.folder == folder);
      final release = planShaderRemoval(
        uid: freeing,
        folder: folder,
        record: record,
        onDisk: await _onDiskForRelease(held, folder, listing),
      );
      planned = record.apply(removed: [...release.forget, ...release.forgetOnDelete.values], added: release.update);
      freed.addAll(release.delete);
    }
    final onDisk = <String, String?>{};
    final linked = <String>{};
    for (final source in sources) {
      final key = ShaderFixesRecord.keyOf(source.path);
      if (_linkOnWay(key, listing.links)) {
        linked.add(key);
        continue;
      }
      if (freed.contains(key)) continue;
      if (listing.files[key] case final actual?) {
        onDisk[key] = await md5OfFile(File(p.join(folder, actual)));
      }
    }
    ShaderPlacementPlan planFor(List<ShaderSource> sources) => planShaderPlacement(
          uid: uid,
          mod: mod,
          folder: folder,
          sources: sources,
          onDisk: onDisk,
          record: planned,
          links: linked,
        );
    var plan = planFor(sources);
    final skipped = <ShaderConflict>[];
    if (plan is ShaderRefusedPlan) {
      // Logged by the caller once the refusal is final: an enable may retry it with another copy's files freed.
      if (!partial) throw ShaderPlacementRefused.conflicts(mod, plan.conflicts);
      skipped.addAll(plan.conflicts);
      final refused = {for (final conflict in plan.conflicts) ShaderFixesRecord.keyOf(conflict.path)};
      plan = planFor([
        for (final source in sources)
          if (!refused.contains(ShaderFixesRecord.keyOf(source.path))) source,
      ]);
    }
    return _Prepared(part, folder, record, plan as ShaderCopyPlan, skipped);
  }

  /// Whether [key], or a folder on the way to it, is in [links].
  static bool _linkOnWay(String key, Map<String, String> links) {
    if (links.isEmpty) return false;
    final parts = key.split('/');
    for (var i = 1; i <= parts.length; i++) {
      if (links.containsKey(parts.take(i).join('/'))) return true;
    }
    return false;
  }

  /// Whether [relative] under [folder], or a folder on the way to it, is a link, live or dangling. Asked right
  /// before a write or a delete, so a link made since the listing is never written through or removed.
  static Future<bool> _throughLink(String folder, String relative) async {
    final parts = p.split(p.normalize(relative));
    var current = folder;
    for (final part in parts) {
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) return true;
      if (type == FileSystemEntityType.notFound) return false;
    }
    return false;
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
  }) => _serialised(() async => (await _release(uid: uid, mod: mod, announce: announce, retryFailed: retryFailed)).changed);

  /// [remove] for another copy's files, taken out to make room for a mod coming on, with no restart notice of its
  /// own. Returns the entries whose files it deleted, which [restore] puts back if that mod does not come on.
  Future<List<ShaderEntry>> free({required String uid, required String mod}) =>
      _serialised(() async => (await _release(uid: uid, mod: mod, announce: false)).deleted);

  /// [remove] inside the queue. With [only], just those of [uid]'s holds are let go of. Returns the files left in
  /// place because they changed, and the entries whose files were deleted.
  Future<({List<String> changed, List<ShaderEntry> deleted})> _release({
    required String uid,
    required String mod,
    required bool announce,
    bool retryFailed = true,
    List<ShaderEntry>? only,
  }) async {
    final keys = only == null ? null : {for (final entry in only) _entryKey(entry)};
    bool included(ShaderEntry entry) => keys == null || keys.contains(_entryKey(entry));
    var record = await _readRecord();
    final folders = record.heldBy(uid).where(included).map((entry) => entry.folder).toSet();
    final changed = <String>[];
    final deletedAll = <ShaderEntry>[];
    var deletedAny = false;

    for (final folder in folders) {
      // With the folder gone there is nothing to take back out; the record is
      // kept so the files are removed if it returns.
      if (!await Directory(folder).exists()) continue;

      final listing = await _listFolder(folder);
      final files = listing.files;
      final onDisk = await _onDiskForRelease(
        record.heldBy(uid).where((entry) => entry.folder == folder).where(included),
        folder,
        listing,
      );

      final plan = planShaderRemoval(
        uid: uid,
        folder: folder,
        record: record,
        onDisk: onDisk,
        only: keys == null ? null : included,
      );
      final emptied = <String>{};
      final deleted = <ShaderEntry>[];
      for (final key in plan.delete) {
        final file = File(p.join(folder, files[key]!));
        try {
          if (await _throughLink(folder, files[key]!)) {
            _log.warning('shader file not removed, a link is in the way', fields: {'mod': mod, 'uid': uid, 'file': file.path});
            continue;
          }
          await file.delete();
          if (!plan.launcherCopies.contains(key)) deletedAny = true;
          if (plan.forgetOnDelete[key] case final entry?) deleted.add(entry);
          _files.info('shader file removed', fields: {'mod': mod, 'uid': uid, 'file': file.path});
          emptied.add(file.parent.path);
        } on FileSystemException catch (error) {
          _log.warning('could not remove shader file', error: error, fields: {'file': file.path});
        }
      }
      await _removeEmptyFolders(emptied, under: folder);
      for (final key in plan.changed) {
        final relative = files[key]!;
        _log.info('shader file changed since placed, left in place',
            fields: {'mod': mod, 'uid': uid, 'file': p.join(folder, relative)});
        changed.add(relative);
      }
      final dropped = retryFailed ? deleted : plan.forgetOnDelete.values;
      record = record.apply(removed: [...plan.forget, ...dropped], added: plan.update);
      deletedAll.addAll(deleted);
    }

    if (folders.isNotEmpty) await _writeRecord(record);
    if (deletedAny && announce) _changes.add(mod);
    return (changed: changed, deleted: deletedAll);
  }

  /// The md5 of each file in [folder] a release of [entries] looks at: each entry's
  /// own, the `.bin` cache beside it, and the copies the XXMI Launcher may have
  /// renamed a missing one to.
  /// Links are left out, so one put where a placed file was reads as that file gone, and none is ever deleted.
  Future<Map<String, String?>> _onDiskForRelease(
    Iterable<ShaderEntry> entries,
    String folder,
    _Listing listing,
  ) async {
    final files = listing.files;
    final onDisk = <String, String?>{};
    for (final entry in entries) {
      final own = ShaderFixesRecord.keyOf(entry.path);
      for (final key in [own, ?cacheBinFor(entry.path)]) {
        if (files[key] case final actual?) {
          onDisk[key] = await md5OfFile(File(p.join(folder, actual)));
        }
      }
      if (!files.containsKey(own)) {
        for (final copy in launcherCopiesOf(entry.path, files.keys)) {
          onDisk[copy] = await md5OfFile(File(p.join(folder, files[copy]!)));
        }
      }
    }
    return onDisk;
  }

  static String _entryKey(ShaderEntry entry) => '${entry.folder}\u0000${ShaderFixesRecord.keyOf(entry.path)}';

  /// Every file and link in [folder], keyed by [ShaderFixesRecord.keyOf], to its
  /// spelling on disk. Listed rather than probed per name: on a case-sensitive
  /// filesystem `exists()` misses a file that differs only in case, which ZZMI
  /// under Wine treats as the same file. Links, live or dangling, are listed apart
  /// and never followed: a copy would write through one into a file the app did
  /// not place.
  Future<_Listing> _listFolder(String folder) async {
    final listing = _Listing();
    final dir = Directory(folder);
    if (!await dir.exists()) return listing;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is Directory) continue;
      final relative = p.relative(entity.path, from: folder).replaceAll(r'\', '/');
      (entity is Link ? listing.links : listing.files)[ShaderFixesRecord.keyOf(relative)] = relative;
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
        if (await FileSystemEntity.isLink(current)) break;
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
  const ShaderPlacementResult({required this.copied, required this.adopted, this.taken = const []});
  final int copied;
  final int adopted;

  /// The entries the mod did not hold before this placement, which
  /// [ShaderFixesService.undo] lets go of.
  final List<ShaderEntry> taken;
}

/// A mod that switched on using [count] files already in the shader folder.
class ShaderAdoption {
  const ShaderAdoption(this.mod, this.count);
  final String mod;
  final int count;
}

/// Another copy of [mod], at [folder], whose [files] were taken out to make room for it and not all put back when it
/// did not come on.
class ShaderRestoreShortfall {
  const ShaderRestoreShortfall(this.mod, this.folder, this.files);
  final String mod;
  final String folder;
  final List<String> files;
}

class _Prepared {
  const _Prepared(this.part, this.folder, this.record, this.plan, [this.skipped = const []]);
  final Directory part;
  final String folder;
  final ShaderFixesRecord record;
  final ShaderCopyPlan plan;

  /// Targets a partial placement leaves out because they would refuse it.
  final List<ShaderConflict> skipped;
}

/// A shader folder's contents: files, and links apart, each keyed by [ShaderFixesRecord.keyOf] to its spelling.
class _Listing {
  final Map<String, String> files = {};
  final Map<String, String> links = {};
}
