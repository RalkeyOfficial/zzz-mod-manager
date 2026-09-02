import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_details_dialog.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The details view saying **what this folder holds**.
///
/// This is the screen whose job is answering "what is this mod", and a folder
/// holding a patch as well as the mod it patches looked exactly like any other
/// here — so the app's own record of the second download was invisible on the
/// one surface a reader would go to for it.
///
/// The rest of this dialog is not covered: it reads local images off disk and
/// edits a description through `ApiService`, which builds a `ConfigService`
/// against the developer's real `config.json`. Only the companion section is
/// exercised, and only with an origin block that reaches no service at all.
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
  }) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showModDetailsDialog(
            context,
            target,
            onEdit: () {},
            onChanged: () {},
          ),
          child: const Text('open'),
        ),
      ),
      overrides: [
        modUpdateRecordsProvider.overrideWith((ref) => sessionRecords),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('both downloads are listed, each with its role', (tester) async {
    await open(
      tester,
      mod(origin: origin(patches: [patch])),
      sessionRecords: const {
        605460: GbMod(idRow: 605460, name: 'Pulchra Bottom Heavy - Reworked'),
      },
    );
    expectBuilt(AlertDialog);

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

  testWidgets('a mod with no origin block at all is unaffected',
      (tester) async {
    await open(tester, mod());

    expect(find.text('This folder holds two downloads'), findsNothing);
  });
}
