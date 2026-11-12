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
/// the unpack, the folders question while it waits on one, and the folders the user picked when the layout asked.
class UpdateRunKept implements HoldsUnpack {
  const UpdateRunKept({this.unpacked, this.pickedFolders, this.foldersQuestion});

  final UpdateUnpacked? unpacked;

  /// The answer to a folders question, paths of [unpacked]'s folders.
  final List<String>? pickedFolders;

  /// The folders question the job waits on: the archive's folders to pick from, and why the layout asks.
  final FoldersQuestion? foldersQuestion;

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
    return await _classify(result, kept, writes: [for (final mod in job.update!.mods) mod.modId]);
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
/// and so is one whose update was ignored or written by something else while the job waited ([_settledMeanwhile]).
/// A verdict changed since the unpack (a restore, a rename of another mod, a patch) is a new question.
/// Each folder is checked immediately before its own write for a write by something else that is running or has started since the stage began reading ([_WritesSince]).
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

  // Before anything is read: a write by something else that starts after this is not in what the reads below saw.
  final since = _WritesSince(container);

  // Nothing is written until `writeUpdate`, so a failure before it is not an interrupted write.
  final UpdatePrepared prepared;
  final _Plan plan;
  try {
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
    final found = await _found(container, job);
    if (found case _Unfound(:final result)) return result;
    final request = (found as _Found).request;
    final skipped = await _settledMeanwhile(container, job, request.mod);
    final busy = {...skip, ...container.read(modWritesInProgressProvider)};
    for (final mod in job.update!.mods) {
      if (busy.contains(mod.modId) || since.moved(mod.modId)) {
        skipped.putIfAbsent(mod.modId, () => UpdateModResult.skipped(mod, UpdateSkipReason.beingWritten));
      }
    }
    final writes = [for (final mod in job.update!.mods) if (!skipped.containsKey(mod.modId)) mod.modId];
    if (writes.isEmpty) return _settled(job, [for (final mod in job.update!.mods) skipped[mod.modId]!], null);
    final result = await _prepare(container, request, kept);
    final verdict = await _classify(result, kept, writes: writes);
    if (verdict is! UpdateStageReady) return verdict;
    prepared = result as UpdatePrepared;
    plan = _planFor(prepared, job.update!, skipped);
    if (plan.targets.isEmpty && !plan.writesPatch) return _settled(job, plan.results, null);
    if (!await _unpackThere(unpacked)) return const UpdateStageFailed(UpdateFailure(UpdateFailureKind.unpackGone));
  } catch (error, stack) {
    _log.error('update not written, its folder could not be read again',
        error: error, stack: stack, fields: {'mod': job.update?.primary.modId});
    return UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: error));
  }

  final clock = _WriteClock(job.update!.primary.modId);
  final queue = container.read(downloadQueueProvider.notifier);
  UpdateReport report;
  try {
    report = await writeUpdate(
      container,
      prepared,
      targets: plan.targets,
      onStep: (mod, step) {
        clock.step(mod, step);
        queue.reportWriteStep(job.seq, UpdateWriting(mod.id, step));
      },
      // Read again at each folder's turn: the mark is set by a write, not held by a lock.
      // A write that started and ended since the reads above is caught by the folder's counter.
      skipWhen: (mod) => container.read(modWritesInProgressProvider).contains(mod.id) || since.moved(mod.id),
    );
  } finally {
    clock.end();
  }
  if (prepared is PreparedPatch && report.outcome.changed) {
    // A patch write leaves the folder's verdict to its caller, since the verdict names layers.
    // It is kept as the mark the write removed, as a base write keeps its own, so the row reads the same after it.
    final id = prepared.request.mod.id;
    final mark = container.read(modUpdateChecksProvider)[id];
    forgetUpdateCheck(container, id);
    if (mark != null) {
      report = UpdateReport(
        applied: report.applied,
        outcome: report.outcome,
        skipped: report.skipped,
        removedMarks: {id: mark},
      );
    }
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

/// [skipped] holds the mods already left out, by folder id, each with why.
_Plan _planFor(UpdatePrepared prepared, UpdateTask task, Map<String, UpdateModResult> skipped) {
  final results = <UpdateModResult>[];
  final targets = <UpdateTarget>[];
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

Future<_Lookup> _found(ProviderContainer container, DownloadJob job) async {
  final config = await ApiService.getConfig();
  final modsPath = config['mods_path'] ?? '';
  if (modsPath.isEmpty) {
    return _Unfound(UpdateStageFailed(UpdateFailure(UpdateFailureKind.other, cause: StateError('no library folder'))));
  }
  final task = job.update!;
  final pick = task.primary;

  final library = await container.read(libraryProvider.future);
  final cached = pickedModIn(library, pick);
  final there = await Directory(path.join(modsPath, pick.modId)).exists();
  if (!there || cached == null) {
    final reason = missingPickReason(library, pick);
    _log.info('update skipped, the mod is not there',
        fields: {'mod': pick.modId, 'renamed': reason == UpdateSkipReason.folderRenamed});
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
/// A patch-shaped download and a patch nothing records are questions, for every mod the write takes ([writes], in the job's order);
/// the folders the write leaves out are not.
Future<UpdateStageResult> _classify(UpdatePrepareResult result, UpdateRunKept kept, {required List<String> writes}) async {
  switch (result) {
    case UpdateAsks(question: PasswordQuestion(:final failed)):
      return UpdateStageAsks(UpdateWait(UpdateQuestionKind.password, passwordFailed: failed), prepared: kept);
    case UpdateAsks(question: final FoldersQuestion question):
      return UpdateStageAsks(
        const UpdateWait(UpdateQuestionKind.folders),
        prepared: UpdateRunKept(unpacked: question.unpacked, foldersQuestion: question),
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
      final stop = _questionOf(prepared, writes);
      if (stop != null) return UpdateStageAsks(UpdateWait(stop), prepared: next);
      return UpdateStageReady(prepared: next);
  }
}

/// The first question that stops the write of [writes]: the primary's, from its own preview, then each picked sibling's from its own.
/// A sibling the group refused is refused at the write, not asked about.
UpdateQuestionKind? _questionOf(UpdatePrepared prepared, List<String> writes) {
  UpdateQuestionKind? first(List<UpdateQuestion> questions) => [
        for (final question in questions)
          if (question is PatchShapedQuestion)
            UpdateQuestionKind.patchShaped
          else if (question is UnrecordedPatchQuestion)
            UpdateQuestionKind.unrecordedPatch,
      ].firstOrNull;

  final primary = prepared.request.mod.id;
  for (final modId in writes) {
    final question = switch (prepared) {
      _ when modId == primary => first(prepared.questions),
      PreparedFolders(:final group) => switch (group.targets.where((t) => t.mod.id == modId && t.canProceed).firstOrNull) {
          final target? => first(confirmationQuestions(target.preview, flattensPatch: target.flattensPatch)),
          null => null,
        },
      PreparedPatch() => null,
    };
    if (question != null) return question;
  }
  return null;
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
