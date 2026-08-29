import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import 'downloads_panel.dart';

/// The title bar's downloads indicator, and the only way to the panel.
///
/// **It is absent until there is something to say.** A permanently-present
/// control that is empty on every launch is a control nobody learns; one that
/// appears the moment a transfer starts is itself a sign that the press did
/// something.
///
/// The ring reports *bytes*, not jobs — a 1.2 GB archive and a 4 MB one are not
/// half the work each — and goes indeterminate rather than inventing a number
/// when any active job's size is still unknown. See [aggregateProgress].
class DownloadsButton extends ConsumerWidget {
  const DownloadsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(downloadQueueProvider);
    if (jobs.isEmpty) return const SizedBox.shrink();

    final loc = context.loc;
    final theme = Theme.of(context);
    final active = activeJobCount(jobs);
    // On the **state**, not on whether an error is attached. A cancel is
    // something the user asked for, and turning the title bar red over it says
    // the app broke when it did as it was told.
    final failed = jobs.any((j) => j.state == DownloadJobState.failed);

    return MenuAnchor(
      // No horizontal offset: the panel is wider than the button and sits near
      // the right edge, and Flutter's menu layout already clamps it back inside
      // the window. Nudging it by hand fights that and lands differently at
      // every window width.
      alignmentOffset: const Offset(0, 4),
      menuChildren: const [DownloadsPanel()],
      builder: (context, controller, _) => SizedBox(
        width: 46,
        height: 40,
        child: IconButton(
          tooltip: loc.t('downloads.tooltip'),
          padding: EdgeInsets.zero,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (active > 0)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    value: aggregateProgress(jobs).fraction,
                    strokeWidth: 2,
                  ),
                ),
              Icon(
                active > 0
                    ? Icons.download_rounded
                    : (failed
                        ? Icons.error_outline_rounded
                        : Icons.download_done_rounded),
                size: 14,
                color: failed && active == 0
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
              if (active > 1)
                Positioned(
                  right: -6,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$active',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                        fontSize: 9,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
