import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/restore_snapshot_flow.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// What the History tab of a mod's page writes, against a real library in a temp directory: the snapshot list read
/// from each snapshot's own sidecar, a restore, and taking an ignored update back (`docs/library-screen.md` §15).
void main() {
  const modName = 'Winter Maid';
  const modId = 531649;

  late TempLibrary temp;
  setUp(() async => temp = await TempLibrary.create(prefix: 'zzz_mod_page_actions_'));

  ModInfo mod() => ModInfo(
    id: modName,
    name: modName,
    characterId: 'ellen',
    isActive: false,
    uid: temp.uidOf(modName),
    origin: temp.originOf(modName),
  );

  Future<ModSnapshot> snapshotNow() async => (await temp.snapshots.capture(
    modName: modName,
    modUid: (await ModUid().ensure(temp.modFolder(modName)))!,
    modFolder: temp.modFolder(modName),
    reason: SnapshotReason.beforeUpdate,
  ))!;

  test('a snapshot is listed with the origin its own copy of the sidecar recorded', () async {
    temp.write(modName, 'mod.ini', 'old');
    await temp.writeOrigin(
      modName,
      originFixture(modId: modId, modIdConfidence: OriginConfidence.exact, fileId: 111, versionConfidence: OriginConfidence.exact),
    );
    await snapshotNow();
    // The folder moves on; the snapshot keeps what it was.
    await temp.writeOrigin(
      modName,
      originFixture(modId: modId, modIdConfidence: OriginConfidence.exact, fileId: 222, versionConfidence: OriginConfidence.exact),
    );

    final container = ProviderContainer(overrides: temp.overrides);
    addTearDown(container.dispose);
    final entries = await container.read(modSnapshotsProvider(temp.uidOf(modName)!).future);

    expect(entries, hasLength(1));
    expect(entries.single.origin?.base?.fileId, 111);
  });

  test('taking an ignored update back clears it on disk and brings the badge back', () async {
    temp.write(modName, 'mod.ini', 'x');
    await temp.writeOrigin(
      modName,
      originFixture(modId: modId, modIdConfidence: OriginConfidence.exact, updatesDismissedUntil: DateTime(2026, 9, 30)),
    );
    final container = ProviderContainer(overrides: [libraryOf([mod()]), ...temp.overrides]);
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = {
      modName: const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true, subject: DownloadKey.base(modId)),
    };

    expect(await stopIgnoringUpdate(container, mod: mod(), subject: const DownloadKey.base(modId)), isTrue);

    expect(temp.originOf(modName)?.base?.updatesDismissedUntil, isNull);
    expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue, reason: 'the badge reads this verdict');
    expect(container.read(modWritesInProgressProvider), isEmpty);
  });

  test("the folder's Ignore silences a newer file listed under both layers of one page with one press", () async {
    // A base and its page's fix both list a newer file nobody labelled. Dismissed on the winner alone, the other
    // layer would win the re-fold with the same file and Ignore would look dead.
    temp.write(modName, 'mod.ini', 'x');
    await temp.writeOrigin(
      modName,
      originFixture(
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionLabel: 'Main file',
        versionConfidence: OriginConfidence.exact,
        patches: [
          patchFixture(
            modId: modId,
            fileId: 2,
            versionLabel: 'Hair fix',
            versionConfidence: OriginConfidence.exact,
          ),
        ],
      ),
    );
    final origin = temp.originOf(modName)!;
    final check = checkForUpdate(
      origin: origin,
      remote: GbMod(idRow: modId, files: [
        GbFile(idRow: 1, description: 'Main file', dateAdded: DateTime.utc(2026, 1)),
        GbFile(idRow: 2, description: 'Hair fix', dateAdded: DateTime.utc(2026, 2)),
        GbFile(idRow: 3, dateAdded: DateTime.utc(2026, 3)),
      ]),
    );
    expect(check.layers.where((layer) => layer.check.hasUpdate), hasLength(2), reason: 'listed under both');
    final container = ProviderContainer(overrides: [libraryOf([mod()]), ...temp.overrides]);
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = {modName: check};

    expect(await ignoreUpdate(container, mod: mod(), check: check), isTrue);

    final written = temp.originOf(modName)!;
    expect(written.base!.updatesDismissedUntil, DateTime.utc(2026, 3));
    expect(written.patches.single.updatesDismissedUntil, DateTime.utc(2026, 3));
    expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isFalse, reason: 'one press is enough');
  });

  test('a mod stays marked as being written until its last write ends', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final first = Completer<void>();
    final second = Completer<void>();
    final firstWrite = whileWritingMod(container, modName, () => first.future);
    final secondWrite = whileWritingMod(container, modName, () => second.future);

    first.complete();
    await firstWrite;
    expect(container.read(modWritesInProgressProvider), {modName}, reason: 'the second write is still running');

    second.complete();
    await secondWrite;
    expect(container.read(modWritesInProgressProvider), isEmpty);
  });

  testWidgets('a restore asks, puts the old files back and says it did', (tester) async {
    late ModSnapshot snapshot;
    await tester.runAsync(() async {
      temp.write(modName, 'mod.ini', 'old');
      await temp.writeOrigin(modName, originFixture(modId: modId, modIdConfidence: OriginConfidence.exact));
      snapshot = await snapshotNow();
      temp.write(modName, 'mod.ini', 'new');
      temp.write(modName, 'added later.dds', 'x');
    });
    bool? restored;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => restored = await restoreSnapshotFlow(context, mod: mod(), snapshot: snapshot),
          child: const Text('restore'),
        ),
      ),
      overrides: [libraryOf([mod()]), ...temp.overrides],
    );
    expectBuilt(ElevatedButton);

    // Pressed on the real event loop, which the flow's file work after the question needs.
    await tapWithIo(tester, find.text('restore'));
    await tester.pumpAndSettle();
    expect(find.textContaining('anything added to the folder since is removed'), findsOneWidget);
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Restore'));
    // The copy runs on the real event loop, which only runAsync turns.
    for (var i = 0; i < 40 && restored == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(restored, isTrue);
    expect(temp.read(modName, 'mod.ini'), 'old');
    expect(temp.has(modName, 'added later.dds'), isFalse);
    expect(find.text('Previous version restored'), findsOneWidget);
  });

  group("a restore's card", () {
    /// Restores a snapshot of `mod.ini` "old" over "new" plus a file added later, through the flow, and hands back
    /// the container whose stack holds the result and every Working card the stack raised.
    Future<({ProviderContainer container, List<AppNotification> working})> restore(WidgetTester tester) async {
      late ModSnapshot snapshot;
      await tester.runAsync(() async {
        temp.write(modName, 'mod.ini', 'old');
        await temp.writeOrigin(modName, originFixture(modId: modId, modIdConfidence: OriginConfidence.exact));
        snapshot = await snapshotNow();
        temp.write(modName, 'mod.ini', 'new');
        temp.write(modName, 'added later.dds', 'x');
      });
      final container = ProviderContainer(overrides: [libraryOf([mod()]), ...temp.overrides]);
      addTearDown(container.dispose);
      final working = <AppNotification>[];
      final listening = container.listen<List<AppNotification>>(notificationsProvider, (_, next) {
        for (final n in next) {
          if (n.kind == NotificationKind.working && !working.any((w) => w.id == n.id)) working.add(n);
        }
      });
      addTearDown(listening.close);
      bool? restored;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => restored = await restoreSnapshotFlow(context, mod: mod(), snapshot: snapshot),
            child: const Text('restore'),
          ),
        ),
        container: container,
      );
      await tapWithIo(tester, find.text('restore'));
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Restore'));
      for (var i = 0; i < 40 && restored == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(restored, isTrue);
      expect(temp.read(modName, 'mod.ini'), 'old');
      return (container: container, working: working);
    }

    /// Presses the stack's only card's Undo and waits for the card it raises to become its result.
    Future<AppNotification> undo(WidgetTester tester, ProviderContainer container) async {
      final card = container.read(notificationsProvider).single;
      // On the real event loop, as the restore's own file work is.
      await tester.runAsync(() async => card.actions.singleWhere((a) => a.label == 'Undo').onPressed());
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        final now = container.read(notificationsProvider);
        if (now.isNotEmpty && now.last.kind != NotificationKind.working && now.last.id != card.id) break;
      }
      return container.read(notificationsProvider).last;
    }

    testWidgets('is a Working card while it copies, which becomes the Done with an Undo', (tester) async {
      final run = await restore(tester);

      expect([for (final n in run.working) (n.title, n.body, n.characterId)],
          [('Restoring a previous version…', modName, 'ellen')]);
      final done = run.container.read(notificationsProvider).single;
      expect(done.id, run.working.single.id, reason: 'the same card, turned into its result');
      expect((done.kind, done.title, done.body), (NotificationKind.done, 'Previous version restored', modName));
      expect([for (final a in done.actions) a.label], ['Undo']);
    });

    testWidgets('Undo puts back the folder as it was before the restore', (tester) async {
      final run = await restore(tester);

      final result = await undo(tester, run.container);

      expect([for (final n in run.working) n.title], ['Restoring a previous version…', 'Undoing the restore…']);
      expect((result.kind, result.title, result.body), (NotificationKind.done, 'Restore undone', modName));
      expect(result.actions, isEmpty, reason: 'an undo is not offered again');
      expect(temp.read(modName, 'mod.ini'), 'new');
      expect(temp.has(modName, 'added later.dds'), isTrue);
      expect(run.container.read(modWritesInProgressProvider), isEmpty);
    });

    testWidgets('Undo with the copy gone says so and changes nothing', (tester) async {
      final run = await restore(tester);
      // The safety copy, deleted as pruning or the list of previous versions would.
      // Named by the time it was taken, so the newest sorts last.
      final safety = Directory(p.join(temp.snapshots.rootPath, temp.uidOf(modName)!, temp.snapshotsOf(modName).last));
      await tester.runAsync(() => safety.delete(recursive: true));

      final result = await undo(tester, run.container);

      expect((result.kind, result.title, result.body),
          (NotificationKind.error, "Couldn't undo the restore", 'The copy saved before the restore is no longer kept.'));
      expect(temp.read(modName, 'mod.ini'), 'old');
    });
  });

  testWidgets('a restore that fails still reads the library again', (tester) async {
    // It may have changed the folder before it failed.
    late ModSnapshot snapshot;
    await tester.runAsync(() async {
      temp.write(modName, 'mod.ini', 'old');
      snapshot = await snapshotNow();
      // Its files gone, its folder kept, so the safety copy the restore takes first gets an id of its own.
      Directory('${snapshot.directory.path}/files').deleteSync(recursive: true);
    });
    final container = ProviderContainer(overrides: [libraryOf([mod()]), ...temp.overrides]);
    addTearDown(container.dispose);
    bool? restored;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => restored = await restoreSnapshotFlow(context, mod: mod(), snapshot: snapshot),
          child: const Text('restore'),
        ),
      ),
      container: container,
    );
    final scans = container.read(libraryScansProvider);

    await tapWithIo(tester, find.text('restore'));
    await tester.pumpAndSettle();
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Restore'));
    for (var i = 0; i < 40 && restored == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(restored, isFalse);
    expect(container.read(libraryScansProvider), scans + 1);
  });

  testWidgets("a restore drops the mod's keys, whether or not it landed", (tester) async {
    // A restore puts back old modification times, which the keys' stamp can't tell from what was there.
    late ModSnapshot snapshot;
    await tester.runAsync(() async {
      temp.write(modName, 'mod.ini', 'old');
      snapshot = await snapshotNow();
      Directory('${snapshot.directory.path}/files').deleteSync(recursive: true);
    });
    final service = RecordingService(temp);
    bool? restored;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => restored = await restoreSnapshotFlow(context, mod: mod(), snapshot: snapshot),
          child: const Text('restore'),
        ),
      ),
      overrides: [libraryOf([mod()]), ...service.overrides],
    );

    await tapWithIo(tester, find.text('restore'));
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Restore'));
    for (var i = 0; i < 40 && restored == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(restored, isFalse);
    expect(service.keysDropped, [modName]);
  });
}
