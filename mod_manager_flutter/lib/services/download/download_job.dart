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
/// and that is worth far more on the row than a generic sentence. An update that
/// failed after its bytes landed carries the update flow's own headline.
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
///
/// There is no cancelled state: a cancelled job, one the user said Don't install
/// to, and an update the user declined leave the list.
enum DownloadJobState {
  /// Admitted, waiting for a slot.
  queued,

  /// Holding a connection.
  running,

  /// Stopped by the user with its partial kept, holding no slot until resumed.
  paused,

  /// Bytes are on disk; waiting for the host to install or report.
  downloaded,

  /// The install stopped at a question for the user and freed the install slot. See [DownloadJob.wait].
  waiting,

  /// The host is unpacking and importing it.
  installing,

  /// A download the update flow owns: its bytes are handed over and the flow is unpacking, asking or writing. The
  /// flow ends it. See [DownloadJob.updateStep].
  updating,

  /// Finished, whatever the intent asked for.
  done,

  /// Stopped by an error, at either half.
  failed;

  /// Whether this job still holds a network connection. Only these count
  /// against the concurrency cap — an install is disk and CPU, and blocking a
  /// download behind one would idle the network for no reason.
  bool get holdsConnection => this == running;

  /// Whether the queue is done with it. Terminal jobs stay in the list so the
  /// panel can show what happened; nothing but the user clears them.
  bool get isTerminal => this == done || this == failed;

  /// Whether it is still going to do something, a paused or a waiting job included.
  bool get isActive => !isTerminal;
}

/// The questions an install can stop at, in the order the install tests them (`docs/downloads.md` §10).
enum InstallQuestion {
  /// The archive is encrypted. Asked before the unpack.
  password,

  /// The archive is byte-identical to one already installed.
  alreadyInstalled,

  /// More than one folder came out of the archive.
  severalFolders,

  /// A planned mod looks like a patch for another mod.
  patch,
}

/// What a waiting job's row says about its question.
class InstallWait {
  const InstallWait(
    this.question, {
    this.folderCount = 0,
    this.installedAs = const <String>[],
    this.passwordFailed = false,
  });

  final InstallQuestion question;

  /// How many folders came out of the archive, for [InstallQuestion.severalFolders].
  final int folderCount;

  /// The library mods the identical archive was installed as, for [InstallQuestion.alreadyInstalled].
  final List<String> installedAs;

  /// The password given last did not open the archive, for [InstallQuestion.password].
  final bool passwordFailed;
}

/// What a finished job came to, for the panel's Finished line.
enum JobOutcome {
  /// New mod folders went into the library ([DownloadJob.installed]).
  installed,

  /// The update flow wrote a newer file over an installed mod.
  updated,

  /// The update flow wrote the installed file over the mod again.
  reinstalled,

  /// The update flow wrote the mod a patch applies to into that patch's folder.
  baseInstalled,

  /// The archive was kept in the app's downloads folder.
  saved,

  /// An install that put nothing in, such as one whose folders were all in the library already. The row says the
  /// result's headline ([DownloadJob.headline]).
  nothingInstalled,
}

/// The step an update download is on, while it is [DownloadJobState.updating].
enum UpdateStep {
  /// Unpacking the file and reading the folder it goes into.
  unpacking,

  /// Waiting for the user to answer the update's own window.
  confirming,

  /// Writing the file over the mod, the old one kept as a snapshot.
  writing,
}

/// The step an install is on, while it is [DownloadJobState.installing].
enum InstallStage {
  /// Unpacking the archive and testing for the questions it may raise.
  unpacking,

  /// Importing the folders into the library, after every question has an answer.
  installing,
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
    this.turnOn = false,
    this.state = DownloadJobState.queued,
    this.progress,
    this.error,
    this.result,
    this.resumed = false,
    this.wait,
    this.unpacked = const <String>[],
    this.prepared,
    this.password,
    this.updateStep,
    this.installStage,
    this.outcome,
    this.installed = const <String>[],
    this.filedUnder,
    this.headline,
    this.finishedAt,
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

  /// The character an install files every new mod under, as the mod page showed it when the button was pressed: the
  /// GameBanana category's, the one the user picked over it, or Unassigned (`unknownCharacterId`) for a page that
  /// names none, which the import honours rather than reading the folder names. Null would leave the import to read
  /// them, and no Browse install carries null. Also whose portrait leads the panel row and any notification.
  final String? characterId;

  /// Whether an install turns its new mods on once they are in the library, the mod page's Turn on after installing.
  final bool turnOn;

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

  /// Resumed from a pause and not started since, which puts it first of the queued jobs.
  final bool resumed;

  /// The question a [DownloadJobState.waiting] job stopped at.
  final InstallWait? wait;

  /// The folders the install unpacked into the system temp folder and holds until it ends. Empty before the unpack
  /// and while the archive waits for its password.
  final List<String> unpacked;

  /// What the install kept between its runs: the unpack's results and the answers so far. Owned by the install flow
  /// (`PreparedInstall` in `install_archive_flow.dart`), which is why it is opaque here: the queue only carries it.
  /// Set on a job that has waited, which is what puts it ahead of jobs that have not ([nextAwaitingHost]).
  final Object? prepared;

  /// The password the user gave, held in memory until the unpack it was given for, and never written anywhere.
  final String? password;

  /// The step an update download is on, while [DownloadJobState.updating].
  final UpdateStep? updateStep;

  /// The step an install is on, while [DownloadJobState.installing].
  final InstallStage? installStage;

  /// What a finished job came to.
  final JobOutcome? outcome;

  /// The mod folders an install created, or an update wrote, by name.
  final List<String> installed;

  /// The character the install filed its mods under, Unknown included, which is where to look for them.
  final String? filedUnder;

  /// The result's headline, for an install that put nothing in.
  final String? headline;

  /// When it finished, for the Finished line's relative time.
  final DateTime? finishedAt;

  /// The archive at its final name, once the transfer is done.
  File? get archive => result?.file;

  bool get isTerminal => state.isTerminal;

  /// Never blocked by the concurrency cap.
  ///
  /// A [DownloadIntent.callerHandles] job is the one the user is watching a
  /// modal dialog for, an update they asked for now. Parked behind two
  /// background transfers, that dialog would say "waiting for a slot" until a
  /// download it has nothing to do with ended. It still *counts* against the
  /// cap, so the next background job waits for it.
  bool get bypassesCap => intent == DownloadIntent.callerHandles;

  /// Whether the user can pause it: a background transfer. An update's download runs behind its own window, which
  /// has Cancel.
  bool get pausable => state == DownloadJobState.running && intent != DownloadIntent.callerHandles;

  DownloadJob copyWith({
    DownloadJobState? state,
    DownloadProgress? progress,
    Object? error,
    DownloadResult? result,
    bool? resumed,
    InstallWait? wait,
    List<String>? unpacked,
    Object? prepared,
    UpdateStep? updateStep,
    InstallStage? installStage,
    JobOutcome? outcome,
    List<String>? installed,
    String? filedUnder,
    String? headline,
    DateTime? finishedAt,
  }) =>
      DownloadJob(
        seq: seq,
        request: request,
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
        turnOn: turnOn,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        result: result ?? this.result,
        resumed: resumed ?? this.resumed,
        wait: wait ?? this.wait,
        unpacked: unpacked ?? this.unpacked,
        prepared: prepared ?? this.prepared,
        password: password,
        updateStep: updateStep ?? this.updateStep,
        installStage: installStage ?? this.installStage,
        outcome: outcome ?? this.outcome,
        installed: installed ?? this.installed,
        filedUnder: filedUnder ?? this.filedUnder,
        headline: headline ?? this.headline,
        finishedAt: finishedAt ?? this.finishedAt,
      );

  /// The same job with its question and its password set as given, both of which `copyWith` cannot clear: a job
  /// leaving the wait drops its question, and a password goes once the unpack it was given for has run.
  DownloadJob withWait(InstallWait? wait, {String? password}) => DownloadJob(
        seq: seq,
        request: request,
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
        turnOn: turnOn,
        state: state,
        progress: progress,
        error: error,
        result: result,
        resumed: resumed,
        wait: wait,
        unpacked: unpacked,
        prepared: prepared,
        password: password,
        updateStep: updateStep,
        installStage: installStage,
        outcome: outcome,
        installed: installed,
        filedUnder: filedUnder,
        headline: headline,
        finishedAt: finishedAt,
      );

  /// The same job, asked for again by a new press: what happens once the bytes land is the new press's, everything
  /// about the transfer stays.
  DownloadJob pressedAgain({
    required DownloadIntent intent,
    required String subject,
    required GbMod? mod,
    required String? characterId,
    required bool turnOn,
  }) =>
      DownloadJob(
        seq: seq,
        request: request,
        intent: intent,
        subject: subject,
        file: file,
        mod: mod,
        characterId: characterId,
        turnOn: turnOn,
        state: state,
        progress: progress,
        error: error,
        result: result,
        resumed: resumed,
        wait: wait,
        unpacked: unpacked,
        prepared: prepared,
        password: password,
        updateStep: updateStep,
        installStage: installStage,
        outcome: outcome,
        installed: installed,
        filedUnder: filedUnder,
        headline: headline,
        finishedAt: finishedAt,
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
        turnOn: turnOn,
      );
}
