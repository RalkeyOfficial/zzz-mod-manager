/// The two stages of an update run's job that `DownloadQueueHost` drives (`docs/update-runs.md` §11):
/// the unpack and preview in the unpack lane ([prepareUpdateJob]), and the write in the install lane ([writeUpdateJob]).
///
/// Neither asks anything or says anything in words.
/// A stage comes to an [UpdateStageResult], and the queue settles the job from it.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../models/character_info.dart';
import '../../utils/state_providers.dart';
import '../api_service.dart';
import '../archive_service.dart';
import '../download/download_job.dart';
import '../download/update_job.dart';
import '../log/logger.dart';
import 'update_applier.dart';
import 'update_layout.dart';
import 'update_prepare.dart';
import 'update_target.dart';
import 'update_write.dart';
import 'update_write_route.dart';

final Logger _log = Logger('update');

/// Unpacks and previews an update job's file.
/// A test substitutes its own, so the host's lanes run without 7-Zip, a mods folder or the network.
typedef UpdatePreparer = Future<UpdateStageResult> Function(ProviderContainer container, DownloadJob job);

/// Writes an update job's file.
/// [skip] holds the job's folders that are being written by something else, which are not written.
typedef UpdateWriter = Future<UpdateStageResult> Function(
  ProviderContainer container,
  DownloadJob job, {
  Set<String> skip,
});

/// What an update job keeps between its stages, as its `prepared`:
/// the unpack, and the folders the user picked when the layout asked.
class UpdateRunKept implements HoldsUnpack {
  const UpdateRunKept({this.unpacked, this.pickedFolders});

  final UpdateUnpacked? unpacked;

  /// The answer to a folders question, paths of [unpacked]'s folders.
  final List<String>? pickedFolders;

  UpdateRunKept withPickedFolders(List<String> folders) => UpdateRunKept(unpacked: unpacked, pickedFolders: folders);

  /// The unpack's folders, or the directory it made when it came out with none.
  @override
  List<String> get unpackedFolders {
    final unpack = unpacked;
    if (unpack == null) return const <String>[];
    if (unpack.folders.isNotEmpty) return unpack.folders;
    final root = unpack.root;
    return root == null ? const <String>[] : [root.path];
  }
}

/// The unpack lane's stage: unpacks the archive, previews it against the mod's folder and stops at the first question only the user can answer.
/// The archive is deleted once unpacked; one that could not be unpacked is kept.
Future<UpdateStageResult> prepareUpdateJob(ProviderContainer container, DownloadJob job) async {
  final found = await _found(container, job);
  if (found case _Unfound(:final result)) return result;
  final _Found(:request, :kept) = found as _Found;

  final archive = job.archive;
  if (kept.unpacked == null && archive == null) {
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no archive to unpack')));
  }
  UpdateUnpacked? made;
  try {
    final result = await _prepare(
      container,
      request,
      kept,
      archive: archive,
      archiveMd5: job.result?.md5,
      password: job.password,
      onUnpacked: (unpacked) => made = unpacked,
    );
    if (made != null && archive != null) await deleteConsumedArchive(archive);
    return await _classify(result, kept);
  } catch (_) {
    await ArchiveService.deleteExtraction(UpdateRunKept(unpacked: made).unpackedFolders);
    rethrow;
  }
}

/// The install lane's stage: previews the kept unpack again against the folder as it is now, and writes it.
///
/// Before anything is turned off or cleared it checks that the unpacked folders are still there, and again just before the write,
/// since a write from a missing unpack would empty the folder and then fail its copy.
/// A mod no longer in the library, or renamed, is skipped,
/// and a verdict changed since the unpack (a restore, a rename of another mod, a patch) is a new question.
/// Each folder is checked for a write by something else immediately before its own write.
/// What came of every mod of the job is in the result.
Future<UpdateStageResult> writeUpdateJob(
  ProviderContainer container,
  DownloadJob job, {
  Set<String> skip = const <String>{},
}) async {
  final kept = job.prepared is UpdateRunKept ? job.prepared! as UpdateRunKept : null;
  final unpacked = kept?.unpacked;
  if (kept == null || unpacked == null) {
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no unpack to write')));
  }

  // Nothing is written until `writeUpdate`, so a failure before it is not an interrupted write.
  final UpdatePrepared prepared;
  final _Plan plan;
  try {
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
    final found = await _found(container, job);
    if (found case _Unfound(:final result)) return result;
    final result = await _prepare(container, (found as _Found).request, kept);
    final verdict = await _classify(result, kept);
    if (verdict is! UpdateStageReady) return verdict;
    prepared = result as UpdatePrepared;
    plan = _planFor(prepared, job.update!, {...skip, ...container.read(modWritesInProgressProvider)});
    if (plan.targets.isEmpty && !plan.writesPatch) return _settled(job, plan.results, null);
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
  } catch (error, stack) {
    _log.error('update not written, its folder could not be read again',
        error: error, stack: stack, fields: {'mod': job.update?.primary.modId});
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: error));
  }

  final clock = _WriteClock(job.update!.primary.modId);
  final UpdateReport report;
  try {
    report = await writeUpdate(
      container,
      prepared,
      targets: plan.targets,
      onStep: clock.step,
      // Read again at each folder's turn: the mark is set by a write, not held by a lock.
      skipWhen: (mod) => container.read(modWritesInProgressProvider).contains(mod.id),
    );
  } finally {
    clock.end();
  }
  if (prepared is PreparedPatch && report.outcome.changed) {
    // A patch write leaves the folder's verdict to its caller, since the verdict names layers.
    forgetUpdateCheck(container, prepared.request.mod.id);
  }

  final results = {for (final result in plan.results) result.mod.modId: result};
  for (final applied in report.applied) {
    final mod = job.update!.modIn(applied.mod.id)!;
    final result = applied.result;
    results[mod.modId] = result.success
        ? UpdateModResult.written(mod)
        : result.failure == UpdateApplyFailure.modMissing
            ? UpdateModResult.skipped(mod, UpdateSkipReason.modGone)
            : UpdateModResult(mod, UpdateModEnd.failed, failure: updateFailureOf(result));
  }
  for (final skipped in report.skipped) {
    final mod = job.update!.modIn(skipped.id)!;
    results[mod.modId] = UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten);
  }
  return _settled(job, [for (final mod in job.update!.mods) ?results[mod.modId]], report);
}

/// Which of a job's mods the write takes, and what came of the ones it does not.
class _Plan {
  const _Plan({required this.targets, required this.writesPatch, required this.results});

  /// The folders a base is written into, in the job's order.
  final List<UpdateTarget> targets;

  /// A patch layer is placed into the job's first mod.
  final bool writesPatch;

  /// The mods not written, each with why.
  final List<UpdateModResult> results;
}

_Plan _planFor(UpdatePrepared prepared, UpdateTask task, Set<String> busy) {
  final results = <UpdateModResult>[];
  final targets = <UpdateTarget>[];
  var writesPatch = false;
  // A pick of the same file that the preview could not place:
  // the archive's group was not looked at (a repair, a patch layer) or did not list it.
  UpdateModResult notPlaced(UpdateMod mod, [Object? cause]) => UpdateModResult(mod, UpdateModEnd.refused,
      failure: UpdateFailure(UpdateFailureKind.refused, cause: cause ?? StateError('not in the archive\'s group')));

  for (final mod in task.mods) {
    final first = identical(mod, task.primary);
    if (busy.contains(mod.modId)) {
      results.add(UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten));
      continue;
    }
    switch (prepared) {
      case PreparedPatch():
        if (first) {
          writesPatch = true;
        } else {
          results.add(notPlaced(mod));
        }
      case PreparedFolders(:final primary, :final group):
        final target = first ? primary : group.targets.where((t) => t.mod.id == mod.modId).firstOrNull;
        if (target != null && target.canProceed) {
          targets.add(target);
        } else if (target != null) {
          results.add(UpdateModResult(mod, UpdateModEnd.refused, failure: _refusalOf(target)));
        } else {
          final refused = group.refused.where((r) => r.mod.id == mod.modId).firstOrNull;
          results.add(notPlaced(mod, refused?.reason));
        }
    }
  }
  return _Plan(targets: targets, writesPatch: writesPatch, results: results);
}

/// The job's result from what came of each of its mods:
/// failed when one failed (a halting failure before any other), written when one was written, refused when one was refused, and skipped otherwise.
UpdateStageResult _settled(DownloadJob job, List<UpdateModResult> results, UpdateReport? report) {
  List<UpdateModResult> ended(UpdateModEnd end) => [for (final r in results) if (r.end == end) r];
  final failed = [for (final r in ended(UpdateModEnd.failed)) r.failure!];
  if (failed.isNotEmpty) {
    return UpdateStageFailed(failed.where((f) => f.haltsRun).firstOrNull ?? failed.first,
        results: results, report: report);
  }
  if (ended(UpdateModEnd.written).isNotEmpty) {
    return UpdateStageWritten(
      job.update!.kind == UpdateKind.reinstall ? JobOutcome.reinstalled : JobOutcome.updated,
      results: results,
      report: report,
    );
  }
  final refused = ended(UpdateModEnd.refused);
  if (refused.isNotEmpty) return UpdateStageFailed(refused.first.failure!, results: results, report: report);
  return UpdateStageSkipped(results.first.skipReason ?? UpdateSkipReason.beingWritten, results: results);
}

Future<bool> _unpackThere(UpdateUnpacked unpacked) async {
  for (final folder in unpacked.folders) {
    if (!await Directory(folder).exists()) return false;
  }
  return true;
}

/// The request for [job]'s first mod, read again from the library and the disk, or why there is none.
sealed class _Lookup {
  const _Lookup();
}

final class _Found extends _Lookup {
  const _Found({required this.request, required this.kept});

  final UpdateRequest request;
  final UpdateRunKept kept;
}

final class _Unfound extends _Lookup {
  const _Unfound(this.result);

  final UpdateStageResult result;
}

Future<_Lookup> _found(ProviderContainer container, DownloadJob job) async {
  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  if (modsPath.isEmpty) {
    return _Unfound(UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no library folder'))));
  }
  final task = job.update!;
  final pick = task.primary;

  final library = await container.read(libraryProvider.future);
  final cached = library.where((mod) => mod.id == pick.modId).firstOrNull;
  final there = await Directory(path.join(modsPath, pick.modId)).exists();
  final same = cached != null && (pick.uid == null || cached.uid == null || cached.uid == pick.uid);
  if (!there || !same) {
    final moved = pick.uid != null && library.any((mod) => mod.uid == pick.uid && mod.id != pick.modId);
    _log.info('update skipped, the mod is not there', fields: {'mod': pick.modId, 'renamed': moved});
    return _Unfound(UpdateStageSkipped(moved ? UpdateSkipReason.folderRenamed : UpdateSkipReason.modGone));
  }
  // The origin from disk: a restore or another write may have changed it since the last scan.
  final service = await container.read(modManagerServiceProvider.future);
  final mod = cached.copyWith(origin: await service.readModOrigin(pick.modId));

  final remoteModId = pick.layer?.modId ?? mod.origin?.base?.modId;
  final route = updateWriteRoute(origin: mod.origin, subject: pick.layer);
  if (remoteModId == null || route.kind == UpdateWriteKind.none) {
    return const _Unfound(UpdateStageFailed(UpdateFailure(UpdateFailureKind.refused)));
  }
  final reinstall = task.kind == UpdateKind.reinstall;
  final kept = job.prepared is UpdateRunKept ? job.prepared! as UpdateRunKept : const UpdateRunKept();
  return _Found(
    kept: kept,
    request: UpdateRequest(
      mod: mod,
      modsPath: modsPath,
      remoteModId: remoteModId,
      file: job.file,
      patchFiles: route.patchFiles,
      patchModId: route.patchModId,
      asCompanion: route.asCompanion,
      flattensPatch: route.flattensPatch,
      published: task.published,
      reinstall: reinstall,
      // Only the mods the user picked are written, so the archive's other mods are looked for only when there are some.
      previewSiblings: task.mods.length > 1 && !reinstall && !route.asCompanion,
      placeAsPatch: route.kind == UpdateWriteKind.patch,
    ),
  );
}

Future<UpdatePrepareResult> _prepare(
  ProviderContainer container,
  UpdateRequest request,
  UpdateRunKept kept, {
  File? archive,
  String? archiveMd5,
  String? password,
  void Function(UpdateUnpacked unpacked)? onUnpacked,
}) {
  final unpacked = kept.unpacked;
  final picked = kept.pickedFolders;
  return prepareUpdate(
    container,
    request,
    archive: archive,
    archiveMd5: archiveMd5,
    password: password,
    foldersAnswer: unpacked != null && picked != null ? FoldersAnswer(unpacked: unpacked, folders: picked) : null,
    unpacked: picked == null ? unpacked : null,
    onUnpacked: onUnpacked,
  );
}

/// Whether [result] can go on to the write, and what stops it when not.
/// A patch-shaped download and a patch nothing records are questions; the folders the write leaves out are not.
Future<UpdateStageResult> _classify(UpdatePrepareResult result, UpdateRunKept kept) async {
  switch (result) {
    case UpdateAsks(question: PasswordQuestion(:final failed)):
      return UpdateStageAsks(UpdateWait(UpdateQuestionKind.password, passwordFailed: failed), prepared: kept);
    case UpdateAsks(question: final FoldersQuestion question):
      return UpdateStageAsks(
        const UpdateWait(UpdateQuestionKind.folders),
        prepared: UpdateRunKept(unpacked: question.unpacked),
      );
    case UpdateAsks(:final question):
      return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('unexpected $question')));
    case UpdateUnpackFailed(:final extraction):
      return UpdateStageFailed(extraction.failure == ExtractFailure.insufficientSpace
          ? UpdateFailure(
              UpdateFailureKind.noSpace,
              requiredBytes: extraction.requiredBytes,
              availableBytes: extraction.availableBytes,
            )
          : UpdateFailure(UpdateFailureKind.unpackFailed, cause: extraction.failure));
    case UpdateNothingToInstall(:final unpacked):
      await ArchiveService.deleteExtraction(UpdateRunKept(unpacked: unpacked).unpackedFolders);
      return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.nothingToInstall));
    case final UpdatePrepared prepared:
      final next = UpdateRunKept(unpacked: prepared.unpacked, pickedFolders: kept.pickedFolders);
      final stop = [
        for (final question in prepared.questions)
          if (question is PatchShapedQuestion)
            UpdateQuestionKind.patchShaped
          else if (question is UnrecordedPatchQuestion)
            UpdateQuestionKind.unrecordedPatch,
      ].firstOrNull;
      if (stop != null) return UpdateStageAsks(UpdateWait(stop), prepared: next);
      return UpdateStageReady(prepared: next);
  }
}

UpdateFailure _refusalOf(UpdateTarget target) => target.preview.layout.problem == UpdateLayoutProblem.nothingToInstall
    ? const UpdateFailure(UpdateFailureKind.nothingToInstall)
    : UpdateFailure(UpdateFailureKind.refused, cause: target.refusal);

/// The failure of one folder's write, as the run calls it.
/// No room for its snapshot, a snapshot that could not be taken and a copy that failed part-way halt the run.
@visibleForTesting
UpdateFailure updateFailureOf(UpdateApplyResult result) => switch (result.failure) {
      UpdateApplyFailure.snapshot => switch (result.snapshotNoRoom) {
          final room? => UpdateFailure(
              UpdateFailureKind.noSpace,
              requiredBytes: room.requiredBytes,
              availableBytes: room.availableBytes,
            ),
          null => UpdateFailure(UpdateFailureKind.snapshotFailed, cause: result.error),
        },
      UpdateApplyFailure.copy => UpdateFailure(UpdateFailureKind.writtenPartway, cause: result.error),
      UpdateApplyFailure.layout => UpdateFailure(UpdateFailureKind.refused, cause: result.error),
      UpdateApplyFailure.modMissing || null => UpdateFailure(UpdateFailureKind.other, cause: result.error),
    };

/// Logs how long a write took, and each of its steps, for the measurement the update limits wait for (`docs/update-runs.md` §4.5).
///
/// The folders of a write are written one after another, so a step ends when the next one starts.
/// The last step runs to the end of the write, the record and the prune included:
/// link and prune for a mod that was on, wipe and copy for one that was off.
/// The write itself is timed only when a folder's write started, that is when its first step was reported, whether it then ended or threw.
class _WriteClock {
  _WriteClock(this._job);

  final String _job;
  final DateTime _started = DateTime.now();
  bool _wrote = false;
  ModInfo? _mod;
  UpdateWriteStep? _step;
  DateTime? _since;

  void step(ModInfo mod, UpdateWriteStep step) {
    _endStep();
    _wrote = true;
    _mod = mod;
    _step = step;
    _since = DateTime.now();
  }

  void end() {
    _endStep();
    if (!_wrote) return;
    _log.info('update stage ended', fields: {'mod': _job, 'stage': 'write', 'seconds': _secondsSince(_started)});
  }

  void _endStep() {
    final (mod, step, since) = (_mod, _step, _since);
    if (mod == null || step == null || since == null) return;
    _log.info('update stage ended', fields: {
      'mod': mod.id,
      'stage': switch (step) {
        UpdateWriteStep.savingSnapshot => 'snapshot',
        UpdateWriteStep.replacingFiles => 'wipe_and_copy',
        UpdateWriteStep.linking => 'link_and_prune',
      },
      'seconds': _secondsSince(since),
    });
    _mod = null;
    _step = null;
    _since = null;
  }

  static double _secondsSince(DateTime since) => DateTime.now().difference(since).inMilliseconds / 1000;
}
