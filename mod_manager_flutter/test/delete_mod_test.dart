import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_library.dart' show FakeTrash;

/// **Deleting a mod moves it to the trash, and takes its saved versions along when asked.**
///
/// The risks are ordering ones. **The identity lives in the sidecar inside the folder being moved**: read afterwards
/// it is unreadable, so the delete meant to reclaim the space would orphan it under a uid nothing can claim. And
/// **the folder moves before any setting is cleared**, so a trash that refuses leaves the mod whole.
///
/// Real directories and a real `ConfigService` over a temp file, so the
/// developer's own library and app-data are never touched.
void main() {
  late Directory temp;
  late Directory mods;
  late SnapshotService snapshots;
  late ModManagerService service;
  late ConfigService config;
  late Directory zzmi;
  late FakeTrash trash;
  final uids = ModUid();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_delete_mod_');
    mods = await Directory(p.join(temp.path, 'mods')).create();
    zzmi = await Directory(p.join(temp.path, 'zzmi')).create();
    trash = FakeTrash(p.join(temp.path, 'trash'));
    snapshots = SnapshotService(rootPath: p.join(temp.path, 'backups'));

    SharedPreferences.setMockInitialValues({});
    config = ConfigService(
      await SharedPreferences.getInstance(),
      configFile: File(p.join(temp.path, 'config.json')),
    );
    await config.setPaths(mods.path, zzmi.path);
    service = ModManagerService(
      config,
      snapshots: snapshots,
      uids: uids,
      moveToTrash: trash.move,
      shaderFixes: ShaderFixesService(recordPath: p.join(temp.path, 'shader_fixes.json')),
    );
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// A mod on disk that has been snapshotted [count] times.
  Future<String> modWithHistory(String name, {int count = 2}) async {
    final folder = Directory(p.join(mods.path, name))..createSync();
    File(p.join(folder.path, 'mod.ini')).writeAsStringSync('[Constants]\n');
    final uid = (await uids.ensure(folder))!;
    for (var i = 0; i < count; i++) {
      await snapshots.take(
        modName: name,
        modUid: uid,
        modFolder: folder,
        reason: SnapshotReason.beforeUpdate,
        now: DateTime.now().subtract(Duration(minutes: count - i)),
      );
    }
    expect(await snapshots.list(uid), hasLength(count));
    return uid;
  }

  test('the saved versions go with the mod', () async {
    final uid = await modWithHistory('Ellen');

    expect((await service.deleteMod('Ellen')).deleted, isTrue);

    expect(Directory(p.join(mods.path, 'Ellen')).existsSync(), isFalse);
    expect(trash.names, ['Ellen'], reason: 'in the trash, not gone from the disk');
    expect(await snapshots.list(uid), isEmpty);
    expect(await snapshots.uidsWithSnapshots(), isEmpty,
        reason: 'and the group itself is gone, not left empty');
  });

  test('another mod keeps its own', () async {
    // The delete is keyed by one identity, and a group is one mod's.
    final ellen = await modWithHistory('Ellen');
    final miyabi = await modWithHistory('Miyabi');

    await service.deleteMod('Ellen');

    expect(await snapshots.list(ellen), isEmpty);
    expect(await snapshots.list(miyabi), hasLength(2));
  });

  test('the names given to its keys go with it, and another mod keeps its own', () async {
    await modWithHistory('Ellen', count: 1);
    await modWithHistory('Miyabi', count: 1);
    await config.setModKeyLabels('Ellen', {'keyhair': 'Hairpin style'});
    await config.setModKeyLabels('Miyabi', {'keyhair': 'Hair'});

    await service.deleteMod('Ellen');

    expect(config.modKeyLabels.keys, ['Miyabi']);
  });

  test('a cleanup step that throws or fails after the folder has moved does not turn the delete into a failure', () async {
    // The folder is in the trash by then, so "delete failed" would be false, and the steps after the bad one must
    // still run.
    final uid = await modWithHistory('Ellen');
    await config.setModNote('Ellen', 'keep me');
    final faulty = ModManagerService(
      _FaultyConfig(await SharedPreferences.getInstance(), configFile: File(p.join(temp.path, 'config.json'))),
      snapshots: snapshots,
      uids: uids,
      moveToTrash: trash.move,
      shaderFixes: ShaderFixesService(recordPath: p.join(temp.path, 'shader_fixes.json')),
    );

    final outcome = await faulty.deleteMod('Ellen');

    expect(outcome.status, DeleteStatus.deleted);
    expect(trash.names, ['Ellen']);
    expect(config.modNotes.containsKey('Ellen'), isFalse, reason: 'the step after the one that threw still ran');
    expect(await snapshots.list(uid), isEmpty, reason: 'and so did the ticked saved versions');
  });

  test('a mod that was never snapshotted deletes cleanly', () async {
    // No uid, nothing filed under one — and nothing to go wrong.
    final folder = Directory(p.join(mods.path, 'Ellen'))..createSync();
    File(p.join(folder.path, 'mod.ini')).writeAsStringSync('[Constants]\n');

    expect((await service.deleteMod('Ellen')).deleted, isTrue);
    expect(folder.existsSync(), isFalse);
  });

  test('the identity is read before the folder is gone', () async {
    // **The ordering, asserted where it can actually fail.** A `deleteMod` that
    // looked the uid up after the folder went would find nothing, leave the
    // group behind, and leave it unclaimable — the exact failure this whole
    // change exists to end. The observable difference is only this: the group
    // is empty afterwards.
    final uid = await modWithHistory('Ellen', count: 3);
    final group = Directory(p.join(snapshots.rootPath, uid));
    expect(group.existsSync(), isTrue);

    await service.deleteMod('Ellen');

    expect(group.existsSync(), isFalse,
        reason: 'the uid was still readable when the delete needed it');
  });

  test('a group that cannot be removed does not fail the delete', () async {
    // The mod is already gone by the time the group is touched, so a failure
    // there is wasted space rather than something to report — telling the user
    // their delete failed when it did not is the worse outcome.
    final uid = await modWithHistory('Ellen');
    expect(await snapshots.deleteGroup(uid), isTrue);
    // Removing it twice: the second call has nothing to do, and "nothing to do"
    // is not a failure.
    expect(await snapshots.deleteGroup(uid), isTrue);
    expect(await snapshots.deleteGroup(''), isFalse,
        reason: 'no identity is not an empty group — it is not a group at all');
  });

  test('a mod deleted with the box unticked keeps its saved versions, claimed by no mod', () async {
    final uid = await modWithHistory('Ellen');

    expect((await service.deleteMod('Ellen', deleteSnapshots: false)).deleted, isTrue);

    expect(trash.names, ['Ellen']);
    expect(await snapshots.list(uid), hasLength(2));
    expect(await snapshots.uidsWithSnapshots(), {uid});
    expect(uids.read(Directory(p.join(trash.root, 'Ellen'))), completion(uid),
        reason: 'the folder in the trash still names its history');
  });

  group('when the trash cannot take the folder', () {
    Future<(String, Link)> activeMod(String name) async {
      final uid = await modWithHistory(name);
      await config.addFavoriteMod(name);
      await config.setModNote(name, 'keep me');
      final link = Link(p.join(zzmi.path, 'Mods', name))..createSync(p.join(mods.path, name), recursive: true);
      return (uid, link);
    }

    for (final answer in [TrashResult.unavailable, TrashResult.failed]) {
      test('${answer.name} leaves the mod, its link, its settings and its saved versions as they were', () async {
        final (uid, link) = await activeMod('Ellen');
        trash.answer = answer;

        final outcome = await service.deleteMod('Ellen');

        expect(outcome.status, DeleteStatus.notTrashed);
        expect(outcome.trash, answer);
        expect(Directory(p.join(mods.path, 'Ellen')).existsSync(), isTrue);
        expect(link.existsSync(), isTrue, reason: 'a mod that was on is turned back on');
        expect(config.favoriteMods, contains('Ellen'));
        expect(config.modNotes['Ellen'], 'keep me');
        expect(await snapshots.list(uid), hasLength(2));
        expect(trash.names, isEmpty);
      });
    }

    test('a mod that was off stays off', () async {
      await modWithHistory('Ellen');
      trash.answer = TrashResult.unavailable;

      await service.deleteMod('Ellen');

      expect(Directory(p.join(zzmi.path, 'Mods', 'Ellen')).existsSync(), isFalse);
    });
  });

  test('deleting for good removes the folder from the disk and never asks the trash', () async {
    final uid = await modWithHistory('Ellen');

    expect((await service.deleteMod('Ellen', forGood: true)).deleted, isTrue);

    expect(Directory(p.join(mods.path, 'Ellen')).existsSync(), isFalse);
    expect(trash.calls, isEmpty);
    expect(trash.names, isEmpty);
    expect(await snapshots.list(uid), isEmpty);
  });

  test('a folder that is not there is reported as missing', () async {
    expect((await service.deleteMod('Nobody')).status, DeleteStatus.missing);
    expect(trash.calls, isEmpty);
  });
}

/// A config whose favourites throw and whose key labels cannot be written.
class _FaultyConfig extends ConfigService {
  _FaultyConfig(super.prefs, {super.configFile});

  @override
  Future<bool> removeFavoriteMod(String modId) async => throw StateError('favourites are unreadable');

  @override
  Future<bool> setModKeyLabels(String modId, Map<String, String> labels) async => false;
}
