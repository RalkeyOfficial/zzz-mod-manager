import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_progress.dart';
import '../../utils/byte_format.dart';

/// Progress for a single download.
///
/// Shows a rate and an ETA rather than only a bar, because these transfers are
/// not always short: archives reach 1.24 GB and a degraded CDN node can stretch
/// one to around 25 minutes. Over a wait that long a bare percentage doesn't
/// answer the only question the user has — is this still moving?
///
/// The dialog is intentionally cancellable throughout, which the previous
/// version was not.
class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  final ValueListenable<DownloadProgress> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;

    return ValueListenableBuilder<DownloadProgress>(
      valueListenable: progress,
      builder: (context, value, _) {
        return AlertDialog(
          title: Text(loc.t('marketplace.downloading')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value.fraction),
              const SizedBox(height: 12),
              Text(
                _statusLine(context, value),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (value.isResumed) ...[
                const SizedBox(height: 4),
                Text(
                  loc.t('marketplace.download_resumed'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: onCancel,
              child: Text(loc.t('marketplace.download_cancel_button')),
            ),
          ],
        );
      },
    );
  }

  String _statusLine(BuildContext context, DownloadProgress value) {
    final loc = context.loc;
    final total = value.total;

    // Without a total there is no percentage to show, only how much has
    // arrived — which is still more useful than an unmoving indeterminate bar.
    final size = total == null
        ? formatBytes(value.received)
        : '${formatBytes(value.received)} / ${formatBytes(total)}';

    final parts = <String>[size];

    final rate = value.bytesPerSecond;
    if (rate != null) {
      parts.add(loc.t('marketplace.download_rate',
          params: {'rate': formatBytes(rate.round())}));
    }

    final eta = value.eta;
    if (eta != null && eta > Duration.zero) {
      parts.add(loc.t('marketplace.download_eta',
          params: {'time': formatDuration(eta)}));
    }

    return parts.join(' · ');
  }
}
