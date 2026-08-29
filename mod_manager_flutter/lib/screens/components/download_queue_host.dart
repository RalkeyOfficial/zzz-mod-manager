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
});

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

  /// The one pinned card describing everything in flight.
  NotificationHandle? _progress;

  /// The jobs the card has already been raised for. Its only job is to tell
  /// "the user closed this" apart from "there is nothing to show" — see
  /// [_syncProgressNotification].
  Set<int> _announced = const {};

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
      _syncProgressNotification(jobs);
      unawaited(_drain());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Every list change, not just an arrival: a transfer finishing, a retry, a
    // cancel and every progress tick all change what there is to do and what
    // there is to say.
    ref.listen<List<DownloadJob>>(downloadQueueProvider, (_, jobs) {
      _syncProgressNotification(jobs);
      unawaited(_drain());
    });
    return widget.child;
  }

  // ── Saying what is happening ───────────────────────────────────────────────

  /// Keeps exactly one pinned notification in step with the queue.
  ///
  /// **One card for the whole queue, not one per download.** The stack holds
  /// four and drops the oldest dismissable one, so a card per job turns a
  /// five-mod queue into a wall and pushes off the messages that actually need
  /// reading. The card carries the aggregate; the panel is where a per-mod
  /// breakdown lives.
  ///
  /// Pinned, because the end of a download is an event rather than a moment —
  /// and that is exactly the shape [NotificationCenter.pinned] exists for: the
  /// **body** is the stable subject and only the title is rewritten.
  ///
  /// It is raised when a job the card has not covered yet appears, and updated
  /// from then on. That distinction is what lets the user close it: nothing this
  /// app shows may be un-dismissable, and a card re-raised on the next progress
  /// tick would ignore them. Closing it therefore holds until the next time they
  /// ask for something, which is itself a request to be told about it.
  void _syncProgressNotification(List<DownloadJob> jobs) {
    final progress = aggregateProgress(jobs);
    if (progress.isEmpty) {
      _progress?.dismiss();
      _progress = null;
      _announced = const {};
      return;
    }

    final seqs = {for (final job in progress.active) job.seq};
    final isNew = seqs.difference(_announced).isNotEmpty;
    _announced = seqs;

    final loc = context.loc;
    final title = _progressTitle(loc, progress);
    final only = progress.only;
    final body = only != null
        ? only.subject
        : loc.t('downloads.notification_body_several',
            params: {'count': '${progress.active.length}'});

    final handle = _progress;
    if (handle == null || !handle.isVisible) {
      if (!isNew) return;
      _progress = context.notify.pinned(
        title,
        body: body,
        // A count-bearing message gets no portrait: one arbitrary face would
        // claim the card is about that mod, and which mod sorted first would
        // change between runs. Same rule the bulk reports follow.
        characterId: only?.characterId,
      );
      return;
    }
    handle.update(
      title: title,
      body: body,
      characterId: only?.characterId,
      clearCharacterId: only == null,
      // Without this an update re-clocks nothing, but being explicit is what
      // stops a future severity change quietly giving the card a timer.
      pin: true,
    );
  }

  /// `Downloading 3 mods · 24% · 18 MB/s · 3m left`.
  ///
  /// A **percentage** rather than two byte counts, because the title has no
  /// `maxLines` and wraps: `5.0 MB / 21.9 MB` costs a second line on a 360px
  /// card and says less than `24%` does. The byte figures are a row away in the
  /// panel.
  String _progressTitle(AppLocalizations loc, QueueProgress progress) {
    if (!progress.transferring) {
      return progress.installing
          ? loc.t('downloads.installing')
          : loc.t('downloads.queued');
    }

    final count = progress.active.length;
    final parts = <String>[
      loc.plural('downloads.notification_title', count,
          params: {'count': '$count'}),
    ];

    final fraction = progress.fraction;
    if (fraction != null) {
      parts.add('${(fraction * 100).round()}%');
    } else if (progress.received > 0) {
      // No total to divide by — how much has arrived is still more useful than
      // nothing, and it is the honest answer rather than an invented percentage.
      parts.add(formatBytes(progress.received));
    }

    final rate = progress.bytesPerSecond;
    if (rate != null) {
      parts.add(loc.t('marketplace.download_rate',
          params: {'rate': formatBytes(rate.round())}));
    }
    final eta = progress.eta;
    if (eta != null && eta > Duration.zero) {
      parts.add(loc.t('marketplace.download_eta',
          params: {'time': formatDuration(eta)}));
    }
    return parts.join(' · ');
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
      context.notify.success(
        context.loc.t('marketplace.download_saved_title'),
        body: archive.path,
        characterId: job.characterId,
      );
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
      );
    } catch (error) {
      queue.markFailed(job.seq, InstallFailure('$error'));
      if (!mounted) return;
      // The mod is new; nothing was updated — so not the update flow's wording.
      context.notify.error(
        context.loc.t('marketplace.install_failed_title'),
        body: job.subject,
        characterId: job.characterId,
      );
      return;
    }

    if (!mounted) return;
    showInstallResult(context, result);

    // The library just changed, and the "in library" badges on the marketplace
    // grid are drawn from that snapshot. Invalidate rather than patch: the mod
    // folder's final name is decided by the import (dedup, the combined-name
    // dialog), so re-reading is the only way to be right about it.
    ref.invalidate(installedModsIndexProvider);

    if (result.mods.isNotEmpty) {
      queue.markDone(job.seq);
    } else if (result.failureSeverity == NotificationSeverity.error) {
      queue.markFailed(
        job.seq,
        InstallFailure(
          result.failure?.title ?? context.loc.t('downloads.failed_install'),
        ),
      );
    } else if (result.failure != null) {
      // A warning that installed nothing — every folder already existed, the
      // archive was empty. Nothing to retry and nothing went wrong.
      queue.markDone(job.seq);
    } else {
      queue.markCancelled(job.seq);
    }
  }
}
