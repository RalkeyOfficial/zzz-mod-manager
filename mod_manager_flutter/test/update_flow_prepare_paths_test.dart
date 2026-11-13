import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/question_parts.dart';
import 'package:mod_manager_flutter/screens/dialogs/apply_update_flow.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/fake_download_transport.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/system_temp.dart';
import 'support/temp_library.dart';

/// The paths `applyUpdateFlow` takes through `prepareUpdate` and `writeUpdate`, driven as the user meets them: the archive's password asked again and declined, the choice of the archive's folders, and the mods an archive also installed.
void main() {
  const modName = 'Ellen';
  const ini = '[KeySwap]\nkey = VK_2\n';
  const wrongPassword = "That password didn't open the archive.";

  late TempLibrary temp;
  late RecordingService service;
  late FakeDownloadTransport transport;
  late ProviderContainer container;
  late Directory systemTemp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_update_paths_');
    service = RecordingService(temp);
    transport = FakeDownloadTransport();
    // The unpacks land in a folder of their own, so a second unpack or a leftover one can be seen.
    systemTemp = Directory(p.join(temp.root.path, 'system_temp'))..createSync();
    IOOverrides.global = SystemTempIn(systemTemp);
  });
  tearDown(() => IOOverrides.global = null);

  List<String> unpacksLeft() => [
        for (final entry in systemTemp.listSync())
          if (p.basename(entry.path).startsWith('zzz_archive_extract_')) p.basename(entry.path),
      ];

  /// What the downloads folder holds: the archive until the update is done with it.
  List<String> archivesLeft() {
    final downloads = Directory(p.join(temp.root.path, 'downloads'));
    return downloads.existsSync() ? [for (final f in downloads.listSync().whereType<File>()) p.basename(f.path)] : [];
  }

  GbFile serveBytes(int fileId, List<int> body, {DateTime? dateAdded}) {
    final url = Uri.parse('https://gamebanana.com/dl/$fileId');
    transport.enqueue(url, body: body);
    return GbFile(
      idRow: fileId,
      file: 'ellen$fileId.zip',
      filesize: body.length,
      downloadUrl: '$url',
      dateAdded: dateAdded,
    );
  }

  GbFile serve(int fileId, Map<String, String> files, {DateTime? dateAdded}) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return serveBytes(fileId, ZipEncoder().encode(archive)!, dateAdded: dateAdded);
  }

  Future<ModInfo> installed(WidgetTester tester, {ModIngest? ingest}) async {
    final origin = originFixture(
      modId: 100,
      modIdConfidence: OriginConfidence.exact,
      fileId: 1,
      versionConfidence: OriginConfidence.exact,
      ingest: ingest,
    );
    temp.write(modName, 'Ellen.ini', '[KeySwap]\nkey = VK_1\n');
    await tester.runAsync(() => temp.writeOrigin(modName, origin));
    return ModInfo(id: modName, name: modName, characterId: 'ellen', isActive: false, origin: origin);
  }

  /// The flow's outcome, once it has one.
  UpdateFlowOutcome? outcome;

  /// Presses a button that runs [flow], on the app's own window.
  Future<void> start(
    WidgetTester tester,
    Future<UpdateFlowOutcome> Function(BuildContext context, WidgetRef ref) flow,
  ) async {
    outcome = null;
    container = ProviderContainer(overrides: [
      ...service.overrides,
      downloadServiceProvider.overrideWith(
        (ref) => DownloadService(
          transport: transport,
          directory: Directory(p.join(temp.root.path, 'downloads')),
          progressInterval: const Duration(milliseconds: 10),
          freeSpace: (_) async => 1 << 40,
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () async => outcome = await flow(context, ref),
          child: const Text('update'),
        ),
      ),
      container: container,
    );
    expectBuilt(ElevatedButton);
    // The download's progress window spins until the flow asks, so the frames are pumped by hand.
    await tester.runAsync(() => tester.tap(find.text('update')));
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, {String reason = 'it never happened'}) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> press(WidgetTester tester, Finder button) => tester.runAsync(() => tester.tap(button));

  bool finished() => container.read(downloadQueueProvider).any((j) => j.state == DownloadJobState.done);
  bool ended() => outcome != null;

  /// Waits for the write, then closes the result window the flow ends behind.
  Future<void> closeResult(WidgetTester tester) async {
    await pumpUntil(tester, finished, reason: 'the update never finished');
    await press(tester, find.text('Close'));
    await pumpUntil(tester, ended, reason: 'the flow never ended');
  }

  group('the archive is locked', () {
    final sevenZip = () {
      try {
        final found = Process.runSync('which', ['7z']);
        return found.exitCode == 0 ? found.stdout.toString().trim() : null;
      } catch (_) {
        return null;
      }
    }();
    final skip = sevenZip == null ? '7z not installed' : null;

    Future<GbFile> locked(WidgetTester tester) async {
      late List<int> bytes;
      await tester.runAsync(() async {
        final src = Directory(p.join(temp.root.path, 'src', modName))..createSync(recursive: true);
        File(p.join(src.path, 'Ellen.ini')).writeAsStringSync(ini);
        final zip = p.join(temp.root.path, 'locked.zip');
        final made = await Process.run(sevenZip!, ['a', '-tzip', '-pSECRET', zip, modName], workingDirectory: src.parent.path);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        bytes = File(zip).readAsBytesSync();
      });
      return serveBytes(5, bytes);
    }

    Future<void> answer(WidgetTester tester, String password) async {
      await tester.enterText(find.byType(TextField), password);
      await tester.pump();
      await press(tester, find.widgetWithText(FilledButton, 'Install'));
    }

    testWidgets('a wrong password is asked for again, and the right one writes the update', (tester) async {
      final mod = await installed(tester, ingest: const ModIngest(folders: [modName]));
      final file = await locked(tester);

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.byType(TextField).evaluate().isNotEmpty, reason: 'no password window');
      expect(find.text(wrongPassword), findsNothing, reason: 'nothing was tried yet');

      await answer(tester, 'wrong');
      await pumpUntil(tester, () => find.text(wrongPassword).evaluate().isNotEmpty, reason: 'the wrong password was not told');
      expect(ended(), isFalse, reason: 'the update waits for another try');
      expect(temp.read(modName, 'Ellen.ini'), '[KeySwap]\nkey = VK_1\n');

      await answer(tester, 'SECRET');
      await pumpUntil(tester, finished);
      expect(temp.read(modName, 'Ellen.ini'), ini);
    }, skip: skip != null);

    testWidgets("Don't install ends the update and deletes the archive", (tester) async {
      final mod = await installed(tester, ingest: const ModIngest(folders: [modName]));
      final file = await locked(tester);

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.byType(TextField).evaluate().isNotEmpty, reason: 'no password window');
      expect(archivesLeft(), isNotEmpty, reason: 'the archive is there until the update is done with it');

      await press(tester, find.text("Don't install"));
      await pumpUntil(tester, ended);

      expect(outcome, UpdateFlowOutcome.declined);
      expect(archivesLeft(), isEmpty);
      expect(temp.read(modName, 'Ellen.ini'), '[KeySwap]\nkey = VK_1\n');
      expect(container.read(downloadQueueProvider), isEmpty, reason: 'declined leaves the list');
    }, skip: skip != null);

    testWidgets('Open mod page ends the update, deletes the archive and opens the mod in Browse', (tester) async {
      final mod = await installed(tester, ingest: const ModIngest(folders: [modName]));
      final file = await locked(tester);

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.text('Open mod page').evaluate().isNotEmpty, reason: 'no password window');

      await press(tester, find.text('Open mod page'));
      await pumpUntil(tester, ended);
      await tester.pumpAndSettle();

      expect(outcome, UpdateFlowOutcome.declined);
      expect(archivesLeft(), isEmpty);
      expect(container.read(destinationProvider), AppDestination.browse);
      expect(container.read(marketplaceOpenModProvider), 100);
      expect(temp.read(modName, 'Ellen.ini'), '[KeySwap]\nkey = VK_1\n');
    }, skip: skip != null);
  });

  group('the archive has two folders and the mod records none', () {
    Map<String, String> twoFolders() => {'Ellen/Ellen.ini': ini, 'Ellen previews/preview.png': 'png'};

    testWidgets('the picker ticks nothing, names the folder like the mod as a hint, and the pick is the layout that is written',
        (tester) async {
      final mod = await installed(tester);
      final file = serve(2, twoFolders());

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.text('Pick what to install').evaluate().isNotEmpty, reason: 'no folders question');
      bool ticked(String folder) => tester
          .widget<ChoiceCheck>(find.descendant(of: find.widgetWithText(InkWell, '$folder/'), matching: find.byType(ChoiceCheck)))
          .ticked;
      expect(ticked('Ellen'), isFalse, reason: 'a guess never ticks');
      expect(ticked('Ellen previews'), isFalse);
      expect(find.text('Same name as your folder'), findsOneWidget);
      expect(find.text('Looks like preview images'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Update Ellen')).onPressed, isNull);
      expect(unpacksLeft(), hasLength(1), reason: 'one unpack is waiting on the answer');

      expect(find.text('Ellen/'), findsNWidgets(2), reason: 'what the mod has now, and the folder of the archive');
      await tester.tap(find.text('Ellen/').last);
      await tester.pump();
      expect(ticked('Ellen'), isTrue);
      await press(tester, find.widgetWithText(FilledButton, 'Update Ellen'));
      await closeResult(tester);

      expect(outcome, UpdateFlowOutcome.written);
      expect(temp.read(modName, 'Ellen.ini'), ini);
      expect(temp.has(modName, 'preview.png'), isFalse, reason: 'only the picked folder is written');
      expect(temp.originOf(modName)?.ingest?.folders, [modName], reason: 'the layout the second preview used is recorded');
      expect(unpacksLeft(), isEmpty, reason: 'the answer did not unpack again, so one unpack was cleaned up');
    });

    testWidgets('the window names the file as it was asked for, not as a name collision saved it', (tester) async {
      final mod = await installed(tester);
      await tester.runAsync(() async {
        final downloads = Directory(p.join(temp.root.path, 'downloads'))..createSync(recursive: true);
        File(p.join(downloads.path, 'ellen2.zip')).writeAsStringSync('an older download of the same name');
      });
      final file = serve(2, twoFolders());

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.text('Pick what to install').evaluate().isNotEmpty, reason: 'no folders question');
      expect(archivesLeft().where((name) => name != 'ellen2.zip'), isNotEmpty, reason: 'the download was saved under another name');
      expect(find.textContaining('ellen2.zip', findRichText: true), findsOneWidget);
      expect(find.textContaining('(1)', findRichText: true), findsNothing);

      await press(tester, find.text('Skip this update'));
      await pumpUntil(tester, ended);
    });

    testWidgets('a pick the second preview follows is the pick, not the folder named like the mod', (tester) async {
      final mod = await installed(tester);
      final file = serve(2, {'Ellen/Ellen.ini': '[Other]\n', 'Ellen alt/Ellen.ini': ini});

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.text('Pick what to install').evaluate().isNotEmpty, reason: 'no folders question');
      await tester.tap(find.text('Ellen alt/'));
      await tester.pump();
      await press(tester, find.widgetWithText(FilledButton, 'Update Ellen'));
      await closeResult(tester);

      expect(outcome, UpdateFlowOutcome.written);
      expect(temp.read(modName, 'Ellen.ini'), ini, reason: 'the folder the user ticked is the one written');
      expect(temp.originOf(modName)?.ingest?.folders, ['Ellen alt']);
      expect(unpacksLeft(), isEmpty);
    });

    testWidgets('cancelling the question declines, writes nothing and cleans up the unpack and the archive', (tester) async {
      final mod = await installed(tester);
      final file = serve(2, twoFolders());

      await start(
        tester,
        (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file, confirm: false),
      );
      await pumpUntil(tester, () => find.text('Pick what to install').evaluate().isNotEmpty, reason: 'no folders question');
      expect(archivesLeft(), isNotEmpty);

      await press(tester, find.text('Skip this update'));
      await pumpUntil(tester, ended);

      expect(outcome, UpdateFlowOutcome.declined);
      expect(temp.read(modName, 'Ellen.ini'), '[KeySwap]\nkey = VK_1\n');
      expect(temp.snapshotsOf(modName), isEmpty);
      expect(unpacksLeft(), isEmpty);
      expect(archivesLeft(), isEmpty);
      expect(container.read(downloadQueueProvider), isEmpty, reason: 'declined leaves the list');
    });
  });

  group('the archive also installed other mods', () {
    final published = DateTime(2026, 1, 1);

    ModOrigin groupOrigin(String name, {int fileId = 1, DateTime? dismissedUntil}) => originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          versionConfidence: OriginConfidence.exact,
          ingest: ModIngest(folders: [name], siblingGroup: 'g1'),
          updatesDismissedUntil: dismissedUntil,
        );

    /// Ellen is updated; Miyabi is offered ticked, Soukaku is offered unticked because its updates were ignored, and Nicole is already on the file.
    Future<ModInfo> library(WidgetTester tester) async {
      final origins = {
        'Ellen': groupOrigin('Ellen'),
        'Miyabi': groupOrigin('Miyabi'),
        'Soukaku': groupOrigin('Soukaku', dismissedUntil: DateTime(2026, 2, 1)),
        'Nicole': groupOrigin('Nicole', fileId: 2),
      };
      for (final entry in origins.entries) {
        temp.write(entry.key, '${entry.key}.ini', '[KeySwap]\nkey = VK_1\n');
        await tester.runAsync(() => temp.writeOrigin(entry.key, entry.value));
      }
      return ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false, origin: origins['Ellen']);
    }

    GbFile groupFile() => serve(2, {for (final name in ['Ellen', 'Miyabi', 'Soukaku', 'Nicole']) '$name/$name.ini': ini},
        dateAdded: published);

    bool ticked(WidgetTester tester, String name) =>
        tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, name)).value!;

    Future<void> openConfirmation(WidgetTester tester, ModInfo mod, GbFile file) async {
      await start(tester, (context, ref) => applyUpdateFlow(context, ref, mod: mod, remoteModId: 100, file: file));
      await pumpUntil(tester, () => find.byType(CheckboxListTile).evaluate().isNotEmpty, reason: 'no confirmation');
    }

    Finder confirmButton() => find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton));

    testWidgets('the confirmation offers the members ticked or not, and writes the ones left ticked', (tester) async {
      final mod = await library(tester);
      await openConfirmation(tester, mod, groupFile());

      expect({for (final name in ['Ellen', 'Miyabi', 'Soukaku']) name: ticked(tester, name)},
          {'Ellen': true, 'Miyabi': true, 'Soukaku': false});
      expect(find.widgetWithText(CheckboxListTile, 'Nicole'), findsNothing, reason: 'already on the file, so not offered');

      await press(tester, confirmButton());
      await closeResult(tester);

      expect(temp.read('Ellen', 'Ellen.ini'), ini);
      expect(temp.read('Miyabi', 'Miyabi.ini'), ini);
      expect(temp.read('Soukaku', 'Soukaku.ini'), '[KeySwap]\nkey = VK_1\n', reason: 'left unticked');
      expect(temp.read('Nicole', 'Nicole.ini'), '[KeySwap]\nkey = VK_1\n');
      expect(temp.originOf('Miyabi')?.fileId, 2);
      expect(temp.originOf('Soukaku')?.fileId, 1);
      expect(unpacksLeft(), isEmpty);
    });

    testWidgets('a member the user unticks is not written, and one the user ticks is', (tester) async {
      final mod = await library(tester);
      await openConfirmation(tester, mod, groupFile());

      await tester.tap(find.widgetWithText(CheckboxListTile, 'Miyabi'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Soukaku'));
      await tester.pump();
      expect(ticked(tester, 'Miyabi'), isFalse);
      expect(ticked(tester, 'Soukaku'), isTrue);

      await press(tester, confirmButton());
      await pumpUntil(tester, finished);

      expect(temp.read('Ellen', 'Ellen.ini'), ini);
      expect(temp.read('Miyabi', 'Miyabi.ini'), '[KeySwap]\nkey = VK_1\n');
      expect(temp.read('Soukaku', 'Soukaku.ini'), ini);
    });

    testWidgets('the mod the update was opened on can be left out, and the others are still written', (tester) async {
      final mod = await library(tester);
      await openConfirmation(tester, mod, groupFile());

      await tester.tap(find.widgetWithText(CheckboxListTile, 'Ellen'));
      await tester.pump();
      await press(tester, confirmButton());
      await pumpUntil(tester, finished);

      expect(temp.read('Ellen', 'Ellen.ini'), '[KeySwap]\nkey = VK_1\n');
      expect(temp.read('Miyabi', 'Miyabi.ini'), ini);
    });
  });
}
