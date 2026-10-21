import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/screens/dialogs/assume_current_dialog.dart';
import 'package:mod_manager_flutter/services/bulk_assume_current.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/all_mods_harness.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The bulk "assume current" surface.
///
/// What is worth pinning here is not the layout but the promises: the
/// confirmation lists what it is about to write *before* writing it, an
/// unticked mod is left out, a dismissed dialog writes nothing, and a run that
/// partly failed says so rather than reporting success for the half that worked.
void main() {
  final installedAt = DateTime.utc(2026, 5, 8);

  ModOrigin origin({
    int? modId = 1,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    bool proxy = true,
    bool undated = false,
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: OriginConfidence.inferred,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        installedAt: undated ? null : installedAt,
        installedAtIsProxy: proxy,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  /// Mounts a button that runs the flow, and hands back what it recorded.
  Future<({List<String> written, List<BulkAssumeCurrentOutcome?> outcomes})>
      runFlow(
    WidgetTester tester,
    BulkAssumeCurrentPlan plan, {
    Set<String> failFor = const {},
    Map<String, ModOrigin?> onDisk = const {},
    Size surfaceSize = const Size(1200, 800),
  }) async {
    final written = <String>[];
    final outcomes = <BulkAssumeCurrentOutcome?>[];

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final loc = context.loc;
            final notify = context.notify;
            final outcome = await confirmAndApplyAssumeCurrent(
              context,
              plan,
              writer: (name, update) async {
                if (failFor.contains(name)) return OriginWriteResult.writeFailed;
                // Mirrors `updateOrigin`: the transform is handed the block as
                // it is **on disk**, which `onDisk` can make differ from the
                // one the plan was built from.
                final next = update(onDisk.containsKey(name)
                    ? onDisk[name]
                    : plan.eligible.firstWhere((m) => m.id == name).origin);
                if (next == null) return OriginWriteResult.declined;
                written.add(name);
                return OriginWriteResult.written;
              },
            );
            // Null too, so a test can tell "returned null" from "never returned".
            outcomes.add(outcome);
            if (outcome != null) showAssumeCurrentOutcome(loc, notify, outcome, into: outcome.card);
          },
          child: const Text('run'),
        ),
      ),
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    return (written: written, outcomes: outcomes);
  }

  Finder confirm(String label) => find.widgetWithText(FilledButton, label);

  /// A mod's own box in the list.
  Finder boxOf(String name) =>
      find.byWidgetPredicate((w) => w is Checkbox && w.semanticLabel == 'Mark $name as current');

  testWidgets('the confirmation lists every mod it would write, and names what it leaves', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('untracked'),
      mod('undated', origin: origin(undated: true)),
    ]);

    await runFlow(tester, plan);

    expect(find.text('Mark 2 mods as current?'), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);
    expect(boxOf('a'), findsOneWidget);
    expect(boxOf('b'), findsOneWidget);
    expect(boxOf('untracked'), findsNothing);
    expect(boxOf('undated'), findsNothing);
    // "2 mods" is a very different offer from "2 of your 4".
    expect(
      find.textContaining("1 that isn't linked to GameBanana, and 1 with no date added on record."),
      findsOneWidget,
    );
    expect(confirm('Mark 2 as current'), findsOneWidget);
  });

  testWidgets('a folder whose question is another layer\'s is named among what it leaves', (tester) async {
    final baseUnknown = originFixture(
      source: 'gamebanana',
      modId: 1,
      modIdConfidence: OriginConfidence.inferred,
      installedAt: installedAt,
      ingest: const ModIngest(patchShaped: true),
    );
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('untracked'),
      mod('undated', origin: origin(undated: true)),
      mod('patch only', origin: baseUnknown),
    ]);

    await runFlow(tester, plan);

    expect(boxOf('patch only'), findsNothing);
    expect(
      find.textContaining("1 that isn't linked to GameBanana, 1 with no date added on record, and 1 whose base mod "
          'or patch file is still to be named in the tracking screen.'),
      findsOneWidget,
    );
  });

  testWidgets('every box starts ticked', (tester) async {
    await runFlow(tester, planBulkAssumeCurrent([mod('a', origin: origin()), mod('b', origin: origin())]));

    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(boxes, hasLength(3), reason: 'the header box and one per mod');
    expect(boxes.map((b) => b.value), everyElement(isTrue));
  });

  testWidgets('it says nothing is downloaded', (tester) async {
    await runFlow(tester, planBulkAssumeCurrent([mod('a', origin: origin())]));
    expect(find.text('Nothing is downloaded'), findsOneWidget);
  });

  testWidgets('the proxy caveat appears only for a derived date', (tester) async {
    await runFlow(tester, planBulkAssumeCurrent([mod('a', origin: origin(proxy: true))]));
    expect(find.textContaining('Copied mods in from another folder?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await runFlow(tester, planBulkAssumeCurrent([mod('a', origin: origin(proxy: false))]));
    expect(find.textContaining('Copied mods in from another folder?'), findsNothing);
  });

  testWidgets('the confirmation fits the smallest window', (tester) async {
    // The app's fonts: the test font draws every glyph a full em wide.
    await loadTableFonts(tester);
    await runFlow(
      tester,
      planBulkAssumeCurrent([
        mod('a', origin: origin()),
        mod('untracked'),
        mod('undated', origin: origin(undated: true)),
      ]),
      surfaceSize: const Size(480, 400),
    );
    expect(confirm('Mark 1 as current'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling writes nothing at all', (tester) async {
    final run = await runFlow(tester, planBulkAssumeCurrent([mod('a', origin: origin())]));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(run.written, isEmpty);
    expect(run.outcomes, [isNull]);
  });

  testWidgets('confirming writes every eligible mod once', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('exact', origin: origin(versionConfidence: OriginConfidence.exact)),
    ]);
    final run = await runFlow(tester, plan);

    await tester.tap(confirm('Mark 2 as current'));
    await tester.pumpAndSettle();

    expect(run.written, ['a', 'b']);
    expect(run.outcomes.single!.written, 2);
    expect(run.outcomes.single!.failed, 0);
    expect(find.textContaining('2 mods now watch for files published'), findsOneWidget);
  });

  testWidgets('the writes show a Working card, which becomes the report in place', (tester) async {
    final plan = planBulkAssumeCurrent([mod('a', origin: origin()), mod('b', origin: origin())]);
    await runFlow(tester, plan);
    final container = ProviderScope.containerOf(tester.element(find.text('run')));
    final working = <AppNotification>[];
    final listening = container.listen<List<AppNotification>>(notificationsProvider, (_, next) {
      for (final n in next) {
        if (n.kind == NotificationKind.working && !working.any((w) => w.id == n.id)) working.add(n);
      }
    });
    addTearDown(listening.close);

    await tester.tap(confirm('Mark 2 as current'));
    await tester.pumpAndSettle();

    expect([for (final n in working) (n.title, n.body)], [('Marking 2 mods as current…', 'a and b')]);
    final report = container.read(notificationsProvider).single;
    expect(report.id, working.single.id, reason: 'the same card, turned into its result');
    expect((report.kind, report.title), (NotificationKind.done, '2 mods marked as current'));
  });

  testWidgets('an unticked mod is left out of the writes', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('c', origin: origin()),
    ]);
    final run = await runFlow(tester, plan);

    await tester.tap(boxOf('b'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isNull, reason: 'the header box is mixed');

    await tester.tap(confirm('Mark 2 as current'));
    await tester.pumpAndSettle();

    expect(run.written, ['a', 'c']);
    expect(run.outcomes.single!.written, 2);
  });

  testWidgets('with every box unticked the confirm button is off, and the header box ticks them back',
      (tester) async {
    final run = await runFlow(
      tester,
      planBulkAssumeCurrent([mod('a', origin: origin()), mod('b', origin: origin())]),
    );

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('0 of 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm('Mark 0 as current')).onPressed, isNull);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm('Mark 2 as current')).onPressed, isNotNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(run.written, isEmpty);
  });

  testWidgets('a partly failed run reports both halves', (tester) async {
    // A folder that can't be written is a state, not a shrug: nothing
    // re-attempts an origin write, so a run that silently reported "3 done"
    // would leave one mod permanently unresolved with no trace.
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('read only', origin: origin()),
    ]);
    final run = await runFlow(tester, plan, failFor: {'read only'});

    await tester.tap(confirm('Mark 3 as current'));
    await tester.pumpAndSettle();

    expect(run.outcomes.single!.written, 2);
    expect(run.outcomes.single!.failed, 1);
    expect(find.textContaining("Couldn't save tracking data for 1"), findsOneWidget);
  });

  testWidgets('a wholly unwritable library says so and nothing else', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
    ]);
    final run = await runFlow(tester, plan, failFor: {'a', 'b'});

    await tester.tap(confirm('Mark 2 as current'));
    await tester.pumpAndSettle();

    expect(run.outcomes.single!.written, 0);
    expect(run.outcomes.single!.failed, 2);
    expect(find.text('Tracking data not saved'), findsOneWidget);
    expect(find.textContaining("2 mods' folders may be read-only."), findsOneWidget);
  });

  testWidgets('a declined write is not reported as a read-only folder', (tester) async {
    // The guard firing is the designed behaviour. Reachable without any concurrency:
    // press the button, then press it again before the rescan has refreshed the plan.
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
    ]);
    final run = await runFlow(
      tester,
      plan,
      onDisk: {
        'a': origin(versionConfidence: OriginConfidence.assumedLatest),
        'b': origin(versionConfidence: OriginConfidence.assumedLatest),
      },
    );

    await tester.tap(confirm('Mark 2 as current'));
    await tester.pumpAndSettle();

    expect(run.written, isEmpty);
    expect(run.outcomes.single!.skipped, 2);
    expect(run.outcomes.single!.failed, 0);
    expect(find.textContaining('already sorted out'), findsOneWidget);
    expect(find.textContaining("Couldn't save"), findsNothing);
  });
}
