import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/screens/components/downloads_button.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';

import 'support/localized_harness.dart';

/// The surface that replaced the modal progress dialog.
///
/// What matters here is that a backgrounded transfer is still *legible*: the
/// dialog used to be the progress report, and a download the user cannot see is
/// one they will assume failed.
void main() {
  var nextSeq = 0;

  DownloadJob job({
    DownloadJobState state = DownloadJobState.running,
    DownloadIntent intent = DownloadIntent.install,
    String? subject,
    DownloadProgress? progress,
    Object? error,
  }) {
    final seq = ++nextSeq;
    return DownloadJob(
      seq: seq,
      request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/$seq')),
      intent: intent,
      subject: subject ?? 'Mod $seq',
      file: GbFile(idRow: seq),
      state: state,
      progress: progress,
      error: error,
    );
  }

  setUp(() => nextSeq = 0);

  ProviderContainer seeded(List<DownloadJob> jobs) {
    final container = ProviderContainer(
      overrides: [downloadQueueProvider.overrideWith(() => _SeededQueue(jobs))],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the panel', () {
    testWidgets('names every transfer, and says which is waiting', (t) async {
      final container = seeded([
        job(
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 5 * 1024 * 1024,
            total: 20 * 1024 * 1024,
          ),
        ),
        job(subject: 'Miyabi Transfer Student', state: DownloadJobState.queued),
      ]);

      await pumpLocalized(t, const DownloadsPanel(), container: container);
      expectBuilt(DownloadsPanel);

      expect(find.text('Ellen Swimsuit'), findsOneWidget);
      expect(find.text('Miyabi Transfer Student'), findsOneWidget);
      // The sizes, so a bar that has not visibly moved over a slow transfer is
      // still distinguishable from a dead one.
      expect(find.textContaining('5.0 MB / 20.0 MB'), findsOneWidget);
      expect(find.text('Waiting for a free slot'), findsOneWidget);
    });

    testWidgets('a stall says how to get out of it', (t) async {
      // The one recoverable failure, so it must not share its wording with a
      // 404: "try again to resume" is the whole point of the resume machinery.
      final container = seeded([
        job(
          state: DownloadJobState.failed,
          error: const DownloadStalledException(
            'no data',
            stallTimeout: Duration(seconds: 60),
          ),
        ),
      ]);

      await pumpLocalized(t, const DownloadsPanel(), container: container);
      expectBuilt(DownloadsPanel);

      expect(find.textContaining('try again to resume'), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    });

    testWidgets('an install failure says so, and offers no re-download',
        (t) async {
      // The bytes arrived fine; what failed was the unpack. Calling that a
      // download failure names the one half that worked, and the retry it would
      // otherwise earn re-fetches two hundred megabytes to hit the same error.
      final container = seeded([
        job(
          state: DownloadJobState.failed,
          error: const InstallFailure("Couldn't extract the archive"),
        ),
      ]);

      await pumpLocalized(t, const DownloadsPanel(), container: container);
      expectBuilt(DownloadsPanel);

      expect(find.text("Couldn't extract the archive"), findsOneWidget);
      expect(find.text('Download failed'), findsNothing);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
      expect(find.byIcon(Icons.clear_rounded), findsOneWidget);
    });

    testWidgets('offers no control at all mid-install', (t) async {
      // Between the unpack and the import there is no safe stopping point.
      final container = seeded([job(state: DownloadJobState.installing)]);

      // An unpack reports no fraction, so the bar is indeterminate and never
      // settles.
      await pumpLocalized(t, const DownloadsPanel(),
          container: container, settle: false);
      expectBuilt(DownloadsPanel);

      expect(find.text('Installing...'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('clears the finished rows and leaves the rest', (t) async {
      final container = seeded([
        job(state: DownloadJobState.done),
        job(state: DownloadJobState.running),
      ]);

      await pumpLocalized(t, const DownloadsPanel(),
          container: container, settle: false);
      expectBuilt(DownloadsPanel);
      expect(find.text('Mod 1'), findsOneWidget);

      await t.tap(find.text('Clear finished'));
      await t.pump();

      expect(find.text('Mod 1'), findsNothing);
      expect(find.text('Mod 2'), findsOneWidget);
      // And the button itself goes with them, rather than sitting there doing
      // nothing.
      expect(find.text('Clear finished'), findsNothing);
    });

    testWidgets('a long mod name is trimmed, not overflowed', (t) async {
      final container = seeded([
        job(subject: 'A' * 400, state: DownloadJobState.queued),
      ]);

      await pumpLocalized(
        t,
        const Center(child: DownloadsPanel()),
        container: container,
        surfaceSize: const Size(420, 400),
      );
      expectBuilt(DownloadsPanel);
      expect(t.takeException(), isNull);
    });
  });

  group('the title-bar button', () {
    testWidgets('is absent until there is something to report', (t) async {
      final container = seeded(const []);
      await pumpLocalized(t, const DownloadsButton(), container: container);

      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('counts the active jobs once there is more than one',
        (t) async {
      final container = seeded([
        job(),
        job(),
        job(state: DownloadJobState.done),
      ]);
      await pumpLocalized(t, const DownloadsButton(),
          container: container, settle: false);
      expectBuilt(DownloadsButton);

      // Two, not three: a finished row is history, and a badge that keeps
      // counting it says the app is still busy when it is not.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('opens the panel, inside a real menu', (t) async {
      // Not a formality. `MenuAnchor` measures its panel through an
      // `IntrinsicWidth`, and a lazy viewport cannot answer an intrinsic-width
      // query — so a `ListView` in the panel takes the whole menu down the
      // first time it is opened, and every test that mounts the panel *directly*
      // passes anyway.
      final container = seeded([job(state: DownloadJobState.done)]);
      await pumpLocalized(t, const DownloadsButton(), container: container);
      expectBuilt(DownloadsButton);

      await t.tap(find.byType(IconButton));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.text('Mod 1'), findsOneWidget);
    });

    testWidgets('stays put once everything has finished, so a failure can be '
        'read', (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.failed,
          error: const DownloadNetworkException('offline'),
        ),
      ]);
      await pumpLocalized(t, const DownloadsButton(), container: container);
      expectBuilt(DownloadsButton);

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('a cancelled download does not turn the title bar red',
        (t) async {
      // A cancel is the user getting what they asked for. Reading `error` here
      // rather than the state made the button claim the app had broken when it
      // did as it was told — and only for a transfer that had started, since the
      // queued-cancel path never recorded one.
      final container = seeded([job(state: DownloadJobState.cancelled)]);
      await pumpLocalized(t, const DownloadsButton(), container: container);
      expectBuilt(DownloadsButton);

      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    });
  });
}

/// A queue that starts with rows already in it.
///
/// The real one only reaches these states by running downloads, and a widget
/// test that had to fetch something to render a failed row would be testing the
/// transport.
class _SeededQueue extends DownloadQueue {
  _SeededQueue(this._seed);

  final List<DownloadJob> _seed;

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }
}
