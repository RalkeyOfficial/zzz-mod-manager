import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_exceptions.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_progress.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../utils/byte_format.dart';
import 'character_avatar.dart';
import 'own_scroll_controller.dart';

/// The list behind the sidebar's downloads button.
///
/// Everything the app is fetching, in the order it was asked for, plus what has
/// finished this session. It is the detail view for work that is otherwise
/// invisible: the pinned notification says *how far along*, this says *what,
/// exactly, and lets the user change it*.
///
/// **Finished rows stay until they are cleared.** A row that vanished on its own
/// would take the only record of a failure with it, and "it said something and
/// then it was gone" is the shape of a bug report nobody can answer.
class DownloadsPanel extends ConsumerWidget {
  const DownloadsPanel({super.key, this.maxHeight = 380});

  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final jobs = ref.watch(downloadQueueProvider);
    final finished = jobs.where((j) => j.isTerminal).length;

    // A fixed width and a **`SingleChildScrollView`, never a `ListView`.**
    // `MenuAnchor` measures its panel through an `IntrinsicWidth`, and a lazy
    // viewport refuses an intrinsic query outright — instantiating every child
    // is exactly what being lazy avoids. So a `ListView` here asserts during
    // layout (`RenderShrinkWrappingViewport does not support returning intrinsic
    // dimensions`) and takes the whole menu down the first time it is opened.
    // A downloads list is a handful of rows; there is nothing to virtualise.
    return SizedBox(
      width: 380,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    loc.t('downloads.title'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (finished > 0)
                  TextButton(
                    onPressed: () => ref
                        .read(downloadQueueProvider.notifier)
                        .clearFinished(),
                    child: Text(loc.t('downloads.clear_finished')),
                  ),
              ],
            ),
          ),
          if (jobs.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                loc.t('downloads.empty'),
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            Flexible(
              // Its own controller, not the primary one. `MenuAnchor` already
              // wraps its panel in a scroll view of its own, and two of those on
              // the `PrimaryScrollController` is a `Scrollbar` throwing "attached
              // to more than one ScrollPosition" the first time the menu opens.
              child: OwnScrollController(
                builder: (context, controller) => SingleChildScrollView(
                  controller: controller,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final job in jobs)
                        // `jobs` as well as the row's own job: which control a
                        // row offers depends on the rest of the queue — see
                        // [rowAction].
                        DownloadRow(
                            key: ValueKey(job.seq), job: job, jobs: jobs),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One transfer.
///
/// Three lines: what it is, how far along, and what is happening in words. The
/// third is not decoration. A degraded CDN node serves at 0.08 MB/s, and over
/// the twenty-five minute transfer that produces, a bar which has not visibly
/// moved is indistinguishable from a dead one — the rate is what tells them
/// apart. See `docs/downloads.md` §5.
class DownloadRow extends ConsumerWidget {
  const DownloadRow({super.key, required this.job, this.jobs = const []});

  final DownloadJob job;

  /// The whole queue, because [rowAction] needs it: a failure another job is
  /// already re-fetching offers no retry.
  final List<DownloadJob> jobs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final queue = ref.read(downloadQueueProvider.notifier);
    final action = rowAction(job, jobs);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The same three-tier leading slot the notification card uses: a
          // portrait when the mod page filed one, else a neutral glyph. Never a
          // guess from the name.
          CharacterAvatar(
            characterId: job.characterId,
            size: 32,
            background: theme.colorScheme.surfaceContainerHigh,
            fallback: Icon(
              Icons.download_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                if (!job.isTerminal)
                  LinearProgressIndicator(
                    value: _barValue(job),
                    minHeight: 3,
                  ),
                const SizedBox(height: 4),
                Text(
                  _statusLine(loc, job),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: job.state == DownloadJobState.failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          switch (action) {
            DownloadRowAction.cancel => _RowButton(
                icon: Icons.close_rounded,
                tooltip: loc.t('downloads.cancel'),
                onPressed: () => queue.cancel(job.seq),
              ),
            DownloadRowAction.retry => _RowButton(
                icon: Icons.refresh_rounded,
                tooltip: loc.t('downloads.retry'),
                onPressed: () => queue.retry(job.seq),
              ),
            DownloadRowAction.dismiss => _RowButton(
                icon: Icons.clear_rounded,
                tooltip: loc.t('downloads.dismiss'),
                onPressed: () => queue.remove(job.seq),
              ),
            // A fixed-size gap rather than nothing: the row must not reflow when
            // a transfer moves into its install step, which is exactly when the
            // user is watching it.
            DownloadRowAction.none => const SizedBox(width: 40, height: 40),
          },
        ],
      ),
    );
  }

  /// Null gives an indeterminate bar, which is the honest rendering for
  /// "something is happening and no fraction of it is known".
  double? _barValue(DownloadJob job) => switch (job.state) {
        DownloadJobState.queued => 0,
        DownloadJobState.running => job.progress?.fraction,
        // Bytes are all in; what is left is unpacking, which reports nothing.
        DownloadJobState.downloaded => 1,
        DownloadJobState.installing => null,
        _ => null,
      };
}

/// What is happening, in words.
///
/// Deliberately says *waiting for a slot* rather than "queued": the user has one
/// question when nothing is moving, and it is whether the app has forgotten
/// about their download.
String _statusLine(AppLocalizations loc, DownloadJob job) {
  switch (job.state) {
    case DownloadJobState.queued:
      return loc.t('downloads.queued');
    case DownloadJobState.running:
      return _transferLine(loc, job.progress);
    case DownloadJobState.downloaded:
    case DownloadJobState.installing:
      return loc.t('downloads.installing');
    case DownloadJobState.done:
      return job.intent == DownloadIntent.keepArchive
          ? loc.t('downloads.saved')
          : loc.t('downloads.done');
    case DownloadJobState.cancelled:
      return loc.t('downloads.cancelled');
    case DownloadJobState.failed:
      return _failureLine(loc, job.error);
  }
}

String _transferLine(AppLocalizations loc, DownloadProgress? progress) {
  if (progress == null || progress.state == DownloadState.connecting) {
    return loc.t('downloads.connecting');
  }

  final total = progress.total;
  // Without a total there is no percentage to show, only how much has arrived —
  // still more useful than an unmoving indeterminate bar.
  final parts = <String>[
    total == null
        ? formatBytes(progress.received)
        : '${formatBytes(progress.received)} / ${formatBytes(total)}',
  ];

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

/// What went wrong, as specifically as the failure allows.
///
/// A stall is the one transfer failure with a way out, so it says so instead of
/// sharing the generic wording with a 404. And an install failure carries its
/// own message: the bytes arrived fine, so "Download failed" would name the one
/// half that worked.
String _failureLine(AppLocalizations loc, Object? error) => switch (error) {
      InstallFailure(:final message) => message,
      DownloadStalledException() => loc.t('downloads.failed_stalled'),
      DownloadNetworkException() => loc.t('downloads.failed_network'),
      _ => loc.t('downloads.failed'),
    };

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}
