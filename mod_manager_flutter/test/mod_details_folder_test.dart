import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_submitter.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The details view saying **what this folder holds**.
///
/// This is the screen whose job is answering "what is this mod", and a folder
/// holding a patch as well as the mod it patches looked exactly like any other
/// here — so the app's own record of the second download was invisible on the
/// one surface a reader would go to for it.
///
/// Only the downloads section is exercised here, with an origin block that
/// reaches no service at all; the note writer is a stub so nothing reaches the
/// developer's own `config.json`.
void main() {
  ModInfo mod({ModOrigin? origin}) => ModInfo(
        id: 'Pulchra-BottomHeavy',
        name: 'Pulchra-BottomHeavy',
        characterId: 'unknown',
        isActive: false,
        origin: origin,
      );

  ModOrigin origin({List<ModDownload> patches = const []}) => originFixture(
        source: 'gamebanana',
        modId: 585282,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1433843,
        versionConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
        patches: patches,
      );

  final patch = patchFixture(
    modId: 605460,
    modIdConfidence: OriginConfidence.exact,
    fileId: 1473174,
    versionConfidence: OriginConfidence.exact,
  );

  Future<void> open(
    WidgetTester tester,
    ModInfo target, {
    Map<int, GbMod> sessionRecords = const {},
    Map<String, UpdateCheck> sessionChecks = const {},
    ValueChanged<ModPageTab>? onOpenPage,
  }) async {
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topRight,
        child: ModDetailsPanel(
          mod: target,
          onClose: () {},
          onOpenPage: onOpenPage ?? (_) {},
          onToggle: () {},
          onFavoriteToggle: () {},
          onEdit: () {},
          onOpenFolder: () {},
          onCheckForUpdate: () {},
          onResolveOrigin: () {},
          onDelete: (_) async {},
          noteWriter: (_, _) async => true,
        ),
      ),
      overrides: [
        // Held in memory: the panel's size row reads the library, and a real scan would reach ApiService.
        libraryOf([target]),
        modUpdateRecordsProvider.overrideWith((ref) => sessionRecords),
        modUpdateChecksProvider.overrideWith((ref) => sessionChecks),
      ],
      // Tall enough that the panel's list builds every section.
      surfaceSize: const Size(1200, 2400),
    );
    expectBuilt(ModDetailsPanel);
  }

  group('Made of N mods', () {
    testWidgets('lists the stack base first, each with its role', (tester) async {
      await open(
        tester,
        mod(origin: origin(patches: [patch])),
        sessionRecords: const {
          605460: GbMod(idRow: 605460, name: 'Pulchra Bottom Heavy - Reworked'),
        },
      );

      expect(find.text('MADE OF 2 MODS'), findsOneWidget);
      expect(find.text('base first, patches on top'), findsOneWidget);
      // Nothing has fetched the base's page and nothing saved its name, so it is named by its id.
      final base = find.text('GameBanana mod #585282');
      expect(base, findsOneWidget);
      final top = find.text('Pulchra Bottom Heavy - Reworked');
      expect(top, findsOneWidget);
      expect(tester.getTopLeft(base).dy, lessThan(tester.getTopLeft(top).dy));
      expect(tester.getTopLeft(find.text('Base')).dy, lessThan(tester.getTopLeft(find.text('Patch')).dy));
    });

    testWidgets("names each row's file, author and upload date once a check has its page", (tester) async {
      await open(
        tester,
        mod(origin: origin(patches: [patch])),
        sessionRecords: {
          585282: GbMod(
            idRow: 585282,
            name: 'Pulchra Bottom Heavy',
            submitter: const GbSubmitter(idRow: 1, name: 'frostbyte'),
            files: [GbFile(idRow: 1433843, file: 'pulchra.zip', dateAdded: DateTime.utc(2025, 3, 1, 12))],
          ),
          605460: GbMod(
            idRow: 605460,
            name: 'Pulchra Bottom Heavy - Reworked',
            submitter: const GbSubmitter(idRow: 2, name: 'patcher'),
            files: [GbFile(idRow: 1473174, file: 'reworked.zip', dateAdded: DateTime.utc(2025, 4, 2, 12))],
          ),
        },
      );

      expect(find.text('Pulchra Bottom Heavy'), findsWidgets);
      expect(find.text('reworked.zip'), findsOneWidget);
      expect(find.text('frostbyte · uploaded 2025-03-01'), findsOneWidget);
      expect(find.text('patcher · uploaded 2025-04-02'), findsOneWidget);
    });

    testWidgets('names a file that was only worked out, and its date, like a confirmed one', (tester) async {
      final guessed = patchFixture(
        modId: 605460,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1473174,
        versionConfidence: OriginConfidence.inferred,
      );
      await open(
        tester,
        mod(origin: origin(patches: [guessed])),
        sessionRecords: {
          605460: GbMod(
            idRow: 605460,
            name: 'Pulchra Bottom Heavy - Reworked',
            submitter: const GbSubmitter(idRow: 2, name: 'patcher'),
            files: [GbFile(idRow: 1473174, file: 'reworked.zip', dateAdded: DateTime.utc(2025, 4, 2, 12))],
          ),
        },
      );

      expect(find.text('reworked.zip'), findsOneWidget);
      expect(find.text('patcher · uploaded 2025-04-02'), findsOneWidget);
    });

    testWidgets('leaves out the file and its date for a patch marked as current', (tester) async {
      // Marking as current records a date and no file.
      final dated = patchFixture(
        modId: 605460,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1473174,
        versionConfidence: OriginConfidence.assumedLatest,
      );
      await open(
        tester,
        mod(origin: origin(patches: [dated])),
        sessionRecords: {
          605460: GbMod(
            idRow: 605460,
            name: 'Pulchra Bottom Heavy - Reworked',
            submitter: const GbSubmitter(idRow: 2, name: 'patcher'),
            files: [GbFile(idRow: 1473174, file: 'reworked.zip', dateAdded: DateTime.utc(2025, 4, 2, 12))],
          ),
        },
      );

      expect(find.text('reworked.zip'), findsNothing);
      expect(find.text('patcher'), findsOneWidget, reason: 'the author is the page\'s, not the file\'s');
    });

    testWidgets('with no name in hand a patch is named by its id, and links to its page', (tester) async {
      // **And spends no request to find one.** A read-only view opened on a mod should not reach the network for a
      // label, so an unnamed download shows its id, which is why every row with a page links to it.
      await open(tester, mod(origin: origin(patches: [patch])));

      expect(find.text('GameBanana mod #605460'), findsOneWidget);
      expect(find.byTooltip("Open this mod's page"), findsNWidgets(2));
    });

    testWidgets("a folder named after its patch never puts the patch's name on the base", (tester) async {
      // A patch installed as its own folder, with the mod it patches fetched in: the folder is named after the
      // patch's archive. The names saved at install are what the rows show, with no page in hand.
      final stacked = origin(patches: [patch]);
      await open(
        tester,
        ModInfo(
          id: 'zhuyuan_blacksuit_culture_edit_52313',
          name: 'zhuyuan_blacksuit_culture_edit_52313',
          characterId: 'zhuyuan',
          isActive: false,
          origin: stacked.copyWith(downloads: [
            stacked.downloads[0].copyWith(name: 'Zhu-Yuan Black-Suit'),
            stacked.downloads[1].copyWith(name: 'Zhu Yuan - Black-Suit edit'),
          ]),
        ),
      );

      expect(find.text('Zhu-Yuan Black-Suit'), findsOneWidget);
      expect(find.text('Zhu Yuan - Black-Suit edit'), findsOneWidget);
      expect(find.text('zhuyuan_blacksuit_culture_edit_52313'), findsOneWidget, reason: 'the panel title only');
    });

    testWidgets('a page in hand wins over a saved name, which may be stale', (tester) async {
      final stacked = origin(patches: [patch]);
      await open(
        tester,
        mod(
          origin: stacked.copyWith(downloads: [stacked.downloads[0], stacked.downloads[1].copyWith(name: 'Old title')]),
        ),
        sessionRecords: const {605460: GbMod(idRow: 605460, name: 'New title')},
      );

      expect(find.text('New title'), findsOneWidget);
      expect(find.text('Old title'), findsNothing);
    });

    testWidgets('a patch from a local file is said to be one', (tester) async {
      await open(tester, mod(origin: origin(patches: [patchFixture(modId: null)])));

      expect(find.text('Patch from a local file'), findsOneWidget);
      expect(find.byTooltip("Open this mod's page"), findsOneWidget, reason: 'only the base has a page');
    });

    testWidgets('Manage in History opens the History tab of the mod\'s page', (tester) async {
      ModPageTab? opened;
      await open(tester, mod(origin: origin(patches: [patch])), onOpenPage: (tab) => opened = tab);

      await tester.tap(find.text('Manage in History'));
      expect(opened, ModPageTab.history);
    });

    testWidgets('Manage in History is offered for a stack with no page of its own', (tester) async {
      await open(tester, mod(origin: originFixture(source: null, patches: [patchFixture(modId: null)])));

      expect(find.text('Manage in History'), findsOneWidget);
    });

    testWidgets('an ordinary mod has no list', (tester) async {
      await open(tester, mod(origin: origin()));

      expect(find.textContaining('MADE OF'), findsNothing);
      expect(find.text('Manage in History'), findsNothing);
    });
  });

  group("the Uploaded line's verdict is the base mod's own", () {
    // The line describes the base mod's file. The folder's verdict is the fold of every layer, and with a patch on
    // top it can be the patch's.
    final stacked = origin(patches: [patch]);
    final baseRecord = GbMod(
      idRow: 585282,
      name: 'Pulchra Bottom Heavy',
      files: [GbFile(idRow: 1433843, file: 'pulchra.zip', dateAdded: DateTime.utc(2025, 3, 1))],
    );

    /// The folder's verdict as the check builds it: one judgement per layer, folded.
    UpdateCheck folded({required UpdateOutcome base, required UpdateOutcome patch}) => foldDownloads([
      DownloadCheck(download: stacked.downloads[0], key: stacked.keyAt(0), check: UpdateCheck(outcome: base)),
      DownloadCheck(download: stacked.downloads[1], key: stacked.keyAt(1), check: UpdateCheck(outcome: patch)),
    ]);

    testWidgets("a newer patch is not the base mod's newer file", (tester) async {
      final check = folded(base: UpdateOutcome.upToDate, patch: UpdateOutcome.updateAvailable);
      expect(check.outcome, UpdateOutcome.updateAvailable, reason: "the folder's verdict is the patch's");

      await open(
        tester,
        mod(origin: stacked),
        sessionRecords: {585282: baseRecord},
        sessionChecks: {'Pulchra-BottomHeavy': check},
      );

      expect(find.textContaining('nothing newer'), findsOneWidget);
      expect(find.textContaining('a newer file is out'), findsNothing);
    });

    testWidgets("a newer base file is said, whatever the patch's verdict", (tester) async {
      await open(
        tester,
        mod(origin: stacked),
        sessionRecords: {585282: baseRecord},
        sessionChecks: {'Pulchra-BottomHeavy': folded(base: UpdateOutcome.updateAvailable, patch: UpdateOutcome.upToDate)},
      );

      expect(find.textContaining('a newer file is out'), findsOneWidget);
      expect(find.textContaining('nothing newer'), findsNothing);
    });

    testWidgets('a one-download mod reads its own verdict', (tester) async {
      final single = origin();
      await open(
        tester,
        mod(origin: single),
        sessionRecords: {585282: baseRecord},
        sessionChecks: {
          'Pulchra-BottomHeavy': foldDownloads([
            DownloadCheck(
              download: single.downloads.single,
              key: single.keyAt(0),
              check: const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
            ),
          ]),
        },
      );

      expect(find.textContaining('a newer file is out'), findsOneWidget);
    });
  });

  group('the File and Uploaded lines', () {
    final page = GbMod(
      idRow: 585282,
      name: 'Pulchra Bottom Heavy',
      files: [GbFile(idRow: 1433843, file: 'pulchra.zip', dateAdded: DateTime.utc(2025, 3, 1))],
    );

    ModInfo recordedAt(OriginConfidence versionConfidence) => mod(
          origin: originFixture(
            source: 'gamebanana',
            modId: 585282,
            modIdConfidence: OriginConfidence.exact,
            fileId: 1433843,
            versionLabel: 'Bunny',
            versionConfidence: versionConfidence,
            provenance: OriginProvenance.downloaded,
          ),
        );

    testWidgets('state a confirmed file', (tester) async {
      await open(tester, recordedAt(OriginConfidence.exact), sessionRecords: {585282: page});

      expect(find.text('File'), findsOneWidget);
      expect(find.text('pulchra.zip'), findsOneWidget);
      expect(find.text('Variant'), findsOneWidget);
      expect(find.text('Bunny'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
    });

    testWidgets('state a file that was only worked out, like a confirmed one', (tester) async {
      await open(tester, recordedAt(OriginConfidence.inferred), sessionRecords: {585282: page});

      expect(find.text('File'), findsOneWidget);
      expect(find.text('pulchra.zip'), findsOneWidget);
      expect(find.text('Variant'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
    });

    testWidgets('leave out the file of a mod marked as current, its variant included', (tester) async {
      // Marking as current records a date and no file.
      await open(tester, recordedAt(OriginConfidence.assumedLatest), sessionRecords: {585282: page});

      expect(find.text('File'), findsNothing);
      expect(find.text('pulchra.zip'), findsNothing);
      expect(find.text('Variant'), findsNothing);
      expect(find.text('Uploaded'), findsNothing);
    });
  });

  testWidgets('a mod with no origin block at all is unaffected',
      (tester) async {
    await open(tester, mod());

    expect(find.text('This folder holds two downloads'), findsNothing);
  });
}
