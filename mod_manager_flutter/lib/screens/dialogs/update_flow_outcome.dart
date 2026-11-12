import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_target.dart';
import 'download_with_progress.dart' show DownloadStop;

/// How a one-mod update flow ended.
enum UpdateFlowOutcome {
  /// The new version was written over the folder.
  written,

  /// The user answered no: cancelled the download, closed a question, or left the archive's password unanswered.
  declined,

  /// Something went wrong and the flow has said what. The folder is as it was.
  failed,

  /// The write began and failed after files had moved, so the folder is not as it was. Reads as a change to the
  /// screens that rescan.
  failedAfterChange,

  /// Nothing was asked and nothing was done: the window the flow was started from had gone, the file was already
  /// being fetched by something else, or the download ended without saying why.
  notStarted;

  /// Whether the mod folder may differ from before, so the library has to be read again.
  bool get changed => this == written || this == failedAfterChange;
}

/// What a download that returned nothing means for the update. Only an explicit Cancel is the user's no; a failure is
/// one, and a stop with no reason given is not read as a refusal.
UpdateFlowOutcome outcomeOfStoppedDownload(DownloadStop? reason) => switch (reason) {
  DownloadStop.cancelled => UpdateFlowOutcome.declined,
  DownloadStop.failed => UpdateFlowOutcome.failed,
  DownloadStop.alreadyRunning || null => UpdateFlowOutcome.notStarted,
};

/// What a write into one or more folders adds up to for the caller: [UpdateFlowOutcome.written] when any folder took the
/// new version, even if another did not (each folder has its own snapshot and copy, so a group is not all or nothing);
/// [UpdateFlowOutcome.failedAfterChange] when none did and a copy had already moved files; otherwise
/// [UpdateFlowOutcome.failed].
UpdateFlowOutcome outcomeOfGroupWrite(List<AppliedUpdate> applied) {
  if (applied.any((entry) => entry.result.success)) return UpdateFlowOutcome.written;
  if (applied.any((entry) => entry.result.failure == UpdateApplyFailure.copy)) return UpdateFlowOutcome.failedAfterChange;
  return UpdateFlowOutcome.failed;
}
