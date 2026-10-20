import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/updates/updates_page.dart';
import 'package:mod_manager_flutter/services/bulk_assume_current.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The Library's Updates page: the coverage strip, the newer files, and the Can't be checked section.
void main() {
  late ProviderContainer container;
  final added = DateTime.utc(2026, 5, 8, 12);

  ModOrigin tracked([OriginConfidence versionConfidence = OriginConfidence.unknown]) => originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.user,
        fileId: versionConfidence == OriginConfidence.unknown ? null : 10,
        versionConfidence: versionConfidence,
        installedAt: added,
      );

  ModInfo mod(String name, [ModOrigin? origin]) =>
      ModInfo(id: name, name: name, characterId: 'ellen', isActive: false, origin: origin);

  /// The sidecars as the writer left them, by folder id.
  late Map<String, ModOrigin?> disk;

  /// The folders whose sidecar can't be written.
  final readOnly = <String>{};

  /// The folders renamed or removed since the page last read them.
  final gone = <String>{};

  Future<OriginWriteResult> writer(String id, ModOrigin? Function(ModOrigin?) update) async {
    if (readOnly.contains(id)) return OriginWriteResult.writeFailed;
    if (gone.contains(id)) return OriginWriteResult.folderMissing;
    final next = update(disk[id]);
    if (next == null) return OriginWriteResult.declined;
    disk[id] = next;
    return OriginWriteResult.written;
  }

  /// What a rescan would read back after the writes.
  void rescanFromDisk(List<ModInfo> mods) => container
      .read(libraryProvider.notifier)
      .put([for (final m in mods) m.copyWith(origin: disk[m.id])]);

  final opened = <String>[];
  final shownUpdates = <String>[];

  Future<void> pumpPage(WidgetTester tester, List<ModInfo> mods, {Map<String, UpdateCheck> checks = const {}}) async {
    disk = {for (final m in mods) m.id: m.origin};
    readOnly.clear();
    gone.clear();
    opened.clear();
    shownUpdates.clear();
    container = ProviderContainer(overrides: [libraryOf(mods)]);
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = checks;
    await loadTableFonts(tester);
    await pumpLocalized(
      tester,
      LibraryActionsHost(
        updateFetcher: (_) async => throw StateError('no fetch expected'),
        updatesFetcher: (_) async => throw StateError('no fetch expected'),
        originWriter: writer,
        child: UpdatesPage(
          onOpenPage: (m) => opened.add(m.id),
          onShowUpdate: (m) => shownUpdates.add(m.id),
          originWriter: writer,
        ),
      ),
      container: container,
      surfaceSize: const Size(1400, 1000),
    );
    expectBuilt(UpdatesPage);
  }

  const answered = UpdateCheck(outcome: UpdateOutcome.upToDate);

  testWidgets('the strip counts the mods checked this session, dated only among them, and leaves Local out',
      (tester) async {
    await pumpPage(
      tester,
      [
        mod('known', tracked(OriginConfidence.exact)),
        mod('dated', tracked(OriginConfidence.assumedLatest)),
        mod('waiting', tracked(OriginConfidence.exact)),
        mod('which 1', tracked()),
        mod('which 2', tracked()),
        mod('untracked'),
        mod('local', originFixture(modId: 1, tracking: OriginTracking.off)),
      ],
      checks: {'known': answered, 'dated': answered},
    );

    expect(find.text('2 of your 6 mods checked for updates'), findsOneWidget);
    for (final label in [
      '1 checked',
      '1 dated only',
      '1 not checked yet',
      '2 which file?',
      '1 not tracked',
      '1 Local, not counted',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('base unknown'), findsNothing, reason: 'a state no mod is in has no legend line');
  });

  testWidgets('before a check nothing reads checked, and the strip fills as the check reaches each mod',
      (tester) async {
    await pumpPage(tester, [mod('a', tracked(OriginConfidence.exact)), mod('b', tracked(OriginConfidence.user))]);

    expect(find.text('None of your 2 mods have been checked for updates yet'), findsOneWidget);
    expect(find.text('2 not checked yet'), findsOneWidget);
    expect(find.text('Not checked since Zenith started'), findsOneWidget);
    expect(find.text("Can't be checked"), findsNothing, reason: 'nothing to settle');
    expect(find.text('Check for updates to see which of your mods have a newer file.'), findsOneWidget);

    container.read(libraryCheckProgressProvider.notifier).state = {'a'};
    await tester.pumpAndSettle();
    expect(find.text('1 of your 2 mods checked for updates'), findsOneWidget);

    container.read(modUpdateChecksProvider.notifier).state = {'a': answered, 'b': answered};
    container.read(libraryCheckProgressProvider.notifier).state = const {};
    await tester.pumpAndSettle();
    expect(find.text('All 2 of your mods have been checked for updates'), findsOneWidget);
  });

  group('newer files', () {
    final check = UpdateCheck(
      outcome: UpdateOutcome.updateAvailable,
      installedFile: GbFile(idRow: 10, file: 'Swimsuit_v1.zip', dateAdded: DateTime.utc(2026, 8, 12)),
      candidate: GbFile(
        idRow: 11,
        file: 'Swimsuit_v2.zip',
        dateAdded: DateTime.utc(2026, 10, 3),
        description: 'hood up',
      ),
      newerFiles: [
        GbFile(idRow: 11, file: 'Swimsuit_v2.zip', dateAdded: DateTime.utc(2026, 10, 3), description: 'hood up'),
      ],
      subjectModId: 1,
    );

    testWidgets('a row shows the file you have and the newer one', (tester) async {
      await pumpPage(tester, [mod('Swimsuit', tracked(OriginConfidence.exact))], checks: {'Swimsuit': check});

      expect(find.text('Swimsuit_v1.zip'), findsOneWidget);
      expect(find.text('uploaded 2026-08-12'), findsOneWidget);
      expect(find.text('Swimsuit_v2.zip'), findsOneWidget);
      expect(find.text('uploaded 2026-10-03 · “hood up”'), findsOneWidget);

      await tester.tap(find.text('Update'));
      expect(shownUpdates, ['Swimsuit']);
      await tester.tap(find.text('Swimsuit'));
      expect(opened, ['Swimsuit']);
    });

    testWidgets('a mod marked as current says so where its file would be', (tester) async {
      final dated = UpdateCheck(
        outcome: UpdateOutcome.possiblyOutdated,
        comparedAgainst: added,
        newerFiles: [GbFile(idRow: 11, file: 'new.zip', dateAdded: DateTime.utc(2026, 10, 3))],
        subjectModId: 1,
      );
      await pumpPage(tester, [mod('Coat', tracked(OriginConfidence.assumedLatest))], checks: {'Coat': dated});

      expect(find.text('Marked as current'), findsOneWidget);
      expect(find.text('the newest on 2026-05-08'), findsOneWidget);
      expect(find.text('MAYBE NEWER'), findsOneWidget);
      expect(find.text('new.zip'), findsOneWidget, reason: 'the one newer file is named');
    });

    testWidgets('Ignore writes the dismissal up to the newest file, and the row leaves', (tester) async {
      final library = [mod('Swimsuit', tracked(OriginConfidence.exact))];
      await pumpPage(tester, library, checks: {'Swimsuit': check});

      await tapWithIo(tester, find.text('Ignore'));
      await tester.pumpAndSettle();

      expect(disk['Swimsuit']?.updatesDismissedUntil, DateTime.utc(2026, 10, 3));
      expect(container.read(modUpdateChecksProvider)['Swimsuit']?.hasUpdate, isFalse);
      expect(find.text('Swimsuit_v2.zip'), findsNothing);
      expect(find.text('No newer files since the last check.'), findsOneWidget);
    });

    testWidgets('an Ignore that cannot be written says so, and the row stays', (tester) async {
      await pumpPage(tester, [mod('Swimsuit', tracked(OriginConfidence.exact))], checks: {'Swimsuit': check});
      readOnly.add('Swimsuit');

      await tapWithIo(tester, find.text('Ignore'));
      await tester.pumpAndSettle();

      expect([for (final n in container.read(notificationsProvider)) n.title], ["Couldn't ignore that update"]);
      expect(find.text('Swimsuit_v2.zip'), findsOneWidget);
    });

    testWidgets('Ignore is off when the check names nothing to ignore', (tester) async {
      // A page and a newer file, but no date to ignore up to.
      const undated = UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        newerFiles: [GbFile(idRow: 11, file: 'new.zip')],
        subjectModId: 1,
      );
      await pumpPage(tester, [mod('Swimsuit', tracked(OriginConfidence.exact))], checks: {'Swimsuit': undated});

      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Ignore')).onPressed, isNull);
    });

    testWidgets('"Marked as current" follows how the check compared, not the tracking now', (tester) async {
      // Checked by its date, then given a file in the tracking screen before the next check.
      final byDate = UpdateCheck(
        outcome: UpdateOutcome.possiblyOutdated,
        comparedAgainst: added,
        newerFiles: [GbFile(idRow: 11, file: 'new.zip', dateAdded: DateTime.utc(2026, 10))],
        subjectModId: 1,
      );
      await pumpPage(tester, [mod('Coat', tracked(OriginConfidence.user))], checks: {'Coat': byDate});

      expect(find.text('Marked as current'), findsOneWidget);
      expect(find.text('No longer on its page'), findsNothing);
    });

    testWidgets('a file the page no longer offers, with nothing newer to name, quotes no date', (tester) async {
      // Compared against its own file's date, which "after" would misreport as the day the page changed.
      final grouped = UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        evidence: InstalledFileEvidence.recorded,
        installedFile: GbFile(idRow: 10, file: 'Coat_v1.zip', dateAdded: DateTime.utc(2026, 8, 12)),
        comparedAgainst: DateTime.utc(2026, 8, 12),
        subjectModId: 1,
      );
      await pumpPage(tester, [mod('Coat', tracked(OriginConfidence.exact))], checks: {'Coat': grouped});

      expect(find.text('Its page changed'), findsOneWidget);
      expect(find.textContaining('after'), findsNothing);
    });

    testWidgets('a dated mod whose page changed with no newer file says so, and quotes no upload date', (tester) async {
      final changed = UpdateCheck(outcome: UpdateOutcome.possiblyOutdated, comparedAgainst: added, subjectModId: 1);
      await pumpPage(tester, [mod('Coat', tracked(OriginConfidence.assumedLatest))], checks: {'Coat': changed});

      expect(find.text('Its page changed'), findsOneWidget);
      expect(find.text('after 2026-05-08'), findsOneWidget);
      expect(find.textContaining('newer file'), findsNothing);
      expect(find.textContaining('uploaded'), findsNothing);
    });

    testWidgets('a file taken off its page says so where the file would be', (tester) async {
      final gone = UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        evidence: InstalledFileEvidence.recorded,
        newerFiles: [
          GbFile(idRow: 11, file: 'a.zip', dateAdded: DateTime.utc(2026, 9)),
          GbFile(idRow: 12, file: 'b.zip', dateAdded: DateTime.utc(2026, 10)),
        ],
        subjectModId: 1,
      );
      await pumpPage(tester, [mod('Coat', tracked(OriginConfidence.exact))], checks: {'Coat': gone});

      expect(find.text('No longer on its page'), findsOneWidget);
      expect(find.text('2 newer files'), findsOneWidget);
      expect(find.text('uploaded 2026-10-01'), findsOneWidget, reason: 'the newest of them');
    });
  });

  testWidgets('while a check runs, nothing on the page can start one or write over its results', (tester) async {
    final update = UpdateCheck(
      outcome: UpdateOutcome.updateAvailable,
      newerFiles: [GbFile(idRow: 11, file: 'new.zip', dateAdded: DateTime.utc(2026, 10))],
      subjectModId: 1,
    );
    await pumpPage(
      tester,
      [mod('known', tracked(OriginConfidence.exact)), mod('which', tracked()), mod('untracked')],
      checks: {'known': update},
    );
    container.read(lastMarkingProvider.notifier).state = [
      MarkedAsCurrent(modId: 'which', before: const ModDownload(), baseline: added),
    ];
    await tester.pump();

    VoidCallback? pressed<T extends ButtonStyleButton>(String label) =>
        tester.widget<T>(find.widgetWithText(T, label)).onPressed;
    // Each of them is on with no check running.
    expect(pressed<OutlinedButton>('Check all for updates'), isNotNull);
    expect(pressed<TextButton>('Ignore'), isNotNull);
    expect(pressed<TextButton>('Pick the files one by one'), isNotNull);
    expect(pressed<OutlinedButton>('Sort out tracking…'), isNotNull);
    expect(pressed<FilledButton>('Check them now'), isNotNull);
    expect(pressed<TextButton>('Undo'), isNotNull);

    container.read(libraryCheckRunningProvider.notifier).state = true;
    await tester.pump();
    expect(pressed<OutlinedButton>('Check all for updates'), isNull);
    expect(pressed<TextButton>('Ignore'), isNull);
    expect(pressed<TextButton>('Pick the files one by one'), isNull);
    expect(pressed<OutlinedButton>('Sort out tracking…'), isNull);
    expect(pressed<FilledButton>('Check them now'), isNull);
    expect(pressed<TextButton>('Undo'), isNull);
  });

  group("can't be checked", () {
    testWidgets('Mark all as current, then Undo, puts each mod back as it was', (tester) async {
      final library = [mod('a', tracked()), mod('b', tracked()), mod('known', tracked(OriginConfidence.exact))];
      await pumpPage(tester, library);
      expect(find.text('a, b · '), findsOneWidget);

      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();
      rescanFromDisk(library);
      await tester.pumpAndSettle();

      expect(disk['a']?.versionConfidence, OriginConfidence.assumedLatest);
      expect(find.text('2 mods marked as current'), findsOneWidget);
      expect(find.text('Mark all as current…'), findsNothing, reason: 'no mod asks which file any more');
      expect(find.text('3 not checked yet'), findsOneWidget, reason: 'marked, and checked by date once checked');

      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();
      rescanFromDisk(library);
      await tester.pumpAndSettle();

      expect(disk['a'], library[0].origin);
      expect(disk['b'], library[1].origin);
      expect(container.read(lastMarkingProvider), isNull);
      expect(find.text('2 mods marked as current'), findsNothing);
      expect(find.text('Mark all as current…'), findsOneWidget);
    });

    testWidgets('Undo leaves a mod whose file was picked since', (tester) async {
      final library = [mod('a', tracked()), mod('b', tracked())];
      await pumpPage(tester, library);
      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();

      final picked = disk['b']!.copyBase(fileId: 10, versionConfidence: OriginConfidence.user);
      disk['b'] = picked;
      const answer = UpdateCheck(outcome: UpdateOutcome.upToDate, subjectModId: 1);
      container.read(modUpdateChecksProvider.notifier).state = {'a': answer, 'b': answer};
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();

      expect(disk['a'], library[0].origin);
      expect(disk['b'], picked);
      expect(container.read(lastMarkingProvider), isNull, reason: 'nothing is left to undo');
      expect(container.read(modUpdateChecksProvider).keys, ['b'], reason: "only a's check by date is dropped");
    });

    testWidgets('an Undo that cannot be written names the mod and leaves it to undo again', (tester) async {
      final library = [mod('a', tracked()), mod('b', tracked())];
      await pumpPage(tester, library);
      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();

      readOnly.add('b');
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();

      final raised = container.read(notificationsProvider).single;
      expect(raised.title, "Couldn't undo marking 1 mod as current");
      expect(raised.body, "The folder couldn't be written to, so the mark stays: b.");
      expect(disk['a'], library[0].origin);
      expect([for (final m in container.read(lastMarkingProvider)!) m.modId], ['b']);
      expect(find.text('1 mod marked as current'), findsOneWidget);

      readOnly.clear();
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();
      expect(disk['b'], library[1].origin);
      expect(container.read(lastMarkingProvider), isNull);
    });

    testWidgets('Undo skips a mod whose folder is being written, names it, and leaves it to undo again',
        (tester) async {
      final library = [mod('a', tracked()), mod('b', tracked())];
      await pumpPage(tester, library);
      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();
      final marked = disk['b'];

      // An update writing b's folder, still running.
      final update = Completer<void>();
      unawaited(whileWritingMod(container, 'b', () => update.future));
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();
      update.complete();

      expect(disk['a'], library[0].origin);
      expect(disk['b'], marked, reason: 'left alone while its folder is written');
      expect([for (final n in container.read(notificationsProvider)) n.title],
          ['1 mod skipped while its folder is being changed']);
      expect([for (final m in container.read(lastMarkingProvider)!) m.modId], ['b']);
    });

    testWidgets("Undo keeps the verdict about a patch in the same folder", (tester) async {
      final library = [mod('a', tracked())];
      await pumpPage(tester, library);
      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 1 as current'));
      await tester.pumpAndSettle();

      // The base was checked by its date and found maybe newer; the patch has a newer file of its own.
      final folder = foldDownloads([
        DownloadCheck(
          download: const ModDownload(modId: 1),
          check: UpdateCheck(outcome: UpdateOutcome.possiblyOutdated, comparedAgainst: added),
        ),
        DownloadCheck(
          download: const ModDownload(role: DownloadRole.patch, modId: 2),
          check: const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        ),
      ]);
      container.read(modUpdateChecksProvider.notifier).state = {'a': folder};
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();

      final kept = container.read(modUpdateChecksProvider)['a']!;
      expect(kept.subjectModId, 2, reason: "the patch's update still stands");
      expect(kept.hasUpdate, isTrue);
      expect(
        kept.layers.firstWhere((l) => l.download.modId == 1).check.outcome,
        UpdateOutcome.versionUnknown,
        reason: "the base's check by date went with the date",
      );
      // Ignoring the patch's update now leaves nothing about the base to bring back.
      expect(refoldDismissal(kept, 2, true).hasUpdate, isFalse);
    });

    test("the base's verdict is the bottom layer's, even with a patch from the same mod page", () {
      final folder = foldDownloads([
        DownloadCheck(
          download: const ModDownload(modId: 1),
          check: UpdateCheck(outcome: UpdateOutcome.upToDate, comparedAgainst: added),
        ),
        DownloadCheck(
          download: const ModDownload(role: DownloadRole.patch, modId: 1),
          check: const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        ),
      ]);

      final kept = forgetBaseVerdict(folder)!;
      expect(kept.hasUpdate, isTrue, reason: "the patch's update stands");
      expect(kept.layers.first.check.outcome, UpdateOutcome.versionUnknown);
      expect(kept.layers.last.check.outcome, UpdateOutcome.updateAvailable);
    });

    test('a base page found gone keeps saying so', () {
      final folder = foldDownloads([
        DownloadCheck(download: const ModDownload(modId: 1), check: const UpdateCheck(outcome: UpdateOutcome.sourceGone)),
        DownloadCheck(
          download: const ModDownload(role: DownloadRole.patch, modId: 2),
          check: const UpdateCheck(outcome: UpdateOutcome.upToDate),
        ),
      ]);

      expect(forgetBaseVerdict(folder)!.layers.first.check.outcome, UpdateOutcome.sourceGone);
      const gone = UpdateCheck(outcome: UpdateOutcome.sourceGone);
      expect(forgetBaseVerdict(gone), same(gone), reason: 'in a folder of one layer too');
      expect(
        forgetBaseVerdict(const UpdateCheck(outcome: UpdateOutcome.upToDate)),
        isNull,
        reason: 'a check by date in a folder of one layer has nothing left',
      );
    });

    testWidgets('Undo names a mod whose folder is gone since the marking, and lets it go', (tester) async {
      final library = [mod('a', tracked()), mod('b', tracked())];
      await pumpPage(tester, library);
      await tester.tap(find.text('Mark all as current…'));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();

      gone.add('b');
      await tapWithIo(tester, find.text('Undo'));
      await tester.pumpAndSettle();

      final raised = container.read(notificationsProvider).single;
      expect(raised.title, "Couldn't undo marking 1 mod as current");
      expect(raised.body, 'The folder is no longer there: b.');
      expect(container.read(lastMarkingProvider), isNull, reason: "it can't be found again under that name");
    });

    testWidgets('the untracked and base-unknown mods share one card with Sort out tracking', (tester) async {
      await pumpPage(tester, [
        mod('Neon'),
        mod('Beach'),
        mod('patch', tracked(OriginConfidence.exact).copyWith(ingest: const ModIngest(patchShaped: true))),
      ]);

      expect(find.text("Zenith doesn't know where these came from"), findsOneWidget);
      expect(find.text('2 mods'), findsOneWidget);
      expect(find.text('1 patch'), findsOneWidget);
      expect(find.text("Zenith doesn't know which mod it patches."), findsOneWidget);
      expect(find.text('Sort out tracking…'), findsOneWidget);
    });

    testWidgets('Hide folds the section for the session', (tester) async {
      await pumpPage(tester, [mod('Neon')]);
      expect(find.textContaining('These can\'t be compared yet'), findsOneWidget);

      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.textContaining('These can\'t be compared yet'), findsNothing);
      expect(find.text('· hidden'), findsOneWidget);
      expect(container.read(updatesCantCheckHiddenProvider), isTrue);

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.textContaining('These can\'t be compared yet'), findsOneWidget);
    });

    testWidgets('See them opens All mods on Can\'t be checked alone', (tester) async {
      await pumpPage(tester, [mod('Neon')]);
      container.read(allModsSearchProvider.notifier).state = 'ellen';

      await tester.tap(find.text('See them'));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.allMods);
      expect(container.read(allModsFilterProvider), AllModsFilter.needsAttention);
      expect(container.read(allModsSearchProvider), '');
    });
  });
}
