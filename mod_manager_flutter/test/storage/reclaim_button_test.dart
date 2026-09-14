import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/storage/reclaim_button.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_service.dart';

import '../support/localized_harness.dart';

ReclaimOutcome outcome({
  int freed = 0,
  int removed = 0,
  int? delta,
  ReclaimSkipReason? refusal,
}) =>
    ReclaimOutcome(
      freeSpaceDelta: delta,
      targets: [
        ReclaimTargetResult(
          target: ReclaimTarget.completedArchives,
          freedBytes: freed,
          removedCount: removed,
          skippedCount: refusal == null ? 0 : 1,
          refusal: refusal,
        ),
      ],
    );

void main() {
  Future<void> pumpButton(WidgetTester tester, ReclaimRunner runner) {
    return pumpLocalized(
      tester,
      Scaffold(body: Center(child: ReclaimButton(runner: runner))),
    );
  }

  /// The dialog's confirm, not the trigger — they deliberately carry the same
  /// words, so the finder has to say which one it means.
  Finder confirmButton() => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Free up space'),
      );

  testWidgets('asks before it deletes anything', (tester) async {
    var ran = false;
    await pumpButton(tester, () async {
      ran = true;
      return outcome();
    });

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();

    expect(find.text('Free up space?'), findsOneWidget);
    expect(ran, isFalse, reason: 'nothing runs before the answer');
  });

  testWidgets('cancelling runs nothing', (tester) async {
    var ran = false;
    await pumpButton(tester, () async {
      ran = true;
      return outcome();
    });

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(ran, isFalse);
  });

  testWidgets('the confirmation names what it will not touch', (tester) async {
    await pumpButton(tester, () async => outcome());

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();

    // Everything the sweep deletes can be got again; what the user is afraid of
    // losing is the two things it cannot reach, so they are named up front.
    expect(
      find.text('Your mods and your saved versions are not touched.'),
      findsOneWidget,
    );
  });

  testWidgets('reports what it freed', (tester) async {
    await pumpButton(
      tester,
      () async => outcome(freed: 2048, removed: 3),
    );

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(find.text('Freed 2.0 KB'), findsOneWidget);
    expect(find.textContaining('Removed 3 items'), findsOneWidget);
  });

  testWidgets('prefers the space the volume actually gave back',
      (tester) async {
    // On a compressed or copy-on-write filesystem the sum of file lengths is
    // not what comes free, so the measured delta is the honest number.
    await pumpButton(
      tester,
      () async => outcome(freed: 4096, removed: 1, delta: 1024),
    );

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(find.text('Freed 1.0 KB'), findsOneWidget);
  });

  testWidgets('says so when there was nothing to free', (tester) async {
    await pumpButton(tester, () async => outcome());

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(find.text('Nothing to free up'), findsOneWidget);
  });

  testWidgets('names what it deliberately left alone', (tester) async {
    await pumpButton(
      tester,
      () async => outcome(
        freed: 100,
        removed: 1,
        refusal: ReclaimSkipReason.downloadsActive,
      ),
    );

    await tester.tap(find.text('Free up space'));
    await tester.pumpAndSettle();
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    // In the same card as the result: a sweep that quietly did less than it
    // offered is worse than one that did nothing.
    expect(
      find.textContaining('Left your downloads alone'),
      findsOneWidget,
    );
  });
}
