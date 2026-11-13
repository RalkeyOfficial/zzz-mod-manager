import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/question_parts.dart';
import 'package:mod_manager_flutter/screens/dialogs/folders_modal.dart';
import 'package:mod_manager_flutter/screens/dialogs/import_selection_dialog.dart';
import 'package:mod_manager_flutter/services/archive_folder_summary.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';

/// The folders window, "Pick what to install" (board `FoldersModal`), in its install and update contexts.
void main() {
  // Regression test for the single-folder aliasing bug: resolveImportSelection
  // must return a fresh list, not the caller's own. Both call sites do
  // `folderPaths..clear()..addAll(plan.folders)`; if plan.folders aliased the
  // argument, that cleared the list and dropped the only folder — surfacing as
  // a false "Mods already exist or an error occurred" with nothing installed.
  testWidgets('single-folder plan does not alias the input list', (tester) async {
    ImportPlan? plan;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                final folders = ['/tmp/extract/Grace-HazekerRedux'];
                plan = (await resolveImportSelection(
                  context,
                  folders,
                  defaultCombinedName: 'Grace-HazekerRedux',
                ))
                    ?.plan;
                // Emulate the caller: mutate the ORIGINAL list.
                folders
                  ..clear()
                  ..addAll(plan!.folders);
              },
              child: const Text('go'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(plan, isNotNull);
    expect(plan!.combine, isFalse);
    expect(plan!.folders, ['/tmp/extract/Grace-HazekerRedux']);
  });

  const hood = ImportFolderChoice(path: '/x/Shark Hoodie (Hood up)', name: 'Shark Hoodie (Hood up)');
  const down = ImportFolderChoice(path: '/x/Shark Hoodie (Hood down)', name: 'Shark Hoodie (Hood down)');
  const previews = ImportFolderChoice(path: '/x/Previews', name: 'Previews');
  final summaries = {
    previews.path: const FolderSummary(path: '/x/Previews', files: 12, images: 12, bytes: 8 * 1024 * 1024),
    hood.path: const FolderSummary(
        path: '/x/Shark Hoodie (Hood up)', files: 42, images: 0, bytes: 142 * 1024 * 1024, firstIni: 'SharkHoodie.ini'),
    down.path: const FolderSummary(
        path: '/x/Shark Hoodie (Hood down)', files: 40, images: 0, bytes: 139 * 1024 * 1024, firstIni: 'SharkHoodie.ini'),
  };

  Future<List<FolderPick?>> open(
    WidgetTester tester,
    FoldersContext question,
    List<ImportFolderChoice> choices, {
    Size surfaceSize = const Size(1440, 900),
    Locale locale = const Locale('en'),
  }) async {
    final answers = <FolderPick?>[];
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              answers.add(await showFoldersModal(context, question: question, choices: choices, summaries: summaries)),
          child: const Text('open'),
        ),
      ),
      surfaceSize: surfaceSize,
      locale: locale,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(FoldersModal);
    return answers;
  }

  bool ticked(WidgetTester tester, String folder) => tester
      .widget<ChoiceCheck>(find.descendant(of: find.widgetWithText(InkWell, '$folder/'), matching: find.byType(ChoiceCheck)))
      .ticked;

  FilledButton primary(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton));

  group('install', () {
    const install = FoldersInstall(archiveName: 'SharkHoodie_Pack.zip', defaultCombinedName: 'SharkHoodie_Pack');

    testWidgets('nothing is ticked, each folder says what it holds, and previews are hinted', (tester) async {
      await open(tester, install, [previews, hood, down]);

      expect(find.text('Pick what to install'), findsOneWidget);
      for (final folder in ['Previews', 'Shark Hoodie (Hood up)', 'Shark Hoodie (Hood down)']) {
        expect(ticked(tester, folder), isFalse, reason: 'nothing is ticked for you');
      }
      expect(find.text('12 images, no .ini'), findsOneWidget);
      expect(find.text('SharkHoodie.ini and 41 files'), findsOneWidget);
      expect(find.text('Looks like preview images'), findsOneWidget);
      expect(find.text('Tick at least one folder'), findsOneWidget);
      expect(primary(tester).onPressed, isNull);
      expect(find.text('Install'), findsOneWidget);
    });

    testWidgets('separate mods count the folders ticked, and the pick is what was ticked', (tester) async {
      final answers = await open(tester, install, [previews, hood, down]);
      await tester.tap(find.text('Shark Hoodie (Hood up)/'));
      await tester.tap(find.text('Shark Hoodie (Hood down)/'));
      await tester.pump();

      expect(find.text('2 folders, 2 mods'), findsOneWidget);
      await tester.tap(find.text('Install 2 mods'));
      await tester.pumpAndSettle();

      expect(answers.single!.folders, [hood.path, down.path]);
      expect(answers.single!.combine, isFalse);
    });

    testWidgets('One mod makes one, under the name given', (tester) async {
      final answers = await open(tester, install, [previews, hood, down]);
      await tester.tap(find.text('Shark Hoodie (Hood up)/'));
      await tester.tap(find.text('Shark Hoodie (Hood down)/'));
      await tester.tap(find.text('One mod'));
      await tester.pump();

      expect(find.text('2 folders, 1 mod'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Shark Hoodie');
      await tester.pump();
      await tester.tap(find.text('Install 1 mod'));
      await tester.pumpAndSettle();

      expect(answers.single!.combine, isTrue);
      expect(answers.single!.combinedName, 'Shark Hoodie');
    });

    testWidgets("Don't install is an answer, and closing the window is none", (tester) async {
      final answers = await open(tester, install, [hood, down]);
      await tester.tap(find.text("Don't install"));
      await tester.pumpAndSettle();
      expect(answers.single!.declined, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(answers.last, isNull);
    });

    testWidgets('Ukrainian counts take their own forms', (tester) async {
      await open(tester, install, [previews, hood, down], locale: const Locale('uk'));
      await tester.tap(find.text('Shark Hoodie (Hood up)/'));
      await tester.tap(find.text('Shark Hoodie (Hood down)/'));
      await tester.pump();
      expect(find.text('2 теки, 2 моди'), findsOneWidget);
      expect(find.text('Встановити 2 моди'), findsOneWidget);
    });

    testWidgets('fits the narrowest window', (tester) async {
      await open(tester, install, [previews, hood, down], surfaceSize: const Size(480, 900));
      expect(tester.takeException(), isNull);
    });
  });

  group('update', () {
    final pastel = ModInfo(
      id: 'PastelBurnice',
      name: 'Pastel Burnice',
      characterId: 'burnice',
      isActive: true,
      origin: const ModOrigin(provenance: OriginProvenance.downloaded, ingest: ModIngest(folders: ['PastelBurnice'])),
    );
    const same = ImportFolderChoice(path: '/x/PastelBurnice', name: 'PastelBurnice');
    const noJacket =
        ImportFolderChoice(path: '/x/PastelBurnice_NoJacket', name: 'PastelBurnice_NoJacket');
    final question = FoldersUpdate(
      archiveName: 'PastelBurnice_NoJacket.zip',
      mod: pastel,
      current: const FolderSummary(
          path: '/lib/PastelBurnice', files: 39, images: 0, bytes: 114 * 1024 * 1024, firstIni: 'PastelBurnice.ini'),
      heldFileDate: DateTime(2026, 7, 15),
    );

    testWidgets('what the mod has now, the folders with their hints and nothing ticked, and no name or separate mods',
        (tester) async {
      await open(tester, question, [same, noJacket]);

      expect(find.text('YOU HAVE NOW'), findsOneWidget);
      expect(find.text('PastelBurnice.ini and 38 files · from the 2026-07-15 file'), findsOneWidget);
      expect(find.text('Same name as your folder'), findsOneWidget);
      expect(find.text('Named like the file'), findsOneWidget);
      expect(ticked(tester, 'PastelBurnice'), isFalse, reason: 'a guess never ticks');
      expect(ticked(tester, 'PastelBurnice_NoJacket'), isFalse);
      expect(find.text('One mod'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('It keeps its name, its character and whether'), findsOneWidget);
      expect(find.text('Tick the folder that replaces it'), findsOneWidget);
      expect(primary(tester).onPressed, isNull);
      expect(find.text('Update Pastel Burnice'), findsOneWidget, reason: 'the button names the mod');
    });

    testWidgets('one folder replaces the mod, two go into it together, and the pick is the ticked ones', (tester) async {
      final answers = await open(tester, question, [same, noJacket]);
      await tester.tap(find.text('PastelBurnice_NoJacket/'));
      await tester.pump();
      expect(find.text('1 folder replaces Pastel Burnice'), findsOneWidget);
      await tester.tap(find.text('PastelBurnice/').last);
      await tester.pump();
      expect(find.text('2 folders go into Pastel Burnice together'), findsOneWidget);
      await tester.tap(find.text('PastelBurnice/').last);
      await tester.pump();

      await tester.tap(find.text('Update Pastel Burnice'));
      await tester.pumpAndSettle();
      expect(answers.single!.folders, [noJacket.path]);
      expect(answers.single!.combine, isFalse);
    });

    testWidgets('Skip this update is an answer, and closing the window is none', (tester) async {
      final answers = await open(tester, question, [same, noJacket]);
      await tester.tap(find.text('Skip this update'));
      await tester.pumpAndSettle();
      expect(answers.single!.declined, isTrue);
    });

    testWidgets('fits the narrowest window', (tester) async {
      await open(tester, question, [same, noJacket], surfaceSize: const Size(480, 900));
      expect(tester.takeException(), isNull);
    });
  });

  test('a folder is summarised from what is in it', () {
    final root = Directory.systemTemp.createTempSync('zzz_folder_summary_');
    addTearDown(() => root.deleteSync(recursive: true));
    final mod = Directory(p.join(root.path, 'Mod'))..createSync();
    File(p.join(mod.path, 'b.ini')).writeAsStringSync('');
    File(p.join(mod.path, 'A.ini')).writeAsStringSync('');
    File(p.join(mod.path, 'body.dds')).writeAsStringSync('12345');
    Directory(p.join(mod.path, '.zzz-mod-manager')).createSync();
    File(p.join(mod.path, '.zzz-mod-manager', 'meta.json')).writeAsStringSync('{}');
    final pics = Directory(p.join(root.path, 'Pics'))..createSync();
    File(p.join(pics.path, 'one.png')).writeAsStringSync('');
    File(p.join(pics.path, 'two.JPG')).writeAsStringSync('');
    final shaders = Directory(p.join(root.path, 'Shaders', 'ShaderFixes'))..createSync(recursive: true);
    File(p.join(shaders.path, 'x.txt')).writeAsStringSync('');

    final modSummary = summariseFolderSync(mod.path);
    expect(modSummary.files, 3, reason: "the app's own sidecar folder is not the mod's");
    expect(modSummary.firstIni, 'A.ini');
    expect(modSummary.bytes, 5);
    expect(modSummary.looksLikePreviews, isFalse);
    expect(summariseFolderSync(pics.path).looksLikePreviews, isTrue);
    expect(summariseFolderSync(p.join(root.path, 'Shaders')).shaderOnly, isTrue);
    expect(namedLikeMod('pastelburnice', modId: 'PastelBurnice'), isTrue);
    expect(namedLikeArchive('PastelBurnice_NoJacket', 'PastelBurnice_NoJacket.zip'), isTrue);
  });

  /// Import moves shader files out of a folder of another name without asking,
  /// so the picker says which folder they came from.
  testWidgets("names the folder a choice's shader fixes came from", (tester) async {
    final root = Directory.systemTemp.createTempSync('zzz_import_picker_');
    addTearDown(() => root.deleteSync(recursive: true));
    final mover = Directory(p.join(root.path, 'CharacterMoverMod'))..createSync();
    File(p.join(mover.path, 'mover.ini')).writeAsStringSync('');
    Directory(p.join(mover.path, 'ShaderFixes')).createSync();
    final previewsDir = Directory(p.join(root.path, 'previews'))..createSync();

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => resolveImportSelection(
            context,
            [mover.path, previewsDir.path],
            defaultCombinedName: 'CharacterMoverMod',
            shaderSources: {mover.path: 'PUT THESE IN SHADERFIXES'},
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tapWithIo(tester, find.text('open'));
    expectBuilt(FoldersModal);

    final moverRow = find.widgetWithText(InkWell, 'CharacterMoverMod/');
    expect(
      find.descendant(of: moverRow, matching: find.text('mover.ini only · Shader fixes from “PUT THESE IN SHADERFIXES”')),
      findsOneWidget,
    );
  });
}
