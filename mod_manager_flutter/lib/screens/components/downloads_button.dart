import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../shell/app_sidebar.dart';
import 'downloads_panel.dart';
import 'sidebar_nav_item.dart';

/// The sidebar's Downloads row, and the way to the panel.
///
/// The count is the jobs still running or waiting; a finished row is history, and counting it would say the app
/// is still busy. A failure with nothing else in flight turns the icon into a warning so it can be found and read.
/// Overall progress is the pinned notification's job, not this row's.
class DownloadsNavItem extends ConsumerWidget {
  const DownloadsNavItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(downloadQueueProvider);
    final active = activeJobCount(jobs);
    // On the **state**, not on whether an error is attached. A cancel is something the user asked for, and
    // flagging it says the app broke when it did as it was told.
    final failed = jobs.any((j) => j.state == DownloadJobState.failed);

    return MenuAnchor(
      // The panel opens against the sidebar's right edge, level with the row. The offset runs from the row's left
      // edge, which sits [AppSidebar.inset] inside the sidebar.
      alignmentOffset: const Offset(AppSidebar.width - AppSidebar.inset, -SidebarNavItem.height),
      menuChildren: const [DownloadsPanel()],
      builder: (context, controller, _) => SidebarNavItem(
        icon: failed && active == 0 ? Icons.error_outline_rounded : Icons.download_rounded,
        label: context.loc.t('navigation.downloads'),
        count: active > 0 ? active : null,
        selected: controller.isOpen,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
