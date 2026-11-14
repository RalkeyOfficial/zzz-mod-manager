/// When an update run's finished row offers Undo (`docs/update-runs.md` §8): what a job's write leaves for it, the one rule every surface reads,
/// and the press reads again.
///
/// A restore puts the folder back to the snapshot and removes everything added since, so Undo is offered only while nothing but the job has written the folder.
/// The rule fails closed: anything it cannot confirm, a snapshot list not read yet or being read again included, is a reason not to offer it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/mod_download.dart';
import '../../utils/state_providers.dart';
import '../backup/snapshot_service.dart' show ModSnapshot;
import '../download/download_job.dart';
import '../download/download_queue.dart';
import '../download/update_job.dart';
import 'update_write.dart';

/// What Undo of one mod's write in a run takes back, and what it checks first.
class UpdateUndoRecord {
  const UpdateUndoRecord({
    required this.folderId,
    required this.snapshot,
    required this.writesStarted,
    this.takeOut,
    this.baseDismissal,
  });

  /// The folder Undo writes: the mod's own, or the one its file went into as a patch.
  final String folderId;

  /// The snapshot the job's write took of that folder. Its `modUid` is the folder's uid at the write.
  final ModSnapshot snapshot;

  /// The folder's write counter (`modWritesStartedProvider`) as the job's write of it started, its own count included.
  final int writesStarted;

  /// The patch layer the write added, which Undo takes out; null for a write Undo restores from [snapshot].
  final DownloadKey? takeOut;

  /// The dismissal the mod's own layer held before a patch put on top of it wrote one, put back after Take out.
  final ({DownloadKey layer, DateTime? until})? baseDismissal;
}

/// What Undo of the mod in the folder [modId] of [job] takes back, or null when its write left nothing to take back.
UpdateUndoRecord? updateUndoRecordOf(DownloadJob? job, String modId) => job?.updateReport?.undo[modId];

/// Why Undo is not offered for a mod's write, or null when it is.
///
/// [record] is what the job's write left for Undo, null too once the job has left the list, and [result] the mod's own result.
/// [folderUid] is the uid of the folder of the record's id, null when there is no such folder or it has no uid;
/// [snapshots] are that folder's snapshots newest first, null while not read, [writesStarted] its write counter now and [beingWritten] whether something writes it now.
/// Offered only while the job's snapshot is the newest of the folder, the counter is where the job's write left it,
/// and the folder is there under the same id and uid.
UpdateUndoProblem? updateUndoProblem({
  required UpdateUndoRecord? record,
  required UpdateModResult? result,
  required String? folderUid,
  required List<ModSnapshot>? snapshots,
  required int? writesStarted,
  required bool beingWritten,
}) {
  if (record == null || result == null || result.undone) return UpdateUndoProblem.nothingToUndo;
  if (beingWritten) return UpdateUndoProblem.beingWritten;
  final snapshot = record.snapshot;
  if (folderUid == null || folderUid != snapshot.modUid) return UpdateUndoProblem.folderGone;
  if (writesStarted != record.writesStarted) return UpdateUndoProblem.writtenSince;
  if (snapshots == null) return UpdateUndoProblem.unknown;
  if (!snapshots.any((s) => s.id == snapshot.id)) return UpdateUndoProblem.snapshotGone;
  final newer = snapshots.any((s) => s.id != snapshot.id && !s.takenAt.isBefore(snapshot.takenAt));
  if (newer) return UpdateUndoProblem.writtenSince;
  return null;
}

/// Which update job and which of its mods an Undo is about.
typedef UpdateUndoKey = ({int seq, String modId});

/// [updateUndoProblem] for the mod of [UpdateUndoKey] as it stands now: null while its row offers Undo.
final updateUndoProvider = Provider.autoDispose.family<UpdateUndoProblem?, UpdateUndoKey>((ref, key) {
  // The job object changes only when the job does, so a tick of another download does not reach this.
  final job = ref.watch(downloadQueueProvider.select((jobs) => jobs.where((j) => j.seq == key.seq).firstOrNull));
  final record = updateUndoRecordOf(job, key.modId);
  final result = job?.resultFor(key.modId);
  if (record == null || result == null || result.undone) {
    return updateUndoProblem(record: null, result: result, folderUid: null, snapshots: null, writesStarted: null, beingWritten: false);
  }
  final folderId = record.folderId;
  final snapshots = ref.watch(modSnapshotListProvider(record.snapshot.modUid));
  return updateUndoProblem(
    record: record,
    result: result,
    folderUid: ref.watch(modsProvider.select((mods) => mods.where((m) => m.id == folderId).firstOrNull?.uid)),
    // A list being read again may be the one the newest write has just changed, so it counts as not read.
    snapshots: snapshots.isLoading || snapshots.hasError ? null : snapshots.valueOrNull,
    writesStarted: ref.watch(modWritesStartedProvider.select((started) => started[folderId])),
    beingWritten: ref.watch(modWritesInProgressProvider.select((writing) => writing.contains(folderId))),
  );
});
