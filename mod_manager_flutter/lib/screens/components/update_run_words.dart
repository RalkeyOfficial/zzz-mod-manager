/// What an update run's job is called on screen: the step, the wait, the question, the failure and the skip, in one
/// place so the Updates page's row, the Downloads panel and the cards say the same thing (`docs/update-runs.md` §2, §10).
///
/// The engine's values are typed (`update_job.dart`); the words are here.
library;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/download/download_exceptions.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_progress.dart';
import '../../services/download/queue_policy.dart';
import '../../services/download/update_job.dart';
import '../../services/update_apply/update_applier.dart' show UpdateWriteStep;
import '../../services/update_apply/update_undo.dart' show updateUndoRecordOf;
import '../../utils/byte_format.dart';
import 'resolve/resolve_fragments.dart';

/// Where an update job that has not ended stands, as every surface says it (`docs/update-runs.md` §2):
/// the one place a job's state, step and halt become a phase.
sealed class UpdatePhase {
  const UpdatePhase();
}

/// In line for a download slot.
final class UpdateInLine extends UpdatePhase {
  const UpdateInLine();
}

/// Held by the run's halt at a gate: in line, landed, or unpacked and waiting for the write.
final class UpdateStopped extends UpdatePhase {
  const UpdateStopped(this.halt);

  final UpdateHalt halt;
}

/// Downloading, before the rate has a figure.
final class UpdateConnecting extends UpdatePhase {
  const UpdateConnecting();
}

final class UpdateDownloading extends UpdatePhase {
  const UpdateDownloading();
}

/// Landed, unpacking, or unpacked and waiting for the write: steps that report no progress.
final class UpdateChecking extends UpdatePhase {
  const UpdateChecking();
}

/// Being written, at [step] when the write has reported one for the mod asked about.
final class UpdateInstalling extends UpdatePhase {
  const UpdateInstalling(this.step);

  final UpdateWriteStep? step;
}

/// Waiting on a question.
final class UpdateAsking extends UpdatePhase {
  const UpdateAsking();
}

/// [job]'s phase, or null once it has ended, and for [modId] once that mod has a result of its own, a skip at its question while the job goes on.
/// The write's step is [modId]'s own, or any mod's when null.
/// A transfer or an unpack under way when the run halts goes on to the next gate, so only a job at a gate reads stopped.
/// A question about another mod of the job than [modId] leaves [modId] waiting in line, since only that mod's row asks it.
UpdatePhase? updatePhaseOf(DownloadJob job, [String? modId]) => switch (job.state) {
      DownloadJobState.done || DownloadJobState.failed => null,
      _ when modId != null && job.resultFor(modId) != null => null,
      DownloadJobState.waiting when modId != null && (job.updateWait?.modId ?? modId) != modId => const UpdateInLine(),
      DownloadJobState.waiting => const UpdateAsking(),
      DownloadJobState.running => updateIsConnecting(job) ? const UpdateConnecting() : const UpdateDownloading(),
      DownloadJobState.updating when job.updateStep == UpdateStep.writing => UpdateInstalling(writingStepOf(job, modId)),
      DownloadJobState.queued || DownloadJobState.paused || DownloadJobState.downloaded when job.halt != null =>
        UpdateStopped(job.halt!),
      DownloadJobState.updating when job.updateStep == UpdateStep.unpacked && job.halt != null =>
        UpdateStopped(job.halt!),
      DownloadJobState.queued || DownloadJobState.paused => const UpdateInLine(),
      _ => const UpdateChecking(),
    };

/// Whether [job]'s transfer reads "Connecting...": until it is connected and the rate has a figure, which takes about
/// a second.
bool updateIsConnecting(DownloadJob job) {
  final progress = job.progress;
  return progress == null || progress.state == DownloadState.connecting || progress.bytesPerSecond == null;
}

/// "replacing the files": the part of a write that has started, in lower case to follow a label.
String updateStepText(AppLocalizations loc, UpdateWriteStep step) => loc.t(switch (step) {
      UpdateWriteStep.savingSnapshot => 'downloads.update.step.snapshot',
      UpdateWriteStep.replacingFiles => 'downloads.update.step.replacing',
      UpdateWriteStep.linking => 'downloads.update.step.linking',
    });

/// "Installing · replacing the files", or "Installing" before the write has reported a step.
String updateInstallingText(AppLocalizations loc, UpdateWriteStep? step) => step == null
    ? loc.t('downloads.update.installing')
    : loc.t('downloads.update.card_installing', params: {'step': updateStepText(loc, step)});

/// "Stopped: the disk is full", for a job the run's halt holds.
String updateStoppedText(AppLocalizations loc, UpdateHalt halt) =>
    loc.t('downloads.update.stopped', params: {'reason': updateFailureText(loc, halt.cause)});

/// The Updates page row's status for [phase].
String updatePhaseLabel(AppLocalizations loc, UpdatePhase phase) => switch (phase) {
      UpdateAsking() => loc.t('library.updates.status.needs_you'),
      UpdateStopped() => loc.t('library.updates.status.stopped'),
      UpdateInLine() => loc.t('library.updates.status.waiting'),
      UpdateConnecting() => loc.t('downloads.connecting'),
      UpdateDownloading() => loc.t('library.updates.status.downloading'),
      UpdateChecking() => loc.t('downloads.update.checking'),
      UpdateInstalling(:final step) => updateInstallingText(loc, step),
    };

/// A Working card's body for an update job at [phase]: the step it is on.
String updateCardBody(AppLocalizations loc, DownloadJob job, UpdatePhase phase) => switch (phase) {
      UpdateInLine() => loc.t('downloads.update.waiting'),
      UpdateStopped(:final halt) => updateStoppedText(loc, halt),
      UpdateConnecting() => loc.t('downloads.connecting'),
      UpdateDownloading() => downloadingStageText(loc, job),
      UpdateChecking() => loc.t('downloads.stage_unpacking'),
      UpdateInstalling(:final step) => updateInstallingText(loc, step),
      UpdateAsking() => loc.t('downloads.needs_you'),
    };

/// "Downloading · 64.0 MB of 214.0 MB", or how much has arrived while the total is unknown: a download card's body.
String downloadingStageText(AppLocalizations loc, DownloadJob job) {
  final received = job.progress?.received ?? 0;
  final total = job.progress?.total ?? job.request.expectedSize;
  // No total to divide by: how much has arrived is the honest answer.
  if (total == null || total <= 0) {
    return loc.t('downloads.stage_downloading_bytes', params: {'received': formatBytes(received)});
  }
  return loc.t('downloads.stage_downloading', params: {'received': formatBytes(received), 'total': formatBytes(total)});
}

/// The step [job] is writing, for its own mod [modId] or any mod of the job when null.
UpdateWriteStep? writingStepOf(DownloadJob job, [String? modId]) {
  final writing = job.writing;
  if (writing == null || job.updateStep != UpdateStep.writing) return null;
  return modId == null || writing.modId == modId ? writing.step : null;
}

/// A queued update's line on its dimmed row: its size and where it stands.
String queuedPlaceText(AppLocalizations loc, UpdateQueuedPlace place, int? size) {
  final sized = size == null || size <= 0 ? '' : formatBytes(size);
  // A file that lists no size leaves the line without its lead.
  String withSize(String text) => sized.isEmpty ? text.replaceFirst(RegExp(r'^\s*·\s*'), '') : text;
  return switch (place) {
    DownloadsNext() => withSize(loc.t('downloads.update.downloads_next', params: {'size': sized})),
    AheadOfIt(:final count) =>
      withSize(loc.plural('downloads.update.ahead', count, params: {'size': sized, 'count': '$count'})),
    WaitsForInstall() => withSize(loc.t('downloads.update.waits_install', params: {'size': sized})),
    WaitsForAnswers() => withSize(loc.t('downloads.update.waits_answers', params: {'size': sized})),
    StoppedBy(:final halt) => updateStoppedText(loc, halt),
  };
}

/// What a waiting update's question says on its row.
String updateQuestionText(AppLocalizations loc, DownloadJob job, {int folderCount = 0}) =>
    switch (job.updateWait) {
      UpdateWait(passwordFailed: true) => loc.t('downloads.question.password_wrong'),
      UpdateWait(question: UpdateQuestionKind.password) || null => loc.t('downloads.question.password'),
      UpdateWait(question: UpdateQuestionKind.folders) =>
        loc.plural('downloads.update.question.folders', folderCount, params: {'count': '$folderCount'}),
      UpdateWait(question: UpdateQuestionKind.patchShaped) => loc.t('downloads.update.question.patch_shaped'),
      UpdateWait(question: UpdateQuestionKind.unrecordedPatch) =>
        loc.t('downloads.update.question.unrecorded_patch'),
    };

/// Why an update failed: one of the run's own failures, or a transfer's.
/// [keptIn] is the folder an archive that could not be unpacked was left in.
String updateFailureText(AppLocalizations loc, Object? error, {String? keptIn}) => switch (error) {
      UpdateFailure(:final kind, :final requiredBytes, :final availableBytes) => switch (kind) {
          UpdateFailureKind.noSpace when requiredBytes != null && availableBytes != null =>
            loc.t('downloads.update.failure.no_space', params: {
              'required': formatBytes(requiredBytes),
              'available': formatBytes(availableBytes),
            }),
          UpdateFailureKind.noSpace => loc.t('downloads.update.failure.no_space_unsized'),
          UpdateFailureKind.snapshotFailed => loc.t('downloads.update.failure.snapshot_failed'),
          UpdateFailureKind.writtenPartway => loc.t('downloads.update.failure.written_partway'),
          UpdateFailureKind.writeInterrupted => loc.t('downloads.update.failure.write_interrupted'),
          UpdateFailureKind.unpackFailed => keptIn == null
              ? loc.t('downloads.update.failure.unpack_failed_unplaced')
              : loc.t('downloads.update.failure.unpack_failed', params: {'folder': keptIn}),
          UpdateFailureKind.nothingToInstall => loc.t('downloads.update.failure.nothing_to_install'),
          UpdateFailureKind.unpackGone => loc.t('downloads.update.failure.unpack_gone'),
          UpdateFailureKind.refused => loc.t('downloads.update.failure.refused'),
          UpdateFailureKind.other => loc.t('downloads.update.failure.other'),
        },
      // An update's row offers no Try again, so a stall is not told to try one.
      DownloadStalledException() => loc.t('downloads.update.failure.stalled'),
      _ => downloadFailureText(loc, error),
    };

/// What went wrong with a transfer, as specifically as the failure allows.
///
/// A stall is the one transfer failure with a way out, so it says so instead of sharing the generic wording with a
/// 404. An install failure carries its own message: the bytes arrived fine, so "Download failed" would name the one
/// half that worked.
String downloadFailureText(AppLocalizations loc, Object? error) => switch (error) {
      InstallFailure(:final message) => message,
      DownloadStalledException() => loc.t('downloads.failed_stalled'),
      DownloadNetworkException() => loc.t('downloads.failed_network'),
      // Named with its numbers, or "not enough space" is a dead end.
      InsufficientSpaceException(:final requiredBytes, :final availableBytes) => loc.t('downloads.failed_space', params: {
          'required': formatBytes(requiredBytes),
          'available': formatBytes(availableBytes),
        }),
      _ => loc.t('downloads.failed'),
    };

/// The repeat key of the counted "N mods updated" card, which an undone update counts down.
const String kUpdatesDoneRepeat = 'update-run-done';

/// The repeat key of the counted "Patch added to N mods" card, which a patch taken out by Undo counts down.
const String kUpdatesPatchRepeat = 'update-run-patch';

/// [modId]'s name, a mod of [job]: the library's [mod], else the name it had when the job was made, else its folder id.
/// The one name a mod of a run goes by on the cards, so the card an undone update counts down finds it.
String updateModName(ModInfo? mod, DownloadJob job, String modId) =>
    mod?.name ?? job.update?.modIn(modId)?.name ?? (modId == job.update?.primary.modId ? job.subject : modId);

/// "the 12 Aug file is a snapshot": the file a mod held before its update, which the write kept. [date] is that file's upload date.
String updateSnapshotText(AppLocalizations loc, DateTime? date) => date == null
    ? loc.t('downloads.update.snapshot_undated')
    : loc.t('downloads.update.snapshot', params: {'date': formatResolveDate(date)});

/// What Undo of [result], a mod of [job], left: "back on the 12 Aug file" for the mod's own folder, which [heldFileDate] dates;
/// for a patch put into another mod, through [nameOf], "the patch came out of Miyabi" after Take out and "Miyabi is back as it was" after a restore.
String updateUndoneText(
  AppLocalizations loc,
  DownloadJob job,
  UpdateModResult result, {
  DateTime? heldFileDate,
  required String Function(String modId) nameOf,
}) {
  if (result.patchedElsewhere) {
    final into = nameOf(result.patchedInto!);
    final takenOut = updateUndoRecordOf(job, result.mod.modId)?.takeOut != null;
    return loc.t(takenOut ? 'downloads.update.patch_out_of' : 'downloads.update.back_as_it_was', params: {'mod': into});
  }
  return heldFileDate == null
      ? loc.t('downloads.update.back_on_undated')
      : loc.t('downloads.update.back_on', params: {'date': formatResolveDate(heldFileDate)});
}

/// Why a press of Undo did nothing. A press stores none of the rule's other answers, which only leave the row without Undo.
String updateUndoProblemText(AppLocalizations loc, UpdateUndoProblem problem) => loc.t(switch (problem) {
      UpdateUndoProblem.folderGone => 'downloads.update.undo_reason.folder_gone',
      UpdateUndoProblem.snapshotGone => 'downloads.update.undo_reason.snapshot_gone',
      UpdateUndoProblem.notRead => 'downloads.update.undo_reason.not_read',
      UpdateUndoProblem.notSaved => 'downloads.update.undo_reason.not_saved',
      UpdateUndoProblem.recordNotRemoved => 'downloads.update.undo_reason.record_not_removed',
      UpdateUndoProblem.partWay => 'downloads.update.undo_reason.part_way',
      UpdateUndoProblem.writtenSince ||
      UpdateUndoProblem.beingWritten ||
      UpdateUndoProblem.nothingToUndo ||
      UpdateUndoProblem.unknown =>
        'downloads.update.undo_reason.written_since',
    });

/// What came of one mod of a finished update job, as one line: "Updated · the 12 Aug file is a snapshot", "Patch added on top",
/// "Skipped · its folder was being changed", "Couldn't update" with why, "Undone · back on the 12 Aug file", "Couldn't undo" with why.
/// [heldFileDate] is the date of the file the mod held before the write, [stillOn] the one it holds now, and [nameOf] names another mod.
String updateModLineText(
  AppLocalizations loc,
  DownloadJob job,
  UpdateModResult result, {
  DateTime? heldFileDate,
  DateTime? stillOn,
  required String Function(String modId) nameOf,
}) {
  final undoProblem = result.undoProblem;
  if (result.undone) {
    return loc.t('downloads.update.undone_line',
        params: {'detail': updateUndoneText(loc, job, result, heldFileDate: heldFileDate, nameOf: nameOf)});
  }
  if (undoProblem != null) {
    return loc.t('downloads.update.undo_failed_line', params: {'reason': updateUndoProblemText(loc, undoProblem)});
  }
  return switch (result.end) {
    UpdateModEnd.written when result.patchAdded => loc.t('downloads.update.patch_on_top'),
    UpdateModEnd.written => loc.t('downloads.update.updated_line', params: {'detail': updateSnapshotText(loc, heldFileDate)}),
    UpdateModEnd.skipped =>
      updateSkipText(loc, result.skipReason, stillOn: stillOn, result: result, nameOf: nameOf),
    UpdateModEnd.failed || UpdateModEnd.refused => loc.t('downloads.update.failed_line',
        params: {'reason': updateFailureText(loc, result.failure ?? job.error, keptIn: job.archive?.parent.path)}),
  };
}

/// Why an update, or one mod of it, was skipped. [stillOn] is the date of the file the mod still holds, said for a skip the user chose.
/// [result] is the mod's own, which names, through [nameOf], the mod whose update wrote this one ([UpdateSkipReason.alreadyUpdated]),
/// the mod the file went into as a patch ([UpdateSkipReason.patchAddedElsewhere]),
/// or the mod it was going into, which the same update had already changed ([UpdateSkipReason.changedByThisUpdate]);
/// when that is the mod's own folder, it names the mod whose patch changed it instead.
String updateSkipText(
  AppLocalizations loc,
  UpdateSkipReason? reason, {
  DateTime? stillOn,
  UpdateModResult? result,
  required String Function(String modId) nameOf,
}) {
  final alongWith = switch (result?.alongWith) { final id? => nameOf(id), null => null };
  final patchedInto = switch (result?.patchedInto) { final id? => nameOf(id), null => null };
  final why = switch (reason) {
    UpdateSkipReason.skippedByUser || null =>
      stillOn == null ? null : loc.t('downloads.update.reason.still_on', params: {'date': formatResolveDate(stillOn)}),
    UpdateSkipReason.beingWritten => loc.t('downloads.update.reason.being_written'),
    UpdateSkipReason.modGone => loc.t('downloads.update.reason.gone'),
    UpdateSkipReason.folderRenamed => loc.t('downloads.update.reason.renamed'),
    UpdateSkipReason.sharedFileNotWritten => loc.t('downloads.update.reason.shared_file'),
    UpdateSkipReason.ignoredMeanwhile => loc.t('downloads.update.reason.ignored'),
    UpdateSkipReason.alreadyUpdated => alongWith == null
        ? loc.t('downloads.update.reason.already_updated')
        : loc.t('downloads.update.reason.updated_along_with', params: {'mod': alongWith}),
    UpdateSkipReason.patchAddedElsewhere => patchedInto == null
        ? loc.t('downloads.update.reason.patch_elsewhere_unnamed')
        : loc.t('downloads.update.reason.patch_elsewhere', params: {'mod': patchedInto}),
    UpdateSkipReason.changedByThisUpdate => switch (result) {
        // On the row of the mod whose own folder it is, the reason says whose write changed it.
        UpdateModResult(alongWith: final into?, changedBy: final by?, mod: UpdateMod(:final modId)) when into == modId =>
          by.modId == into
              ? loc.t('downloads.update.reason.left_part_way')
              : loc.t(
                  by.partWay ? 'downloads.update.reason.patch_left_part_way' : 'downloads.update.reason.patch_went_in_first',
                  params: {'mod': nameOf(by.modId)}),
        _ => alongWith == null
            ? loc.t('downloads.update.reason.changed_by_this_update_unnamed')
            : loc.t('downloads.update.reason.changed_by_this_update', params: {'mod': alongWith}),
      },
  };
  return why == null
      ? loc.t('downloads.update.skipped')
      : loc.t('downloads.update.skipped_reason', params: {'reason': why});
}
