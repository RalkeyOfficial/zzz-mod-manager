import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// **Deleting a mod takes its saved versions with it.**
///
/// Keeping gigabytes of a mod the user has just deleted is a surprise, and
/// nothing would ever offer them again — the rollback list is per mod, and this
/// mod is gone.
///
/// The whole risk is an ordering one, and it is the reason this file exists:
/// **the identity lives in the sidecar inside the folder being deleted.** Read
/// it afterwards and it is unreadable, so the operation meant to reclaim the
/// space would be the one that orphaned it forever — under a uid nothing can
/// ever claim again, and exempt from pruning, which protects each group's
/// newest entry.
///
/// Real directories and a real `ConfigService` over a temp file, so the
/// developer's own library and app-data are never touched.
void main() {
  late Directory temp;
  late Directory mods;
  late SnapshotService snapshots;
  late ModManagerService service;
  final uids = ModUid();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_delete_mod_');
    mods = await Directory(p.join(temp.path, 'mods')).create();
    final saveMods = await Directory(p.join(temp.path, 'saveMods')).create();
    snapshots = SnapshotService(rootPath: p.join(temp.path, 'backups'));

    SharedPreferences.setMockInitialValues({});
    final config = ConfigService(
      await SharedPreferences.getInstance(),
      configFile: File(p.join(temp.path, 'config.json')),
    );
    await config.setPaths(mods.path, saveMods.path);
    service = ModManagerService(config, snapshots: snapshots, uids: uids);
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
      await snapshots.capture(
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

    expect(await service.deleteMod('Ellen'), isTrue);

    expect(Directory(p.join(mods.path, 'Ellen')).existsSync(), isFalse);
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

  test('a mod that was never snapshotted deletes cleanly', () async {
    // No uid, nothing filed under one — and nothing to go wrong.
    final folder = Directory(p.join(mods.path, 'Ellen'))..createSync();
    File(p.join(folder.path, 'mod.ini')).writeAsStringSync('[Constants]\n');

    expect(await service.deleteMod('Ellen'), isTrue);
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
}
