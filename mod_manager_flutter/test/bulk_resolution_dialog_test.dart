import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/screens/dialogs/bulk_resolution_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/resolve_origin_dialog.dart';
import 'package:mod_manager_flutter/services/bulk_resolution.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The per-mod dialog's local side, keeping each mod's origin "on disk" in [onDisk] and touching no library.
class _FakeGateway implements ResolveOriginGateway {
  _FakeGateway([Map<String, ModOrigin?>? onDisk]) : onDisk = onDisk ?? {};

  final Map<String, ModOrigin?> onDisk;
  int writes = 0;

  /// What the bulk screen's reader sees: the same blocks this gateway writes.
  Future<ModOrigin?> read(String modId) async => onDisk[modId];

  @override
  Future<DateTime?> installDateProxy(String modId) async => null;

  @override
  Future<OriginWriteResult> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) async {
    writes++;
    final next = update(onDisk[modId]);
    if (next == null) return OriginWriteResult.declined;
    onDisk[modId] = next;
    return OriginWriteResult.written;
  }

  @override
  Future<void> fillMetadata(String modId, RemoteModMetadata remote) async {}
}

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
    ResolveOriginOpener? resolveOrigin,
    List<Override> overrides = const [],

    /// For a test that reads provider state afterwards; replaces [overrides].
    ProviderContainer? container,

    /// What a Resolve press reads as saved; by default the block each untracked mod arrived with.
    OriginReader? readOrigin,

    /// Collects what the screen answers its caller when it closes.
    List<bool>? returned,
  }) async {
    final written = <String>[];
    final results = <String, ModOrigin?>{};

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final wrote = await showBulkResolutionDialog(
              context,
              plan,
              resolveOrigin: resolveOrigin ?? showResolveOriginDialogForResult,
              reader: readOrigin ??
                  (name) async =>
                      plan.untracked.firstWhere((m) => m.id == name).origin,
              writer: (name, update) async {
                if (failFor.contains(name)) {
                  return OriginWriteResult.writeFailed;
                }
                // Mirrors `updateOrigin`:
                // the transform sees the block as it is **on disk**, which `onDisk` can make differ from the one the plan was built from.
                final current = onDisk.containsKey(name)
                    ? onDisk[name]
                    : plan.rows.firstWhere((r) => r.mod.id == name).mod.origin;
                final next = update(current);
                if (next == null) return OriginWriteResult.declined;
                written.add(name);
                results[name] = next;
                return OriginWriteResult.written;
              },
            );
            returned?.add(wrote);
          },
          child: const Text('run'),
        ),
      ),
      surfaceSize: surfaceSize,
      overrides: container == null ? overrides : null,
      container: container,
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
    expect(
        find.textContaining(
            'Nothing you tick here is saved until you press Save'),
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
    // The guard doing its job must never be reported as a filesystem permission error.
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

  testWidgets(
      'Apply clears the verdict of each mod it writes, unless it found an update',
      (tester) async {
    // The update dialog skips its check while a verdict is stored, so a written mod must not keep one about its old block.
    // A found update stays: this screen never rebinds a folder, so that verdict is still about the right page.
    ModInfo ticked(String name, int modId) => mod(name,
        origin: origin(modId: modId, modIdConfidence: OriginConfidence.user));
    final plan = planBulkResolution(
      mods: [
        ticked('written', 1),
        ticked('update', 2),
        ticked('dismissed', 3),
        ticked('declined', 4),
        ticked('failed', 5),
        mod('unticked', origin: origin(modId: 6)),
      ],
      records: {
        for (var id = 1; id <= 5; id++)
          id: remote(modId: id, files: [file(900 + id)]),
        6: remote(modId: 6),
      },
    );
    const unknown = UpdateCheck(outcome: UpdateOutcome.versionUnknown);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = {
      'written': unknown,
      'update': const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated),
      'dismissed': const UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        dismissed: true,
      ),
      'declined': unknown,
      'failed': unknown,
      'unticked': unknown,
    };

    final run = await runFlow(
      tester,
      plan,
      container: container,
      failFor: {'failed'},
      // Resolved by something else while the screen was open, so its write is declined.
      onDisk: {
        'declined': origin(
          modId: 4,
          modIdConfidence: OriginConfidence.exact,
          versionConfidence: OriginConfidence.exact,
        ),
      },
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save 5 mods'));
    await tester.pumpAndSettle();

    expect(run.mods, unorderedEquals(['written', 'update', 'dismissed']));
    expect(
      container.read(modUpdateChecksProvider).keys,
      unorderedEquals(['update', 'dismissed', 'declined', 'failed', 'unticked']),
    );
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

  group('mods with no mod page', () {
    const resolveLabel = 'Resolve…';
    const resolvedLine =
        'Resolved and saved now — check again to see its updates.';
    const pageName = 'ZZMI RabbitFX - Glow FX + Censor Remover';

    /// One tracked row with a gone page, pre-ticked, so the screen opens and Apply reads "Save 1 mod" — plus the untracked mods named.
    BulkResolutionPlan withUntracked(List<String> names) => planBulkResolution(
          mods: [
            mod('vanished',
                origin: origin(modIdConfidence: OriginConfidence.user)),
            for (final name in names) mod(name),
          ],
          records: {1: remote(name: 'Gone page', trashed: true)},
        );

    /// The real per-mod dialog, over a scripted GameBanana and a recording gateway.
    ({
      ResolveOriginOpener open,
      List<Override> overrides,
      List<String> opened,
      _FakeGateway gateway,
    }) realDialog() {
      final gateway = _FakeGateway();
      final opened = <String>[];
      final transport = FakeHttpTransport()
        ..stub(
          Uri.parse(
            'https://gamebanana.com/apiv13/Util/Search/Results'
            '?_sModelName=Mod&_sSearchString=Ellen+Swimsuit&_idGameRow=19567&_nPage=1',
          ),
          body: loadGbFixture('search_ellen'),
        )
        ..stub(
          Uri.parse('https://gamebanana.com/apiv13/Mod/531649/ProfilePage'),
          body: loadGbFixture('mod_profile_531649'),
        )
        // For the patch-shaped folder: its name seeds the search for what it patches, and that mod's page.
        ..stub(
          Uri.parse(
            'https://gamebanana.com/apiv13/Util/Search/Results'
            '?_sModelName=Mod&_sSearchString=RabbitFX&_idGameRow=19567&_nPage=1',
          ),
          body: loadGbFixture('search_ellen'),
        )
        ..stub(
          Uri.parse('https://gamebanana.com/apiv13/Mod/527697/ProfilePage'),
          body: loadGbFixture('mod_profile_rated'),
        );
      return (
        open: (context, mod) {
          opened.add(mod.id);
          return showResolveOriginDialogForResult(context, mod,
              gateway: gateway);
        },
        overrides: [
          gameBananaClientProvider.overrideWithValue(
            GameBananaClient(transport: transport, maxRetries: 0),
          ),
        ],
        opened: opened,
        gateway: gateway,
      );
    }

    Future<void> expand(WidgetTester tester) async {
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
    }

    Finder inResolveDialog(Finder finder) =>
        find.descendant(of: find.byType(ResolveOriginDialog), matching: finder);

    /// Opens the first row's dialog and binds it to a page by pasting its url.
    Future<void> resolveFirst(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(TextButton, resolveLabel).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        inResolveDialog(find.byType(TextField)),
        'https://gamebanana.com/mods/531649',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(inResolveDialog(find.text('Save')));
      await tester.pumpAndSettle();
    }

    testWidgets('are folded under their count, and expand into rows',
        (tester) async {
      await runFlow(tester, withUntracked(['handmade', 'my own thing']));

      expect(find.textContaining("2 mods aren't linked to a GameBanana page"),
          findsOneWidget);
      expect(find.text('handmade'), findsNothing);
      expect(find.text(resolveLabel), findsNothing);

      await expand(tester);
      expect(find.text('handmade'), findsOneWidget);
      expect(find.text('my own thing'), findsOneWidget);
      expect(find.widgetWithText(TextButton, resolveLabel), findsNWidgets(2));
    });

    testWidgets('are sorted by name, ignoring case', (tester) async {
      // A case-sensitive sort would put "Charlie" first.
      await runFlow(tester, withUntracked(['beta', 'Charlie', 'alpha']));
      await expand(tester);

      double top(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(top('alpha'), lessThan(top('beta')));
      expect(top('beta'), lessThan(top('Charlie')));
    });

    testWidgets('Resolve opens the per-mod dialog over the screen',
        (tester) async {
      final dialog = realDialog();
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      await expand(tester);
      await tester.tap(find.widgetWithText(TextButton, resolveLabel));
      await tester.pumpAndSettle();

      expectBuilt(ResolveOriginDialog);
      expect(find.text('Which mod is this?'), findsOneWidget);
      expect(find.byType(BulkResolutionDialog), findsOneWidget);
      expect(dialog.opened, ['Ellen Swimsuit']);
    });

    testWidgets('a resolved row shows it is done, and the page it went to',
        (tester) async {
      final dialog = realDialog();
      final returned = <bool>[];
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
        returned: returned,
      );
      await expand(tester);
      await resolveFirst(tester);

      expect(dialog.gateway.writes, 1);
      expect(find.byType(ResolveOriginDialog), findsNothing);
      expect(find.text('Ellen Swimsuit'), findsOneWidget);
      expect(find.text(pageName), findsOneWidget);
      expect(find.text(resolvedLine), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text(resolveLabel), findsNothing);

      // Saved by the per-mod dialog already, so closing without Apply still tells the caller to rescan.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(returned, [true]);
    });

    testWidgets('folding and unfolding keeps a resolved row', (tester) async {
      final dialog = realDialog();
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      await expand(tester);
      await resolveFirst(tester);

      await expand(tester);
      expect(find.text(resolvedLine), findsNothing);
      await expand(tester);
      expect(find.text(pageName), findsOneWidget);
      expect(find.text(resolvedLine), findsOneWidget);
      expect(find.text(resolveLabel), findsNothing);
    });

    testWidgets('a double click opens one dialog', (tester) async {
      final dialog = realDialog();
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      await expand(tester);
      final button = find.widgetWithText(TextButton, resolveLabel);
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(dialog.opened, ['Ellen Swimsuit']);
      expect(find.byType(ResolveOriginDialog), findsOneWidget);
    });

    testWidgets('Cancel reads Close once the per-mod dialog has saved',
        (tester) async {
      // Leaving undoes nothing at that point, so "Cancel" would claim more than it does.
      final dialog = realDialog();
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Close'), findsNothing);

      await expand(tester);
      await resolveFirst(tester);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
    });

    testWidgets('with no question rows there is no intro and no Save button',
        (tester) async {
      await runFlow(
        tester,
        planBulkResolution(
          mods: [mod('handmade'), mod('my own thing')],
          records: const {},
        ),
      );

      expectBuilt(BulkResolutionDialog);
      expect(find.textContaining("2 mods aren't linked to a GameBanana page"),
          findsOneWidget);
      expect(find.textContaining('Nothing you tick here'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    });

    testWidgets('cancelling the per-mod dialog leaves the row as it was',
        (tester) async {
      final dialog = realDialog();
      final returned = <bool>[];
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
        returned: returned,
      );
      await expand(tester);
      await tester.tap(find.widgetWithText(TextButton, resolveLabel));
      await tester.pumpAndSettle();
      await tester.tap(inResolveDialog(find.text('Cancel')));
      await tester.pumpAndSettle();

      expect(find.byType(ResolveOriginDialog), findsNothing);
      expect(find.widgetWithText(TextButton, resolveLabel), findsOneWidget);
      expect(find.text(resolvedLine), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(returned, [false]);
    });

    testWidgets('"not from GameBanana" settles the row, with no button left',
        (tester) async {
      // A button left behind would reopen the dialog on the mod as it was before the save,
      // whose page search can bind a page while the folder stays marked as the user's own.
      final dialog = realDialog();
      final returned = <bool>[];
      await runFlow(
        tester,
        withUntracked(['Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
        returned: returned,
      );
      await expand(tester);
      await tester.tap(find.widgetWithText(TextButton, resolveLabel));
      await tester.pumpAndSettle();
      await tester.tap(
          inResolveDialog(find.text("Not from GameBanana, or it's my own")));
      await tester.pumpAndSettle();

      expect(dialog.gateway.writes, 1);
      expect(find.byType(ResolveOriginDialog), findsNothing);
      expect(find.text('Marked as not from GameBanana — saved now.'),
          findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text(resolveLabel), findsNothing);
      expect(find.text(resolvedLine), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(returned, [true]);
    });

    testWidgets('closing the per-mod dialog opens nothing else',
        (tester) async {
      // No chaining: the user picks the next mod, or stops.
      final dialog = realDialog();
      await runFlow(
        tester,
        withUntracked(['zeta', 'Ellen Swimsuit']),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      await expand(tester);
      await resolveFirst(tester);

      expect(dialog.opened, ['Ellen Swimsuit']);
      expect(find.byType(ResolveOriginDialog), findsNothing);
      expect(find.byType(BulkResolutionDialog), findsOneWidget);
      expect(find.widgetWithText(TextButton, resolveLabel), findsOneWidget);
    });

    testWidgets('Apply counts and writes only its own rows', (tester) async {
      final dialog = realDialog();
      final plan = withUntracked(['Ellen Swimsuit']);
      final result = await runFlow(
        tester,
        plan,
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
      );
      expect(find.text('Save 1 mod'), findsOneWidget);

      await expand(tester);
      await resolveFirst(tester);
      expect(find.text(resolvedLine), findsOneWidget);
      expect(find.text('Save 1 mod'), findsOneWidget);

      await apply(tester);
      expect(result.mods, ['vanished']);
    });

    testWidgets('Resolve opens on the mod as saved, not as the screen found it',
        (tester) async {
      // Naming what a patch applies to saves without settling the row, so the screen's own copy goes out of date.
      const patchOrigin = ModOrigin(
        provenance: OriginProvenance.importedFolder,
        ingest: ModIngest(patchShaped: true),
      );
      final dialog = realDialog();
      dialog.gateway.onDisk['RabbitFX'] = patchOrigin;
      await runFlow(
        tester,
        planBulkResolution(
          mods: [
            mod('vanished',
                origin: origin(modIdConfidence: OriginConfidence.user)),
            mod('RabbitFX', origin: patchOrigin),
          ],
          records: {1: remote(name: 'Gone page', trashed: true)},
        ),
        resolveOrigin: dialog.open,
        overrides: dialog.overrides,
        readOrigin: dialog.gateway.read,
      );
      await expand(tester);
      await tester.tap(find.widgetWithText(TextButton, resolveLabel));
      await tester.pumpAndSettle();
      expect(find.text('Which mod is this?'), findsOneWidget);

      await tester.enterText(
        inResolveDialog(find.byType(TextField)),
        'https://gamebanana.com/mods/531649',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final nameBase = find.text('Name the mod it patches');
      await tester.ensureVisible(nameBase);
      await tester.tap(nameBase);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.byType(ResolveOriginDialog), findsNothing);
      expect(dialog.gateway.onDisk['RabbitFX']!.base!.modId, 527697);
      // Saved, but not a settled row: the button stays.
      final resolve = find.widgetWithText(TextButton, resolveLabel);
      expect(resolve, findsOneWidget);

      await tester.tap(resolve);
      await tester.pumpAndSettle();
      expect(find.byType(ResolveOriginDialog), findsOneWidget);
      // The folder now has a base on record, so the dialog opens on it rather than on the page search.
      expect(find.text('Which mod is this?'), findsNothing);
      expect(find.textContaining('Megalodon Maid Ellen'), findsWidgets);
    });
  });
}
