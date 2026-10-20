import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/restore_snapshot_flow.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

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
      modName: const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true, subjectModId: modId),
    };

    expect(await stopIgnoringUpdate(container, mod: mod(), subject: modId), isTrue);

    expect(temp.originOf(modName)?.base?.updatesDismissedUntil, isNull);
    expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue, reason: 'the badge reads this verdict');
    expect(container.read(modWritesInProgressProvider), isEmpty);
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
