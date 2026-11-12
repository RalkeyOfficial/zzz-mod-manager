/// What a download job of [DownloadIntent.update] carries, and what each of its stages can come to (`docs/update-runs.md` §11).
///
/// Typed values only: what a reason is called on screen belongs to the surface that shows it.
library;

import '../../models/gamebanana/gb_file.dart';
import '../../models/mod_download.dart';
import '../update_apply/update_applier.dart' show UpdateWriteStep;
import 'download_exceptions.dart';
import 'download_job.dart';

/// Whether a job writes a newer file or the installed one again.
enum UpdateKind { update, reinstall }

/// One mod an update job writes: its folder, and the layer of it the file is for.
class UpdateMod {
  const UpdateMod({
    required this.modId,
    required this.layer,
    this.name,
    this.uid,
    this.heldFileId,
    this.heldDismissedUntil,
  });

  /// The mod's folder id.
  final String modId;

  /// The mod's name when the job was made, for a card about a mod no longer in the library.
  final String? name;

  /// The layer the file belongs to: the folder's own mod, or a patch over it.
  /// Always the layer's own key, so two presses for one layer compare equal ([sameLayerAs]).
  final DownloadKey layer;

  /// The mod's uid when the job was made, so a folder renamed meanwhile is told apart from one that is gone.
  final String? uid;

  /// The file id the layer's record named when the job was made, so a layer written by something else meanwhile is told apart.
  final int? heldFileId;

  /// The dismissal the layer's record held when the job was made, so only an Ignore written or raised since is read as one.
  final DateTime? heldDismissedUntil;

  bool sameLayerAs(UpdateMod other) => modId == other.modId && layer == other.layer;

  /// Whether the file is for a patch over the folder rather than the folder's own mod.
  bool get isPatchLayer => layer.role == DownloadRole.patch;
}

/// What an update job is for. The picked file is the job's own `file`.
class UpdateTask {
  const UpdateTask({required this.mods, this.published = const <GbFile>[], this.kind = UpdateKind.update});

  /// The mod the job is for first, then the other picked mods of the same archive, written in this order.
  /// Never empty on a job, since `DownloadQueue.enqueueUpdate` adds no job without a mod.
  final List<UpdateMod> mods;

  /// Every file the check found newer, so a pick below the newest records the rest as passed over.
  final List<GbFile> published;

  final UpdateKind kind;

  UpdateMod get primary => mods.first;

  /// The folders the job writes.
  Set<String> get folders => {for (final mod in mods) mod.modId};

  /// The job's mod in the folder [modId], or null.
  UpdateMod? modIn(String modId) {
    for (final mod in mods) {
      if (mod.modId == modId) return mod;
    }
    return null;
  }

  UpdateTask withMods(List<UpdateMod> mods) => UpdateTask(mods: mods, published: published, kind: kind);
}

/// One file of a press, for `DownloadQueue.enqueueUpdates`: the file and the mods it is written into.
class UpdateEnqueue {
  const UpdateEnqueue({required this.file, required this.subject, required this.task, this.characterId});

  final GbFile file;

  /// What the job is of, for its row: a mod name.
  final String subject;
  final UpdateTask task;

  /// Whose portrait leads the job's row and card.
  final String? characterId;
}

/// What an update stage keeps that holds an unpack in the temp folder.
/// It is the one place the queue learns what to delete when the job ends, through `ArchiveService.deleteExtraction`.
abstract interface class HoldsUnpack {
  List<String> get unpackedFolders;
}

/// Which mod of a writing update job is being written, and the part of its write that has started (`docs/update-runs.md` §2).
class UpdateWriting {
  const UpdateWriting(this.modId, this.step);

  final String modId;
  final UpdateWriteStep step;
}

/// The questions an update job can stop at (`docs/update-runs.md` §6).
enum UpdateQuestionKind {
  /// The archive is locked.
  password,

  /// Which of the archive's folders is this mod: the layout is unknown or changed.
  folders,

  /// The download is shaped like a patch, and is never written by the wipe.
  patchShaped,

  /// The folder holds a patch nothing records, which the write would take with the old version.
  unrecordedPatch,
}

/// The question a waiting update job stopped at.
class UpdateWait {
  const UpdateWait(this.question, {this.passwordFailed = false});

  final UpdateQuestionKind question;

  /// The password given last did not open the archive.
  final bool passwordFailed;
}

/// Why an update job failed after its bytes landed. A transfer failure is the download's own exception instead.
enum UpdateFailureKind {
  /// Not enough free space at the unpack or for the snapshot. Halts the run.
  noSpace,

  /// The snapshot could not be taken, so nothing was written. Halts the run.
  snapshotFailed,

  /// The copy failed after the folder was cleared, so the folder is not as it was. Halts the run.
  writtenPartway,

  /// The write stage stopped with an error and how far it got is not known. Halts the run.
  writeInterrupted,

  /// The archive could not be unpacked. It is kept.
  unpackFailed,

  /// The archive holds no mod folder.
  nothingToInstall,

  /// The unpacked folders were gone or could not be read at the write, so nothing was written.
  unpackGone,

  /// The file cannot be written into this folder.
  /// Its layout cannot be reconciled, the group refused the folder, the archive's preview did not find it, or the folder's record names nothing the file belongs to.
  refused,

  /// Anything else before the write. Nothing was written.
  other,
}

class UpdateFailure {
  const UpdateFailure(this.kind, {this.requiredBytes, this.availableBytes, this.cause});

  final UpdateFailureKind kind;

  /// What the refused step needed and found, for [UpdateFailureKind.noSpace].
  final int? requiredBytes;
  final int? availableBytes;

  /// What went wrong underneath, for the log and a Copy details.
  final Object? cause;

  bool get haltsRun => switch (kind) {
        UpdateFailureKind.noSpace ||
        UpdateFailureKind.snapshotFailed ||
        UpdateFailureKind.writtenPartway ||
        UpdateFailureKind.writeInterrupted =>
          true,
        _ => false,
      };

  @override
  String toString() => 'UpdateFailure(${kind.name}${cause == null ? '' : ': $cause'})';
}

/// Whether [error], a failed update job's, is one every later job of the run would share.
/// That is the disk being full or not taking the writes (`docs/update-runs.md` §4.4 item 5).
bool haltsUpdateRun(Object? error) => switch (error) {
      UpdateFailure(:final haltsRun) => haltsRun,
      InsufficientSpaceException() || DownloadWriteException() => true,
      _ => false,
    };

/// Why an update job, or one mod of it, wrote nothing and ended without failing.
enum UpdateSkipReason {
  /// Skip, at a question.
  skippedByUser,

  /// The folder was being written by something else at the write: a restore, Edit info, a patch.
  beingWritten,

  /// The folder is no longer in the library.
  modGone,

  /// The folder was renamed while the job waited.
  folderRenamed,

  /// The job's archive was not written, because the mod it was asked for first was skipped.
  sharedFileNotWritten,

  /// The update was ignored while the job waited: the verdict or the sidecar dismisses the picked file.
  ignoredMeanwhile,

  /// The layer was written by something else while the job waited, and its update mark is gone.
  /// [UpdateModResult.alongWith] names the mod of the run's job that wrote it, when one did.
  alreadyUpdated,
}

/// How one mod of an ended update job came out.
enum UpdateModEnd { written, skipped, refused, failed }

/// What an ended update job came to for one of its mods.
class UpdateModResult {
  const UpdateModResult(this.mod, this.end, {this.skipReason, this.failure, this.alongWith});

  const UpdateModResult.written(this.mod)
      : end = UpdateModEnd.written,
        skipReason = null,
        failure = null,
        alongWith = null;

  const UpdateModResult.skipped(this.mod, UpdateSkipReason this.skipReason, {this.alongWith})
      : end = UpdateModEnd.skipped,
        failure = null;

  final UpdateMod mod;
  final UpdateModEnd end;

  /// Why it was skipped, for [UpdateModEnd.skipped].
  final UpdateSkipReason? skipReason;

  /// Why it was refused or failed.
  final UpdateFailure? failure;

  /// For [UpdateSkipReason.alreadyUpdated]: the folder id of the mod whose job wrote this one, or null.
  final String? alongWith;
}

/// A run stopped by a failure every later job would share.
/// Set on every job of the run that has not ended, taken off a job when it ends, and cleared from every job by Continue or Cancel all.
/// A job tried again takes the run's halt as it is then.
class UpdateHalt {
  const UpdateHalt({required this.cause, required this.bySeq, this.modId, this.modName});

  /// The failure that stopped it: an [UpdateFailure], or a transfer's own exception.
  final Object cause;

  /// The job it happened to.
  final int bySeq;

  /// The folder id of the mod whose failure it is: the one whose write failed or was being written when the write threw,
  /// or the job's first for a transfer or an unpack.
  final String? modId;

  /// That mod's name when the job was made, for when the library no longer has it.
  final String? modName;
}

/// What an update job's stage came to, told to `DownloadQueue.settleUpdate`.
sealed class UpdateStageResult {
  const UpdateStageResult();
}

/// The unpack and preview are done and nothing has to be asked: the job waits for the install lane.
final class UpdateStageReady extends UpdateStageResult {
  const UpdateStageReady({this.prepared});

  /// What the stage keeps until the write, opaque to the queue but for the unpack it holds ([HoldsUnpack]).
  final Object? prepared;
}

/// Only the user can answer [wait].
/// The job leaves the unpack and install lanes and keeps its place under the lookahead.
final class UpdateStageAsks extends UpdateStageResult {
  const UpdateStageAsks(this.wait, {this.prepared});

  final UpdateWait wait;
  final Object? prepared;
}

/// The write ended with [outcome]: at least one mod written and none failed.
/// [results] says what came of each mod; left empty, every mod of the job was written.
final class UpdateStageWritten extends UpdateStageResult {
  const UpdateStageWritten(this.outcome, {this.results = const <UpdateModResult>[], this.report});

  final JobOutcome outcome;
  final List<UpdateModResult> results;

  /// What the write did, opaque to the queue (`UpdateReport`).
  final Object? report;
}

/// Nothing was written and nothing failed.
/// [results] says what came of each mod.
/// A mod it leaves out is skipped for [reason] when it is the job's first, and as [UpdateSkipReason.sharedFileNotWritten] otherwise.
final class UpdateStageSkipped extends UpdateStageResult {
  const UpdateStageSkipped(this.reason, {this.results = const <UpdateModResult>[]});

  final UpdateSkipReason reason;
  final List<UpdateModResult> results;
}

/// [failure] is the job's: the one that matters most when several mods failed.
/// [results] says what came of each mod; a mod it leaves out failed for [failure].
final class UpdateStageFailed extends UpdateStageResult {
  const UpdateStageFailed(this.failure, {this.results = const <UpdateModResult>[], this.report});

  final UpdateFailure failure;
  final List<UpdateModResult> results;

  /// What a write did before it failed, when it got that far.
  final Object? report;
}
