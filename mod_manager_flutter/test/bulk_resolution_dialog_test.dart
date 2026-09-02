import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/bulk_resolution_dialog.dart';
import 'package:mod_manager_flutter/services/bulk_resolution.dart';

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The bulk results/resolution screen.
///
/// What is worth pinning is not the layout but the promises it makes about
/// writing: an identity is never confirmed for you, a safe inference is offered
/// pre-ticked, cancelling writes nothing, and the tier each answer records is
/// the tier it is entitled to.
void main() {
  final installedAt = DateTime.utc(2026, 5, 8);

  ModOrigin origin({
    int modId = 1,
    OriginConfidence modIdConfidence = OriginConfidence.inferred,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    bool remoteMissing = false,
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: modIdConfidence,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        installedAt: installedAt,
        remoteMissing: remoteMissing,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  GbMod remote({
    int modId = 1,
    String name = 'Ellen Swimsuit',
    List<GbFile>? files,
    bool trashed = false,
  }) =>
      GbMod(
        idRow: modId,
        name: name,
        files: files,
        isTrashed: trashed,
      );

  GbFile file(int id, {String? label, DateTime? added}) => GbFile(
        idRow: id,
        file: 'file$id.zip',
        description: label,
        dateAdded: added ?? DateTime.utc(2026),
      );

  /// Mounts a button that opens the screen, and hands back what was written.
  Future<({List<String> mods, Map<String, ModOrigin?> results})> runFlow(
    WidgetTester tester,
    BulkResolutionPlan plan, {
    Map<String, ModOrigin?> onDisk = const {},
    Set<String> failFor = const {},
    Size surfaceSize = const Size(1200, 800),
  }) async {
    final written = <String>[];
    final results = <String, ModOrigin?>{};

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showBulkResolutionDialog(
            context,
            plan,
            writer: (name, update) async {
              if (failFor.contains(name)) return false;
              // Mirrors `updateOrigin`: the transform sees the block as it is
              // **on disk**, which `onDisk` can make differ from the one the
              // plan was built from.
              final current = onDisk.containsKey(name)
                  ? onDisk[name]
                  : plan.rows.firstWhere((r) => r.mod.id == name).mod.origin;
              final next = update(current);
              if (next == null) return false;
              written.add(name);
              results[name] = next;
              return true;
            },
          ),
          child: const Text('run'),
        ),
      ),
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    return (mods: written, results: results);
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save 1 mod'));
    await tester.pumpAndSettle();
  }

  testWidgets('every question arrives under a heading that explains it',
      (tester) async {
    // The first version was an undifferentiated list of bordered boxes: a row
    // asking "is this the right mod?" looked exactly like one asking "which
    // file?", and nothing on screen said what the screen was for. Reported as
    // taking minutes to work out. The structure is the fix, so it is pinned.
    final plan = planBulkResolution(
      mods: [
        mod('unconfirmed', origin: origin(modId: 1)),
        mod('needs a file',
            origin: origin(modId: 2, modIdConfidence: OriginConfidence.user)),
        mod('vanished',
            origin: origin(modId: 3, modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [file(900)]),
        2: remote(modId: 2, files: [file(901), file(902)]),
        3: remote(modId: 3, trashed: true),
      },
    );
    await runFlow(tester, plan, surfaceSize: const Size(1100, 900));

    // What the screen is for, before any of the questions.
    expect(find.textContaining('Nothing is saved until you press Save'),
        findsOneWidget);
    // One heading per kind of question, each carrying its own count and its own
    // reason for existing.
    expect(find.text('Is this the right mod page? (1)'), findsOneWidget);
    expect(find.text('Which file do you have? (1)'), findsOneWidget);
    expect(find.text('No longer on GameBanana (1)'), findsOneWidget);
    expect(find.textContaining('an update is only ever offered once you have'),
        findsOneWidget);
  });

  testWidgets('a page that came back, on a mod nobody confirmed, is listed once',
      (tester) async {
    // The overlap that got through: `back` did not exclude `needsIdentity`, so
    // this mod appeared under two headings with the same two checkboxes. State
    // is shared, so nothing was written twice — but "Save 1 mod" under two
    // visible rows reads as a bug. Ordinary rather than exotic: writing
    // `remote_missing` never touches `mod_id_confidence`, so a withheld page
    // that comes back lands here with its identity still `inferred`.
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(
              modIdConfidence: OriginConfidence.inferred,
              versionConfidence: OriginConfidence.user,
              remoteMissing: true,
            )),
      ],
      records: {1: remote()},
    );
    await runFlow(tester, plan);

    expect(find.text('Ellen'), findsOneWidget);
    expect(find.text('Yes, this is the right mod page'), findsOneWidget);
    expect(find.text('Clear the mark on this mod'), findsOneWidget);
    // Filed under the heavier question, and only there.
    expect(find.text('Is this the right mod page? (1)'), findsOneWidget);
    expect(find.textContaining('Available again'), findsNothing);
  });

  testWidgets('a mod asking two questions is listed once, not twice',
      (tester) async {
    // The alternative grouping — a section per question, a mod in both — reads
    // better on paper and is worse in practice: on a legacy library nearly
    // every row asks both, so every name would appear twice.
    final plan = planBulkResolution(
      mods: [mod('Ellen', origin: origin(modId: 1))],
      records: {
        1: remote(files: [file(900), file(901)]),
      },
    );
    await runFlow(tester, plan);

    expect(find.text('Ellen'), findsOneWidget);
    expect(find.text('Is this the right mod page? (1)'), findsOneWidget);
    expect(find.textContaining('Which file do you have?'), findsNothing);
    // Both questions are still asked, in the one row.
    expect(find.text('Yes, this is the right mod page'), findsOneWidget);
    expect(find.text('Pick the file you installed…'), findsOneWidget);
  });

  testWidgets('an identity is never confirmed for you', (tester) async {
    // The one thing only the user can settle: `mod_id` came from a free-form
    // url somebody pasted. Pre-ticking it turns the glance test into a rubber
    // stamp, which is the failure "bulk acts only on precise handles" exists to
    // prevent.
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(versionConfidence: OriginConfidence.user)),
      ],
      records: {1: remote()},
    );
    final run = await runFlow(tester, plan);

    expect(find.text('Yes, this is the right mod page'), findsOneWidget);
    // Nothing ticked, so there is nothing to apply.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.text('Yes, this is the right mod page'));
    await tester.pumpAndSettle();
    await apply(tester);

    expect(run.mods, ['Ellen']);
    expect(run.results['Ellen']!.modIdConfidence, OriginConfidence.user);
  });

  testWidgets('saving without confirming leaves the identity a guess',
      (tester) async {
    // The row that asks both questions, with only the pre-ticked file answer
    // left on. Saving records the file — the box was visibly ticked — and must
    // not quietly upgrade the mod page nobody confirmed.
    final plan = planBulkResolution(
      mods: [mod('Ellen', origin: origin())],
      records: {
        1: remote(files: [file(900)]),
      },
    );
    final run = await runFlow(tester, plan);

    expect(find.text('Yes, this is the right mod page'), findsOneWidget);
    await apply(tester);

    final written = run.results['Ellen']!;
    expect(written.fileId, 900);
    expect(written.versionConfidence, OriginConfidence.inferred);
    expect(written.modIdConfidence, OriginConfidence.inferred);
  });

  testWidgets('a row with nothing ticked is not saved at all', (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('untouched', origin: origin()),
        mod('ticked',
            origin: origin(modId: 2, modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(),
        2: remote(modId: 2, files: [file(900)]),
      },
    );
    final run = await runFlow(tester, plan);

    // Only the second mod has a pre-ticked answer, so only it is counted.
    await apply(tester);
    expect(run.mods, ['ticked']);
  });

  testWidgets('a single-file inference arrives pre-ticked, at inferred',
      (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [file(900, label: 'Main file')]),
      },
    );
    final run = await runFlow(tester, plan);

    expect(find.textContaining('You have file900.zip'), findsOneWidget);
    await apply(tester);

    final written = run.results['Ellen']!;
    expect(written.fileId, 900);
    expect(written.versionLabel, 'Main file');
    // The user consented to a plan; they did not look at a file list and
    // recognise their download. `inferred` is what that is worth.
    expect(written.versionConfidence, OriginConfidence.inferred);
  });

  testWidgets('an ambiguous mod gets a picker with nothing chosen',
      (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('Ellen', origin: origin(modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [
          file(900, label: 'SFW', added: DateTime.utc(2026, 1)),
          file(901, label: 'NSFW', added: DateTime.utc(2026, 2)),
        ]),
      },
    );
    final run = await runFlow(tester, plan);

    // The question is the section heading; the control under it is a picker
    // with nothing chosen.
    expect(find.text('Which file do you have? (1)'), findsOneWidget);
    expect(find.text('Pick the file you installed…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'a guess must not be preselected',
    );

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('file901.zip').last);
    await tester.pumpAndSettle();
    await apply(tester);

    // Reading the list and choosing a row is exactly what `user` means.
    expect(run.results['Ellen']!.fileId, 901);
    expect(run.results['Ellen']!.versionConfidence, OriginConfidence.user);
  });

  testWidgets('a gone page is offered pre-ticked and writes the flag',
      (tester) async {
    final plan = planBulkResolution(
      mods: [mod('Ellen', origin: origin())],
      records: {1: remote(trashed: true)},
    );
    final run = await runFlow(tester, plan);

    expect(find.text('Record that this page is gone'), findsOneWidget);
    await apply(tester);
    expect(run.results['Ellen']!.remoteMissing, isTrue);
  });

  testWidgets('cancelling writes nothing', (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [file(900)]),
      },
    );
    final run = await runFlow(tester, plan);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(run.mods, isEmpty);
  });

  testWidgets('a mod resolved while the screen was open is a skip, not a failure',
      (tester) async {
    // `updateOrigin` answers one bare `false` for "unwritable" and "the
    // transform declined". Reporting the guard doing its job as a filesystem
    // permission error is the conflation this outcome split exists to avoid.
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [file(900)]),
      },
    );
    final run = await runFlow(
      tester,
      plan,
      onDisk: {
        'Ellen': origin(
          modIdConfidence: OriginConfidence.exact,
          versionConfidence: OriginConfidence.exact,
        ),
      },
    );
    await apply(tester);

    expect(run.mods, isEmpty);
    expect(find.textContaining('already sorted out'), findsOneWidget);
    expect(find.textContaining('read-only'), findsNothing);
  });

  testWidgets('an unwritable folder is reported as one', (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('Ellen',
            origin: origin(modIdConfidence: OriginConfidence.user)),
      ],
      records: {
        1: remote(files: [file(900)]),
      },
    );
    await runFlow(tester, plan, failFor: {'Ellen'});
    await apply(tester);
    expect(find.textContaining('read-only'), findsOneWidget);
  });

  testWidgets('it names the mods it is not acting on', (tester) async {
    final plan = planBulkResolution(
      mods: [
        mod('Ellen', origin: origin()),
        mod('handmade'),
        mod('done',
            origin: origin(
              modIdConfidence: OriginConfidence.user,
              versionConfidence: OriginConfidence.exact,
            )),
      ],
      records: {1: remote()},
    );
    await runFlow(tester, plan);

    expect(find.textContaining("1 mod isn't linked to a GameBanana page"),
        findsOneWidget);
    // Worded to cover both reasons a mod is absent: it counts mods the user
    // declared their own as well as ones already resolved.
    expect(find.textContaining("1 mod isn't listed"), findsOneWidget);
  });

  testWidgets('it fits the smallest window without overflowing',
      (tester) async {
    // The mods toolbar has overflowed twice at the narrow end, and this dialog
    // stacks a summary, a scrolling list and two footers.
    final plan = planBulkResolution(
      mods: [
        for (var i = 0; i < 12; i++)
          mod('A mod with a fairly long folder name $i',
              origin: origin(modId: i)),
      ],
      records: {
        for (var i = 0; i < 12; i++)
          i: remote(
            modId: i,
            name: 'An equally long remote mod page name $i',
            files: [file(900 + i), file(1000 + i)],
          ),
      },
    );
    await runFlow(tester, plan, surfaceSize: const Size(480, 600));
    expectBuilt(BulkResolutionDialog);
    expect(find.textContaining('Save '), findsOneWidget);
  });
}
