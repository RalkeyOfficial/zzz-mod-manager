import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/backup/retention.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

/// Snapshots to keep, from the setting down to what `prune` leaves on disk.
void main() {
  test('the snapshot service keeps as many as the setting says', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(snapshotServiceProvider).policy.keepPerMod, defaultSnapshotsToKeep);

    container.read(snapshotsToKeepProvider.notifier).state = 7;
    expect(container.read(snapshotServiceProvider).policy.keepPerMod, 7);
  });

  group('prune on disk', () {
    late Directory root;
    late Directory mod;

    setUp(() {
      root = Directory.systemTemp.createTempSync('zzz_snapshots_setting_');
      mod = Directory(p.join(root.path, 'Ellen'))..createSync();
      File(p.join(mod.path, 'Body.dds')).writeAsStringSync('v1');
      addTearDown(() => root.deleteSync(recursive: true));
    });

    Future<SnapshotService> keeping(int count) async {
      final service = SnapshotService(rootPath: p.join(root.path, 'backups'), policy: RetentionPolicy(keepPerMod: count));
      for (var i = 0; i < 6; i++) {
        await service.capture(
          modName: 'Ellen',
          modUid: 'ellen-uid',
          modFolder: mod,
          reason: SnapshotReason.beforeUpdate,
          // Taken minutes apart: how recent they are makes no difference to what is kept.
          now: DateTime(2026, 10, 24, 12, i),
        );
      }
      return service;
    }

    test('a count of two leaves the two newest, however recent the others are', () async {
      final service = await keeping(2);
      expect((await service.list('ellen-uid')).length, 6);

      await service.prune();

      final left = await service.list('ellen-uid');
      expect(left.length, 2);
      expect(left.map((e) => e.takenAt.minute), unorderedEquals([4, 5]));
    });

    test('a count of one still keeps the newest', () async {
      final service = await keeping(1);

      await service.prune();

      final left = await service.list('ellen-uid');
      expect(left.single.takenAt.minute, 5);
    });

    test('a higher count keeps more, and prune never makes more than it was asked to keep', () async {
      final service = await keeping(10);

      await service.prune();

      expect((await service.list('ellen-uid')).length, 6);
    });
  });
}
