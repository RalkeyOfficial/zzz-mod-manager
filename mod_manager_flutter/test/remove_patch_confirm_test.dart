import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/dialogs/remove_patch_flow.dart';
import 'package:mod_manager_flutter/services/patch_removal.dart';

import 'support/localized_harness.dart';

/// **What the user agrees to before a patch is taken out.**
///
/// The screen has one job that nothing else can do: say what will happen while
/// it can still be declined. Two things it must get right — the counts are the
/// *plan*, not an estimate read off the record, and the one loss it cannot pay
/// for with a rule is stated rather than reported afterwards.
void main() {
  bool? answer;

  Future<void> pump(WidgetTester tester, PatchRemovalPlan plan) async {
    answer = null;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                answer = await showRemovePatchConfirmation(
                  context,
                  modName: 'Ellen Swimsuit',
                  patchName: 'Ellen Swimsuit Fix',
                  plan: plan,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    expectBuilt(ElevatedButton);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('names both mods, so it is clear which is being removed',
      (tester) async {
    await pump(
      tester,
      const PatchRemovalPlan(delete: ['patch.ini']),
    );

    expect(find.text('Remove this patch?'), findsOneWidget);
    expect(find.textContaining('Ellen Swimsuit Fix'), findsOneWidget);
    expect(find.textContaining('was installed into'), findsOneWidget);
  });

  testWidgets('counts what goes and what comes back', (tester) async {
    await pump(
      tester,
      const PatchRemovalPlan(
        delete: ['patch.ini', 'extra.ini'],
        restore: ['Textures/Body.dds'],
      ),
    );

    expect(find.textContaining('2 files the patch added are deleted'),
        findsOneWidget);
    expect(find.textContaining('1 of the mod\'s own files comes back'),
        findsOneWidget);
  });

  testWidgets('a line with nothing to count does not appear', (tester) async {
    // A confirmation reading "0 files are deleted" is noise that makes the line
    // that matters harder to find.
    await pump(tester, const PatchRemovalPlan(restore: ['Body.dds']));

    expect(find.textContaining('the patch added'), findsNothing);
    expect(find.textContaining('comes back'), findsOneWidget);
  });

  testWidgets('the file it cannot put back is stated before the answer',
      (tester) async {
    // **The one loss on this screen not paid for by a rule.** Said here because
    // it is invisible afterwards — the folder looks complete either way.
    await pump(
      tester,
      const PatchRemovalPlan(unrecoverable: ['Textures/Body.dds']),
    );

    expect(
      find.textContaining('1 file stays as the patch left it'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('a recorded file the user deleted is reported as left alone',
      (tester) async {
    await pump(tester, const PatchRemovalPlan(gone: ['old.ini']));

    expect(
      find.textContaining('no longer in the folder and is left alone'),
      findsOneWidget,
    );
  });

  testWidgets('cancelling answers no', (tester) async {
    await pump(tester, const PatchRemovalPlan(delete: ['patch.ini']));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });

  testWidgets('confirming answers yes', (tester) async {
    await pump(tester, const PatchRemovalPlan(delete: ['patch.ini']));

    await tester.tap(find.text('Remove patch'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('dismissing it is not agreement', (tester) async {
    // Clicking away closes the route with no value, and the flow must read that
    // as "no" rather than as an empty answer it can proceed on.
    await pump(tester, const PatchRemovalPlan(delete: ['patch.ini']));

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });
}
