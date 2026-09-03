import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/screens/dialogs/download_with_progress.dart';
import 'package:mod_manager_flutter/screens/dialogs/progress_modal.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';

import 'support/localized_harness.dart';

/// **The modal does not close when the bytes land.**
///
/// This is the whole point of the wait modal and it cannot be seen from the
/// widget alone: what makes the window survive is the download handing its
/// closer over instead of using it. A version that closes here looks correct in
/// every widget test and leaves the user staring at their mod list while the
/// archive is unpacked — which is what the modal exists to stop.
void main() {
  const file = GbFile(idRow: 42, file: 'ellen_v2.zip');

  late _StubQueue queue;

  /// Presses a button that runs one foreground download, with or without a
  /// hold, and hands back what it returned.
  Future<List<DownloadResult?>> press(
    WidgetTester tester, {
    required ProgressHold? hold,
  }) async {
    final returned = <DownloadResult?>[];
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () async {
            returned.add(await downloadFileWithProgress(
              context,
              ref,
              file,
              subject: 'Ellen',
              hold: hold,
            ));
          },
          child: const Text('go'),
        ),
      ),
      overrides: [downloadQueueProvider.overrideWith(() => queue = _StubQueue())],
      // A progress bar animates forever, so settling never returns.
      settle: false,
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    return returned;
  }

  testWidgets('with a hold, it stays up and says it is preparing',
      (tester) async {
    final hold = ProgressHold();
    await press(tester, hold: hold);

    expect(find.text('Downloading...'), findsOneWidget);

    queue.finish();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'the same window, not a new one and not none');
    expect(find.text('Preparing...'), findsOneWidget);

    // Released inside the test, not in a tear-down: popping a route while the
    // navigator is being torn down trips its own assertion, which reports as a
    // failure of whatever ran last.
    hold.release();
    await tester.pump();
    hold.dispose();
  });

  testWidgets('the caller is what finally takes it down', (tester) async {
    final hold = ProgressHold();
    await press(tester, hold: hold);

    queue.finish();
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    hold.release();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
    hold.dispose();
  });

  testWidgets('with no hold it closes itself, as it always did',
      (tester) async {
    // The marketplace's own use: nothing follows the transfer, so leaving a
    // modal up would be the bug in the other direction.
    await press(tester, hold: null);

    expect(find.text('Downloading...'), findsOneWidget);

    queue.finish();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a cancelled download closes even with a hold', (tester) async {
    // Nothing landed, so there is nothing to prepare — and the caller returns
    // without ever releasing.
    final hold = ProgressHold();
    await press(tester, hold: hold);

    queue.cancelled();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
    hold.dispose();
  });
}

/// One queued job whose completion the test decides.
class _StubQueue extends DownloadQueue {
  final _completer = Completer<DownloadResult>();
  final _progress = StreamController<DownloadProgress>.broadcast();

  @override
  List<DownloadJob> build() {
    super.build();
    return const <DownloadJob>[];
  }

  @override
  DownloadJob enqueue({
    required GbFile file,
    required String subject,
    required DownloadIntent intent,
    GbMod? mod,
    String? characterId,
  }) =>
      DownloadJob(
        seq: 1,
        request: DownloadRequest(url: Uri()),
        intent: intent,
        subject: subject,
        file: file,
        state: DownloadJobState.running,
        progress: const DownloadProgress(
          state: DownloadState.downloading,
          received: 10,
          total: 100,
        ),
      );

  @override
  Future<DownloadResult> completionOf(int seq) => _completer.future;

  @override
  Stream<DownloadProgress> progressOf(int seq) => _progress.stream;

  @override
  Future<void> cancel(int seq) async {}

  @override
  void remove(int seq) {}

  void finish() => _completer.complete(
        DownloadResult(file: File('/tmp/ellen_v2.zip'), totalBytes: 100),
      );

  void cancelled() =>
      _completer.completeError(DownloadCancelledException());
}
