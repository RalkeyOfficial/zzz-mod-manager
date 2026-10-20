import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/update_apply/mod_activation_port.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart';
import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// The All mods table's bulk Enable, Disable and Delete over a real library in a temp directory, the rule that they
/// reach only the ticked rows shown, and what the Delete confirmation says (`docs/library-screen.md` §16).
void main() {
  ModInfo mod(String name, {String characterId = 'ellen', bool active = false, bool favorite = false, String? uid}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: active, isFavorite: favorite, uid: uid);

  List<(String, String)> notified(ProviderContainer container) =>
      [for (final n in container.read(notificationsProvider)) (n.title, n.body)];

  Finder dialogText(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  /// Marks [id] as having its folder written, as an update or a restore does while it runs.
  void writing(ProviderContainer container, String id) =>
      container.read(modWritesInProgressProvider.notifier).state = {id};

  /// The notice naming one mod a bulk action skipped while its folder was being written.
  (String, String) skippedNotice(String name) =>
      ('1 mod skipped while its folder is being changed', '$name. Try again once the update, reinstall, patch or restore is done.');

  group('over a real library', () {
    late TempLibrary temp;

    setUp(() async {
      temp = await TempLibrary.create(prefix: 'zzz_all_mods_bulk_');
    });

    void installMod(String name) {
      temp.createMod(name);
      temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
    }

    /// Installs [name] and turns it on, as the held list says it is.
    Future<void> installActive(WidgetTester tester, String name) async {
      installMod(name);
      await tester.runAsync(() async {
        expect(await temp.service.activateMod(name), isTrue);
      });
    }

    bool linked(String name) => Link(p.join(temp.saveMods.path, name)).existsSync();

    Future<ProviderContainer> pumpTable(WidgetTester tester, List<ModInfo> mods) =>
        pumpAllModsTable(tester, mods, overrides: temp.overrides);

    /// Presses the bar's Delete, which reads the saved versions off disk before it asks, then the dialog's confirm.
    Future<void> deleteTicked(WidgetTester tester, ProviderContainer container, String confirm) async {
      await tapWithIo(tester, barButton('Delete'));
      expect(find.byType(AlertDialog), findsOneWidget);
      await pressBulk(tester, container, find.widgetWithText(FilledButton, confirm));
    }

    group('act only on the ticked rows shown', () {
      testWidgets('Disable leaves a ticked mod the search hides', (tester) async {
        await installActive(tester, 'Alpha');
        await installActive(tester, 'Bravo');
        final container = await pumpTable(tester, [mod('Alpha', active: true), mod('Bravo', active: true)]);
        await tick(tester, ['Alpha', 'Bravo']);

        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Alpha'), isFalse);
        expect(linked('Bravo'), isTrue);
        expect(container.read(allModsSelectionProvider), {'Alpha', 'Bravo'}, reason: 'the hidden tick outlives it');
      });

      testWidgets('Disable leaves a ticked mod the filter hides', (tester) async {
        await installActive(tester, 'Alpha');
        await installActive(tester, 'Bravo');
        final container = await pumpTable(tester, [
          mod('Alpha', active: true, favorite: true),
          mod('Bravo', active: true),
        ]);
        await tick(tester, ['Alpha', 'Bravo']);

        await tester.tap(find.widgetWithText(ZenithChip, 'Favorites'));
        await tester.pumpAndSettle();
        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Alpha'), isFalse);
        expect(linked('Bravo'), isTrue);
      });

      testWidgets('Disable leaves a ticked mod in a folded group', (tester) async {
        await installActive(tester, 'Alpha');
        await installActive(tester, 'Bravo');
        final container = await pumpTable(tester, [
          mod('Alpha', active: true),
          mod('Bravo', characterId: 'cat_ui', active: true),
        ]);
        await tick(tester, ['Alpha', 'Bravo']);

        container.read(allModsGroupingProvider.notifier).state = AllModsGrouping.character;
        await tester.pumpAndSettle();
        // Headings in the character list's order: Ellen, then UI.
        await tester.tap(find.byType(AnimatedRotation).at(1));
        await tester.pumpAndSettle();
        expect(find.text('Bravo'), findsNothing);
        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Alpha'), isFalse);
        expect(linked('Bravo'), isTrue);
      });

      testWidgets('Delete asks about, and deletes, only the mod shown', (tester) async {
        installMod('Alpha');
        installMod('Bravo');
        final container = await pumpTable(tester, [mod('Alpha'), mod('Bravo')]);
        await tick(tester, ['Alpha', 'Bravo']);

        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pumpAndSettle();
        await tapWithIo(tester, barButton('Delete'));
        expect(find.text('Delete 1 mod?'), findsOneWidget);
        expect(dialogText('Alpha'), findsOneWidget);
        expect(dialogText('Bravo'), findsNothing);
        await pressBulk(tester, container, find.widgetWithText(FilledButton, 'Delete 1 mod'));

        expect(temp.modFolder('Alpha').existsSync(), isFalse);
        expect(temp.modFolder('Bravo').existsSync(), isTrue);
        expect(container.read(allModsSelectionProvider), {'Bravo'});
      });
    });

    group('Enable', () {
      testWidgets('leaves a mod whose folder is being written, turns the rest on, and names it', (tester) async {
        installMod('Ellen School');
        installMod('Miyabi Kimono');
        final container = await pumpTable(tester, [
          mod('Ellen School'),
          mod('Miyabi Kimono', characterId: 'miyabi'),
        ]);
        writing(container, 'Miyabi Kimono');
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Ellen School'), isTrue);
        expect(linked('Miyabi Kimono'), isFalse);
        expect(notified(container), [skippedNotice('Miyabi Kimono')]);
      });

      // Read off: a rescan during the write sees the link the write took out.
      for (final readOff in [false, true]) {
      testWidgets(
          "under One at a time, turns off the character's mod being written, and its write leaves it off"
          "${readOff ? ', when the library already reads it off' : ''}", (tester) async {
        File(p.join(temp.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
        installMod('Ellen School');
        temp.write('Ellen School', 'ShaderFixes/abc123-ps_replace.txt', 'shader');
        installMod('Ellen Maid');
        await tester.runAsync(() => temp.service.activateMod('Ellen School'));
        final placed = File(p.join(temp.root.path, 'ShaderFixes', 'abc123-ps_replace.txt'));
        expect(placed.existsSync(), isTrue);
        final container = await pumpTable(tester, [mod('Ellen School', active: true), mod('Ellen Maid')]);

        // A write's own turn-off and turn-back-on, held between the two, as an update holds them around its copy.
        final done = Completer<void>();
        await tester.runAsync(() async {
          unawaited(whileWritingMod(container, 'Ellen School', () async {
            final port = ModManagerActivationPort(temp.service, leaveOff: (m) => leftOffAfterWrite(container, m));
            await port.deactivate('Ellen School');
            await done.future;
            await port.activate('Ellen School');
          }));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        if (readOff) container.read(libraryProvider.notifier).put([mod('Ellen School'), mod('Ellen Maid')]);
        await tick(tester, ['Ellen Maid']);

        await pressBulk(tester, container, barButton('Enable'));
        expect(linked('Ellen Maid'), isTrue);

        await tester.runAsync(() async {
          done.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        expect(linked('Ellen Maid'), isTrue);
        expect(linked('Ellen School'), isFalse);
        expect(placed.existsSync(), isFalse, reason: 'its shader files are not placed again');
        expect(notified(container), isEmpty);
      });
      }

      testWidgets('turns each ticked mod on, says nothing, and reads the library again', (tester) async {
        installMod('Ellen School');
        installMod('Miyabi Kimono');
        final container = await pumpTable(tester, [
          mod('Ellen School'),
          mod('Miyabi Kimono', characterId: 'miyabi'),
        ]);
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);
        final scans = container.read(libraryScansProvider);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Ellen School'), isTrue);
        expect(linked('Miyabi Kimono'), isTrue);
        expect(notified(container), isEmpty);
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets("under One at a time, turns the character's other mod off", (tester) async {
        await installActive(tester, 'Ellen School');
        installMod('Ellen Maid');
        final container = await pumpTable(tester, [mod('Ellen School', active: true), mod('Ellen Maid')]);
        await tick(tester, ['Ellen Maid']);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Ellen Maid'), isTrue);
        expect(linked('Ellen School'), isFalse);
        expect(temp.config.activeMods, ['Ellen Maid']);
        expect(notified(container), isEmpty);
      });

      testWidgets('two ticked mods of a One at a time character are both left off, with a warning', (tester) async {
        await installActive(tester, 'Ellen School');
        installMod('Ellen Maid');
        installMod('Ellen Beach');
        installMod('Miyabi Kimono');
        final container = await pumpTable(tester, [
          mod('Ellen School', active: true),
          mod('Ellen Maid'),
          mod('Ellen Beach'),
          mod('Miyabi Kimono', characterId: 'miyabi'),
        ]);
        await tick(tester, ['Ellen Maid', 'Ellen Beach', 'Miyabi Kimono']);
        final scans = container.read(libraryScansProvider);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Ellen Maid'), isFalse);
        expect(linked('Ellen Beach'), isFalse);
        expect(linked('Ellen School'), isTrue, reason: 'nothing of hers was switched off');
        expect(linked('Miyabi Kimono'), isTrue, reason: 'another character is not held back');
        final notifications = container.read(notificationsProvider);
        expect([for (final n in notifications) n.kind], [NotificationKind.warning]);
        expect(notifications.single.title, 'Some mods were left off');
        expect(notifications.single.body, contains('Ellen'));
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets('a mod the dry run refuses stays off, and the mod that was on stays on', (tester) async {
        await installActive(tester, 'Ellen School');
        // Shader files, and no d3dx.ini beside the links folder to say where they would go.
        temp.createMod('Jiggle');
        temp.write('Jiggle', 'Jiggle.ini', '[TextureOverrideBody]\n');
        temp.write('Jiggle', 'ShaderFixes/abc123-ps_replace.txt', 'shader');
        final container = await pumpTable(tester, [mod('Ellen School', active: true), mod('Jiggle')]);
        await tick(tester, ['Jiggle']);
        final scans = container.read(libraryScansProvider);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Jiggle'), isFalse);
        expect(linked('Ellen School'), isTrue);
        // With its reason, as the switch reports it, rather than as a bare failure.
        expect(notified(container), [
          (
            "Couldn't find ZZMI's shader folder",
            'Jiggle stays off: there is no d3dx.ini in your ZZMI folder, so there is nowhere to put its shader files.',
          ),
        ]);
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets('mods the missing shader folder keeps off share one notice', (tester) async {
        for (final name in ['Jiggle', 'Wobble']) {
          temp.createMod(name);
          temp.write(name, '$name.ini', '[TextureOverrideBody]\n');
          temp.write(name, 'ShaderFixes/abc123-ps_replace.txt', 'shader');
        }
        final container = await pumpTable(tester, [mod('Jiggle'), mod('Wobble', characterId: 'miyabi')]);
        await tick(tester, ['Jiggle', 'Wobble']);

        await pressBulk(tester, container, barButton('Enable'));

        expect(notified(container), [
          (
            "Couldn't find ZZMI's shader folder",
            'Jiggle, Wobble stay off: there is no d3dx.ini in your ZZMI folder, so there is nowhere to put their shader '
                'files.',
          ),
        ]);
      });

      testWidgets('a partial failure is reported only as the failure', (tester) async {
        installMod('Ellen School');
        // Listed, but not on disk: there is nothing to link.
        final container = await pumpTable(tester, [
          mod('Ellen School'),
          mod('Ghost', characterId: 'miyabi'),
        ]);
        await tick(tester, ['Ellen School', 'Ghost']);

        await pressBulk(tester, container, barButton('Enable'));

        expect(linked('Ellen School'), isTrue);
        expect(notified(container), [("Couldn't turn on 1 mod", 'Ghost')]);
      });
    });

    group('Disable', () {
      testWidgets('turns each ticked mod off, says nothing, and reads the library again', (tester) async {
        await installActive(tester, 'Ellen School');
        await installActive(tester, 'Miyabi Kimono');
        final container = await pumpTable(tester, [
          mod('Ellen School', active: true),
          mod('Miyabi Kimono', characterId: 'miyabi', active: true),
        ]);
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);
        final scans = container.read(libraryScansProvider);

        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Ellen School'), isFalse);
        expect(linked('Miyabi Kimono'), isFalse);
        expect(temp.config.activeMods, isEmpty);
        expect(notified(container), isEmpty);
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets('a partial failure is reported only as the failure', (tester) async {
        await installActive(tester, 'Ellen School');
        installMod('Unlinked');
        // Listed as on, with no link to remove.
        final container = await pumpTable(tester, [
          mod('Ellen School', active: true),
          mod('Unlinked', characterId: 'miyabi', active: true),
        ]);
        await tick(tester, ['Ellen School', 'Unlinked']);
        final scans = container.read(libraryScansProvider);

        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Ellen School'), isFalse);
        expect(notified(container), [("Couldn't turn off 1 mod", 'Unlinked')]);
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets('leaves a mod whose folder is being written, turns the rest off, and names it', (tester) async {
        await installActive(tester, 'Ellen School');
        await installActive(tester, 'Miyabi Kimono');
        final container = await pumpTable(tester, [
          mod('Ellen School', active: true),
          mod('Miyabi Kimono', characterId: 'miyabi', active: true),
        ]);
        writing(container, 'Miyabi Kimono');
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);

        await pressBulk(tester, container, barButton('Disable'));

        expect(linked('Ellen School'), isFalse);
        expect(linked('Miyabi Kimono'), isTrue);
        expect(notified(container), [skippedNotice('Miyabi Kimono')]);
      });
    });

    group('Delete', () {
      testWidgets('deletes each ticked mod and its link, clears their ticks, and reads the library again',
          (tester) async {
        await installActive(tester, 'Ellen School');
        installMod('Miyabi Kimono');
        installMod('Kept');
        final container = await pumpTable(tester, [
          mod('Ellen School', active: true),
          mod('Miyabi Kimono', characterId: 'miyabi'),
          mod('Kept', characterId: 'cat_ui'),
        ]);
        container.read(selectedModIdProvider.notifier).state = 'Ellen School';
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);
        final scans = container.read(libraryScansProvider);

        await deleteTicked(tester, container, 'Delete 2 mods');

        expect(temp.modFolder('Ellen School').existsSync(), isFalse);
        expect(temp.modFolder('Miyabi Kimono').existsSync(), isFalse);
        expect(temp.modFolder('Kept').existsSync(), isTrue);
        expect(linked('Ellen School'), isFalse);
        expect(container.read(allModsSelectionProvider), isEmpty);
        expect(container.read(selectedModIdProvider), isNull, reason: 'the details panel let go of a deleted mod');
        expect(notified(container), isEmpty);
        expect(container.read(libraryScansProvider), scans + 1);
      });

      testWidgets('a partial failure is reported only as the failure, and its tick stays', (tester) async {
        installMod('Ellen School');
        // Listed, but no folder to delete.
        final container = await pumpTable(tester, [mod('Ellen School'), mod('Ghost', characterId: 'miyabi')]);
        container.read(selectedModIdProvider.notifier).state = 'Ghost';
        await tick(tester, ['Ellen School', 'Ghost']);

        await deleteTicked(tester, container, 'Delete 2 mods');

        expect(temp.modFolder('Ellen School').existsSync(), isFalse);
        expect(notified(container), [("Couldn't delete 1 mod", 'Ghost')]);
        expect(container.read(allModsSelectionProvider), {'Ghost'});
        expect(container.read(selectedModIdProvider), 'Ghost');
      });

      testWidgets('leaves a mod whose folder is being written, deletes the rest, and names it', (tester) async {
        installMod('Ellen School');
        installMod('Miyabi Kimono');
        final container = await pumpTable(tester, [mod('Ellen School'), mod('Miyabi Kimono', characterId: 'miyabi')]);
        writing(container, 'Miyabi Kimono');
        await tick(tester, ['Ellen School', 'Miyabi Kimono']);

        await deleteTicked(tester, container, 'Delete 2 mods');

        expect(temp.modFolder('Ellen School').existsSync(), isFalse);
        expect(temp.modFolder('Miyabi Kimono').existsSync(), isTrue);
        expect(notified(container), [skippedNotice('Miyabi Kimono')]);
        expect(container.read(allModsSelectionProvider), {'Miyabi Kimono'}, reason: 'ticked, to do again');
      });

      testWidgets('cancelled, deletes nothing and reads nothing again', (tester) async {
        installMod('Ellen School');
        final container = await pumpTable(tester, [mod('Ellen School')]);
        await tick(tester, ['Ellen School']);
        final scans = container.read(libraryScansProvider);

        await tapWithIo(tester, barButton('Delete'));
        await pressBulk(tester, container, find.text('Cancel'));

        expect(temp.modFolder('Ellen School').existsSync(), isTrue);
        expect(container.read(allModsSelectionProvider), {'Ellen School'});
        expect(container.read(libraryScansProvider), scans);
        expect(container.read(allModsBulkRunningProvider), isFalse);
      });
    });
  });

  group('the Delete confirmation', () {
    /// Opens the confirmation over [mods], every one ticked. Nothing here is confirmed, so nothing is written.
    Future<void> openConfirmation(
      WidgetTester tester,
      List<ModInfo> mods, {
      Map<String, int> savedVersions = const {},
      Future<Map<String, int>>? sizes,
      List<String>? ticked,
    }) async {
      await pumpAllModsTable(
        tester,
        mods,
        overrides: [
          snapshotServiceProvider.overrideWithValue(_SavedVersions(savedVersions)),
          librarySizesProvider.overrideWith((ref) => sizes ?? Completer<Map<String, int>>().future),
        ],
      );
      await tick(tester, ticked ?? [for (final m in mods) m.name]);
      await tester.tap(barButton('Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    }

    testWidgets('names six, counts the rest, and says the size, how many are on and the saved versions',
        (tester) async {
      const mib = 1024 * 1024;
      final mods = [
        for (var i = 1; i <= 8; i++) mod('mod $i', active: i <= 2, uid: 'uid-$i'),
        mod('not ticked', uid: 'uid-x'),
      ];
      await openConfirmation(
        tester,
        mods,
        savedVersions: {'uid-1': 2, 'uid-5': 1, 'uid-x': 4},
        sizes: Future.value({for (var i = 1; i <= 8; i++) 'mod $i': mib, 'not ticked': 100 * mib}),
        ticked: [for (var i = 1; i <= 8; i++) 'mod $i'],
      );

      expect(dialogText('Delete 8 mods?'), findsOneWidget);
      for (var i = 1; i <= 6; i++) {
        expect(dialogText('mod $i'), findsOneWidget);
      }
      expect(dialogText('mod 7'), findsNothing);
      expect(dialogText('mod 8'), findsNothing);
      expect(dialogText('not ticked'), findsNothing);
      expect(dialogText('and 2 more'), findsOneWidget);
      expect(
        dialogText("Their folders and every file in them, 8.0 MB in all, are deleted from disk. This can't be undone."),
        findsOneWidget,
      );
      expect(dialogText('2 of them are on in the game right now.'), findsOneWidget);
      expect(dialogText('3 saved versions go with them, so there will be nothing left to restore.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete 8 mods'), findsOneWidget);
    });

    testWidgets('for one mod, off, with nothing saved and no size yet, says only what it deletes', (tester) async {
      await openConfirmation(tester, [mod('Alpha', uid: 'uid-a')]);

      expect(dialogText('Delete 1 mod?'), findsOneWidget);
      expect(dialogText('Alpha'), findsOneWidget);
      expect(find.textContaining('more'), findsNothing);
      expect(
        dialogText("Its folder and every file in it are deleted from disk. This can't be undone."),
        findsOneWidget,
      );
      expect(find.textContaining('on in the game'), findsNothing);
      expect(find.textContaining('saved version'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Delete 1 mod'), findsOneWidget);
    });

    testWidgets('one mod ticked reads as "it"', (tester) async {
      await openConfirmation(tester, [mod('Alpha', active: true, uid: 'uid-a')], savedVersions: {'uid-a': 1});

      expect(dialogText('It is on in the game right now.'), findsOneWidget);
      expect(dialogText('1 saved version goes with it, so there will be nothing left to restore.'), findsOneWidget);
    });

    testWidgets('one of two mods on and one saved version read in the singular', (tester) async {
      await openConfirmation(
        tester,
        [mod('Alpha', active: true, uid: 'uid-a'), mod('Beta', uid: 'uid-b')],
        savedVersions: {'uid-a': 1},
      );

      expect(dialogText('1 of them is on in the game right now.'), findsOneWidget);
      expect(dialogText('1 saved version goes with them, so there will be nothing left to restore.'), findsOneWidget);
    });

    testWidgets('seven mods name six and one more', (tester) async {
      await openConfirmation(tester, [for (var i = 1; i <= 7; i++) mod('mod $i')]);

      expect(dialogText('mod 6'), findsOneWidget);
      expect(dialogText('mod 7'), findsNothing);
      expect(dialogText('and 1 more'), findsOneWidget);
    });
  });
}

/// Saved versions by uid, held in memory, so the confirmation's count reads no folder.
class _SavedVersions extends SnapshotService {
  _SavedVersions(this.counts);

  final Map<String, int> counts;

  @override
  Future<List<ModSnapshot>> list(String? modUid) async => [
        for (var i = 0; i < (counts[modUid] ?? 0); i++)
          ModSnapshot(
            modName: '',
            modUid: modUid!,
            id: '$i',
            takenAt: DateTime.utc(2026),
            sizeBytes: 0,
            directory: Directory('unused'),
          ),
      ];
}
