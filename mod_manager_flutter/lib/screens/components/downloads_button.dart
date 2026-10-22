import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../utils/state_providers.dart';
import 'downloads_panel.dart';
import 'sidebar_nav_item.dart';

/// The sidebar's Downloads row, and the way to the panel.
///
/// One badge at a time, the first that applies (`docs/downloads.md` §14): an amber pill with the downloads waiting
/// for an answer, the plain count of those in progress or waiting for a slot, a red pill with the failed rows, or
/// nothing. A finished row is history and is never counted; a cancel shows nothing, since it is what the user asked
/// for. The row keeps its download arrow whatever the state.
///
/// A card's Open Downloads opens the panel through [downloadsPanelRequestProvider], which this row answers.
class DownloadsNavItem extends ConsumerStatefulWidget {
  const DownloadsNavItem({super.key});

  @override
  ConsumerState<DownloadsNavItem> createState() => _DownloadsNavItemState();
}

class _DownloadsNavItemState extends ConsumerState<DownloadsNavItem> {
  DownloadsPanelRoute? _panel;

  void _open() {
    if (_panel != null) return;
    final route = DownloadsPanelRoute(context);
    setState(() => _panel = route);
    Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
      if (mounted && _panel == route) setState(() => _panel = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(downloadsPanelRequestProvider, (_, __) => _open());
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final jobs = ref.watch(downloadQueueProvider);
    final waiting = waitingJobCount(jobs);
    final active = activeJobCount(jobs);
    final failed = failedJobCount(jobs);

    final badge = switch ((waiting, active, failed)) {
      (> 0, _, _) => SidebarBadge(
          icon: Icons.warning_amber_rounded,
          count: waiting,
          tone: palette.badgeUpdate,
          label: loc.plural('downloads.badge_waiting', waiting, params: {'count': '$waiting'}),
        ),
      (_, > 0, _) => null,
      (_, _, > 0) => SidebarBadge(
          icon: Icons.highlight_off_rounded,
          count: failed,
          tone: palette.badgeMissing,
          label: loc.plural('downloads.badge_failed', failed, params: {'count': '$failed'}),
        ),
      _ => null,
    };

    return SidebarNavItem(
      icon: Icons.download_rounded,
      label: loc.t('navigation.downloads'),
      count: waiting == 0 && active > 0 ? active : null,
      badge: badge,
      selected: _panel != null,
      onTap: () => _panel == null ? _open() : _panel!.close(),
    );
  }
}
