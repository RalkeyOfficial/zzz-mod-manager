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
import 'support/origin_shorthand.dart';

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
    expect(find.text('Tracking data not saved'), findsOneWidget);
    expect(find.textContaining('2 mods'), findsOneWidget);
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

  group('the library menu', () {
    late ProviderContainer container;
    late List<String> written;

    Future<void> pumpToolbar(
      WidgetTester tester,
      List<ModInfo> mods, {
      Size surfaceSize = const Size(1200, 800),
      VoidCallback? onLibraryChanged,
    }) async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(charactersProvider.notifier).state = [
        CharacterInfo(id: 'all', name: 'All', skins: mods),
      ];
      written = <String>[];

      await pumpLocalized(
        tester,
        ModsToolbar(
          onLibraryChanged: onLibraryChanged,
          originWriter: (name, update) async {
            written.add(name);
            return update(mods.firstWhere((m) => m.id == name).origin) != null;
          },
        ),
        container: container,
        surfaceSize: surfaceSize,
      );
      expectBuilt(ModsToolbar);
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
    }

    testWidgets('turns the filter on before it asks', (tester) async {
      // The rule is unchanged — the user must have *seen* the set being
      // rewritten — but it is now enforced by the action rather than by hiding
      // the control until the filter happens to be on. The grid behind the
      // confirmation shows exactly those mods.
      await pumpToolbar(tester, [
        mod('a', origin: origin()),
        mod('b', origin: origin()),
        mod('resolved', origin: origin(versionConfidence: OriginConfidence.exact)),
      ]);
      expect(container.read(modNeedsAttentionOnlyProvider), isFalse);

      await openMenu(tester);
      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();

      expect(container.read(modNeedsAttentionOnlyProvider), isTrue);
      expect(container.read(visibleModsProvider).map((m) => m.id), ['a', 'b']);
      expect(find.text('Assume 2 mods are up to date?'), findsOneWidget);
    });

    testWidgets('the count in the menu is the count that gets written',
        (tester) async {
      // Flipping the filter cannot change *which* mods are eligible, only which
      // are on screen: the plan already keeps only versionUnknown mods, and
      // needs-attention drops exactly the ones it would have skipped anyway.
      await pumpToolbar(tester, [
        mod('a', origin: origin()),
        mod('b', origin: origin()),
        mod('untracked'),
        mod('resolved', origin: origin(versionConfidence: OriginConfidence.exact)),
      ]);
      await openMenu(tester);
      expect(find.text('2'), findsOneWidget);

      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark 2 mods'));
      await tester.pumpAndSettle();

      expect(written, ['a', 'b']);
    });

    testWidgets('cancelling puts the filter back the way it was',
        (tester) async {
      // Turning the filter on *for* the confirmation means cancelling — the one
      // thing a confirmation exists to allow — would otherwise leave the grid
      // filtered behind the user's back, with nothing on screen saying why.
      // Under the old placement the filter was a precondition, so declining
      // changed nothing.
      await pumpToolbar(tester, [mod('a', origin: origin())]);
      expect(container.read(modNeedsAttentionOnlyProvider), isFalse);

      await openMenu(tester);
      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();
      expect(container.read(modNeedsAttentionOnlyProvider), isTrue,
          reason: 'the grid shows the set while the confirmation is up');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(written, isEmpty);
      expect(container.read(modNeedsAttentionOnlyProvider), isFalse);
    });

    testWidgets('cancelling leaves a filter the user had already set alone',
        (tester) async {
      await pumpToolbar(tester, [mod('a', origin: origin())]);
      container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();

      await openMenu(tester);
      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(container.read(modNeedsAttentionOnlyProvider), isTrue,
          reason: 'restoring means restoring, not switching off');
    });

    testWidgets('is disabled when there is nothing it can act on',
        (tester) async {
      // An untracked mod needs attention but may never be resolved in bulk.
      await pumpToolbar(tester, [mod('untracked')]);
      await openMenu(tester);

      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();
      expect(find.textContaining('are up to date?'), findsNothing);
      expect(container.read(modNeedsAttentionOnlyProvider), isFalse,
          reason: 'a disabled entry must not flip a filter on the way to '
              'doing nothing');
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
        onLibraryChanged: () => rescans++,
      );

      await openMenu(tester);
      await tester.tap(find.text('Mark all as current'));
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

    testWidgets('turns the filter off again when it leaves nothing behind',
        (tester) async {
      // Otherwise the reward for pressing is an empty grid.
      await pumpToolbar(tester, [mod('a', origin: origin())]);

      await openMenu(tester);
      await tester.tap(find.text('Mark all as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark 1 mod'));
      await tester.pumpAndSettle();

      expect(container.read(modNeedsAttentionOnlyProvider), isFalse);
    });

    testWidgets('the filter row survives a three-digit count at 480px',
        (tester) async {
      // The narrowest the toolbar can get: an 800px minimum window, less the
      // nav rail and the character panel beside it. Nothing in that row can
      // ellipsise, so a Row that doesn't fit overflows rather than degrading.
      await pumpToolbar(
        tester,
        [for (var i = 0; i < 120; i++) mod('mod $i', origin: origin())],
        surfaceSize: const Size(480, 400),
      );
      container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(find.text('120'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
