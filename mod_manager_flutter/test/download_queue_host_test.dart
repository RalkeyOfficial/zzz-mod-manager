import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/download_queue_host.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The half of the queue that has a `BuildContext`.
///
/// Two things are being pinned here, and the first is the one that decides how
/// an install meets the user: **a background install never opens a window by
/// itself.** Where it needs an answer it waits in the panel, frees the install
/// slot, and says so on the one Needs you card; the question is asked only when
/// the user presses the row's button, from this host's context, which outlives
/// the tabs and the panel.
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
    bool turnOn = false,
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
      turnOn: turnOn,
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

  ProviderContainer seeded(List<DownloadJob> jobs, {List<Override> extra = const []}) {
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => queue = _SeededQueue(jobs)),
        ...extra,
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

  late _Gate gate;
  setUp(() => gate = _Gate());

  Future<void> host(WidgetTester t, ProviderContainer container, {InstallQuestionAsker? asker}) async {
    await pumpLocalized(
      t,
      DownloadQueueHost(
        installer: gate.installer,
        asker: asker ?? (context, ref, job) async => fail('nothing asks in this test'),
        child: const SizedBox.shrink(),
      ),
      container: container,
      settle: false,
    );
    // The host reconciles with the queue after its first frame.
    await frames(t);
  }

  DownloadJob jobOf(ProviderContainer container, int seq) =>
      container.read(downloadQueueProvider).firstWhere((j) => j.seq == seq);

  const folders = InstallWaits(InstallWait(InstallQuestion.severalFolders, folderCount: 3), PreparedInstall());

  group('an install that stops at a question', () {
    testWidgets('opens no window: the download waits, frees the slot, and the next install runs', (t) async {
      final container = seeded([job(subject: 'Ellen Swimsuit', characterId: 'ellen'), job()]);
      await host(t, container);
      final working = container.read(notificationsProvider).firstWhere((n) => n.title == 'Installing Ellen Swimsuit');

      gate.release(folders);
      await frames(t);

      expect(find.byType(AlertDialog), findsNothing, reason: 'nothing opens over what the user is doing');
      expect(jobOf(container, 1).state, DownloadJobState.waiting);
      expect(jobOf(container, 1).wait?.folderCount, 3);
      expect(gate.seen.map((j) => j.seq), [1, 2], reason: 'a second install proceeds while one waits');

      final needsYou = container.read(notificationsProvider).singleWhere((n) => n.kind == NotificationKind.needsYou);
      expect(needsYou.id, working.id, reason: "the waiting download's Working card turns into it");
      expect(needsYou.title, 'Waiting for your answer');
      expect(needsYou.body, 'Ellen Swimsuit');
      expect(needsYou.characterId, 'ellen');
      expect(needsYou.deck, isNull, reason: 'a waiting download leaves the deck');
      expect(needsYou.actions.map((a) => a.label), ['Open Downloads']);

      gate.release(InstallEnds(InstallResult.success(const ['Mod 2'])));
      await frames(t);
      expect(jobOf(container, 2).state, DownloadJobState.done);
      expect(jobOf(container, 2).outcome, JobOutcome.installed);
      expect(jobOf(container, 2).installed, ['Mod 2']);
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('the row asks from the host, and the answered download goes ahead of one that has not waited',
        (t) async {
      const answered = PreparedInstall(duplicateAnswered: true);
      final asked = <int>[];
      final container = seeded([job(), job(), job()]);
      await host(t, container, asker: (context, ref, job) async {
        asked.add(job.seq);
        return const AnswerGiven(prepared: answered);
      });

      gate.release(folders);
      await frames(t);
      expect(gate.seen.map((j) => j.seq), [1, 2]);

      await container.read(downloadQuestionsProvider).answer(1);
      await frames(t);
      expect(asked, [1]);
      expect(jobOf(container, 1).state, DownloadJobState.downloaded);
      expect(container.read(notificationsProvider).where((n) => n.kind == NotificationKind.needsYou), isEmpty,
          reason: 'it goes once nothing waits');

      gate.release(InstallEnds(InstallResult.success(const ['Mod 2'])));
      await frames(t);
      expect(gate.seen.map((j) => j.seq), [1, 2, 1], reason: 'ahead of job 3');
      expect(gate.seen.last.prepared, same(answered), reason: 'the answers travel with it');

      gate.release(InstallEnds(InstallResult.success(const ['Mod 1'])));
      await frames(t);
      expect(jobOf(container, 1).state, DownloadJobState.done);
      gate.release(InstallEnds(InstallResult.success(const ['Mod 3'])));
      await frames(t);
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a dialog closed without an answer keeps the download waiting, with the answers before it',
        (t) async {
      const kept = PreparedInstall(duplicateAnswered: true);
      final container = seeded([job()]);
      await host(t, container,
          asker: (context, ref, job) async => const AnswerKept(InstallWait(InstallQuestion.patch), prepared: kept));
      gate.release(folders);
      await frames(t);

      await container.read(downloadQuestionsProvider).answer(1);
      await frames(t);

      expect(jobOf(container, 1).state, DownloadJobState.waiting);
      expect(jobOf(container, 1).wait?.question, InstallQuestion.patch);
      expect(jobOf(container, 1).prepared, same(kept));
      expect(container.read(notificationsProvider).where((n) => n.kind == NotificationKind.needsYou), hasLength(1));
    });

    testWidgets("Don't install ends it: the row leaves the list and the card goes", (t) async {
      final container = seeded([job()]);
      await host(t, container, asker: (context, ref, job) async => const AnswerDeclined());
      gate.release(folders);
      await frames(t);

      // Not awaited: what the job kept is deleted on disk after the row leaves, and a widget test's zone never
      // turns real I/O. The queue's own test covers the delete.
      unawaited(container.read(downloadQuestionsProvider).answer(1));
      await frames(t);

      expect(container.read(downloadQueueProvider), isEmpty);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('several waiting share one card that counts them, with no portrait, moved to the newest place',
        (t) async {
      final container = seeded([job(characterId: 'ellen'), job(), job(state: DownloadJobState.running)]);
      await host(t, container);
      gate.release(folders);
      await frames(t);
      gate.release(folders);
      await frames(t);

      final cards = container.read(notificationsProvider);
      final needsYou = cards.singleWhere((n) => n.kind == NotificationKind.needsYou);
      expect(needsYou.title, '2 downloads are waiting for your answer');
      expect(needsYou.body, 'Mod 1 and Mod 2');
      expect(needsYou.characterId, isNull);
      expect(needsYou.actions.map((a) => a.label), ['Open Downloads'], reason: 'about the list, so it stays');
      expect(cards.last.id, needsYou.id, reason: 'a download joining it is news');
    });

    testWidgets('closed while a download waits, it comes back when another starts waiting', (t) async {
      final container = seeded([job(), job()]);
      await host(t, container);
      gate.release(folders);
      await frames(t);
      final center = container.read(notificationsProvider.notifier);
      center.close(container.read(notificationsProvider).singleWhere((n) => n.kind == NotificationKind.needsYou).id);
      await frames(t);

      gate.release(folders);
      await frames(t);
      final needsYou = container.read(notificationsProvider).singleWhere((n) => n.kind == NotificationKind.needsYou);
      expect(needsYou.title, '2 downloads are waiting for your answer');
    });

    testWidgets('a download whose Working card was hidden still raises it', (t) async {
      final container = seeded([job()]);
      await host(t, container);
      final center = container.read(notificationsProvider.notifier);
      center.close(container.read(notificationsProvider).single.id);
      await frames(t);
      expect(container.read(notificationsProvider), isEmpty);

      gate.release(folders);
      await frames(t);
      expect(container.read(notificationsProvider).single.kind, NotificationKind.needsYou,
          reason: 'hiding the progress never hides what comes of it');
    });

    testWidgets('Open mod page shows the mod in Browse and asks the panel to close, the download still waiting',
        (t) async {
      final container = seeded([job()]);
      await host(t, container, asker: (context, ref, job) async => const AnswerOpenModPage());
      gate.release(const InstallWaits(InstallWait(InstallQuestion.password), PreparedInstall()));
      await frames(t);

      await container.read(downloadQuestionsProvider).answer(1);
      await frames(t);

      expect(container.read(marketplaceOpenModProvider), 1001);
      expect(container.read(destinationProvider), AppDestination.browse);
      expect(container.read(downloadsPanelCloseRequestProvider), 1);
      expect(jobOf(container, 1).state, DownloadJobState.waiting);
    });

    testWidgets('installs one archive at a time', (t) async {
      // The hazard is two unpacks writing into the mods folder through one
      // singleton at once.
      final container = seeded([job(), job()]);
      await host(t, container);

      expect(
        container
            .read(downloadQueueProvider)
            .where((j) => j.state == DownloadJobState.installing),
        hasLength(1),
      );
      expect(gate.seen, hasLength(1));

      gate.release(InstallEnds(InstallResult.success(const ['Installed Mod'])));
      await frames(t);
      expect(container.read(downloadQueueProvider).first.state, DownloadJobState.done);
      expect(gate.seen, hasLength(2));
      gate.release(InstallEnds(InstallResult.success(const ['Installed Mod'])));
      await frames(t);
      await t.pump(const Duration(seconds: 6));
    });
  });

  group('an install that finishes', () {

    InstallEnds installed() => InstallEnds(InstallResult.success(const ['Installed Mod']));

    testWidgets('a lone job turns its Working card into the result', (t) async {
      final container = seeded([job(subject: 'Ellen Swimsuit')]);
      await host(t, container);
      final working = container.read(notificationsProvider).single;
      expect(working.kind, NotificationKind.working);

      gate.release(installed());
      await frames(t);
      final result = container.read(notificationsProvider).single;
      expect(result.id, working.id);
      expect(result.kind, NotificationKind.done);
      expect(result.title, 'Mod installed');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('each download takes its own card to its result as it lands, counted on one card', (t) async {
      final container = seeded([job(), job()]);
      await host(t, container);
      final [first, second] = container.read(notificationsProvider);
      gate.release(installed());
      await frames(t);

      // Nothing waits for the rest of the queue.
      var cards = container.read(notificationsProvider);
      expect(cards.map((n) => (n.id, n.kind)),
          [(second.id, NotificationKind.working), (first.id, NotificationKind.done)]);
      expect(cards.map((n) => n.deck?.key), [kDownloadsDeck, kDownloadsDeck], reason: 'a result is dealt on top');
      expect(cards.last.title, 'Mod installed');

      gate.release(installed());
      await frames(t);
      cards = container.read(notificationsProvider);
      expect(cards.single.id, first.id, reason: "the second result is counted on the first's card");
      expect(cards.single.title, '2 mods installed');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a hidden deck still reports every result, a new download joining or not', (t) async {
      final container = seeded([job(), job()]);
      await host(t, container);
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

      gate.release(installed());
      await frames(t);
      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Ellen Maid', 'Mod installed']);
      gate.release(installed());
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
        installer: (context, ref, job) async =>
            InstallEnds(InstallResult.warning('Nothing to install', "The archive doesn't contain any mod folders.")),
        child: const SizedBox.shrink(),
      ),
      container: container,
      settle: false,
    );
    await frames(t);

    final card = container.read(notificationsProvider).single;
    expect(card.kind, NotificationKind.warning);
    expect(card.hasClock, isTrue);
    final done = container.read(downloadQueueProvider).single;
    expect(done.state, DownloadJobState.done);
    expect(done.outcome, JobOutcome.nothingInstalled);
    expect(done.headline, 'Nothing to install', reason: "the row says the result's headline");
    expect(done.finishedAt, isNotNull);
    await t.pump(const Duration(seconds: 9));
  });

  group('what a job carries to the install', () {
    /// Every enable, as the mod and the mods it was told to turn off.
    late List<(String, Set<String>)> enables;

    setUp(() => enables = []);

    ModEnabler enabler({Object Function(String modId)? refuse, bool Function(String modId)? fails}) =>
        (modId, {switchOff = const [], whileWritten}) async {
          enables.add((modId, switchOff.toSet()));
          if (refuse?.call(modId) case final refusal?) throw refusal;
          return !(fails?.call(modId) ?? false);
        };

    final ellenA = ModInfo(id: 'Ellen A', name: 'Ellen A', characterId: 'ellen', isActive: false);
    final ellenB = ModInfo(id: 'Ellen B', name: 'Ellen B', characterId: 'ellen', isActive: false);
    final oldEllen = ModInfo(id: 'Old Ellen', name: 'Old Ellen', characterId: 'ellen', isActive: true);

    Future<void> pump(WidgetTester t, ProviderContainer container, ArchiveInstaller installer, ModEnabler enabler) async {
      await pumpLocalized(
        t,
        DownloadQueueHost(installer: installer, enabler: enabler, child: const SizedBox.shrink()),
        container: container,
        settle: false,
      );
      await frames(t);
    }

    testWidgets("hands the installer the job's character", (t) async {
      final characters = <String?>[];
      final container = seeded([job(characterId: 'anby')], extra: [libraryOf(const [])]);
      await pump(t, container, _installing(const ['Anby Suit'], characters: characters), enabler());
      expect(characters, ['anby']);
      expect(enables, isEmpty, reason: 'Turn on after installing was off');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets("turns each new mod on after the install, under the character's One at a time", (t) async {
      // The new folders are in the library only once the rescan has read them.
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [_rescanReveals([oldEllen], [oldEllen, ellenA, ellenB])],
      );
      await pump(t, container, _installing(const ['Ellen A', 'Ellen B']), enabler());

      expect(enables.map((e) => e.$1), ['Ellen A', 'Ellen B']);
      expect(enables[0].$2, {'Old Ellen'});
      expect(enables[1].$2, {'Ellen A'}, reason: "the second sees the first on, so one of Ellen's mods stays on");
      expect(container.read(notificationsProvider).single.title, '2 mods installed');
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('an enable that fails leaves the mod installed and says so as a warning, not an error', (t) async {
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [_rescanReveals(const [], [ellenA])],
      );
      await pump(t, container, _installing(const ['Ellen A']), enabler(fails: (_) => true));

      final cards = container.read(notificationsProvider);
      final warning = cards.singleWhere((n) => n.kind == NotificationKind.warning);
      expect(warning.title, 'Installed, but not turned on');
      expect(warning.body, 'Ellen A');
      final result = cards.singleWhere((n) => n.kind == NotificationKind.done);
      expect(result.title, 'Mod installed');
      expect(result.actions.map((a) => a.label), ['Open'], reason: 'the install card keeps its one action');
      expect(cards.where((n) => n.kind == NotificationKind.error), isEmpty);
      expect(container.read(downloadQueueProvider).single.state, DownloadJobState.done);
      await t.pump(const Duration(seconds: 9));
    });

    testWidgets('a new mod the rescan does not find is named as not turned on', (t) async {
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [_rescanReveals(const [], [ellenA])],
      );
      await pump(t, container, _installing(const ['Ellen A', 'Ellen Gone']), enabler());

      expect(enables.map((e) => e.$1), ['Ellen A']);
      final warning = container.read(notificationsProvider).singleWhere((n) => n.kind == NotificationKind.warning);
      expect(warning.body, 'Ellen Gone');
      await t.pump(const Duration(seconds: 9));
    });

    testWidgets('an enable refused for its shader files or a network folder says why, as the Library does', (t) async {
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [_rescanReveals(const [], [ellenA, ellenB])],
      );
      await pump(
        t,
        container,
        _installing(const ['Ellen A', 'Ellen B']),
        enabler(
          refuse: (id) => id == 'Ellen A'
              ? const ShaderPlacementRefused.noShaderFolder('Ellen A')
              : const NetworkLinkRefused('/links/Ellen B', '//nas/mods/Ellen B'),
        ),
      );

      final cards = container.read(notificationsProvider);
      final errors = cards.where((n) => n.kind == NotificationKind.error).map((n) => n.title);
      expect(errors, containsAll(["Couldn't find ZZMI's shader folder", "Couldn't link to a network folder"]));
      expect(cards.where((n) => n.title == 'Installed, but not turned on'), isEmpty,
          reason: 'the refusal is the report, not a second line about the same mod');
      expect(container.read(downloadQueueProvider).single.state, DownloadJobState.done);
      await t.pump(const Duration(seconds: 9));
    });

    testWidgets('waits for a running bulk action before turning anything on', (t) async {
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [_rescanReveals(const [], [ellenA])],
      );
      container.read(allModsBulkRunningProvider.notifier).state = true;
      await pump(t, container, _installing(const ['Ellen A']), enabler());
      expect(enables, isEmpty, reason: 'One at a time is being set by the bulk action');

      container.read(allModsBulkRunningProvider.notifier).state = false;
      await frames(t);
      expect(enables.map((e) => e.$1), ['Ellen A']);
      expect(container.read(downloadQueueProvider).single.state, DownloadJobState.done);
      await t.pump(const Duration(seconds: 6));
    });

    testWidgets('a rescan that throws still finishes the install, naming the mods as not turned on', (t) async {
      final container = seeded(
        [job(characterId: 'ellen', turnOn: true)],
        extra: [libraryProvider.overrideWith(() => _RescanThrows())],
      );
      await pump(t, container, _installing(const ['Ellen A', 'Ellen B']), enabler());

      expect(enables, isEmpty);
      final warning = container.read(notificationsProvider).singleWhere((n) => n.kind == NotificationKind.warning);
      expect(warning.body, 'Ellen A, Ellen B');
      expect(container.read(downloadQueueProvider).single.state, DownloadJobState.done);
      await t.pump(const Duration(seconds: 9));
    });
  });

  group('the Working progress card', () {
    Future<void> pump(WidgetTester t, ProviderContainer container) async {
      await pumpLocalized(
        t,
        DownloadQueueHost(
          // Never reached: every job in these tests is still transferring.
          installer: (context, ref, job) async => fail('nothing in this group should reach the installer'),
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
      unawaited(container.read(downloadQueueProvider.notifier).cancel(1));
      await t.pump();

      expect(container.read(notificationsProvider).map((n) => n.title), ['Installing Mod 2']);
    });

    testWidgets("a paused download's card goes, and Resume raises it again", (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
        ),
      ]);
      await pump(t, container);
      final first = container.read(notificationsProvider).single;

      queue.put(1, DownloadJobState.paused);
      await t.pump();
      expect(container.read(notificationsProvider), isEmpty, reason: 'a spinner would claim work that is not happening');

      container.read(downloadQueueProvider.notifier).resume(1);
      await t.pump();
      final again = container.read(notificationsProvider).single;
      expect(again.title, 'Installing Ellen Swimsuit');
      expect(again.id, isNot(first.id));
    });

    testWidgets("an update download's card goes once its bytes are handed over", (t) async {
      final container = seeded([
        job(
          state: DownloadJobState.running,
          intent: DownloadIntent.callerHandles,
          subject: 'Ellen Swimsuit',
          progress: const DownloadProgress(state: DownloadState.downloading, received: 10, total: 100),
        ),
      ]);
      await pump(t, container);
      expect(container.read(notificationsProvider).single.title, 'Downloading Ellen Swimsuit');

      queue.put(1, DownloadJobState.updating);
      await t.pump();
      expect(container.read(notificationsProvider), isEmpty, reason: 'the update flow reports it');
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

/// An installer whose runs end when the test says, in the order they started: each run waits for the next
/// [release]. Standing in for the unpack and the import, so the host's sequencing is what is under test.
class _Gate {
  final List<Completer<InstallStep>> _pending = [];

  /// Every job a run was started for, in order.
  final List<DownloadJob> seen = [];

  ArchiveInstaller get installer => (context, ref, job) {
        seen.add(job);
        final run = Completer<InstallStep>();
        _pending.add(run);
        return run.future;
      };

  void release(InstallStep step) => _pending.removeAt(0).complete(step);
}

/// An installer that installs [mods] at once, writing down the character it was handed into [characters].
ArchiveInstaller _installing(List<String> mods, {List<String?>? characters}) {
  return (context, ref, job) async {
    characters?.add(job.characterId);
    return InstallEnds(InstallResult.success(mods, characterId: job.characterId));
  };
}

/// A library that reads [before] until its rescan reads [after], as a real one does once an install has written.
Override _rescanReveals(List<ModInfo> before, List<ModInfo> after) =>
    libraryProvider.overrideWith(() => _RevealingLibrary(before, after));

class _RevealingLibrary extends LibraryNotifier {
  _RevealingLibrary(this._before, this._after);

  final List<ModInfo> _before;
  final List<ModInfo> _after;

  @override
  FutureOr<List<ModInfo>> build() => _before;

  @override
  Future<void> rescan() async {
    await Future<void>.value();
    state = AsyncData(_after);
  }
}

class _RescanThrows extends LibraryNotifier {
  @override
  FutureOr<List<ModInfo>> build() => const <ModInfo>[];

  @override
  Future<void> rescan() async => throw const FileSystemException('library unreadable');
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

  /// Moves [seq] to [next], as the real queue does on a pause or a handover.
  void put(int seq, DownloadJobState next) => state = [
        for (final job in state)
          if (job.seq == seq) job.copyWith(state: next) else job,
      ];
}
