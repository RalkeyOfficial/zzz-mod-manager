import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/download/download_exceptions.dart';
import '../../services/download/download_handle.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_progress.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/queue_policy.dart';
import '../../utils/notifications.dart';
import 'download_progress_dialog.dart';

/// Fetches one published file **while the user waits**, with a modal progress
/// dialog in front of it.
///
/// The one remaining foreground transfer, and the exception rather than the
/// rule: every download the user starts from the marketplace goes to the queue
/// and runs in the background. This exists for `applyUpdateFlow`, which is a
/// *conversation* — download, show what is about to be written over an installed
/// mod, write only if they agree — and holding that open across a tab switch
/// would mean asking about a mod the user has since navigated away from.
///
/// It still goes through the queue, so the panel shows every transfer the app is
/// making and the concurrency cap covers all of them. A
/// [DownloadIntent.callerHandles] job **bypasses the cap on the way in** (see
/// [DownloadJob.bypassesCap]): the modal barrier covers the panel, so a job
/// parked behind two background transfers would leave the user watching "waiting
/// for a slot" with no way to reach the thing they would have to cancel.
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

  final queue = ref.read(downloadQueueProvider.notifier);

  // The queue keys on the file id, and that is load-bearing rather than polite:
  // two runs of the same file would write the same `.part` and the same resume
  // record in `<appData>/downloads`, appending two streams into one plausible
  // and corrupt archive. So a file already being fetched is never fetched twice
  // — and here that means declining, because the job in flight belongs to
  // somebody else and will be consumed by them.
  final inFlight = activeJobForFile(ref.read(downloadQueueProvider), file.idRow);
  if (inFlight != null && inFlight.intent != DownloadIntent.callerHandles) {
    notify.info(
      loc.t('marketplace.download_already_queued_title'),
      body: body,
      characterId: characterId,
    );
    return null;
  }

  final job = queue.enqueue(
    file: file,
    subject: body,
    characterId: characterId,
    intent: DownloadIntent.callerHandles,
  );
  if (job.state == DownloadJobState.failed) {
    // The only way enqueuing fails outright: a download url that will not parse.
    // Reported here rather than returned silently — the caller reads a null as
    // "already reported", so a quiet one makes pressing Update do nothing at
    // all.
    report(loc.t('marketplace.download_failed_title'));
    queue.remove(job.seq);
    return null;
  }

  final progress = ValueNotifier<DownloadProgress>(
    job.progress ?? const DownloadProgress(state: DownloadState.connecting),
  );
  final subscription =
      queue.progressOf(job.seq).listen((p) => progress.value = p);

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
        onCancel: () => unawaited(queue.cancel(job.seq)),
      ),
    ),
  );

  try {
    final result = await queue.completionOf(job.seq);
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
    // A foreground download leaves no row behind. The panel is a list of work
    // the user cannot otherwise see, and this one they watched from start to
    // finish inside a dialog.
    queue.remove(job.seq);
  }
}
