import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/dialogs/progress_modal.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';

import 'support/localized_harness.dart';

/// **The one window the user waits in**, from pressing the button to being
/// asked the next question.
///
/// What is worth pinning is the property the whole thing exists for: it does
/// not close between the download finishing and the work that follows it. A
/// modal that closes is the same signal the user gets when a job is done, and
/// the silence after it is long enough on a big archive to read as one.
void main() {
  ValueNotifier<DownloadProgress> arriving() => ValueNotifier(
        const DownloadProgress(
          state: DownloadState.downloading,
          received: 500000,
          total: 1000000,
        ),
      );

  Future<ProgressHold> pump(
    WidgetTester tester, {
    Size surfaceSize = const Size(1200, 800),
  }) async {
    final hold = ProgressHold();
    addTearDown(hold.dispose);
    await pumpLocalized(
      tester,
      ProgressModal(
        progress: arriving(),
        onCancel: () {},
        hold: hold,
      ),
      surfaceSize: surfaceSize,
      // A progress bar animates forever, so settling never returns — the
      // harness's own note on this parameter.
      settle: false,
    );
    return hold;
  }

  testWidgets('shows the transfer while bytes are arriving', (tester) async {
    await pump(tester);
    expectBuilt(AlertDialog);

    expect(find.text('Downloading...'), findsOneWidget);
    expect(find.textContaining(' / '), findsOneWidget,
        reason: 'how much has arrived, of how much');
    expect(find.text('Cancel download'), findsOneWidget);
  });

  testWidgets('carries on into a preparing phase in the same window',
      (tester) async {
    // The property this exists for. Not a second dialog: one window, two
    // phases, so nothing on screen ever says "finished" while the app is still
    // working.
    final hold = await pump(tester);

    hold.handOver(() {});
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Preparing...'), findsOneWidget);
    expect(find.text('Downloading...'), findsNothing);
  });

  testWidgets('offers no cancel once it is preparing', (tester) async {
    // Gone rather than disabled: unpacking cannot be stopped half way and
    // leave anything usable, and a dead control invites the press that proves
    // it is dead.
    final hold = await pump(tester);

    hold.handOver(() {});
    await tester.pump();

    expect(find.text('Cancel download'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('says which piece of work is running, and updates',
      (tester) async {
    // A live line rather than one static sentence: the wait is two different
    // pieces of work, and saying which is the difference between "something is
    // running" and "this is what is running".
    final hold = await pump(tester);
    hold.handOver(() {});
    await tester.pump();

    expect(find.text('Getting the download ready.'), findsOneWidget,
        reason: 'the fallback, before anything says otherwise');

    hold.say('Unpacking the download.');
    await tester.pump();
    expect(find.text('Unpacking the download.'), findsOneWidget);

    hold.say('Checking what this changes in the mod folder.');
    await tester.pump();
    expect(find.text('Checking what this changes in the mod folder.'),
        findsOneWidget);
    expect(find.text('Unpacking the download.'), findsNothing);
  });

  testWidgets('the bar keeps moving with no total to measure against',
      (tester) async {
    // An indeterminate bar is the honest answer while unpacking, which reports
    // no progress of its own.
    final hold = await pump(tester);
    hold.handOver(() {});
    await tester.pump();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
  });

  testWidgets('releasing takes it down exactly once', (tester) async {
    // Every path in the flows above releases it, and the `finally` releases it
    // again — so a second call has to be harmless.
    final hold = await pump(tester);
    var closes = 0;
    hold.handOver(() => closes++);

    hold.release();
    hold.release();
    hold.dispose();

    expect(closes, 1);
  });

  testWidgets('it fits the narrowest window', (tester) async {
    final hold = await pump(tester, surfaceSize: const Size(480, 900));
    hold.handOver(() {});
    hold.say('Checking what this changes in the mod folder.');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
