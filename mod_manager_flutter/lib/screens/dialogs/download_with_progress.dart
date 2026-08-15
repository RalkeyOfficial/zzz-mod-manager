import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/download/download_exceptions.dart';
import '../../services/download/download_handle.dart';
import '../../services/download/download_progress.dart';
import '../../services/download/download_request.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'download_progress_dialog.dart';

/// Fetches one published file, with the modal progress dialog in front of it.
///
/// Extracted from the marketplace's install flow because a second caller
/// arrived: applying an update downloads exactly the same way, and the parts
/// that are easy to get wrong — closing the dialog exactly once, telling a
/// cancellation apart from a failure, disposing the notifier on every path —
/// are the parts that must not exist twice.
///
/// What is deliberately *not* here is the install: the marketplace imports the
/// archive as a new mod folder, while an update overwrites an existing one.
/// Those are different operations with different hazards, and folding them
/// together is what would produce a shared "install" that quietly does the wrong
/// one.
///
/// Returns null when the user cancelled or the transfer failed — a notification
/// has already said which.
Future<DownloadResult?> downloadFileWithProgress(
  BuildContext context,
  WidgetRef ref,
  GbFile file,
) async {
  final loc = context.loc;
  // Read before the first await and kept: the dialog this runs behind can be
  // gone by the time there is something to report, and this object does not
  // care.
  final notify = context.notify;
  final navigator = Navigator.of(context, rootNavigator: true);

  void report(String message) => notify.error(message);

  final raw = file.downloadUrl ?? 'https://gamebanana.com/dl/${file.idRow}';
  final url = Uri.tryParse(raw);
  if (url == null) {
    // Returning null silently here broke this function's own contract — both
    // callers read null as "already reported" and stop, so pressing Download or
    // Update produced nothing at all. Unlikely (the fallback is a literal), but
    // a silent failure in the one helper that exists so the error handling is
    // not written twice is the worst place for one.
    report(loc.t('marketplace.download_failed', params: {'message': raw}));
    return null;
  }

  final handle = ref.read(downloadServiceProvider).start(
        DownloadRequest(
          url: url,
          suggestedFilename: file.file,
          fileId: file.idRow,
          // `_nFilesize` is exactly the eventual Content-Length, so it is a
          // reliable progress denominator from the first frame.
          expectedSize: file.filesize,
          expectedMd5: file.md5Checksum,
        ),
      );

  final progress = ValueNotifier<DownloadProgress>(
    const DownloadProgress(state: DownloadState.connecting),
  );
  final subscription = handle.progress.listen((p) => progress.value = p);

  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    navigator.pop();
  }

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DownloadProgressDialog(
        progress: progress,
        onCancel: () => unawaited(handle.cancel(deletePartial: true)),
      ),
    ),
  );

  try {
    final result = await handle.done;
    close();
    return result;
  } on DownloadCancelledException {
    close();
    // Info, not an error: the user pressed cancel, and telling them off in red
    // for doing what they asked for is exactly the noise this rework removed.
    notify.info(
      loc.t('marketplace.download_cancelled'),
      icon: Icons.cancel_outlined,
    );
    return null;
  } catch (e) {
    close();
    report(
      e is DownloadStalledException
          ? loc.t('marketplace.download_stalled')
          : loc.t('marketplace.download_failed', params: {'message': '$e'}),
    );
    return null;
  } finally {
    close();
    await subscription.cancel();
    progress.dispose();
  }
}
