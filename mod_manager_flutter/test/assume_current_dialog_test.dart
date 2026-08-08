import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/dialogs/assume_current_dialog.dart';
import 'package:mod_manager_flutter/services/bulk_assume_current.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// The bulk "assume current" surface.
///
/// What is worth pinning here is not the layout but the promises: the
/// confirmation states the size of what it is about to do *before* doing it, a
/// dismissed dialog writes nothing, and a run that partly failed says so rather
/// than reporting success for the half that worked.
void main() {
  final installedAt = DateTime.utc(2026, 5, 8);

  ModOrigin origin({
    int? modId = 1,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    bool proxy = true,
    bool undated = false,
  }) =>
      ModOrigin(
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
  Future<({List<String> written, List<BulkAssumeCurrentOutcome> outcomes})>
      runFlow(
    WidgetTester tester,
    BulkAssumeCurrentPlan plan, {
    Set<String> failFor = const {},
    Map<String, ModOrigin?> onDisk = const {},
    Size surfaceSize = const Size(1200, 800),
  }) async {
    final written = <String>[];
    final outcomes = <BulkAssumeCurrentOutcome>[];

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final outcome = await confirmAndApplyAssumeCurrent(
              context,
              plan,
              writer: (name, update) async {
                if (failFor.contains(name)) return false;
                // Mirrors `updateOrigin`: the transform is handed the block as
                // it is **on disk**, which `onDisk` can make differ from the
                // one the plan was built from — and a null answer abandons the
                // write, indistinguishable from a failure in the return value.
                final next = update(onDisk.containsKey(name)
                    ? onDisk[name]
                    : plan.eligible.firstWhere((m) => m.id == name).origin);
                if (next == null) return false;
                written.add(name);
                return true;
              },
            );
            if (outcome == null) return;
            outcomes.add(outcome);
            if (context.mounted) showAssumeCurrentOutcome(context, outcome);
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

  testWidgets('the confirmation names the size before acting', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('untracked'),
      mod('undated', origin: origin(undated: true)),
    ]);

    await runFlow(tester, plan);

    // Two eligible, and the two groups it is deliberately not touching are
    // named too — "2 mods" is a very different offer from "2 of your 4".
    expect(find.textContaining('2 mods are up to date'), findsOneWidget);
    expect(find.textContaining('1 more mod needs attention'), findsOneWidget);
    expect(find.textContaining('1 mod is skipped'), findsOneWidget);
    expect(find.text('Mark 2 mods'), findsOneWidget);
  });

  testWidgets('it says a version is not being invented', (tester) async {
    await runFlow(
      tester,
      planBulkAssumeCurrent([mod('a', origin: origin())]),
    );
    expect(find.textContaining("No version number is invented"), findsOneWidget);
  });

  testWidgets('the proxy caveat appears only for a derived date',
      (tester) async {
    await runFlow(
      tester,
      planBulkAssumeCurrent([mod('a', origin: origin(proxy: true))]),
    );
    expect(find.textContaining('worked out from the oldest file'),
        findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await runFlow(
      tester,
      planBulkAssumeCurrent([mod('a', origin: origin(proxy: false))]),
    );
    expect(find.textContaining('worked out from the oldest file'), findsNothing);
  });

  testWidgets('the confirmation fits the smallest window', (tester) async {
    // 460px of content inside an AlertDialog that only has ~400 to give. The
    // SizedBox clamps rather than overflowing, and the body scrolls — but that
    // is a property of how it is built, not an obvious one, so it is pinned.
    await runFlow(
      tester,
      planBulkAssumeCurrent([
        mod('a', origin: origin()),
        mod('untracked'),
        mod('undated', origin: origin(undated: true)),
      ]),
      surfaceSize: const Size(480, 400),
    );
    expect(find.text('Mark 1 mod'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling writes nothing at all', (tester) async {
    final plan = planBulkAssumeCurrent([mod('a', origin: origin())]);
    final run = await runFlow(tester, plan);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(run.written, isEmpty);
    expect(run.outcomes, isEmpty);
  });

  testWidgets('confirming writes every eligible mod once', (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
      mod('exact', origin: origin(versionConfidence: OriginConfidence.exact)),
    ]);
    final run = await runFlow(tester, plan);

    await tester.tap(find.text('Mark 2 mods'));
    await tester.pumpAndSettle();

    expect(run.written, ['a', 'b']);
    expect(run.outcomes.single.written, 2);
    expect(run.outcomes.single.failed, 0);
    expect(
      find.textContaining('2 mods now watch for files published'),
      findsOneWidget,
    );
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

    await tester.tap(find.text('Mark 3 mods'));
    await tester.pumpAndSettle();

    expect(run.outcomes.single.written, 2);
    expect(run.outcomes.single.failed, 1);
    expect(find.textContaining("Couldn't save tracking data for 1"),
        findsOneWidget);
  });

  testWidgets('a wholly unwritable library says so and nothing else',
      (tester) async {
    final plan = planBulkAssumeCurrent([
      mod('a', origin: origin()),
      mod('b', origin: origin()),
    ]);
    final run = await runFlow(tester, plan, failFor: {'a', 'b'});

    await tester.tap(find.text('Mark 2 mods'));
    await tester.pumpAndSettle();

    expect(run.outcomes.single.written, 0);
    expect(run.outcomes.single.failed, 2);
    expect(find.textContaining("Couldn't save tracking data for 2 mods"),
        findsOneWidget);
  });

  testWidgets('a declined write is not reported as a read-only folder',
      (tester) async {
    // The guard firing is the *designed* behaviour, and `updateOrigin` answers
    // the same bare `false` for it as for a filesystem failure. Reachable
    // without any concurrency: press the button, then press it again before the
    // rescan has refreshed the plan. Reporting a permission error there sends
    // the user hunting through folder permissions for a problem that is not
    // there.
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

    await tester.tap(find.text('Mark 2 mods'));
    await tester.pumpAndSettle();

    expect(run.written, isEmpty);
    expect(run.outcomes.single.skipped, 2);
    expect(run.outcomes.single.failed, 0);
    expect(find.textContaining('already sorted out'), findsOneWidget);
    expect(find.textContaining("Couldn't save"), findsNothing);
  });

  group('the toolbar button', () {
    late ProviderContainer container;
    late List<String> written;

    Future<void> pumpToolbar(
      WidgetTester tester,
      List<ModInfo> mods, {
      required bool filterOn,
      Size surfaceSize = const Size(1200, 800),
      VoidCallback? onLibraryChanged,
    }) async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(charactersProvider.notifier).state = [
        CharacterInfo(id: 'all', name: 'All', skins: mods),
      ];
      container.read(modNeedsAttentionOnlyProvider.notifier).state = filterOn;
      written = <String>[];

      await pumpLocalized(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: ModsToolbar(
            onLibraryChanged: onLibraryChanged,
            originWriter: (name, update) async {
              written.add(name);
              return update(mods.firstWhere((m) => m.id == name).origin) != null;
            },
          ),
        ),
        surfaceSize: surfaceSize,
      );
      expectBuilt(ModsToolbar);
    }

    testWidgets('is hidden until the mods have been enumerated',
        (tester) async {
      // Deliberate: the action rewrites every mod on the list, so it is offered
      // only once the filter has put that list on screen.
      await pumpToolbar(tester, [mod('a', origin: origin())], filterOn: false);
      expect(find.textContaining('Assume'), findsNothing);

      await pumpToolbar(tester, [mod('a', origin: origin())], filterOn: true);
      expect(find.text('Assume 1 are current'), findsOneWidget);
    });

    testWidgets('is hidden when the filter has nothing it can act on',
        (tester) async {
      // An untracked mod needs attention but may never be resolved in bulk, so
      // the filter is non-empty while the button has no work.
      await pumpToolbar(tester, [mod('untracked')], filterOn: true);
      expect(find.textContaining('Assume'), findsNothing);
    });

    testWidgets('presses through to the writes and asks for a rescan',
        (tester) async {
      var rescans = 0;
      await pumpToolbar(
        tester,
        [
          mod('a', origin: origin()),
          mod('b', origin: origin()),
          mod('untracked'),
        ],
        filterOn: true,
        onLibraryChanged: () => rescans++,
      );

      await tester.tap(find.text('Assume 2 are current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark 2 mods'));
      await tester.pumpAndSettle();

      expect(written, ['a', 'b']);
      // The status slot is drawn from `ModInfo.origin`, which only a scan
      // refreshes — without this the marks would sit there until a tab switch.
      expect(rescans, 1);
      // An untracked mod is still on the list, so the filter has something left
      // to show and stays on.
      expect(container.read(modNeedsAttentionOnlyProvider), isTrue);
    });

    testWidgets('turns the filter off when it leaves nothing behind',
        (tester) async {
      // Otherwise the reward for pressing the button is an empty grid.
      await pumpToolbar(
        tester,
        [mod('a', origin: origin())],
        filterOn: true,
      );

      await tester.tap(find.text('Assume 1 are current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark 1 mod'));
      await tester.pumpAndSettle();

      expect(container.read(modNeedsAttentionOnlyProvider), isFalse);
    });

    testWidgets('counts what the grid shows, not what the filter could show',
        (tester) async {
      // The whole argument for this button's placement is that it acts on the
      // list in front of the user. Combine the needs-attention filter with the
      // search box and the two lists come apart — so the plan is built from
      // `visibleModsProvider`, the one the grid renders.
      await pumpToolbar(
        tester,
        [
          mod('ellen skin', origin: origin()),
          mod('rina skin', origin: origin()),
          mod('rina other', origin: origin()),
        ],
        filterOn: true,
      );
      expect(find.text('Assume 3 are current'), findsOneWidget);

      container.read(modSearchQueryProvider.notifier).state = 'ellen';
      await tester.pumpAndSettle();

      expect(container.read(visibleModsProvider), hasLength(1));
      expect(find.text('Assume 1 are current'), findsOneWidget);
      // The `!` toggle deliberately still counts the unfiltered view — it
      // answers "what could this view show", not "what is it showing".
      expect(container.read(modsNeedingAttentionCountProvider), 3);
    });

    testWidgets('leaves no gap behind when the toolbar loses the "!" toggle',
        (tester) async {
      // Reported after the first real run: resolving the last mod removed the
      // toggle but left both of its 8px spacers, so the two controls either
      // side of it sat 16px apart and the row read as though a button had
      // failed to render. The control and its spacer are conditional together
      // now — the same shape the tag filter already used.
      //
      // Measured against the update-check button rather than the favourites
      // star, because that button now sits between the toggle and the star:
      // what this test is about is the *hole the toggle leaves*, so it has to
      // span the toggle's slot and nothing else.
      double gapAfterSort() {
        Finder box(IconData icon) => find
            .ancestor(of: find.byIcon(icon), matching: find.byType(Container))
            .first;
        return tester.getTopLeft(box(Icons.arrow_circle_up)).dx -
            tester.getTopRight(box(Icons.sort)).dx;
      }

      await pumpToolbar(tester, [mod('a', origin: origin())], filterOn: false);
      final withToggle = gapAfterSort();

      await pumpToolbar(
        tester,
        [mod('a', origin: origin(versionConfidence: OriginConfidence.exact))],
        filterOn: false,
      );
      expect(find.byIcon(Icons.priority_high), findsNothing);
      // One gap where the toggle used to be, not two — and the same 8px the
      // toggle itself sits behind.
      expect(gapAfterSort(), 8);
      expect(withToggle, greaterThan(8));
    });

    testWidgets('shares its row with "clear filters" without overflowing',
        (tester) async {
      // The narrowest the toolbar can get: an 800px minimum window, less the
      // nav rail and the character panel beside it. Both labels are whole words
      // with nothing to ellipsise, so a Row that doesn't fit overflows rather
      // than degrading — and a three-digit count is the widest label there is.
      await pumpToolbar(
        tester,
        [for (var i = 0; i < 120; i++) mod('mod $i', origin: origin())],
        filterOn: true,
        surfaceSize: const Size(480, 400),
      );
      expect(find.text('Assume 120 are current'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
