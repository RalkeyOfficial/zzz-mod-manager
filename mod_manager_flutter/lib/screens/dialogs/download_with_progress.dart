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
  GbFile file, {
  /// Whose portrait leads any notification this raises. A [GbFile] knows
  /// neither the character nor the mod's name, and both callers do — so they
  /// arrive as parameters rather than being looked up here, which would be a
  /// read after the awaits below.
  String? characterId,

  /// What the download is *of*, for the body line. `file.file` is a filename,
  /// not a mod name.
  String? subject,
}) async {
  final loc = context.loc;
  // Read before the first await and kept: the dialog this runs behind can be
  // gone by the time there is something to report, and this object does not
  // care.
  final notify = context.notify;
  final navigator = Navigator.of(context, rootNavigator: true);

  final body = subject ?? file.file ?? loc.t('marketplace.unknown_file');
  void report(String title) =>
      notify.error(title, body: body, characterId: characterId);

  final raw = file.downloadUrl ?? 'https://gamebanana.com/dl/${file.idRow}';
  final url = Uri.tryParse(raw);
  if (url == null) {
    // Returning null silently here broke this function's own contract — both
    // callers read null as "already reported" and stop, so pressing Download or
    // Update produced nothing at all. Unlikely (the fallback is a literal), but
    // a silent failure in the one helper that exists so the error handling is
    // not written twice is the worst place for one.
    report(loc.t('marketplace.download_failed_title'));
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
    return null;
  } catch (e) {
    close();
    if (e is DownloadStalledException) {
      // The one recoverable failure, so its body is the way out rather than the
      // name of what stalled.
      notify.error(
        loc.t('marketplace.download_stalled_title'),
        body: loc.t('marketplace.download_stalled_body'),
        characterId: characterId,
      );
    } else {
      report(loc.t('marketplace.download_failed_title'));
    }
    return null;
  } finally {
    close();
    await subscription.cancel();
    progress.dispose();
  }
}
