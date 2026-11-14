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
import '../../models/mod_download.dart';
import '../../utils/state_providers.dart';
import '../api_service.dart';
import '../archive_service.dart';
import '../download/download_job.dart';
import '../download/download_queue.dart';
import '../download/update_job.dart';
import '../log/logger.dart';
import '../update_check.dart';
import 'update_applier.dart';
import 'update_layout.dart';
import 'update_prepare.dart';
import 'update_target.dart';
import 'update_undo.dart' show UpdateUndoRecord;
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
/// the unpack, the question it waits on with what that question shows, and the answers given so far,
/// so a preview made again, the write's included, asks nothing already answered.
class UpdateRunKept implements HoldsUnpack {
  const UpdateRunKept({
    this.unpacked,
    this.pickedFolders,
    this.foldersQuestion,
    this.patchQuestion,
    this.answers = const <String, UpdateModAnswer>{},
  });

  final UpdateUnpacked? unpacked;

  /// The answer to a folders question, paths of [unpacked]'s folders.
  final List<String>? pickedFolders;

  /// The folders question the job waits on: the archive's folders to pick from, and why the layout asks.
  final FoldersQuestion? foldersQuestion;

  /// The patch question the job waits on: what its window shows.
  final UpdatePatchFinding? patchQuestion;

  /// The answers about each mod, by folder id.
  final Map<String, UpdateModAnswer> answers;

  /// The same with the fields given. A question is kept only while the job waits on it, so [noQuestion] drops both.
  /// [noPick] drops [pickedFolders], whose paths belong to the unpack they were picked from.
  UpdateRunKept copyWith({
    UpdateUnpacked? unpacked,
    List<String>? pickedFolders,
    FoldersQuestion? foldersQuestion,
    UpdatePatchFinding? patchQuestion,
    Map<String, UpdateModAnswer>? answers,
    bool noQuestion = false,
    bool noPick = false,
  }) =>
      UpdateRunKept(
        unpacked: unpacked ?? this.unpacked,
        pickedFolders: pickedFolders ?? (noPick ? null : this.pickedFolders),
        foldersQuestion: foldersQuestion ?? (noQuestion ? null : this.foldersQuestion),
        patchQuestion: patchQuestion ?? (noQuestion ? null : this.patchQuestion),
        answers: answers ?? this.answers,
      );

  /// The same, with the folders question answered by [folders].
  UpdateRunKept withPickedFolders(List<String> folders) => copyWith(pickedFolders: folders, noQuestion: true);

  /// The same, with [answer] about the mod [modId] and no question waiting.
  UpdateRunKept withAnswer(String modId, UpdateModAnswer answer) =>
      copyWith(answers: {...answers, modId: answer}, noQuestion: true);

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

/// What an update job's stages keep with it ([UpdateRunKept]), or null for any other job.
extension UpdateKeptOf on DownloadJob {
  UpdateRunKept? get updateKept => switch (prepared) {
        final UpdateRunKept kept => kept,
        _ => null,
      };
}

/// What the patch question about one mod shows: the archive folders its file would put down, and what that file's `.ini` asks for and does not carry.
class UpdatePatchFinding {
  const UpdatePatchFinding({required this.modId, required this.sources, this.missing = const <String>[]});

  /// The folder id of the mod the update is for.
  final String modId;

  /// The unpacked folders the layout maps onto the mod.
  final List<String> sources;

  /// Normalised and sorted, as the patch rule keeps them.
  final List<String> missing;
}

/// The unpack lane's stage: unpacks the archive, previews it against the mod's folder and stops at the first question only the user can answer.
/// The archive is deleted once unpacked; one that could not be unpacked is kept.
///
/// A mod whose update was ignored or written by something else while the job waited is left out before anything is unpacked,
/// so it asks nothing, its archive's password included; when that leaves no mod, the job is skipped ([modsLeftOut]).
Future<UpdateStageResult> prepareUpdateJob(ProviderContainer container, DownloadJob job) async {
  final found = await _found(container, job);
  if (found case _Unfound(:final result)) return result;
  final _Found(:request, :kept) = found as _Found;

  final skipped = await modsLeftOut(container, job, primary: request.mod);
  final writes = [for (final mod in job.update!.mods) if (!skipped.containsKey(mod.modId)) mod.modId];
  if (writes.isEmpty) return _settled(job, [for (final mod in job.update!.mods) skipped[mod.modId]!], null);

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
    return await _classify(result, kept, writes: writes, primary: request.mod.id);
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
/// and so is one whose update was ignored or written by something else while the job waited ([modsLeftOut]).
/// A verdict changed since the unpack (a restore, a rename of another mod, a patch) is a new question.
/// Each folder is checked immediately before its own write for a write by something else that is running or has started since the stage began reading ([_WritesSince]).
/// What came of every mod of the job is in the result.
Future<UpdateStageResult> writeUpdateJob(
  ProviderContainer container,
  DownloadJob job, {
  Set<String> skip = const <String>{},
}) async {
  final kept = job.updateKept;
  final unpacked = kept?.unpacked;
  if (kept == null || unpacked == null) {
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no unpack to write')));
  }

  // Before anything is read: a write by something else that starts after this is not in what the reads below saw.
  final since = _WritesSince(container);

  // Nothing is written until `writeUpdate`, so a failure before it is not an interrupted write.
  final UpdatePrepared prepared;
  final _Plan plan;
  var library = const <ModInfo>[];
  try {
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
    final found = await _found(container, job);
    if (found case _Unfound(:final result)) return result;
    final request = (found as _Found).request;
    final skipped = await modsLeftOut(container, job, primary: request.mod);
    final busy = {...skip, ...container.read(modWritesInProgressProvider)};
    for (final mod in job.update!.mods) {
      if (busy.contains(mod.modId) || since.moved(mod.modId)) {
        skipped.putIfAbsent(mod.modId, () => UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten));
      }
    }
    final writes = [for (final mod in job.update!.mods) if (!skipped.containsKey(mod.modId)) mod.modId];
    if (writes.isEmpty) return _settled(job, [for (final mod in job.update!.mods) skipped[mod.modId]!], null);
    final result = await _prepare(container, request, kept);
    final verdict = await _classify(result, kept, writes: writes, primary: request.mod.id);
    if (verdict is! UpdateStageReady) return verdict;
    prepared = result as UpdatePrepared;
    plan = _planFor(prepared, job.update!, skipped, kept.answers);
    if (plan.targets.isEmpty && !plan.writesPatch && plan.placements.isEmpty) return _settled(job, plan.results, null);
    if (plan.placements.isNotEmpty) library = await container.read(libraryProvider.future);
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
  } catch (error, stack) {
    _log.error('update not written, its folder could not be read again',
        error: error, stack: stack, fields: {'mod': job.update?.primary.modId});
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: error));
  }

  final clock = _WriteClock(job.update!.primary.modId);
  final queue = container.read(downloadQueueProvider.notifier);
  void onStep(ModInfo mod, UpdateWriteStep step) {
    clock.step(mod, step);
    queue.reportWriteStep(job.seq, UpdateWriting(mod.id, step));
  }

  // Read again at each folder's turn: the mark is set by a write, not held by a lock.
  // A write that started and ended since the reads above is caught by the folder's counter.
  bool busyNow(String modId) => container.read(modWritesInProgressProvider).contains(modId) || since.moved(modId);

  final results = {for (final result in plan.results) result.mod.modId: result};
  var report = const UpdateReport(applied: [], outcome: GroupWriteOutcome(settledMarks: <String>{}, changed: false));
  try {
    if (plan.targets.isNotEmpty || plan.writesPatch) {
      report = await writeUpdate(
        container,
        prepared,
        targets: plan.targets,
        onStep: onStep,
        skipWhen: (mod) => busyNow(mod.id),
      );
    }
    if (prepared is PreparedPatch && report.outcome.changed) report = _withVerdictForgotten(container, report, prepared.request.mod.id);
    final written = {for (final applied in report.applied) if (applied.result.success) applied.mod.id};
    // The write counter of each folder this job has written, as its last write of it started; null when another write overlapped it.
    // That write is the last to move it, so a counter past this is a write by something else since.
    final ownWrite = {for (final applied in report.applied) applied.mod.id: applied.writesStarted};
    bool writtenSinceOwn(String modId) => ownWrite.containsKey(modId)
        ? ownWrite[modId] == null || container.read(modWritesStartedProvider)[modId] != ownWrite[modId]
        : since.moved(modId);
    // A folder takes one placement per job, and none once a write of the job left it part-way (`docs/update-runs.md` §6).
    // Keyed by folder, with the job's mod whose write changed it.
    final changedByJob = <String, ({String modId, bool partWay})>{
      for (final applied in report.applied)
        if (applied.result.failure == UpdateApplyFailure.copy) applied.mod.id: (modId: applied.mod.id, partWay: true),
    };
    for (final placement in plan.placements) {
      final mod = placement.mod;
      final into = library.where((m) => m.id == placement.intoModId).firstOrNull;
      if (into == null) {
        results[mod.modId] = UpdateModResult(mod, UpdateModEnd.refused,
            failure: UpdateFailure(UpdateFailureKind.refused, cause: StateError('the mod to patch is not in the library')));
        continue;
      }
      if (changedByJob[into.id] case final changedBy?) {
        results[mod.modId] =
            UpdateModResult.skipped(mod, UpdateSkipReason.changedByThisUpdate, alongWith: into.id, changedBy: changedBy);
        continue;
      }
      if (container.read(modWritesInProgressProvider).contains(into.id) || writtenSinceOwn(into.id)) {
        results[mod.modId] = UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten);
        continue;
      }
      final onTop = into.id == mod.modId;
      final dismissUpTo = mod.dismissUpTo;
      final applied = await placeUpdateAsPatch(
        container,
        prepared as PreparedFolders,
        target: placement.target,
        into: into,
        dismissBase: onTop && dismissUpTo != null ? (layer: mod.layer, until: dismissUpTo) : null,
        onStep: onStep,
      );
      report = report.including(applied, forMod: mod.modId);
      // A placement refused before its write started has neither, and leaves the counter where it was.
      if (applied.writesStarted != null || applied.result.snapshot != null) ownWrite[into.id] = applied.writesStarted;
      if (applied.result.success || applied.result.failure == UpdateApplyFailure.copy) {
        changedByJob[into.id] = (modId: mod.modId, partWay: !applied.result.success);
      }
      if (applied.result.success) {
        // A patch layer changes what the folder's verdict says about it; the mod the update is for keeps it as the mark the write removed, so its row reads the same.
        // A mod of this job whose own update was not written keeps its verdict, since that update is still to take.
        final unwrittenOfJob = job.update!.modIn(into.id) != null && !written.contains(into.id);
        if (onTop || !unwrittenOfJob) report = _withVerdictForgotten(container, report, into.id, keep: onTop);
        results[mod.modId] = onTop
            ? UpdateModResult.written(mod, patchedInto: into.id)
            : UpdateModResult.skipped(mod, UpdateSkipReason.patchAddedElsewhere, patchedInto: into.id);
      } else {
        results[mod.modId] = UpdateModResult(mod, UpdateModEnd.failed, failure: updateFailureOf(applied.result));
      }
    }
  } finally {
    clock.end();
  }

  final placements = report.placed.values.toSet();
  for (final applied in report.applied) {
    final mod = job.update!.modIn(applied.mod.id);
    // A placement has its result on the mod it was for, above; the folder it went into keeps its own.
    if (mod == null || placements.contains(applied)) continue;
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
  bool wrote(String modId) => results[modId]?.hasWrite ?? false;
  report = report.copyWith(
    undo: {
      for (final mod in job.update!.mods)
        if (_undoRecordFor(mod, results[mod.modId], report) case final record?) mod.modId: record,
    },
    leftOut: switch (prepared) {
      PreparedFolders() => _leftOut([
          for (final target in plan.targets)
            if (wrote(target.mod.id)) target,
          for (final placement in plan.placements)
            if (wrote(placement.mod.modId)) placement.target,
        ]),
      PreparedPatch() => const <String>[],
    },
  );
  return _settled(job, [for (final mod in job.update!.mods) ?results[mod.modId]], report);
}

/// What Undo takes back for [mod], from what [report] says its write did ([UpdateReport.writeFor]). Null when nothing of it can be undone:
/// nothing was written for it, the write took no snapshot, or another write was running on the folder as this one started.
/// A placement that added a layer is taken out; every other write is restored from its snapshot (`docs/update-runs.md` §8).
UpdateUndoRecord? _undoRecordFor(UpdateMod mod, UpdateModResult? result, UpdateReport report) {
  if (result == null || !result.hasWrite) return null;
  final written = report.writeFor(mod.modId);
  if (written == null || !written.result.success) return null;
  final folderId = written.mod.id;
  final snapshot = written.result.snapshot;
  final writesStarted = written.writesStarted;
  if (snapshot == null || writesStarted == null) return null;
  if (!identical(written, report.placed[mod.modId]) || !written.newLayer) {
    return UpdateUndoRecord(folderId: folderId, snapshot: snapshot, writesStarted: writesStarted);
  }
  return UpdateUndoRecord(
    folderId: folderId,
    snapshot: snapshot,
    writesStarted: writesStarted,
    takeOut: DownloadKey.patch(mod.layer.modId),
    // Put on top of its own folder, the placement wrote the dismissal Ignore would have on the mod's own layer.
    baseDismissal: folderId == mod.modId && mod.dismissUpTo != null ? (layer: mod.layer, until: mod.heldDismissedUntil) : null,
  );
}

/// The archive's top-level folders, by name, that none of [targets] took.
List<String> _leftOut(List<UpdateTarget> targets) {
  final taken = {
    for (final target in targets)
      for (final source in target.preview.sourceFolders) path.basename(source),
  };
  return {
    for (final target in targets)
      for (final folder in target.preview.layout.unused)
        if (!taken.contains(path.basename(folder))) path.basename(folder),
  }.toList()
    ..sort();
}

/// [report] with the session verdict of the folder [modId] dropped, as a write of a patch layer leaves it to its caller:
/// the verdict names the folder's layers, and the write changed them.
/// With [keep] it is kept in the report as the mark the write removed, as a base write keeps its own.
UpdateReport _withVerdictForgotten(ProviderContainer container, UpdateReport report, String modId, {bool keep = true}) {
  final mark = container.read(modUpdateChecksProvider)[modId];
  forgetUpdateCheck(container, modId);
  if (!keep || mark == null) return report;
  return report.copyWith(removedMarks: {...report.removedMarks, modId: mark});
}

/// The mods of [job] its write leaves out, by folder id, each skipped with why:
/// those skipped one at a time at a question about each ([UpdateRunKept.answers]),
/// and those whose update was ignored or written by something else while the job waited ([_settledMeanwhile]).
/// [primary] is the job's first mod as just read again; without it, it is read here,
/// and when it is no longer in the library only the skips are known, since its own stage says the rest.
Future<Map<String, UpdateModResult>> modsLeftOut(ProviderContainer container, DownloadJob job, {ModInfo? primary}) async {
  // Only a read: the skip, if any, is the stage's or the question's to log.
  final first = primary ?? switch (await _found(container, job, quiet: true)) {
    _Found(:final request) => request.mod,
    _Unfound() => null,
  };
  return {
    ..._answeredSkips(job),
    if (first != null) ...await _settledMeanwhile(container, job, first),
  };
}

/// The mods of [job] skipped one at a time, at a question about each, by folder id.
Map<String, UpdateModResult> _answeredSkips(DownloadJob job) => {
      for (final mod in job.update!.mods)
        if (job.updateKept?.answers[mod.modId] case SkipThisMod(:final reason)) mod.modId: UpdateModResult.skipped(mod, reason),
    };

/// Which of a job's mods the write takes, and what came of the ones it does not.
class _Plan {
  const _Plan({required this.targets, required this.writesPatch, required this.results, this.placements = const []});

  /// The folders a base is written into, in the job's order.
  final List<UpdateTarget> targets;

  /// A patch layer is placed into the job's first mod.
  final bool writesPatch;

  /// The patch-shaped files the user answered should go on top of a folder as a patch, written after the bases.
  final List<_Placement> placements;

  /// The mods not written, each with why.
  final List<UpdateModResult> results;
}

/// A patch-shaped file for [mod], placed over the folder [intoModId] as the user answered.
class _Placement {
  const _Placement(this.mod, this.target, this.intoModId);

  final UpdateMod mod;
  final UpdateTarget target;
  final String intoModId;
}

/// [skipped] holds the mods already left out, by folder id, each with why, and [answers] what the user answered about each.
_Plan _planFor(
  UpdatePrepared prepared,
  UpdateTask task,
  Map<String, UpdateModResult> skipped,
  Map<String, UpdateModAnswer> answers,
) {
  final results = <UpdateModResult>[];
  final targets = <UpdateTarget>[];
  final placements = <_Placement>[];
  var writesPatch = false;
  // A pick of the same file that the preview could not place:
  // the archive's group was not looked at (a repair, a patch layer) or did not list it.
  UpdateModResult notPlaced(UpdateMod mod, [Object? cause]) => UpdateModResult(mod, UpdateModEnd.refused,
      failure: UpdateFailure(UpdateFailureKind.refused, cause: cause ?? StateError('not in the archive\'s group')));

  for (final mod in task.mods) {
    final first = identical(mod, task.primary);
    if (skipped[mod.modId] case final result?) {
      results.add(result);
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
        final answer = answers[mod.modId];
        if (target != null && answer is PlaceAsPatch) {
          placements.add(_Placement(mod, target, answer.intoModId));
        } else if (_unplaceablePatch(_ownQuestions(prepared, mod.modId))) {
          // Never written by the wipe, and no placement could take it.
          results.add(UpdateModResult(mod, UpdateModEnd.refused,
              failure: UpdateFailure(UpdateFailureKind.refused, cause: StateError('a patch of several folders'))));
        } else if (target != null && target.canProceed) {
          targets.add(target);
        } else if (target != null) {
          results.add(UpdateModResult(mod, UpdateModEnd.refused, failure: _refusalOf(target)));
        } else {
          final refused = group.refused.where((r) => r.mod.id == mod.modId).firstOrNull;
          results.add(notPlaced(mod, refused?.reason));
        }
    }
  }
  return _Plan(targets: targets, writesPatch: writesPatch, results: results, placements: placements);
}

/// The job's result from what came of each of its mods:
/// failed when one failed (a halting failure before any other), written when one was written, refused when one was refused, and skipped otherwise.
/// A job whose every written mod had its file put on top as a patch is "Patch added".
UpdateStageResult _settled(DownloadJob job, List<UpdateModResult> results, UpdateReport? report) {
  List<UpdateModResult> ended(UpdateModEnd end) => [for (final r in results) if (r.end == end) r];
  final failed = [for (final r in ended(UpdateModEnd.failed)) r.failure!];
  if (failed.isNotEmpty) {
    return UpdateStageFailed(failed.where((f) => f.haltsRun).firstOrNull ?? failed.first,
        results: results, report: report);
  }
  final written = ended(UpdateModEnd.written);
  if (written.isNotEmpty) {
    return UpdateStageWritten(
      job.update!.kind == UpdateKind.reinstall
          ? JobOutcome.reinstalled
          : written.every((r) => r.patchAdded)
              ? JobOutcome.patchAdded
              : JobOutcome.updated,
      results: results,
      report: report,
    );
  }
  final refused = ended(UpdateModEnd.refused);
  if (refused.isNotEmpty) return UpdateStageFailed(refused.first.failure!, results: results, report: report);
  return UpdateStageSkipped(results.first.skipReason ?? UpdateSkipReason.beingWritten, results: results, report: report);
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

/// [pick]'s mod in [library]: the mod in its folder, unless that folder now holds a mod of another uid.
ModInfo? pickedModIn(List<ModInfo> library, UpdateMod pick) {
  final cached = library.where((mod) => mod.id == pick.modId).firstOrNull;
  final same = cached != null && (pick.uid == null || cached.uid == null || cached.uid == pick.uid);
  return same ? cached : null;
}

/// Why [pick] has no mod to write into: renamed when its uid is under another folder, else gone.
UpdateSkipReason missingPickReason(List<ModInfo> library, UpdateMod pick) {
  final moved = pick.uid != null && library.any((mod) => mod.uid == pick.uid && mod.id != pick.modId);
  return moved ? UpdateSkipReason.folderRenamed : UpdateSkipReason.modGone;
}

/// The library folder an update run writes into, or null when none is set.
Future<String?> updateLibraryFolder() async {
  final modsPath = (await ApiService.getConfig())['mods_path'] ?? '';
  return modsPath.isEmpty ? null : modsPath;
}

/// [quiet] logs nothing, for a read that skips nothing itself.
Future<_Lookup> _found(ProviderContainer container, DownloadJob job, {bool quiet = false}) async {
  final modsPath = await updateLibraryFolder();
  if (modsPath == null) {
    return _Unfound(UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no library folder'))));
  }
  final task = job.update!;
  final pick = task.primary;

  final library = await container.read(libraryProvider.future);
  final cached = pickedModIn(library, pick);
  final there = await Directory(path.join(modsPath, pick.modId)).exists();
  if (!there || cached == null) {
    final reason = missingPickReason(library, pick);
    if (!quiet) {
      _log.info('update skipped, the mod is not there',
          fields: {'mod': pick.modId, 'renamed': reason == UpdateSkipReason.folderRenamed});
    }
    return _Unfound(UpdateStageSkipped(reason));
  }
  // The origin from disk: a restore or another write may have changed it since the last scan.
  final service = await container.read(modManagerServiceProvider.future);
  final mod = cached.copyWith(origin: await service.readModOrigin(pick.modId));

  final remoteModId = pick.layer.modId;
  final route = updateWriteRoute(origin: mod.origin, subject: pick.layer);
  if (route.kind == UpdateWriteKind.none) {
    return const _Unfound(UpdateStageFailed(UpdateFailure(UpdateFailureKind.refused)));
  }
  final reinstall = task.kind == UpdateKind.reinstall;
  final kept = job.updateKept ?? const UpdateRunKept();
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

/// The mods' write counters (`modWritesStartedProvider`) and the writes running, as they were when the write stage started.
///
/// Taken before the stage reads a sidecar, so a write by something else that starts after it, an Ignore or a one-mod write, is seen even when it ends before the stage's own read or before a folder's turn.
/// The run's own earlier writes are not mistaken for one: a folder's next job starts its write stage only after its previous job has ended, and a job's folders are written one after another, each counted on its own.
class _WritesSince {
  _WritesSince(ProviderContainer container)
      : _container = container,
        _started = container.read(modWritesStartedProvider),
        _running = container.read(modWritesInProgressProvider);

  final ProviderContainer _container;
  final Map<String, int> _started;
  final Set<String> _running;

  /// Whether a write on [modId] was running at the start or has started since.
  bool moved(String modId) =>
      _running.contains(modId) || _container.read(modWritesStartedProvider)[modId] != _started[modId];
}

/// The mods of [job] whose update settled while the job waited, by folder id, each skipped with why (`docs/update-runs.md` §10).
///
/// Ignored meanwhile: the verdict dismisses the layer, or the sidecar's dismissal changed since the press and reaches the picked file's date.
/// A dismissal the layer already held at the press is not read as one: the user pressed Update with it in place.
/// Already updated: the layer's record names the picked file, or it names another file than at the press, none included, while the verdict neither offers the update nor dismisses it,
/// so a file written through the one-mod window is not written over with this older one.
/// A layer whose record is unchanged is written even without a verdict: a base written earlier in the run drops the folder's whole verdict, its patch layer's included.
/// A reinstall writes the file the layer holds, so none of this applies to it.
Future<Map<String, UpdateModResult>> _settledMeanwhile(ProviderContainer container, DownloadJob job, ModInfo primary) async {
  final task = job.update!;
  final settled = <String, UpdateModResult>{};
  if (task.kind == UpdateKind.reinstall) return settled;
  final checks = container.read(modUpdateChecksProvider);
  final service = await container.read(modManagerServiceProvider.future);
  final fileDate = job.file.dateAdded;
  for (final mod in task.mods) {
    final origin = mod.modId == primary.id ? primary.origin : await service.readModOrigin(mod.modId);
    if (origin == null) continue;
    final record = origin.downloadOf(mod.layer);
    final verdict = _layerVerdict(checks[mod.modId], mod.layer);
    final until = record?.updatesDismissedUntil;
    final held = mod.heldDismissedUntil;
    // By instant: the press read the library's copy and this reads the disk, which can differ in time zone only.
    final ignoredSince = until != null &&
        (held == null || !until.isAtSameMomentAs(held)) &&
        fileDate != null &&
        !fileDate.isAfter(until);
    final changed = record?.fileId != mod.heldFileId;
    final written = record?.fileId == job.file.idRow ||
        (changed && verdict?.hasUpdate != true && verdict?.dismissed != true);
    if (written) {
      settled[mod.modId] = UpdateModResult.skipped(
        mod,
        UpdateSkipReason.alreadyUpdated,
        alongWith: _writtenAlongWith(container.read(downloadQueueProvider), job, mod),
      );
    } else if (verdict?.dismissed == true || ignoredSince) {
      settled[mod.modId] = UpdateModResult.skipped(mod, UpdateSkipReason.ignoredMeanwhile);
    }
  }
  if (settled.isNotEmpty) {
    _log.info('update skipped, settled while it waited', fields: {
      for (final MapEntry(key: id, value: result) in settled.entries) id: result.skipReason!.name,
    });
  }
  return settled;
}

/// What [check], a folder's verdict, says about [layer], or null when it says nothing about it.
UpdateCheck? _layerVerdict(UpdateCheck? check, DownloadKey layer) {
  if (check == null) return null;
  for (final own in check.layers) {
    if (own.key == layer) return own.check;
  }
  return check.layers.isEmpty || check.subject == layer ? check : null;
}

/// The folder id of the mod whose job, another of the run, wrote [mod]'s layer, or null.
String? _writtenAlongWith(List<DownloadJob> jobs, DownloadJob job, UpdateMod mod) {
  for (final other in jobs) {
    if (other.seq == job.seq || !other.isUpdate) continue;
    final wrote = other.modResults.any((r) => r.end == UpdateModEnd.written && r.mod.sameLayerAs(mod));
    final by = other.update!.primary.modId;
    if (wrote && by != mod.modId) return by;
  }
  return null;
}

/// Whether [result] can go on to the write, and what stops it when not.
/// A patch-shaped download and a patch nothing records are questions, for every mod the write takes ([writes], in the job's order),
/// unless the user has answered that question about that mod ([UpdateRunKept.answers]); the folders the write leaves out are not.
/// The folders question is about the job's first mod, [primary], whose preview drives the job.
Future<UpdateStageResult> _classify(
  UpdatePrepareResult result,
  UpdateRunKept kept, {
  required List<String> writes,
  required String primary,
}) async {
  switch (result) {
    case UpdateAsks(question: PasswordQuestion(:final failed)):
      return UpdateStageAsks(UpdateWait(UpdateQuestionKind.password, passwordFailed: failed), prepared: kept);
    case UpdateAsks(question: final FoldersQuestion question):
      return UpdateStageAsks(
        UpdateWait(UpdateQuestionKind.folders, modId: primary),
        // Asked again: the question comes with its own unpack, which an earlier pick's paths do not name.
        prepared: kept.copyWith(unpacked: question.unpacked, foldersQuestion: question, noQuestion: true, noPick: true),
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
      final next = kept.copyWith(unpacked: prepared.unpacked, noQuestion: true);
      final stop = _questionOf(prepared, writes, kept.answers);
      if (stop == null) return UpdateStageReady(prepared: next);
      return UpdateStageAsks(UpdateWait(stop.kind, modId: stop.modId), prepared: next.copyWith(patchQuestion: stop.finding));
  }
}

/// Whether [answer] settles the question [kind] about its mod. A file placed as a patch is not written by the wipe, so a patch nothing records is no loss to it.
bool _answers(UpdateModAnswer? answer, UpdateQuestionKind kind) => switch (answer) {
      SkipThisMod() || PlaceAsPatch() => true,
      UpdateAnyway() => kind == UpdateQuestionKind.unrecordedPatch,
      null => false,
    };

/// The questions [modId]'s own preview raises, with that preview: the primary's from the job's, a picked sibling's from its own.
/// None for a sibling the group refused, which is refused at the write, and none for a patch layer's file.
({List<UpdateQuestion> questions, UpdatePreview? preview}) _ownQuestions(UpdatePrepared prepared, String modId) =>
    switch (prepared) {
      PreparedFolders(primary: final target) when modId == prepared.request.mod.id =>
        (questions: prepared.questions, preview: target.preview),
      PreparedFolders(:final group) => switch (group.targets.where((t) => t.mod.id == modId && t.canProceed).firstOrNull) {
          final target? => (
              questions: confirmationQuestions(target.preview, flattensPatch: target.flattensPatch),
              preview: target.preview,
            ),
          null => (questions: const <UpdateQuestion>[], preview: null),
        },
      PreparedPatch() => (questions: const <UpdateQuestion>[], preview: null),
    };

/// Whether a mod's file is shaped like a patch and its layout does not map exactly one of the archive's folders onto it:
/// no answer to the patch question could place it (`placeUpdateAsPatch`), so it is refused at the write rather than asked.
bool _unplaceablePatch(({List<UpdateQuestion> questions, UpdatePreview? preview}) own) =>
    own.questions.any((question) => question is PatchShapedQuestion) && own.preview?.placeableAsPatch == false;

/// The first question that stops the write of [writes] and has no answer in [answers]:
/// the primary's, from its own preview, then each picked sibling's from its own, with the mod it is about.
/// A sibling the group refused, and a patch-shaped file no answer could place, are refused at the write, not asked about.
({UpdateQuestionKind kind, String modId, UpdatePatchFinding? finding})? _questionOf(
  UpdatePrepared prepared,
  List<String> writes,
  Map<String, UpdateModAnswer> answers,
) {
  for (final modId in writes) {
    final own = _ownQuestions(prepared, modId);
    if (_unplaceablePatch(own) && answers[modId] is! PlaceAsPatch) continue;
    final (:questions, :preview) = own;
    for (final question in questions) {
      final kind = switch (question) {
        PatchShapedQuestion() => UpdateQuestionKind.patchShaped,
        UnrecordedPatchQuestion() => UpdateQuestionKind.unrecordedPatch,
        _ => null,
      };
      if (kind == null || _answers(answers[modId], kind)) continue;
      final finding = kind == UpdateQuestionKind.patchShaped && preview != null
          ? UpdatePatchFinding(
              modId: modId,
              sources: preview.sourceFolders,
              missing: preview.patch.missing,
            )
          : null;
      return (kind: kind, modId: modId, finding: finding);
    }
  }
  return null;
}

/// Skip, at [job]'s question: the mod the question is about writes nothing, for [reason], and the job's other mods go on.
/// Its row reads skipped at once.
/// A question about the archive (its password) and the folders question, which the job's first mod's preview drives, skip the whole job.
/// A question about the job's last mod left ends the job, each mod skipped with its own reason (`docs/update-runs.md` §7).
/// Nothing changes when the job no longer waits on that question, and the result is false.
Future<bool> skipUpdateQuestion(
  ProviderContainer container,
  DownloadJob job, {
  UpdateSkipReason reason = UpdateSkipReason.skippedByUser,
}) async {
  final queue = container.read(downloadQueueProvider.notifier);
  final wait = job.updateWait;
  if (wait == null) return false;
  final task = job.update!;
  final kept = job.updateKept;
  final mod = wait.question == UpdateQuestionKind.password ? null : task.modIn(wait.modId ?? task.primary.modId);
  if (mod == null || kept == null || wait.question == UpdateQuestionKind.folders) {
    // A reason the answer found about another mod than the first is that mod's own; the job's skip then reads as the user's.
    final asked = mod == null || identical(mod, task.primary) ? reason : UpdateSkipReason.skippedByUser;
    return queue.skipUpdate(job.seq, reason: asked, asking: wait.asking);
  }

  final skip = UpdateModResult.skipped(mod, reason);
  final leftOut = await modsLeftOutOrAnswered(container, job);
  if (task.mods.every((other) => other.modId == mod.modId || leftOut.containsKey(other.modId))) {
    return queue.skipUpdate(job.seq, reason: reason, asking: wait.asking, results: [
      for (final result in leftOut.values) if (result.mod.modId != mod.modId) result,
      skip,
    ]);
  }
  final answered = queue.answerUpdate(
    job.seq,
    asking: wait.asking,
    prepared: kept.withAnswer(mod.modId, SkipThisMod(reason)),
    skipping: skip,
  );
  if (answered) logUpdateQuestionSkip(job, wait.question, reason, mod: mod);
  return answered;
}

/// [modsLeftOut], or only the mods skipped at their questions when the library or a sidecar cannot be read:
/// what is asked or skipped then goes on as it would, and the write checks again.
Future<Map<String, UpdateModResult>> modsLeftOutOrAnswered(ProviderContainer container, DownloadJob job) async {
  try {
    return await modsLeftOut(container, job);
  } catch (error) {
    _log.warning('update not checked for an ignore at its question', error: error);
    return _answeredSkips(job);
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
