import 'dart:io';

import '../../models/gamebanana/gb_file.dart';
import '../../models/gamebanana/gb_mod.dart';
import 'download_handle.dart';
import 'download_progress.dart';
import 'download_request.dart';

/// Why a download was started, and therefore what happens when the bytes land.
///
/// The queue itself only moves bytes. **What happens afterwards is decided
/// here**, once, at the moment the user presses the button — never inferred
/// later from which screen happens to be on top, because by then the screen that
/// knew may be gone.
enum DownloadIntent {
  /// Import the archive into the library. Run by `DownloadQueueHost`, which
  /// outlives every screen, so switching tabs mid-transfer cannot lose it.
  install,

  /// Keep the archive and say where it landed. Nothing is installed.
  keepArchive,

  /// A caller is awaiting [DownloadQueue.completionOf] and owns everything from
  /// the bytes onwards — the update flow, which writes over an existing mod
  /// rather than importing a new one.
  callerHandles,
}

/// A job that failed at the **install** half rather than the transfer.
///
/// Typed rather than a bare string so the panel can tell the two apart, which
/// decides both what the row says and what it offers. An archive that arrived
/// intact and then would not unpack is not a download failure: reporting it as
/// one hides the actual cause, and the retry that a download failure earns
/// would re-fetch two hundred megabytes to hit the same `7z` error.
///
/// Carries the message the install already produced — `extractFailureMessage`
/// and friends have worked out what went wrong and where the archive was left,
/// and that is worth far more on the row than a generic sentence.
class InstallFailure {
  const InstallFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where a job is in its life.
///
/// Longer than [DownloadState] because a transfer is only half of what a job
/// does: [downloaded] is the handover point where the queue is finished and the
/// host has not started, and it is a real state rather than a fleeting one — the
/// host installs strictly one at a time.
enum DownloadJobState {
  /// Admitted, waiting for a slot.
  queued,

  /// Holding a connection.
  running,

  /// Bytes are on disk; waiting for the host to install or report.
  downloaded,

  /// The host is unpacking and importing it.
  installing,

  /// Finished, whatever the intent asked for.
  done,

  /// Stopped by an error, at either half.
  failed,

  /// Stopped by the user.
  cancelled;

  /// Whether this job still holds a network connection. Only these count
  /// against the concurrency cap — an install is disk and CPU, and blocking a
  /// download behind one would idle the network for no reason.
  bool get holdsConnection => this == running;

  /// Whether the queue is done with it. Terminal jobs stay in the list so the
  /// panel can show what happened; nothing but the user clears them.
  bool get isTerminal =>
      this == done || this == failed || this == cancelled;

  /// Whether it is still going to do something. Drives the panel's badge.
  bool get isActive => !isTerminal;
}

/// One download the app has been asked to make, and what became of it.
///
/// Immutable: the queue replaces jobs rather than mutating them, so a widget
/// holding an old one renders an old frame instead of a half-updated object.
class DownloadJob {
  const DownloadJob({
    required this.seq,
    required this.request,
    required this.intent,
    required this.subject,
    required this.file,
    this.mod,
    this.characterId,
    this.state = DownloadJobState.queued,
    this.progress,
    this.error,
    this.result,
  });

  /// Monotonic per session. Both the identity (a `Map` key, a `ValueKey`) and
  /// the order — the queue is first-in-first-out and this is what says so.
  final int seq;

  final DownloadRequest request;
  final DownloadIntent intent;

  /// What the download is *of*, for the panel and any notification. A mod name,
  /// never a filename: `remielleswimlite.rar` is not what the user asked for.
  final String subject;

  final GbFile file;

  /// The mod page the file came from. Required to install (it carries the
  /// character, the description and the gallery the import fills from); absent
  /// for [DownloadIntent.callerHandles], which needs none of it.
  final GbMod? mod;

  /// Whose portrait leads the panel row and any notification.
  final String? characterId;

  final DownloadJobState state;

  /// The last transfer snapshot. Null until the first one arrives, and kept
  /// after the transfer so a finished row can still show the size.
  final DownloadProgress? progress;

  /// Why it failed, when it did.
  final Object? error;

  /// What the transfer produced, from [DownloadJobState.downloaded] onwards.
  ///
  /// The whole result rather than just the file, because the install needs the
  /// in-stream md5 that came with it — free during the download and
  /// **unrecoverable** afterwards, since the archive is deleted once unpacked.
  final DownloadResult? result;

  /// The archive at its final name, once the transfer is done.
  File? get archive => result?.file;

  bool get isTerminal => state.isTerminal;

  /// Never blocked by the concurrency cap.
  ///
  /// A [DownloadIntent.callerHandles] job is the one the user is watching a
  /// modal dialog for, and that dialog covers the panel — so parking it behind
  /// two background transfers would leave them staring at "waiting for a slot"
  /// with no way to reach the thing they would have to cancel. It still
  /// *counts* against the cap, so the next background job waits for it.
  bool get bypassesCap => intent == DownloadIntent.callerHandles;

  DownloadJob copyWith({
    DownloadJobState? state,
    DownloadProgress? progress,
    Object? error,
    DownloadResult? result,
  }) =>
      DownloadJob(
        seq: seq,
        request: request,
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        result: result ?? this.result,
      );

  /// Clears the transfer's outcome so the job can be tried again from scratch.
  ///
  /// Separate from [copyWith] rather than a nullable flag on it: `copyWith`
  /// cannot express "set this back to null" without a sentinel, and a retry that
  /// silently kept the previous error is exactly the bug that would look fixed.
  DownloadJob restarted() => DownloadJob(
        seq: seq,
        request: request,
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
      );
}
