import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/remove_patch_flow.dart';
import 'package:mod_manager_flutter/services/patch_store.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// **Taking a patch out, from the press to the bytes.**
///
/// The three pieces of this were each covered on their own and never together:
/// `patch_removal_test` decides what should happen, `remove_patch_test` performs
/// a decided plan, and `remove_patch_confirm_test` renders one. What none of them
/// can see is the wiring — that the plan on screen is the plan that runs, that
/// declining writes nothing, and that the record and the files change in the
/// same act.
///
/// It runs against a real library in a temp directory ([TempLibrary]) because
/// the whole subject is a write: the mod's own file coming back is a byte
/// comparison, and a fake filesystem would replace it with an assertion that the
/// fake was called.
void main() {
  const modName = 'Ellen Swimsuit';
  const patchId = 605460;
  const store = PatchStore();

  late TempLibrary library;
  bool? changed;

  setUp(() async {
    library = await TempLibrary.create(prefix: 'zzz_remove_patch_flow_');
    changed = null;
  });

  /// One layer over the mod, recording both kinds of file a patch writes.
  ModOrigin patchRecord({bool ini = true, bool added = true}) => originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        patches: [
          patchFixture(
            modId: patchId,
            files: [
              if (ini)
                const InstalledFile(
                    path: 'Ellen.ini', role: InstalledFileRole.replaced),
              if (added)
                const InstalledFile(
                    path: 'Textures/Patch.dds', role: InstalledFileRole.added),
            ],
          ),
        ],
      );

  /// The folder as it is after installing a patch over a mod: one of the mod's
  /// own files written over with the original kept, and one file the patch added.
  ///
  /// [keepOriginal] false stands in for a folder patched before the store
  /// existed, or one whose store could not be written.
  Future<ModOrigin> patchedFolder(
    WidgetTester tester, {
    bool keepOriginal = true,
  }) async {
    library.createMod(modName);
    library.write(modName, 'Ellen.ini', 'the mod');
    final origin = patchRecord();
    await tester.runAsync(() async {
      if (keepOriginal) {
        await store.keep(
          modFolder: library.modFolder(modName),
          patchModId: patchId,
          relativePath: 'Ellen.ini',
        );
      }
      await library.writeOrigin(modName, origin);
    });
    // After the store, the way an install writes it.
    library.write(modName, 'Ellen.ini', 'the patch');
    library.write(modName, 'Textures/Patch.dds', 'the patch');
    return origin;
  }

  /// Mounts the flow behind a button, so the confirmation is reached the way the
  /// menu reaches it and the return value is the one the caller rescans on.
  ///
  /// With [container], the notifications are read back from it.
  Future<void> press(WidgetTester tester, ModOrigin origin,
      {ProviderContainer? container}) async {
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () async {
            changed = await removePatchFlow(
              context,
              mod: ModInfo(
                id: modName,
                name: modName,
                characterId: 'ellen',
                isActive: false,
                origin: origin,
              ),
              patch: origin.patches.single,
              patchName: 'Ellen Fix',
            );
          },
          child: const Text('open'),
        ),
      ),
      overrides: container == null ? library.overrides : null,
      container: container,
    );
    expectBuilt(ElevatedButton);
    await tapWithIo(tester, find.text('open'));
  }

  Future<void> confirm(WidgetTester tester) =>
      tapWithIo(tester, find.text('Remove patch'));

  /// A container over the temp library, and every Working card its stack
  /// raises from now on, as each first appeared.
  ({ProviderContainer container, List<AppNotification> working}) watched() {
    final container = ProviderContainer(overrides: library.overrides);
    addTearDown(container.dispose);
    final working = <AppNotification>[];
    final listening = container.listen<List<AppNotification>>(
        notificationsProvider, (_, next) {
      for (final n in next) {
        if (n.kind == NotificationKind.working &&
            !working.any((w) => w.id == n.id)) {
          working.add(n);
        }
      }
    });
    addTearDown(listening.close);
    return (container: container, working: working);
  }

  /// Presses the stack's only card's Undo, on the real event loop, and waits
  /// for the card it raises to become its result.
  Future<AppNotification> undo(
      WidgetTester tester, ProviderContainer container) async {
    final card = container.read(notificationsProvider).single;
    await tester.runAsync(() async =>
        card.actions.singleWhere((a) => a.label == 'Undo').onPressed());
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final now = container.read(notificationsProvider);
      if (now.isNotEmpty &&
          now.last.kind != NotificationKind.working &&
          now.last.id != card.id) {
        break;
      }
    }
    return container.read(notificationsProvider).last;
  }

  testWidgets('a Working card shows while it runs and becomes the Done, with an Undo',
      (tester) async {
    final origin = await patchedFolder(tester);
    final run = watched();
    await press(tester, origin, container: run.container);
    expect(run.working, isEmpty,
        reason: 'nothing runs while the question is on screen');

    await confirm(tester);

    expect([for (final n in run.working) (n.title, n.body, n.characterId)],
        [('Taking the patch out…', 'Ellen Fix', 'ellen')]);
    final done = run.container.read(notificationsProvider).single;
    expect(done.id, run.working.single.id,
        reason: 'the same card, turned into its result');
    expect((done.kind, done.title, done.body),
        (NotificationKind.done, 'Patch removed', 'Ellen Fix'));
    expect([for (final a in done.actions) a.label], ['Undo']);
  });

  testWidgets('Undo puts the patch back, its record and kept originals too',
      (tester) async {
    final origin = await patchedFolder(tester);
    final run = watched();
    await press(tester, origin, container: run.container);
    await confirm(tester);
    expect(library.originOf(modName)!.patches, isEmpty);

    final result = await undo(tester, run.container);

    expect((result.kind, result.title, result.body),
        (NotificationKind.done, 'Patch put back', 'Ellen Fix'));
    expect(result.actions, isEmpty, reason: 'an undo is not offered again');
    expect(run.working.last.title, 'Putting the patch back…');
    expect(library.read(modName, 'Ellen.ini'), 'the patch');
    expect(library.read(modName, 'Textures/Patch.dds'), 'the patch');
    expect(library.originOf(modName)!.patches.single.modId, patchId);
    late Set<int> kept;
    await tester.runAsync(() async {
      kept = await PatchStore.idsIn(library.modFolder(modName));
    });
    expect(kept, {patchId},
        reason: 'the mod\'s own files are kept again, for the next removal');
  });

  testWidgets('Undo with the copy gone says so and changes nothing',
      (tester) async {
    final origin = await patchedFolder(tester);
    final run = watched();
    await press(tester, origin, container: run.container);
    await confirm(tester);
    // As pruning or the list of previous versions would delete it.
    final snapshot = Directory(p.join(library.snapshots.rootPath,
        library.uidOf(modName)!, library.snapshotsOf(modName).single));
    await tester.runAsync(() => snapshot.delete(recursive: true));

    final result = await undo(tester, run.container);

    expect((result.kind, result.title, result.body), (
      NotificationKind.error,
      "Couldn't put the patch back",
      'The copy saved before the patch was taken out is no longer kept.',
    ));
    expect(library.read(modName, 'Ellen.ini'), 'the mod');
    expect(library.originOf(modName)!.patches, isEmpty);
  });

  testWidgets('confirming puts the mod back and takes the patch away',
      (tester) async {
    final origin = await patchedFolder(tester);
    await press(tester, origin);

    // The plan reached the screen before anything was touched.
    expect(find.text('Remove this patch?'), findsOneWidget);
    expect(library.has(modName, 'Textures/Patch.dds'), isTrue);

    await confirm(tester);

    expect(changed, isTrue);
    expect(library.read(modName, 'Ellen.ini'), 'the mod',
        reason: "the mod's own file has to come back, not stay patched");
    expect(library.has(modName, 'Textures/Patch.dds'), isFalse);
    expect(find.text('Patch removed'), findsOneWidget);

    // The record and the files change together: a `patch_files` still naming a
    // patch that has gone would have the next base update set aside files
    // nothing owns.
    final onDisk = library.originOf(modName);
    expect(onDisk!.patches, isEmpty);
    expect(onDisk.base?.modId, 100);
    expect(onDisk.ingest?.patchFiles ?? const <String>[], isEmpty);
  });

  testWidgets('the displaced originals are dropped once they are back',
      (tester) async {
    final origin = await patchedFolder(tester);
    await press(tester, origin);
    await confirm(tester);

    // Nothing may be left in the folder that no record explains — an
    // unreferenced store is dead weight forever, and on a re-import there is
    // nothing left to say which patch it belonged to.
    late Set<int> remaining;
    await tester.runAsync(() async {
      remaining = await PatchStore.idsIn(library.modFolder(modName));
    });
    expect(remaining, isEmpty);
  });

  testWidgets('a snapshot exists before the folder is changed', (tester) async {
    final origin = await patchedFolder(tester);
    await press(tester, origin);
    expect(library.snapshotsOf(modName), isEmpty,
        reason: 'nothing may be written while the question is still on screen');

    await confirm(tester);

    expect(library.snapshotsOf(modName), hasLength(1),
        reason: '"Restore a previous version…" is the way back from this');
  });

  testWidgets('declining changes nothing at all', (tester) async {
    final origin = await patchedFolder(tester);
    await press(tester, origin);

    await tapWithIo(tester, find.text('Cancel'));

    expect(changed, isFalse);
    expect(library.read(modName, 'Ellen.ini'), 'the patch');
    expect(library.has(modName, 'Textures/Patch.dds'), isTrue);
    expect(library.originOf(modName)!.patches, hasLength(1));
    expect(library.snapshotsOf(modName), isEmpty);
  });

  testWidgets('a patch whose files are gone loses only its record',
      (tester) async {
    final origin = await patchedFolder(tester);
    library.deleteMod(modName);
    library.createMod(modName);
    await tester.runAsync(() => library.writeOrigin(modName, origin));

    await press(tester, origin);

    // No question, because there is nothing to agree to — the folder
    // demonstrably does not hold this patch any more.
    expect(find.text('Remove this patch?'), findsNothing);
    expect(
        find.text('That patch is not in this folder any more'), findsOneWidget);
    expect(changed, isTrue);
    expect(library.originOf(modName)!.patches, isEmpty);
  });

  testWidgets("the mod's keys are dropped even when the record can't be written",
      (tester) async {
    // The files have moved by then, and the record is the last step.
    final origin = await patchedFolder(tester);
    final service = RecordingService(library)..failOriginWrites = true;
    Object? thrown;
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () async {
            try {
              await removePatchFlow(
                context,
                mod: ModInfo(
                  id: modName,
                  name: modName,
                  characterId: 'ellen',
                  isActive: false,
                  origin: origin,
                ),
                patch: origin.patches.single,
                patchName: 'Ellen Fix',
              );
            } catch (e) {
              thrown = e;
            }
          },
          child: const Text('open'),
        ),
      ),
      overrides: service.overrides,
    );
    await tapWithIo(tester, find.text('open'));
    await confirm(tester);

    expect(thrown, isNotNull, reason: 'the record write failed');
    expect(library.read(modName, 'Ellen.ini'), 'the mod');
    expect(service.keysDropped, [modName]);
  });

  testWidgets('a file with no saved original stays, and is warned about first',
      (tester) async {
    library.createMod(modName);
    library.write(modName, 'Ellen.ini', 'the patch');
    final origin = patchRecord(added: false);
    await tester.runAsync(() => library.writeOrigin(modName, origin));

    await press(tester, origin);

    // The one loss on this screen is stated while it can still be declined.
    expect(
      find.textContaining("the mod's original was never saved"),
      findsOneWidget,
    );

    await confirm(tester);

    expect(library.read(modName, 'Ellen.ini'), 'the patch',
        reason: "deleting this would take the mod's own file with the patch");
    expect(library.originOf(modName)!.patches, isEmpty);
  });
}
