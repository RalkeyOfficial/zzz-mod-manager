import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/install_result.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../utils/byte_format.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../dialogs/install_archive_flow.dart';
import 'install_result_feedback.dart';

/// What turns a downloaded archive into a mod. The real one is
/// [installArchiveFlow]; a test substitutes its own so the host's sequencing can
/// be exercised without 7z, a mods folder or the network.
typedef ArchiveInstaller = Future<InstallResult> Function(
  BuildContext context,
  WidgetRef ref, {
  required File archiveFile,
  required GbMod mod,
  required GbFile file,
  String? knownMd5,
  String? requestedName,
});

/// The deck every download's card is dealt into, so downloads running at once take one slot of the stack.
const String kDownloadsDeck = 'downloads';

/// Finishes what the download queue starts, and reports it while it runs.
///
/// The queue moves bytes and stops; everything after — unpacking, importing,
/// saying what is happening — needs localized strings and can raise a dialog,
/// and a `Notifier` has neither. This is the half that has both.
///
/// **Where it is mounted is the whole design.** It wraps the tab switcher rather
/// than living inside a tab, because the three tabs are keyed `AnimatedSwitcher`
/// children with no keep-alive and are therefore *disposed* when the user moves
/// between them — so an install owned by a tab dies on the first tab switch,
/// silently, with the archive already downloaded.
///
/// It must also sit **below** the `Navigator`: `showDialog` needs one as an
/// ancestor, so unlike `NotificationHost` this cannot go in
/// `MaterialApp.builder`.
///
/// **One job at a time.** Installing runs `7z`, writes into the mods folder
/// through a service held as a singleton, and can ask a question. Two of those
/// interleaving would race on all three, and two dialogs would stack.
class DownloadQueueHost extends ConsumerStatefulWidget {
  const DownloadQueueHost({
    super.key,
    required this.child,
    this.installer = installArchiveFlow,
  });

  final Widget child;

  /// Seam for tests. Production is [installArchiveFlow].
  final ArchiveInstaller installer;

  @override
  ConsumerState<DownloadQueueHost> createState() => _DownloadQueueHostState();
}

class _DownloadQueueHostState extends ConsumerState<DownloadQueueHost> {
  /// Whether a drain loop is already running. The guard, not a queue of its own:
  /// the loop re-reads the list every turn, so anything that arrives while it is
  /// working is picked up by the next iteration rather than needing to be
  /// remembered.
  bool _draining = false;

  /// Each download's Working card, by the job's `seq`, from the moment it is
  /// raised until its result takes the card over or the job leaves the queue.
  /// A card the user hid stays here, so its result still arrives.
  final Map<int, NotificationHandle> _cards = {};

  @override
  void initState() {
    super.initState();
    // Reconcile with whatever the queue already holds, rather than waiting for
    // the next change. Nothing is in flight on a cold start, but a hot reload
    // rebuilds this host under a live queue, and reacting only to changes would
    // leave a running download with no card and an already-downloaded job with
    // nothing to install it.
    //
    // **After the frame, not during it.** Both calls below write to providers,
    // and Riverpod refuses that while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final jobs = ref.read(downloadQueueProvider);
      _syncCards(jobs);
      unawaited(_drain());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every list change, not just an arrival: a transfer finishing, a retry, a
    // cancel and every progress tick all change what there is to do and what
    // there is to say.
    ref.listen<List<DownloadJob>>(downloadQueueProvider, (_, jobs) {
      _syncCards(jobs);
      unawaited(_drain());
    });
    return widget.child;
  }

  // ── Saying what is happening ───────────────────────────────────────────────

  /// Keeps one Working card per download in step with the queue, its bar the
  /// download's own share and a sweep while its size is unknown.
  ///
  /// **One card per download, dealt into one deck.** Every card joins the
  /// [kDownloadsDeck] deck, which the stack draws as one slot: the front card in
  /// full, "2 more downloading" under it, and the others' edges above it. So a
  /// five-mod queue never takes every visible slot and folds an error under
  /// "+N more", and one download looks the same as several.
  ///
  /// A card is raised when its download becomes active and updated from then
  /// on, so hiding it holds: a card re-raised on the next progress tick would
  /// ignore the user. A hidden card still takes its result, which comes back as
  /// a card. Each download's result takes its own card over the moment it
  /// lands, without waiting for the rest of the queue.
  void _syncCards(List<DownloadJob> jobs) {
    _reportFailedTransfers(jobs);

    final active = {
      for (final job in jobs)
        if (job.state.isActive) job.seq: job,
    };
    // Gone without a result: cancelled, cleared, or handed to the flow that
    // owns it, which reports it itself.
    for (final seq in [..._cards.keys]) {
      if (!active.containsKey(seq)) _cards.remove(seq)!.dismiss();
    }

    final loc = context.loc;
    final notify = context.notify;
    for (final job in active.values) {
      final title = _loneTitle(loc, job);
      final body = _loneBody(loc, job);
      final fraction = aggregateProgress([job]).fraction;
      final card = _cards[job.seq];
      if (card == null) {
        _cards[job.seq] = notify.working(
          title,
          body: body,
          characterId: job.characterId,
          progress: fraction,
          deck: NotificationDeck(
            kDownloadsDeck,
            more: (count) => loc.plural('downloads.deck_more', count,
                params: {'count': '$count'}),
          ),
        );
      } else {
        card.update(
          title: title,
          body: body,
          progress: fraction,
          clearProgress: fraction == null,
        );
      }
    }
  }

  /// A transfer that failed gets a card of its own, since the panel row is
  /// otherwise the only place it is said. The download's card becomes it, and
  /// leaves the deck as its own card.
  ///
  /// Install failures are reported where the install ran, a download the
  /// update flow owns is reported by that flow, and one that failed as it was
  /// queued, which never had a card, by the button that queued it.
  void _reportFailedTransfers(List<DownloadJob> jobs) {
    for (final job in jobs) {
      if (job.state != DownloadJobState.failed ||
          job.error is InstallFailure ||
          job.intent == DownloadIntent.callerHandles ||
          !_cards.containsKey(job.seq)) {
        continue;
      }
      final loc = context.loc;
      final container = ProviderScope.containerOf(context, listen: false);
      final actions = [
        if (rowAction(job, jobs) == DownloadRowAction.retry)
          retryAction(loc,
              () => container.read(downloadQueueProvider.notifier).retry(job.seq)),
        openDownloadsAction(loc, container),
      ];
      _takeCardFor(job)!.update(
        kind: NotificationKind.error,
        title: loc.t('downloads.failed_title'),
        body: job.subject,
        characterId: job.characterId,
        clearCharacterId: job.characterId == null,
        actions: actions,
      );
    }
  }

  /// [job]'s card, handed over to its result. The host lets go of it, so the
  /// job leaving the queue does not dismiss the result.
  NotificationHandle? _takeCardFor(DownloadJob job) => _cards.remove(job.seq);

  /// `Installing Victorian Ballgown`, or `Downloading …` for a download that
  /// installs nothing here: one kept as an archive, or one the update flow
  /// writes. The mod stays in the title while the line under it moves on.
  static String _loneTitle(AppLocalizations loc, DownloadJob job) =>
      loc.t(
        job.intent == DownloadIntent.install
            ? 'downloads.lone_title_installing'
            : 'downloads.lone_title_downloading',
        params: {'mod': job.subject},
      );

  /// Where the one download is: `Waiting for a free slot`,
  /// `Downloading · 64.0 MB of 214.0 MB`, then `Unpacking`. The bar shows
  /// the share.
  static String _loneBody(AppLocalizations loc, DownloadJob job) {
    switch (job.state) {
      case DownloadJobState.queued:
        return loc.t('downloads.queued');
      case DownloadJobState.running:
        final received = job.progress?.received ?? 0;
        final total = job.progress?.total ?? job.request.expectedSize;
        if (received == 0) return loc.t('downloads.connecting');
        // No total to divide by: how much has arrived is the honest answer.
        if (total == null || total <= 0) {
          return loc.t('downloads.stage_downloading_bytes',
              params: {'received': formatBytes(received)});
        }
        return loc.t('downloads.stage_downloading', params: {
          'received': formatBytes(received),
          'total': formatBytes(total),
        });
      default:
        return loc.t('downloads.stage_unpacking');
    }
  }

  // ── Finishing the work ─────────────────────────────────────────────────────

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (mounted) {
        // Claim-and-mark in one call: as two steps a rebuild between them could
        // hand the same job to a second pass.
        final job = ref.read(downloadQueueProvider.notifier).claimNextForHost();
        if (job == null) return;
        await _handle(job);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _handle(DownloadJob job) async {
    final queue = ref.read(downloadQueueProvider.notifier);
    final archive = job.archive;
    if (archive == null) {
      // Only reachable through a bug: nothing reaches `downloaded` without a
      // result. Failing loudly in the panel beats leaving a row that never
      // moves again.
      queue.markFailed(job.seq, StateError('downloaded job with no archive'));
      return;
    }

    if (job.intent == DownloadIntent.keepArchive) {
      // A file the user cannot see arriving in a folder they would have to go
      // and look at — the case the notification rules keep a *success* message
      // for. The body is the path because the path is the whole point.
      final loc = context.loc;
      final title = loc.t('marketplace.download_saved_title');
      final actions = [openFolderAction(loc, context.notify, archive.parent.path)];
      final card = _takeCardFor(job);
      if (card != null) {
        card.update(
          kind: NotificationKind.done,
          title: title,
          body: archive.path,
          characterId: job.characterId,
          clearCharacterId: job.characterId == null,
          actions: actions,
        );
      } else {
        context.notify.done(title,
            body: archive.path, characterId: job.characterId, actions: actions);
      }
      queue.markDone(job.seq);
      return;
    }

    final mod = job.mod;
    if (mod == null) {
      queue.markFailed(job.seq, StateError('install job with no mod page'));
      return;
    }

    InstallResult result;
    try {
      result = await widget.installer(
        context,
        ref,
        archiveFile: archive,
        mod: mod,
        file: job.file,
        // Free during the download and unrecoverable afterwards — the archive is
        // deleted once unpacked and a zip cannot be reproduced from its
        // contents.
        knownMd5: job.result?.md5,
        // What the download asked to be called, which is not always what it
        // ended up called: a name already taken in the downloads folder becomes
        // `mod (2).rar`, and for an archive with no folder inside it that would
        // become the mod's name.
        requestedName: job.result?.requestedName,
      );
    } catch (error) {
      // Taken before the queue changes, or the job leaving it dismisses it.
      final card = _takeCardFor(job);
      queue.markFailed(job.seq, InstallFailure('$error'));
      if (!mounted) return;
      // The mod is new; nothing was updated — so not the update flow's wording.
      final loc = context.loc;
      final title = loc.t('marketplace.install_failed_title');
      // The panel's row holds what the install said went wrong.
      final actions = [
        openDownloadsAction(loc, ProviderScope.containerOf(context, listen: false)),
      ];
      if (card != null) {
        card.update(
          kind: NotificationKind.error,
          title: title,
          body: job.subject,
          characterId: job.characterId,
          clearCharacterId: job.characterId == null,
          actions: actions,
        );
      } else {
        context.notify.error(title,
            body: job.subject, characterId: job.characterId, actions: actions);
      }
      return;
    }

    if (!mounted) return;
    showInstallResult(
      context,
      result,
      into: _takeCardFor(job),
      characterId: job.characterId,
    );

    // The library just changed, and both the Library's grid and the
    // marketplace's "in library" badges are drawn from it. Invalidate rather
    // than patch: the mod folder's final name is decided by the import (dedup,
    // the combined-name dialog), so re-reading is the only way to be right
    // about it.
    ref.invalidate(libraryProvider);

    if (result.mods.isNotEmpty) {
      queue.markDone(job.seq);
    } else if (result.failureKind == NotificationKind.error) {
      queue.markFailed(
        job.seq,
        InstallFailure(
          result.failure?.title ?? context.loc.t('downloads.failed_install'),
        ),
      );
    } else if (result.failure != null) {
      // An install that put nothing in: every folder already existed (a note),
      // or the archive held no mod folder (a warning). Nothing to retry and
      // nothing failed.
      queue.markDone(job.seq);
    } else {
      queue.markCancelled(job.seq);
    }
  }
}
