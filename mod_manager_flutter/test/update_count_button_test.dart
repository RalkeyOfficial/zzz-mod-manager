import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_modal.dart';
import 'package:mod_manager_flutter/screens/updates/updates_page.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/seeded_queue.dart';
import 'support/update_jobs.dart';

/// "Update N" beside Check all for updates, on All mods and on Updates: shown for the mods that have a file to
/// install and are not already in an update run, which is not the sidebar's count, and never disabled by a run.
void main() {
  ModInfo mod(String id, int modId) => ModInfo(
        id: id,
        name: id,
        characterId: 'ellen',
        isActive: false,
        origin: originFixture(
          modId: modId,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
        ),
      );

  UpdateCheck withFile(int modId, {int fileId = 2}) => UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        newerFiles: [GbFile(idRow: fileId, file: 'f$fileId.zip', dateAdded: DateTime.utc(2026, 10, 1))],
        subject: DownloadKey.base(modId),
      );

  /// "Its page changed": an update to know about, with no file to name.
  UpdateCheck pageChanged(int modId) => UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        comparedAgainst: DateTime.utc(2026, 9, 1),
        subject: DownloadKey.base(modId),
      );

  final mods = [mod('A', 100), mod('B', 200), mod('C', 300)];

  Finder updateButton(String label) => find.widgetWithText(FilledButton, label);

  Future<ProviderContainer> pumpAllMods(WidgetTester tester, Map<String, UpdateCheck> checks) async {
    final container = await pumpAllModsTable(tester, mods);
    container.read(modUpdateChecksProvider.notifier).state = checks;
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('no button while no mod has a file to install', (tester) async {
    await pumpAllMods(tester, {});

    expect(find.widgetWithText(OutlinedButton, 'Check all for updates'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('the number counts mods with a file to install, not the sidebar count', (tester) async {
    final container = await pumpAllMods(tester, {'A': withFile(100), 'B': withFile(200), 'C': pageChanged(300)});

    expect(container.read(libraryUpdateCountProvider), 3, reason: 'the sidebar counts every verdict that shows an update');
    expect(updateButton('Update 2'), findsOneWidget);
  });

  testWidgets('a mod whose verdict is about a layer the folder does not hold has nothing to install', (tester) async {
    await pumpAllMods(tester, {'A': withFile(100), 'B': withFile(999)});

    expect(updateButton('Update 1'), findsOneWidget);
  });

  testWidgets('pressing it opens the list, which has as many cards as the button promised', (tester) async {
    await pumpAllMods(tester, {'A': withFile(100), 'B': withFile(200), 'C': pageChanged(300)});

    await tester.tap(updateButton('Update 2'));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateModal), findsOneWidget);
    expect(find.text('2 mods have newer files'), findsOneWidget);
  });

  testWidgets('it stays pressable while a check runs', (tester) async {
    final container = await pumpAllMods(tester, {'A': withFile(100)});
    container.read(libraryCheckRunningProvider.notifier).state = true;
    await tester.pump();

    expect(tester.widget<FilledButton>(updateButton('Update 1')).onPressed, isNotNull);
  });

  testWidgets('a run never disables it: it counts the mods not already in the run', (tester) async {
    final container = await pumpAllModsTable(
      tester,
      mods,
      overrides: [
        downloadQueueProvider.overrideWith(() => SeededQueue([updateJob(1, mods: [baseOf('A', 100)])])),
      ],
    );
    container.read(modUpdateChecksProvider.notifier).state = {'A': withFile(100), 'B': withFile(200)};
    await tester.pumpAndSettle();

    expect(updateButton('Update 1'), findsOneWidget, reason: "A's base is already in the run");
    expect(tester.widget<FilledButton>(updateButton('Update 1')).onPressed, isNotNull);

    await tester.tap(updateButton('Update 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 mod has a newer file'), findsOneWidget, reason: 'the list offers only B');
  });

  group('in a narrow window', () {
    for (final locale in [const Locale('en'), const Locale('uk')]) {
      testWidgets('the All mods header wraps its two buttons without overflowing (${locale.languageCode})', (tester) async {
        final container = await pumpAllModsTable(
          tester,
          mods,
          locale: locale,
          surfaceSize: const Size(360, 800),
        );
        container.read(modUpdateChecksProvider.notifier).state = {'A': withFile(100), 'B': withFile(200)};
        await tester.pumpAndSettle();

        expect(find.byType(FilledButton), findsOneWidget);
        expect(tester.takeException(), isNull);
        final check = tester.getRect(find.widgetWithText(OutlinedButton, locale.languageCode == 'en' ? 'Check all for updates' : 'Перевірити всі на оновлення'));
        final update = tester.getRect(find.byType(FilledButton));
        expect(check.right, lessThanOrEqualTo(360));
        expect(update.right, lessThanOrEqualTo(360));
      });

      testWidgets('the Updates header does the same (${locale.languageCode})', (tester) async {
        final container = ProviderContainer(overrides: [libraryOf(mods)]);
        addTearDown(container.dispose);
        container.read(modUpdateChecksProvider.notifier).state = {'A': withFile(100)};
        await loadTableFonts(tester);
        await pumpLocalized(
          tester,
          LibraryActionsHost(
            updateFetcher: (_) async => throw StateError('no fetch expected'),
            originWriter: (_, _) async => OriginWriteResult.writeFailed,
            child: UpdatesPage(onOpenPage: (_) {}, onShowUpdate: (_) {}),
          ),
          container: container,
          locale: locale,
          surfaceSize: const Size(360, 800),
        );

        expect(find.byType(FilledButton), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byType(FilledButton)).right, lessThanOrEqualTo(360));
      });
    }
  });

  group('on the Updates page', () {
    Future<ProviderContainer> pumpUpdates(WidgetTester tester, Map<String, UpdateCheck> checks) async {
      final container = ProviderContainer(overrides: [libraryOf(mods)]);
      addTearDown(container.dispose);
      container.read(modUpdateChecksProvider.notifier).state = checks;
      await loadTableFonts(tester);
      await pumpLocalized(
        tester,
        LibraryActionsHost(
          updateFetcher: (_) async => throw StateError('no fetch expected'),
          originWriter: (_, _) async => OriginWriteResult.writeFailed,
          child: UpdatesPage(onOpenPage: (_) {}, onShowUpdate: (_) {}),
        ),
        container: container,
        surfaceSize: const Size(1400, 900),
      );
      expectBuilt(UpdatesPage);
      return container;
    }

    testWidgets('the same button sits beside Check all for updates', (tester) async {
      await pumpUpdates(tester, {'A': withFile(100), 'B': pageChanged(200)});

      expect(find.widgetWithText(OutlinedButton, 'Check all for updates'), findsOneWidget);
      expect(updateButton('Update 1'), findsOneWidget);
    });

    testWidgets('it is absent with nothing to install, and stays pressable during a run', (tester) async {
      final container = await pumpUpdates(tester, {'B': pageChanged(200)});
      expect(find.byType(FilledButton), findsNothing);

      container.read(modUpdateChecksProvider.notifier).state = {'A': withFile(100)};
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(updateButton('Update 1')).onPressed, isNotNull);
    });
  });
}
