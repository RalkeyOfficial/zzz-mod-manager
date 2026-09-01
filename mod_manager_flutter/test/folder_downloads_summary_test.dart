import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/folder_downloads_summary.dart';
import 'package:mod_manager_flutter/services/folder_downloads.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// The section that says **what this folder holds**.
///
/// Role derivation and ordering are `folder_downloads_test.dart`; this covers
/// what the rows say. The thing worth pinning hardest is that no row is
/// privileged: a mod and a patch in one folder are the same shape whichever of
/// them the sidecar happens to store in `origin`'s own fields.
void main() {
  ModCompanion companion({
    CompanionRole role = CompanionRole.patch,
    int modId = 605460,
    int? fileId = 1473174,
    String? version,
    String? versionLabel,
    OriginConfidence versionConfidence = OriginConfidence.exact,
    bool remoteMissing = false,
  }) =>
      ModCompanion(
        role: role,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        remoteMissing: remoteMissing,
      );

  ModOrigin origin({
    int? modId = 585282,
    List<ModCompanion> companions = const [],
  }) =>
      ModOrigin(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1433843,
        versionConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
        companions: companions,
      );

  Future<void> pump(
    WidgetTester tester,
    ModOrigin? block, {
    String folderName = 'Pulchra-BottomHeavy(NSFW)',
    Map<int, String> knownNames = const {},
    Map<int, String> notes = const {},
    Map<int, GbMod> sessionRecords = const {},
    Set<int> editableModIds = const {},
    void Function(FolderDownload)? onEdit,
  }) =>
      pumpLocalized(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: FolderDownloadsSummary(
              origin: block,
              folderName: folderName,
              knownNames: knownNames,
              notes: notes,
              editableModIds: editableModIds,
              onEdit: onEdit,
            ),
          ),
        ),
        overrides: [
          modUpdateRecordsProvider.overrideWith((ref) => sessionRecords),
        ],
      );

  testWidgets('a folder with one download says nothing at all', (tester) async {
    // A one-row list is a heading and a restatement of the mod you are already
    // looking at. Saying "nothing else here" would be worse: a claim about a
    // scan this never performs.
    await pump(tester, origin());

    expect(find.text('This folder holds two downloads'), findsNothing);
  });

  testWidgets('no origin block at all is also silent', (tester) async {
    await pump(tester, null);

    expect(find.text('This folder holds two downloads'), findsNothing);
  });

  testWidgets('both downloads get a row, each labelled with its role',
      (tester) async {
    await pump(
      tester,
      origin(companions: [companion()]),
      knownNames: const {
        585282: 'Pulchra - Bottom Heavy',
        605460: 'Pulchra Bottom Heavy - Reworked',
      },
    );

    expect(find.text('This folder holds two downloads'), findsOneWidget);
    expect(find.text('Pulchra - Bottom Heavy'), findsOneWidget);
    expect(find.text('Pulchra Bottom Heavy - Reworked'), findsOneWidget);
    expect(find.text('Mod'), findsOneWidget);
    expect(find.text('Patch'), findsOneWidget);
  });

  testWidgets('the same pair reads the same when the patch is the primary',
      (tester) async {
    // **The asymmetry this design exists to remove.** Same two mods, sidecar
    // mirrored because they were installed in the other order — and the section
    // must be indistinguishable.
    await pump(
      tester,
      origin(
        modId: 605460,
        companions: [companion(role: CompanionRole.base, modId: 585282)],
      ),
      knownNames: const {
        585282: 'Pulchra - Bottom Heavy',
        605460: 'Pulchra Bottom Heavy - Reworked',
      },
    );

    expect(find.text('Pulchra - Bottom Heavy'), findsOneWidget);
    expect(find.text('Pulchra Bottom Heavy - Reworked'), findsOneWidget);
    expect(find.text('Mod'), findsOneWidget);
    expect(find.text('Patch'), findsOneWidget);
  });

  testWidgets('the folder\'s own row falls back to the folder name',
      (tester) async {
    // Better than an id and better than a spinner: it is the name the user
    // knows this thing by everywhere else in the app. Only the folder's own
    // entry has one to fall back to.
    await pump(tester, origin(companions: [companion()]));

    expect(find.text('Pulchra-BottomHeavy(NSFW)'), findsOneWidget);
    expect(find.text('GameBanana mod #605460'), findsOneWidget);
  });

  testWidgets('a name fetched earlier this session is used', (tester) async {
    await pump(
      tester,
      origin(companions: [companion()]),
      sessionRecords: const {
        605460: GbMod(idRow: 605460, name: 'Pulchra Bottom Heavy - Reworked'),
      },
    );

    expect(find.text('Pulchra Bottom Heavy - Reworked'), findsOneWidget);
  });

  testWidgets('a recorded file with no version string says nothing about it',
      (tester) async {
    // "the file you chose" names no file, and for a patch the app downloaded
    // itself it is not even true. `_sVersion` is routinely null upstream, so
    // this is the common case rather than a corner.
    await pump(tester, origin(companions: [companion()]));

    expect(find.textContaining('you chose'), findsNothing);
    expect(find.textContaining('you downloaded'), findsNothing);
  });

  testWidgets('a version string on record is named', (tester) async {
    await pump(
      tester,
      origin(companions: [companion(version: '1.02', versionLabel: 'Reworked')]),
    );

    expect(find.text('1.02 · Reworked'), findsOneWidget);
  });

  testWidgets('a download with no file recorded says so', (tester) async {
    await pump(
      tester,
      origin(
        companions: [
          companion(fileId: null, versionConfidence: OriginConfidence.unknown),
        ],
      ),
    );

    expect(find.text('No version recorded yet.'), findsOneWidget);
  });

  testWidgets('a page that has gone says that on its own row', (tester) async {
    await pump(tester, origin(companions: [companion(remoteMissing: true)]));

    expect(find.text('Its mod page is no longer available.'), findsOneWidget);
  });

  testWidgets('every row links to its page', (tester) async {
    await pump(tester, origin(companions: [companion()]));

    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));
  });

  testWidgets('a note lands under the download it belongs to', (tester) async {
    await pump(
      tester,
      origin(companions: [companion()]),
      notes: const {
        585282: 'Updates: This is the latest file',
        605460: 'Updates: An update is available',
      },
    );

    expect(find.text('Updates: This is the latest file'), findsOneWidget);
    expect(find.text('Updates: An update is available'), findsOneWidget);
  });

  testWidgets('only a row named as editable offers to change', (tester) async {
    // A button on a row nothing can change would do nothing when pressed, so
    // the caller names the rows rather than the widget guessing.
    FolderDownload? edited;
    await pump(
      tester,
      origin(
        modId: 605460,
        companions: [companion(role: CompanionRole.base, modId: 585282)],
      ),
      editableModIds: const {585282},
      onEdit: (download) => edited = download,
    );

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    expect(edited?.modId, 585282);
    expect(edited?.role, FolderDownloadRole.mod);
  });

  testWidgets('no edit affordance when nothing is editable', (tester) async {
    await pump(tester, origin(companions: [companion()]));

    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });
}
