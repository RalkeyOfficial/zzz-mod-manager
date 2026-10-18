import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
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
  }) async {
    await pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topRight,
        child: ModDetailsPanel(
          mod: target,
          onClose: () {},
          onToggle: () {},
          onFavoriteToggle: () {},
          onEdit: () {},
          onOpenFolder: () {},
          onCheckForUpdate: () {},
          onResolveOrigin: () {},
          onDelete: () {},
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

  testWidgets('both downloads are listed, each with its role', (tester) async {
    await open(
      tester,
      mod(origin: origin(patches: [patch])),
      sessionRecords: const {
        605460: GbMod(idRow: 605460, name: 'Pulchra Bottom Heavy - Reworked'),
      },
    );

    expect(find.text('This folder holds two downloads'), findsOneWidget);
    // The folder's own download, named by the folder — nothing here has fetched
    // its page, and the folder name is what the user knows it by anyway.
    expect(find.text('Pulchra-BottomHeavy'), findsWidgets);
    expect(find.text('Pulchra Bottom Heavy - Reworked'), findsOneWidget);
    expect(find.text('Mod'), findsOneWidget);
    expect(find.text('Patch'), findsOneWidget);
  });

  testWidgets('this is the surface that explains why a folder holds two',
      (tester) async {
    // The one caller that shows the hint: the details view's job is answering
    // "what is this", and its column has the room. The action dialogs are at
    // their height budget and a sentence there competes with their controls.
    await open(tester, mod(origin: origin(patches: [patch])));

    expect(find.textContaining('A patch replaces some of a mod\'s files'),
        findsOneWidget);
  });

  testWidgets('with no name in hand it still lists the download',
      (tester) async {
    // **And spends no request to find one.** A read-only view opened on a mod
    // should not reach the network for a label, so an unnamed download shows
    // its id — which is why every row also carries a link to its page.
    await open(tester, mod(origin: origin(patches: [patch])));

    expect(find.text('GameBanana mod #605460'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsWidgets);
  });

  testWidgets('an ordinary mod says nothing about a second download',
      (tester) async {
    await open(tester, mod(origin: origin()));

    expect(find.text('This folder holds two downloads'), findsNothing);
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
      DownloadCheck(download: stacked.downloads[0], check: UpdateCheck(outcome: base)),
      DownloadCheck(download: stacked.downloads[1], check: UpdateCheck(outcome: patch)),
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
            DownloadCheck(download: single.downloads.single, check: const UpdateCheck(outcome: UpdateOutcome.updateAvailable)),
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

    testWidgets('leave out a file that was only worked out, its variant included', (tester) async {
      // The card says "Guessed file"; stating it here as the file would contradict it.
      await open(tester, recordedAt(OriginConfidence.inferred), sessionRecords: {585282: page});

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
