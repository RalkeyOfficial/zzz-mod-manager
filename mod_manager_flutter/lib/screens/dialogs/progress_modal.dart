import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/download/download_progress.dart';
import '../../utils/byte_format.dart';

/// **The one window the user waits in**, from pressing the button to being
/// asked the next question.
///
/// Two phases, one modal. It opens on a download — a rate and an ETA rather
/// than only a bar, because these transfers are not always short: archives
/// reach 1.24 GB and a degraded CDN node can stretch one to around 25 minutes,
/// and over a wait that long a bare percentage does not answer the only
/// question the user has. Then it stays up through the work that has to happen
/// before anything can be asked: unpacking the archive, and reading both it and
/// the folder it is going into.
///
/// **Why it is one window and not two.** A modal that closes is the same signal
/// the user gets when a job has finished, so closing it and reopening a
/// different one seconds later reads as "that's done" followed by an
/// interruption. There are also *two* slow steps, so a spinner bolted onto
/// either one still leaves a blank screen for the other. Keeping this up across
/// the whole wait is what makes the sequence legible.
///
/// The download phase is cancellable throughout. The preparing phase is not,
/// and the button goes rather than being disabled: unpacking cannot be stopped
/// half way and leave anything usable, and a dead control invites the press
/// that proves it is dead.
class ProgressModal extends StatelessWidget {
  const ProgressModal({
    super.key,
    required this.progress,
    required this.onCancel,
    required this.hold,
  });

  final ValueListenable<DownloadProgress> progress;
  final VoidCallback onCancel;

  /// Drives the second phase. See [ProgressHold].
  final ProgressHold hold;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;

    return ValueListenableBuilder<bool>(
      valueListenable: hold.preparing,
      builder: (context, preparing, _) {
        if (preparing) return _preparing(context, loc);
        return ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, value, _) => _downloading(context, loc, value),
        );
      },
    );
  }

  Widget _preparing(BuildContext context, AppLocalizations loc) {
    return AlertDialog(
      title: Text(loc.t('marketplace.preparing_title')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Indeterminate, and honestly so: extraction reports no progress,
            // and a bar pretending to know how far along it is would be the
            // one thing worse than not saying.
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            ValueListenableBuilder<String?>(
              valueListenable: hold.message,
              builder: (context, message, _) => Text(
                message ?? loc.t('marketplace.preparing_body'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloading(
    BuildContext context,
    AppLocalizations loc,
    DownloadProgress value,
  ) {
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

/// **Keeps the wait modal up past the end of the download**, and takes it down
/// when there is finally something to show.
///
/// Ownership is split because neither side can do it alone: only the download
/// knows which queue job the Cancel button belongs to, and only the caller
/// knows when its question is ready. So the download hands the closer over
/// rather than using it.
///
/// Without a hold the download closes its own modal, which is what every caller
/// that has nothing further to do wants.
class ProgressHold {
  final ValueNotifier<bool> preparing = ValueNotifier(false);

  /// What is being waited on right now, or null for the generic line.
  ///
  /// A live line rather than one static sentence: the wait is two different
  /// pieces of work, and saying which is happening is the difference between
  /// "something is running" and "this is what is running".
  final ValueNotifier<String?> message = ValueNotifier(null);

  VoidCallback? _close;
  var _disposed = false;

  /// Called by the download once its bytes have landed. The modal stays up from
  /// here and switches to its preparing phase.
  void handOver(VoidCallback close) {
    _close = close;
    preparing.value = true;
  }

  void say(String text) => message.value = text;

  /// Takes the modal down. Safe to call more than once, and safe to call when
  /// the download never got as far as handing anything over.
  void release() {
    _close?.call();
    _close = null;
  }

  /// Idempotent, like [release]: this is the last line of a `finally` on a flow
  /// whose happy path already released it, and a lifecycle object that throws
  /// on a second teardown turns tidy-up into a new failure.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    release();
    preparing.dispose();
    message.dispose();
  }
}

/// Puts the modal straight into its preparing phase, for a caller whose
/// download already finished somewhere the user could not watch it.
///
/// The install path: the transfer ran in the background queue and the user was
/// told it arrived, so what is left is the unpacking — and that is the whole of
/// the wait they would otherwise spend looking at nothing.
ProgressHold showPreparingModal(BuildContext context, {String? message}) {
  final hold = ProgressHold();
  if (message != null) hold.say(message);
  final navigator = Navigator.of(context, rootNavigator: true);
  var closed = false;
  hold.handOver(() {
    if (closed) return;
    closed = true;
    navigator.pop();
  });
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ProgressModal(
      progress: ValueNotifier(
        const DownloadProgress(state: DownloadState.completed),
      ),
      onCancel: () {},
      hold: hold,
    ),
  ).ignore();
  return hold;
}
