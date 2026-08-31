import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// The half of the queue that has a `BuildContext`.
///
/// Two things are being pinned here, and the first is the one that made moving
/// the install worth testing at all: **a background install can still stop and
/// ask.** The dialogs it may raise — the folder picker for an archive with
/// several top-level folders, the "you already have this archive" question —
/// used to run from a screen the tab switcher disposes. They now run from a host
/// mounted above the tabs, and a host that could not raise a dialog would fail
/// silently, on the uncommon archives, minutes after the user pressed Download.
///
/// The second is that it says what is happening while it happens.
void main() {
  var nextSeq = 0;

  DownloadJob job({
    DownloadJobState state = DownloadJobState.downloaded,
    DownloadIntent intent = DownloadIntent.install,
    String? subject,
    String? characterId,
    DownloadProgress? progress,
    int? expectedSize,
  }) {
    final seq = ++nextSeq;
    return DownloadJob(
      seq: seq,
      request: DownloadRequest(
        url: Uri.parse('https://gamebanana.com/dl/$seq'),
        expectedSize: expectedSize,
      ),
      intent: intent,
      subject: subject ?? 'Mod $seq',
      characterId: characterId,
      file: GbFile(idRow: seq),
      mod: GbMod(idRow: 1000 + seq, name: subject ?? 'Mod $seq'),
      state: state,
      progress: progress,
      result: state == DownloadJobState.downloaded
          ? DownloadResult(file: File('/tmp/mod$seq.zip'), totalBytes: 1)
          : null,
    );
  }

  setUp(() => nextSeq = 0);

  late _SeededQueue queue;

  ProviderContainer seeded(List<DownloadJob> jobs) {
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => queue = _SeededQueue(jobs)),
      ],
    );
    addTearDown(container.dispose);
    // Forces the override to build, so `queue` is assigned before a test uses it.
    container.read(downloadQueueProvider);
    return container;
  }

  group('an install that has to ask', () {
    testWidgets('raises its dialog, from a context above the tabs', (t) async {
      final container = seeded([job(subject: 'Ellen Swimsuit')]);

      await pumpLocalized(
        t,
        DownloadQueueHost(
          installer: _askingInstaller('Which folders?'),
          child: const SizedBox.shrink(),
        ),
        container: container,
        settle: false,
      );
      // The host reconciles with the queue after its first frame.
      await t.pumpAndSettle();

      expect(find.text('Which folders?'), findsOneWidget);
    });

    testWidgets('asks about one archive at a time', (t) async {
      // Two dialogs stacked over each other is the visible symptom; the real
      // hazard underneath is two unpacks writing into the mods folder through
      // one singleton at once.
      final container = seeded([job(), job()]);

      await pumpLocalized(
        t,
        DownloadQueueHost(
          installer: _askingInstaller('Which folders?'),
          child: const SizedBox.shrink(),
        ),
        container: container,
        settle: false,
      );
      await t.pumpAndSettle();

      expect(find.text('Which folders?'), findsOneWidget);
      expect(
        container
            .read(downloadQueueProvider)
            .where((j) => j.state == DownloadJobState.installing),
        hasLength(1),
      );

      // Answering the first lets the second through.
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(find.text('Which folders?'), findsOneWidget);
      expect(container.read(downloadQueueProvider).first.state,
          DownloadJobState.done);

      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(find.text('Which folders?'), findsNothing);
    });
  });

  group('the pinned progress notification', () {
    Future<void> pump(WidgetTester t, ProviderContainer container) async {
      await pumpLocalized(
        t,
        DownloadQueueHost(
          // Never reached: every job in these tests is still transferring.
          installer: _neverInstaller,
          child: const SizedBox.shrink(),
        ),
        container: container,
        settle: false,
      );
      // One frame to mount, one for the post-frame reconcile to render.
      await t.pump();
      await t.pump();
    }

    testWidgets('carries the rate and the estimate, and names the mod',
        (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          // A quarter of 2.34 MB in, at 15 KB/s: 1.76 MB left is two minutes.
          // The card's ETA is **derived** from what the queue has left over the
          // combined rate, not copied from a job — the queue finishes when the
          // last byte lands, not when this transfer does.
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 614400,
            total: 2457600,
            bytesPerSecond: 15 * 1024,
          ),
        ),
      ]);
      await pump(t, container);

      // A percentage rather than two byte counts: the card's title has no
      // maxLines and `5.0 MB / 21.9 MB` costs a second line on a 360px card.
      expect(find.textContaining('Downloading'), findsWidgets);
      expect(find.textContaining('25%'), findsOneWidget);
      expect(find.textContaining('15.0 KB/s'), findsOneWidget);
      expect(find.textContaining('2m left'), findsOneWidget);
      expect(find.text('Ellen Swimsuit'), findsOneWidget);
    });

    testWidgets('is one card for the whole queue, not one per download',
        (t) async {
      // Four cards is the cap and it drops the oldest, so a card per job turns a
      // five-mod queue into a wall and pushes off the messages that need
      // reading.
      final container = seeded([
        for (var i = 0; i < 3; i++)
          job(
            state: DownloadJobState.running,
            progress: const DownloadProgress(
              state: DownloadState.downloading,
              received: 10,
              total: 100,
              bytesPerSecond: 1024,
            ),
          ),
      ]);
      await pump(t, container);

      expect(find.textContaining('Downloading 3 mods'), findsOneWidget);
      expect(find.text('3 downloads'), findsOneWidget);
    });

    testWidgets('goes when the queue empties', (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 1,
            total: 100,
          ),
        ),
      ]);
      await pump(t, container);
      expect(find.text('Ellen Swimsuit'), findsOneWidget);

      container.read(downloadQueueProvider.notifier).markDone(1);
      await t.pump();

      // Pinned means "ends on a condition", and this is the condition. What is
      // left to say about a finished install is said by the install itself.
      expect(find.text('Ellen Swimsuit'), findsNothing);
    });

    testWidgets('stays closed once the user closes it', (t) async {
      // Nothing this app puts on screen may be un-dismissable, so a card
      // re-raised on the next progress tick would override them.
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 1,
            total: 100,
          ),
        ),
      ]);
      await pump(t, container);
      expect(find.text('Ellen Swimsuit'), findsOneWidget);

      // Through the queue rather than the close button: the button is the
      // overlay's business and has its own test, and what is under examination
      // here is what the host does *after* the card is gone.
      final center = container.read(notificationsProvider.notifier);
      center.dismiss(container.read(notificationsProvider).single.id);
      await t.pump();
      expect(find.text('Ellen Swimsuit'), findsNothing);

      // A progress tick arrives — and does not bring it back.
      queue.tick();
      await t.pump();
      expect(find.text('Ellen Swimsuit'), findsNothing);
    });
  });
}

/// An installer that raises a dialog and returns whatever the user's answer
/// implies — standing in for the folder picker and the duplicate-archive
/// question, which are the two places a real install stops and asks.
ArchiveInstaller _askingInstaller(String question) {
  return (
    BuildContext context,
    WidgetRef ref, {
    required File archiveFile,
    required GbMod mod,
    required GbFile file,
    String? knownMd5,
    String? requestedName,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return InstallResult.success(const ['Installed Mod']);
  };
}

Future<InstallResult> _neverInstaller(
  BuildContext context,
  WidgetRef ref, {
  required File archiveFile,
  required GbMod mod,
  required GbFile file,
  String? knownMd5,
  String? requestedName,
}) async {
  fail('nothing in this group should reach the installer');
}

class _SeededQueue extends DownloadQueue {
  _SeededQueue(this._seed);

  final List<DownloadJob> _seed;

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }

  /// Re-emits without changing anything — a stand-in for a progress tick, which
  /// the real queue produces twice a second per running transfer.
  void tick() => state = [...state];
}
