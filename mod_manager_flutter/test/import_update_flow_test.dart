import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin_seed.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_update_flow.dart';
import 'package:mod_manager_flutter/services/import_result.dart';
import 'package:mod_manager_flutter/services/import_review.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:path/path.dart' as p;

import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/mods_screen_harness.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// What an import does with the rows set to Update it once the review is answered (`docs/importing-mods.md` §3, §5):
/// a mod that became busy meanwhile, a library that is not set, and a refused new mod next to an update.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TempLibrary temp;
  late AppLocalizations loc;

  setUpAll(() async {
    loc = AppLocalizations(const Locale('en'));
    await loc.load();
  });

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_import_update_');
  });

  ModInfo mod(String id) => ModInfo(id: id, name: id, characterId: 'ellen', isActive: false);

  Directory dropped(String name, Map<String, String> files) {
    final folder = Directory(p.join(temp.root.path, 'drop', name))..createSync(recursive: true);
    for (final entry in files.entries) {
      File(p.join(folder.path, entry.key)).writeAsStringSync(entry.value);
    }
    return folder;
  }

  /// The review's row for [source] set to Update it, as it stood when the user pressed Import: the mod not busy.
  ImportRow updateRow(Directory source, ModInfo target) {
    final review = evaluateImport(
      [
        ImportItem(
          id: source.path,
          sources: [source.path],
          label: p.basename(source.path),
          kind: ImportSourceKind.folder,
          name: target.id,
        ),
      ],
      [ExistingMod.of(target, busy: false)],
    );
    expect(review.rows.single.updates, isTrue);
    return review.rows.single;
  }

  group('updateFromDropped', () {
    late ProviderContainer container;
    late ModInfo ellen;

    setUp(() {
      ellen = mod('Ellen Maid');
      temp.write('Ellen Maid', 'ellen.ini', 'old ini');
      container = ProviderContainer(overrides: [libraryOf([ellen]), ...temp.overrides]);
      addTearDown(container.dispose);
    });

    Future<({List<String> updated, List<NotificationLines> failures})> run(
      List<ImportRow> rows, {
      bool noLibrary = false,
    }) => updateFromDropped(
      container: container,
      loc: loc,
      service: temp.service,
      modsPath: noLibrary ? null : temp.mods.path,
      rows: rows,
      originSeeds: const {},
    );

    test('writes the dropped files into a mod that is not busy', () async {
      final row = updateRow(dropped('Ellen Maid', {'ellen.ini': 'new ini'}), ellen);

      final result = await run([row]);

      expect(result.updated, ['Ellen Maid']);
      expect(result.failures, isEmpty);
      expect(temp.read('Ellen Maid', 'ellen.ini'), 'new ini');
    });

    test('skips a mod that became busy after the review, names it, and leaves it as it was', () async {
      final row = updateRow(dropped('Ellen Maid', {'ellen.ini': 'new ini'}), ellen);
      final held = holdWrite(container, 'Ellen Maid');

      final result = await run([row]);
      await held.release();

      expect(result.updated, isEmpty);
      expect(result.failures.single.title, 'Not updated');
      expect(result.failures.single.body, contains('Ellen Maid'));
      expect(temp.read('Ellen Maid', 'ellen.ini'), 'old ini', reason: 'nothing may write into a folder another write holds');
      expect(temp.snapshotsOf('Ellen Maid'), isEmpty);
    });

    test('a busy mod does not stop the rows after it', () async {
      final other = mod('Nicole Maid');
      temp.write('Nicole Maid', 'nicole.ini', 'old');
      container.dispose();
      container = ProviderContainer(overrides: [libraryOf([ellen, other]), ...temp.overrides]);
      addTearDown(container.dispose);
      final rows = [
        updateRow(dropped('Ellen Maid', {'ellen.ini': 'new ini'}), ellen),
        updateRow(dropped('Nicole Maid', {'nicole.ini': 'new'}), other),
      ];
      final held = holdWrite(container, 'Ellen Maid');

      final result = await run(rows);
      await held.release();

      expect(result.updated, ['Nicole Maid']);
      expect(result.failures, hasLength(1));
      expect(temp.read('Nicole Maid', 'nicole.ini'), 'new');
    });

    test('with no library set, reports it once and writes nothing', () async {
      final row = updateRow(dropped('Ellen Maid', {'ellen.ini': 'new ini'}), ellen);

      final result = await run([row], noLibrary: true);

      expect(result.updated, isEmpty);
      expect(result.failures.map((lines) => lines.title), ['No mods folder is set']);
      expect(temp.read('Ellen Maid', 'ellen.ini'), 'old ini');
    });

    test('with no rows has nothing to say, library or not', () async {
      final result = await run(const [], noLibrary: true);

      expect(result.updated, isEmpty);
      expect(result.failures, isEmpty);
    });
  });

  group('a new mod the copy refuses, beside an Update it', () {
    const noFolders = 'No mod folders or archives found';

    testWidgets('is reported next to the update, not swallowed by it', (tester) async {
      final service = _RefusingImports(temp)..install();
      final ellen = mod('Ellen Maid');
      temp.write('Ellen Maid', 'ellen.ini', 'old ini');
      final update = dropped('Ellen Maid', {'ellen.ini': 'new ini'});
      final fresh = dropped('Ellen Fresh', {'fresh.ini': '[TextureOverrideBody]\n'});
      final container = await pumpModsScreen(tester, temp, [ellen], services: service.overrides);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '${update.path}\n${fresh.path}'};
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      // Two folders: which of them to install, as separate mods.
      await waitFor(find.text('Install (2)'));
      await tester.tap(find.text('Install (2)'));
      await tester.pump();
      final confirm = find.byKey(const ValueKey('import_confirm'));
      await waitFor(confirm);
      expect(confirm, findsOneWidget, reason: 'the review is the step before the copy');
      expect(find.text('Update it'), findsOneWidget, reason: 'the first folder is the mod the library has');
      await tester.tap(confirm);
      await tester.pump();

      List<AppNotification> cards() => container.read(notificationsProvider);
      for (var i = 0; i < 60 && !cards().any((n) => n.kind == NotificationKind.error); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(temp.read('Ellen Maid', 'ellen.ini'), 'new ini', reason: 'the update itself went through');
      expect(cards().where((n) => n.kind == NotificationKind.error).map((n) => n.title), [
        "The mod couldn't be copied in",
      ]);
      expect(find.text(noFolders), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  });
}

/// The library's real service, except that a copy of a new mod into the library is refused, as a read-only folder does.
class _RefusingImports extends RecordingService {
  _RefusingImports(super.temp);

  @override
  Future<ImportResult> importMods(
    List<String> folderPaths, {
    Map<String, String>? detectionHints,
    Map<String, ModOriginSeed>? originSeeds,
    Map<String, String>? knownCharacters,
    Map<String, String>? targetNames,
  }) async => const ImportResult.failed(ImportFailure.copyFailed);
}
