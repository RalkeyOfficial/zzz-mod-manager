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
/// run from a host mounted above the tabs, since the tab switcher disposes a
/// tab's screen, and a host that could not raise a dialog would fail silently,
/// on the uncommon archives, minutes after the user pressed Download.
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

  /// Fixed frames rather than settling: the Working card's spinner and sweep repeat for as long as it shows.
  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
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
      await frames(t);

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
      await frames(t);

      expect(find.text('Which folders?'), findsOneWidget);
      expect(
        container
            .read(downloadQueueProvider)
            .where((j) => j.state == DownloadJobState.installing),
        hasLength(1),
      );

      // Answering the first lets the second through.
      await t.tap(find.text('OK'));
      await frames(t);
      expect(find.text('Which folders?'), findsOneWidget);
      expect(container.read(downloadQueueProvider).first.state,
          DownloadJobState.done);

      await t.tap(find.text('OK'));
      await frames(t);
      expect(find.text('Which folders?'), findsNothing);
    });

    testWidgets('a lone job turns its Working card into the result', (t) async {
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
      await frames(t);
      final working = container.read(notificationsProvider).single;
      expect(working.kind, NotificationKind.working);

      await t.tap(find.text('OK'));
      await frames(t);
      final result = container.read(notificationsProvider).single;
      expect(result.id, working.id);
      expect(result.kind, NotificationKind.done);
      expect(result.title, 'Mod installed');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('each download takes its own card to its result as it lands, counted on one card', (t) async {
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
      await frames(t);
      final [first, second] = container.read(notificationsProvider);
      await t.tap(find.text('OK'));
      await frames(t);

      // Nothing waits for the rest of the queue.
      var cards = container.read(notificationsProvider);
      expect(cards.map((n) => (n.id, n.kind)),
          [(second.id, NotificationKind.working), (first.id, NotificationKind.done)]);
      expect(cards.map((n) => n.deck?.key), [kDownloadsDeck, kDownloadsDeck], reason: 'a result is dealt on top');
      expect(cards.last.title, 'Mod installed');

      await t.tap(find.text('OK'));
      await frames(t);
      cards = container.read(notificationsProvider);
      expect(cards.single.id, first.id, reason: "the second result is counted on the first's card");
      expect(cards.single.title, '2 mods installed');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a hidden deck still reports every result, a new download joining or not', (t) async {
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
      await frames(t);
      final center = container.read(notificationsProvider.notifier);
      for (final card in [...container.read(notificationsProvider)]) {
        center.close(card.id);
      }
      await frames(t);
      expect(container.read(notificationsProvider), isEmpty);

      queue.state = [
        ...queue.state,
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Maid',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 1, total: 100),
        ),
      ];
      await frames(t);
      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Ellen Maid'],
          reason: 'a new download raises its own card; the hidden ones stay hidden');

      await t.tap(find.text('OK'));
      await frames(t);
      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Ellen Maid', 'Mod installed']);
      await t.tap(find.text('OK'));
      await frames(t);
      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Ellen Maid', '2 mods installed']);
      await t.pump(const Duration(seconds: 6));
    });
  });

  testWidgets('an empty archive is a timed warning, and its download is marked done, not failed', (t) async {
    final container = seeded([job(subject: 'Ellen Swimsuit')]);

    await pumpLocalized(
      t,
      DownloadQueueHost(
        installer: (context, ref, {required archiveFile, required mod, required file, knownMd5, requestedName}) async =>
            InstallResult.warning('Nothing to install', "The archive doesn't contain any mod folders."),
        child: const SizedBox.shrink(),
      ),
      container: container,
      settle: false,
    );
    await frames(t);

    final card = container.read(notificationsProvider).single;
    expect(card.kind, NotificationKind.warning);
    expect(card.hasClock, isTrue);
    expect(container.read(downloadQueueProvider).single.state, DownloadJobState.done);
    await t.pump(const Duration(seconds: 9));
  });

  group('the Working progress card', () {
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

    testWidgets('names the mod in its title, and how far it is under it',
        (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(
            state: DownloadState.downloading,
            received: 614400,
            total: 2457600,
            bytesPerSecond: 15 * 1024,
          ),
        ),
      ]);
      await pump(t, container);

      final card = container.read(notificationsProvider).single;
      expect(card.title, 'Installing Ellen Swimsuit');
      expect(card.body, startsWith('Downloading · '));
      expect(card.body, contains(' of '));
      expect(card.progress, 0.25, reason: "the bar is the queue's fraction");
    });

    testWidgets('draws the sweep while a size is unknown', (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 10),
        ),
      ]);
      await pump(t, container);

      expect(container.read(notificationsProvider).single.progress, isNull);
      expect(find.byKey(const ValueKey('notification-sweep')), findsOneWidget);
    });

    testWidgets('deals one card per download into one deck, the oldest in front', (t) async {
      final container = seeded([
        for (var i = 0; i < 3; i++)
          job(
            state: i == 2 ? DownloadJobState.queued : DownloadJobState.running,
            characterId: i == 0 ? 'ellen' : null,
            expectedSize: 100,
            progress: i == 2
                ? null
                : const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
          ),
      ]);
      await pump(t, container);

      final cards = container.read(notificationsProvider);
      expect(cards.map((n) => n.title), ['Installing Mod 1', 'Installing Mod 2', 'Installing Mod 3']);
      expect(cards.map((n) => n.body), [startsWith('Downloading · '), startsWith('Downloading · '), 'Waiting for a free slot']);
      expect(cards.map((n) => n.progress), [0.1, 0.1, 0.0], reason: "each bar is its own download's share");
      expect(cards.map((n) => n.characterId), ['ellen', null, null]);
      expect(cards.map((n) => n.deck?.key), List.filled(3, kDownloadsDeck));
      expect(cards.every((n) => n.actions.isEmpty), isTrue);

      // On screen: the front card in full, the other two under it.
      expect(find.text('Installing Mod 1'), findsOneWidget);
      expect(find.text('Installing Mod 2'), findsNothing);
      expect(find.text('2 more downloading'), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-ghost-2')), findsOneWidget);
    });

    testWidgets('a second download joins the deck behind the first, whose card stays', (t) async {
      DownloadJob running(String subject) => job(
            state: DownloadJobState.running,
            subject: subject,
            characterId: 'ellen',
            progress: const DownloadProgress(state: DownloadState.downloading, received: 50, total: 100),
          );
      final container = seeded([running('Ellen Swimsuit')]);
      await pump(t, container);
      final lone = container.read(notificationsProvider).single;
      expect(lone.characterId, 'ellen');
      expect(find.byKey(const ValueKey('notification-ghost-1')), findsNothing);

      queue.state = [...queue.state, running('Ellen Maid')];
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final cards = container.read(notificationsProvider);
      expect(cards.first, lone.copyWith(), reason: 'the first card is untouched');
      expect(cards.last.title, 'Installing Ellen Maid');
      expect(find.text('Installing Ellen Swimsuit'), findsOneWidget);
      expect(find.text('Installing Ellen Maid'), findsNothing);
      expect(find.text('1 more downloading'), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-ghost-1')), findsOneWidget);
    });

    testWidgets('a failed transfer among several leaves the deck as its own error', (t) async {
      final container = seeded([
        for (var i = 0; i < 2; i++)
          job(
            state: DownloadJobState.running,
            progress: const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
          ),
      ]);
      await pump(t, container);
      final failing = container.read(notificationsProvider).first;
      container.read(downloadQueueProvider.notifier).markFailed(1, StateError('stalled'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final cards = container.read(notificationsProvider);
      expect(cards.map((n) => n.kind), [NotificationKind.working, NotificationKind.error]);
      expect(cards.last.id, failing.id, reason: "the download's own card turns into it");
      expect(cards.last.deck, isNull);
      expect(cards.last.title, "Couldn't download the mod");
      expect(cards.last.body, 'Mod 1');
      expect(cards.last.actions.map((a) => a.label), ['Try again', 'Open Downloads']);
      expect(cards.first.title, 'Installing Mod 2');
      // Both on screen: the error is not folded into the deck.
      expect(find.text("Couldn't download the mod"), findsOneWidget);
      expect(find.text('Installing Mod 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-deck-line')), findsNothing);

      queue.tick();
      await t.pump();
      expect(container.read(notificationsProvider), hasLength(2), reason: 'reported once');
    });

    testWidgets("a cancelled download's card goes, and the rest of the deck stays", (t) async {
      final container = seeded([
        for (var i = 0; i < 2; i++)
          job(
            state: DownloadJobState.running,
            progress: const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
          ),
      ]);
      await pump(t, container);
      container.read(downloadQueueProvider.notifier).markCancelled(1);
      await t.pump();

      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Mod 2']);
    });

    testWidgets('a download that failed as it was queued is left to the button that queued it', (t) async {
      final container = seeded([job(state: DownloadJobState.failed)]);
      await pump(t, container);
      queue.tick();
      await t.pump();
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets("a lone download's failed transfer becomes its error in place", (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
        ),
      ]);
      await pump(t, container);
      final working = container.read(notificationsProvider).single;
      container.read(downloadQueueProvider.notifier).markFailed(1, StateError('stalled'));
      await t.pump();

      final card = container.read(notificationsProvider).single;
      expect(card.id, working.id);
      expect(card.kind, NotificationKind.error);
      expect(card.body, 'Ellen Swimsuit');
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
      expect(find.text('Installing Ellen Swimsuit'), findsOneWidget);

      container.read(downloadQueueProvider.notifier).markDone(1);
      await t.pump();

      // A Working card ends on a condition, and this is the condition. What is
      // left to say about a finished install is said by the install itself.
      expect(find.text('Installing Ellen Swimsuit'), findsNothing);
    });

    testWidgets('stays hidden once the user hides it', (t) async {
      // A card re-raised on the next progress tick would override them.
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
      expect(find.text('Installing Ellen Swimsuit'), findsOneWidget);

      // Through the queue rather than the close button: the button is the
      // overlay's business and has its own test, and what is under examination
      // here is what the host does *after* the card is gone.
      final center = container.read(notificationsProvider.notifier);
      center.close(container.read(notificationsProvider).single.id);
      await t.pump();
      expect(find.text('Installing Ellen Swimsuit'), findsNothing);

      // A progress tick arrives — and does not bring it back.
      queue.tick();
      await t.pump();
      expect(find.text('Installing Ellen Swimsuit'), findsNothing);
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
