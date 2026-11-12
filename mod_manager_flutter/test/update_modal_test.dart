import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_modal.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/seeded_queue.dart';
import 'support/update_jobs.dart';

/// The list behind "Update N": a snapshot of every mod with a newer file, a file picked for each, Ignore with Undo,
/// and what it hands back to the run.
void main() {
  ModOrigin originOf(int modId, int fileId, {List<ModDownload> patches = const []}) => originFixture(
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        versionConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
        patches: patches,
      );

  GbFile file(int id, String name, String label, DateTime added, {int size = 140 << 20}) =>
      GbFile(idRow: id, file: name, description: label, dateAdded: added, filesize: size);

  final aug = DateTime.utc(2026, 8, 12);
  final oct = DateTime.utc(2026, 10, 1);

  // Shark Hoodie has two newer files, the first in the installed file's own variant: nothing is preselected.
  final sharkOrigin = originOf(100, 1);
  final sharkRemote = GbMod(
    idRow: 100,
    dateAdded: aug,
    files: [
      file(1, 'SharkHoodie_v2.zip', 'Hood up', aug),
      file(2, 'SharkHoodie_v2.1.7z', 'Hood up', oct),
      file(3, 'SharkHoodie_HoodDown.7z', 'Hood down', oct, size: 139 << 20),
    ],
  );
  // Crimson Kimono has exactly one: it starts picked.
  final kimonoOrigin = originOf(200, 10);
  final kimonoRemote = GbMod(
    idRow: 200,
    dateAdded: aug,
    files: [
      file(10, 'CrimsonKimono.zip', 'Main', aug),
      file(11, 'CrimsonKimono_fixed.zip', 'fixed hair clipping!!', oct, size: 233 << 20),
    ],
  );

  ModInfo mod(String id, String name, ModOrigin origin, {String characterId = 'ellen', bool active = false}) =>
      ModInfo(id: id, name: name, characterId: characterId, isActive: active, origin: origin);

  final shark = mod('Shark', 'Shark Hoodie Recolor', sharkOrigin);
  final kimono = mod('Kimono', 'Crimson Kimono', kimonoOrigin, characterId: 'miyabi', active: true);

  UpdateCheck sharkCheck() => checkForUpdate(origin: sharkOrigin, remote: sharkRemote);
  UpdateCheck kimonoCheck() => checkForUpdate(origin: kimonoOrigin, remote: kimonoRemote);

  late ProviderContainer container;
  late List<(String, ModOrigin?)> written;
  List<UpdatePick>? result;
  var closed = false;

  Future<void> open(
    WidgetTester tester, {
    List<ModInfo>? mods,
    Map<String, UpdateCheck>? checks,
    Size surfaceSize = const Size(1200, 900),
    List<DownloadJob> jobs = const [],
  }) async {
    written = [];
    result = null;
    closed = false;
    final library = mods ?? [shark, kimono];
    container = ProviderContainer(
      overrides: [libraryOf(library), downloadQueueProvider.overrideWith(() => SeededQueue(jobs))],
    );
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = checks ?? {'Shark': sharkCheck(), 'Kimono': kimonoCheck()};
    final byId = {for (final m in library) m.id: m};
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showUpdateModal(
              context,
              writer: (id, update) async {
                written.add((id, update(byId[id]!.origin)));
                return OriginWriteResult.written;
              },
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
      container: container,
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateModal), findsOneWidget);
  }

  Finder footerButton(String label) => find.widgetWithText(FilledButton, label);

  Future<void> pickFile(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pump();
  }

  testWidgets('every mod with a newer file is a card with what it holds and the files to pick from', (tester) async {
    await open(tester);

    expect(find.text('2 mods have newer files'), findsOneWidget);
    expect(find.text('Shark Hoodie Recolor'), findsOneWidget);
    expect(find.text('Crimson Kimono'), findsOneWidget);
    expect(find.textContaining('· off'), findsOneWidget);
    expect(find.textContaining('· active'), findsOneWidget);
    // The file each holds, and the newer ones, by their names.
    expect(find.text('SharkHoodie_v2.zip'), findsOneWidget);
    expect(find.text('SharkHoodie_v2.1.7z'), findsOneWidget);
    expect(find.text('SharkHoodie_HoodDown.7z'), findsOneWidget);
    expect(find.text('CrimsonKimono_fixed.zip'), findsOneWidget);
    expect(find.text('YOU HAVE'), findsNWidgets(2));
    expect(find.textContaining('Ignoring an update stops it showing as a newer file'), findsOneWidget);
    // The press is the consent, so the footer states what every update does.
    expect(
      find.textContaining("Each update keeps the file you have now as a snapshot, then replaces the folder's contents."),
      findsOneWidget,
    );
    expect(find.textContaining('keys you rebound are replaced by the author'), findsOneWidget);
  });

  testWidgets('a sole newer file starts picked, and with several nothing is, so the button counts one mod',
      (tester) async {
    await open(tester);

    expect(footerButton('Update 1 mod'), findsOneWidget);
    final radios = tester.widgetList<Semantics>(find.byType(Semantics)).where((s) => s.properties.checked != null).toList();
    expect({for (final r in radios) r.properties.label: r.properties.checked}, {
      'SharkHoodie_v2.1.7z, matches your variant, Hood up, uploaded 2026-10-01, 140 MB': false,
      'SharkHoodie_HoodDown.7z, Hood down, uploaded 2026-10-01, 139 MB': false,
      'CrimsonKimono_fixed.zip, fixed hair clipping!!, uploaded 2026-10-01, 233 MB': true,
    });

    await pickFile(tester, 'SharkHoodie_HoodDown.7z');
    expect(footerButton('Update 2 mods'), findsOneWidget);
  });

  testWidgets("the app's candidate is shown as a chip and is never picked for the user", (tester) async {
    await open(tester, mods: [shark], checks: {'Shark': sharkCheck()});

    expect(find.text('matches your variant'), findsOneWidget);
    final update = tester.widget<FilledButton>(footerButton('Update'));
    expect(update.onPressed, isNull, reason: 'nothing is picked');
  });

  testWidgets('with nothing picked the button reads Update and is disabled, and a pick enables and counts it',
      (tester) async {
    await open(tester, mods: [shark], checks: {'Shark': sharkCheck()});
    expect(tester.widget<FilledButton>(footerButton('Update')).onPressed, isNull);

    await pickFile(tester, 'SharkHoodie_v2.1.7z');
    expect(tester.widget<FilledButton>(footerButton('Update 1 mod')).onPressed, isNotNull);
  });

  testWidgets('Update hands the picks back in list order, with every newer file for the passed-over record',
      (tester) async {
    await open(tester);
    await pickFile(tester, 'SharkHoodie_HoodDown.7z');

    await tester.tap(footerButton('Update 2 mods'));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect([for (final p in result!) (p.modId, p.file.idRow)], [('Shark', 3), ('Kimono', 11)]);
    expect(result!.first.published.map((f) => f.idRow), containsAll([2, 3]));
    expect(result!.first.subject, const DownloadKey.base(100));
  });

  testWidgets('a mod already in an update run is not listed, and a run does not stop the list opening', (tester) async {
    await open(tester, jobs: [updateJob(1, mods: [baseOf('Shark', 100)])]);

    expect(find.text('1 mod has a newer file'), findsOneWidget);
    expect(find.text('Crimson Kimono'), findsOneWidget);
    expect(find.text('Shark Hoodie Recolor'), findsNothing);
  });

  testWidgets('asking for the list while it is open opens no second one', (tester) async {
    await open(tester);
    final context = tester.element(find.byType(UpdateModal));

    expect(await showUpdateModal(context), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateModal), findsOneWidget);
    expect(container.read(updateModalOpenProvider), isTrue);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Later'));
    await tester.pumpAndSettle();
    expect(container.read(updateModalOpenProvider), isFalse, reason: 'closing frees it for the next press');
  });

  testWidgets('Later and Escape hand back nothing', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Later'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);

    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  group('Ignore', () {
    testWidgets('writes at once and collapses the card to its header, keeping the title and the card', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('ignore_Kimono')));
      await tester.pumpAndSettle();

      expect(written.single.$1, 'Kimono');
      expect(written.single.$2!.base!.updatesDismissedUntil, oct);
      expect(find.text('Update ignored ·'), findsOneWidget);
      expect(find.byKey(const ValueKey('undo_Kimono')), findsOneWidget);
      expect(find.text('Crimson Kimono'), findsOneWidget, reason: 'the card stays so Undo has somewhere to be');
      expect(find.text('CrimsonKimono_fixed.zip'), findsNothing);
      expect(find.text('2 mods have newer files'), findsOneWidget, reason: 'the title counts the list it opened with');
      expect(container.read(modUpdateChecksProvider)['Kimono']!.hasUpdate, isFalse);
      // The ignored mod's pick is gone with it: nothing left to update.
      expect(tester.widget<FilledButton>(footerButton('Update')).onPressed, isNull);
    });

    testWidgets('Undo takes it back and reopens the card with no file picked', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('ignore_Kimono')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('undo_Kimono')));
      await tester.pumpAndSettle();

      expect(written.last.$2!.base!.updatesDismissedUntil, isNull);
      expect(find.text('CrimsonKimono_fixed.zip'), findsOneWidget);
      expect(find.text('Update ignored ·'), findsNothing);
      expect(container.read(modUpdateChecksProvider)['Kimono']!.hasUpdate, isTrue);
      expect(tester.widget<FilledButton>(footerButton('Update')).onPressed, isNull, reason: 'no pick after Undo');
    });

    testWidgets('an ignored mod is left out of what Update hands back', (tester) async {
      await open(tester);
      await pickFile(tester, 'SharkHoodie_v2.1.7z');
      await tester.tap(find.byKey(const ValueKey('ignore_Kimono')));
      await tester.pumpAndSettle();

      await tester.tap(footerButton('Update 1 mod'));
      await tester.pumpAndSettle();

      expect([for (final p in result!) p.modId], ['Shark']);
    });
  });

  testWidgets('Ignore and the radios wait while the mod is being written', (tester) async {
    await open(tester);
    container.read(modWritesInProgressProvider.notifier).state = {'Shark'};
    await tester.pump();

    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ignore_Shark'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ignore_Kimono'))).onPressed, isNotNull);
    await pickFile(tester, 'SharkHoodie_HoodDown.7z');
    expect(footerButton('Update 1 mod'), findsOneWidget, reason: 'the press on a busy mod picks nothing');
  });

  testWidgets('a mod whose winning layer is a patch says so', (tester) async {
    final patched = mod(
      'Patched',
      'Patched Outfit',
      originOf(300, 20, patches: [patchFixture(modId: 301, fileId: 30, modIdConfidence: OriginConfidence.exact)]),
    );
    final check = UpdateCheck(
      outcome: UpdateOutcome.updateAvailable,
      newerFiles: [file(31, 'Patch_v2.zip', 'fix', oct)],
      subject: const DownloadKey.patch(301),
    );
    await open(tester, mods: [patched], checks: {'Patched': check});

    expect(find.text('Patch'), findsOneWidget);
    expect(find.text('Patch_v2.zip'), findsOneWidget);
  });

  testWidgets('a maybe-newer verdict carries the guess caveat under the card header', (tester) async {
    final check = UpdateCheck(
      outcome: UpdateOutcome.possiblyOutdated,
      isGuess: true,
      newerFiles: [file(11, 'CrimsonKimono_fixed.zip', 'x', oct)],
      subject: const DownloadKey.base(200),
    );
    await open(tester, mods: [kimono], checks: {'Kimono': check});

    expect(find.textContaining('a best guess, not a guarantee'), findsOneWidget);
  });

  testWidgets('a narrow window does not overflow, and the footer stays in reach', (tester) async {
    await open(tester, surfaceSize: const Size(400, 600));

    expect(tester.takeException(), isNull);
    expect(footerButton('Update 1 mod'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Later'), findsOneWidget);
  });
}
