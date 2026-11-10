import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/apply_update_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_modal.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_run.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The run behind "Update N": one update after another through the one-mod flow, ended by a refusal and not by a
/// failure, with a mod already written as a sibling left out and a busy folder skipped.
void main() {
  ModInfo mod(String id) => ModInfo(id: id, name: id, characterId: 'ellen', isActive: false);

  UpdateCheck check(int fileId) => UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        newerFiles: [GbFile(idRow: fileId, file: 'f$fileId.zip', dateAdded: DateTime.utc(2026, 10, 1))],
        subject: const DownloadKey.base(100),
      );

  UpdatePick pick(String id, int fileId) => UpdatePick(
        modId: id,
        file: GbFile(idRow: fileId, file: 'f$fileId.zip'),
        subject: const DownloadKey.base(100),
        published: [GbFile(idRow: fileId, file: 'f$fileId.zip')],
      );

  late ProviderContainer container;
  late List<AppNotification> raised;

  /// Updates run so far: the mod, and the position it was handed.
  late List<(String, int, int)> ran;

  /// Whether the result window offered Next, by mod: asked after the update's own write, as the flow asks it.
  late Map<String, bool> offeredNext;

  setUp(() {
    raised = [];
    ran = [];
    offeredNext = {};
  });

  Future<void> pumpRun(
    WidgetTester tester,
    List<String> ids,
    Future<void> Function(BuildContext context, WidgetRef ref) press,
  ) async {
    container = ProviderContainer(overrides: [libraryOf([for (final id in ids) mod(id)])]);
    addTearDown(container.dispose);
    container.listen(notificationsProvider, (_, next) => raised.addAll(next));
    container.read(modUpdateChecksProvider.notifier).state = {for (final (i, id) in ids.indexed) id: check(i + 1)};
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(onPressed: () => press(context, ref), child: const Text('run')),
      ),
      container: container,
    );
    expectBuilt(ElevatedButton);
  }

  /// An update that answers from [outcomes] by mod and records what it was handed. A written one settles its own mark,
  /// as the real flow does, unless the mod is in [leaveMark]: an archive's other mods written while this one was
  /// unticked.
  ModUpdater fake(
    Map<String, UpdateFlowOutcome> outcomes, {
    void Function(String id)? onRun,
    Set<String> leaveMark = const {},
  }) =>
      (context, ref, {required mod, required subject, required file, required published, run}) async {
        ran.add((mod.id, run!.index, run.total));
        onRun?.call(mod.id);
        final outcome = outcomes[mod.id] ?? UpdateFlowOutcome.written;
        if (outcome == UpdateFlowOutcome.written && !leaveMark.contains(mod.id)) {
          final checks = container.read(modUpdateChecksProvider.notifier);
          checks.state = {...checks.state}..remove(mod.id);
        }
        offeredNext[mod.id] = run.hasMore;
        return outcome;
      };

  Iterable<String> titles() => raised.map((n) => n.title).toSet();

  testWidgets('the mods are updated in list order, each told where it sits, and a clean run raises no card', (tester) async {
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran, [('A', 1, 3), ('B', 2, 3), ('C', 3, 3)]);
    expect(raised, isEmpty);
    expect(container.read(libraryScansProvider), 1, reason: 'one rescan once the run is over');
  });

  testWidgets('declining ends the run: the rest are left alone and a Note says how far it got', (tester) async {
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({'B': UpdateFlowOutcome.declined}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran.map((r) => r.$1), ['A', 'B'], reason: 'C is never asked about');
    expect(titles(), {'Updates stopped'});
    expect(find.text('1 of 3 mods updated. The rest were left as they were.'), findsOneWidget);
    expect(container.read(libraryScansProvider), 1);
  });

  testWidgets('a failed update and one that never started do not stop the run', (tester) async {
    await pumpRun(tester, ['A', 'B', 'C', 'D'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3), pick('D', 4)],
          update: fake({'A': UpdateFlowOutcome.failed, 'B': UpdateFlowOutcome.failedAfterChange, 'C': UpdateFlowOutcome.notStarted}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran.map((r) => r.$1), ['A', 'B', 'C', 'D']);
    expect(raised, isEmpty, reason: 'each failure already raised its own card, and the run itself did not stop');
  });

  testWidgets("a mod whose mark an earlier update settled is skipped with a Note, and counts as done", (tester) async {
    // A and B came from one archive: A's confirmation listed B and wrote it, which cleared B's mark.
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({'C': UpdateFlowOutcome.declined}, onRun: (id) {
            if (id != 'A') return;
            final checks = container.read(modUpdateChecksProvider.notifier);
            checks.state = {...checks.state}..remove('B');
          }),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran.map((r) => r.$1), ['A', 'C'], reason: 'B is not downloaded again');
    expect(find.text('“B” was already updated with another mod from the same archive.'), findsOneWidget);
    expect(find.text('2 of 3 mods updated. The rest were left as they were.'), findsOneWidget);
  });

  testWidgets('a mod whose folder is being written when its turn comes is skipped, and named', (tester) async {
    await pumpRun(tester, ['A', 'B'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2)],
          update: fake({}),
        ));
    final held = holdWrite(container, 'A');
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    await held.release();

    expect(ran.map((r) => r.$1), ['B']);
    expect(find.text('“A” was being written to when its turn came.'), findsOneWidget);
  });

  testWidgets('a mod gone from the library is skipped without a word', (tester) async {
    await pumpRun(tester, ['A'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('Gone', 9), pick('A', 1)],
          update: fake({}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran.map((r) => r.$1), ['A']);
    expect(raised, isEmpty);
  });

  testWidgets('a mod whose update was ignored while the run went is skipped with a Note, and is not counted',
      (tester) async {
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({'C': UpdateFlowOutcome.declined}, onRun: (id) {
            if (id != 'A') return;
            final checks = container.read(modUpdateChecksProvider.notifier);
            checks.state = {...checks.state, 'B': checks.state['B']!.asDismissed(true)};
          }),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(ran.map((r) => r.$1), ['A', 'C'], reason: 'B is not updated');
    expect(find.text('“B” was ignored while the updates ran.'), findsOneWidget);
    expect(find.text('1 of 3 mods updated. The rest were left as they were.'), findsOneWidget);
  });

  testWidgets('a written mod whose own mark stays, because it was left unticked, is not counted', (tester) async {
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({'C': UpdateFlowOutcome.declined}, leaveMark: {'A'}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(find.text('1 of 3 mods updated. The rest were left as they were.'), findsOneWidget);
  });

  testWidgets('Next is offered only while a later mod can still run', (tester) async {
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({}),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(offeredNext, {'A': true, 'B': true, 'C': false});
  });

  testWidgets('Next is not offered when the write settled every later mod, or the later ones are busy', (tester) async {
    // A's write settles B and C, which came from its archive.
    await pumpRun(tester, ['A', 'B', 'C'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2), pick('C', 3)],
          update: fake({}, onRun: (id) {
            final checks = container.read(modUpdateChecksProvider.notifier);
            checks.state = {...checks.state}..remove('B')..remove('C');
          }),
        ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    expect(offeredNext, {'A': false}, reason: 'the later turns are skipped, so Next would promise nothing');
  });

  testWidgets('a later mod whose folder is being written does not earn Next', (tester) async {
    await pumpRun(tester, ['A', 'B'], (context, ref) => runModUpdates(
          context,
          ref,
          [pick('A', 1), pick('B', 2)],
          update: fake({}),
        ));
    final held = holdWrite(container, 'B');
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    await held.release();

    expect(offeredNext, {'A': false});
  });

  testWidgets('the host runs one run at a time, and says so while it runs', (tester) async {
    final first = Completer<UpdateFlowOutcome>();
    var calls = 0;
    container = ProviderContainer(overrides: [libraryOf([mod('A')])]);
    addTearDown(container.dispose);
    container.read(modUpdateChecksProvider.notifier).state = {'A': check(1)};
    await pumpLocalized(
      tester,
      LibraryActionsHost(
        modUpdater: (context, ref, {required mod, required subject, required file, required published, run}) {
          calls++;
          return first.future;
        },
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LibraryActionsHost.of(context).updateMods([pick('A', 1)]),
            child: const Text('run'),
          ),
        ),
      ),
      container: container,
    );

    await tester.tap(find.text('run'));
    await tester.pump();
    expect(container.read(libraryUpdateRunProvider), isTrue);

    await tester.tap(find.text('run'));
    await tester.pump();
    expect(calls, 1, reason: 'a second press while a run is under way does nothing');

    first.complete(UpdateFlowOutcome.written);
    await tester.pumpAndSettle();
    expect(container.read(libraryUpdateRunProvider), isFalse);
  });
}
