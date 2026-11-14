/// Undo, on an update run's finished row (`docs/update-runs.md` §8): the press, shared by the Updates page's row and the Downloads panel.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../models/character_info.dart';
import '../../models/mod_download.dart';
import '../../services/download/download_job.dart';
import '../../services/download/download_queue.dart';
import '../../services/download/update_job.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart';
import '../../services/mod_rollback.dart';
import '../../services/mod_uid.dart';
import '../../services/update_apply/update_applier.dart';
import '../../services/update_apply/update_undo.dart';
import '../../services/update_apply/update_write.dart' show UpdateReportOf;
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'update_run_words.dart';

final Logger _log = Logger('update');

/// Why a press did nothing, with what was thrown when something was.
typedef _Refusal = ({UpdateUndoProblem problem, Object? error, StackTrace? stack});

/// Takes back what the update job [seq] wrote for its mod in the folder [modId].
///
/// A base update, and any write over a layer the folder had, is restored from the snapshot the write took;
/// a patch the write added as a new layer is taken out, and a patch put on top of the mod's own folder also puts back the dismissal it wrote on the mod's layer.
/// Either takes a snapshot of the folder as it is first, so undoing is itself undoable.
///
/// The folder is marked as being written for the whole of it, and [updateUndoProblem] is read again under that mark, from the disk:
/// a press that finds it no longer holds does nothing and the row says "Couldn't undo" with why, except while another write is running,
/// which only leaves the row without Undo. Only a failure is said, on the row; a change the user sees is not announced.
/// On success the update mark the write removed comes back unless a check stored a newer verdict meanwhile, the mod reads "Undone",
/// and the counted "N mods updated" or "Patch added to N mods" card counts it off.
/// A second press while the first runs finds the first's mark, so it does nothing and stores nothing.
Future<void> undoUpdate(ProviderContainer container, int seq, String modId) async {
  final queue = container.read(downloadQueueProvider.notifier);
  DownloadJob? jobNow() => container.read(downloadQueueProvider).where((j) => j.seq == seq).firstOrNull;
  final job = jobNow();
  final record = updateUndoRecordOf(job, modId);
  final result = job?.resultFor(modId);
  if (job == null || record == null || result == null || result.undone) return;
  final folderId = record.folderId;
  // The verdict the write removed, to put back once the folder is on the old file again, unless a check has stored a newer one since.
  // Read before the write, since a Take out drops the folder's verdict.
  final removed = job.updateReport?.removedMarks[modId];
  final checkedSince = container.read(modUpdateChecksProvider).containsKey(modId);
  void markBack() {
    if (removed == null || checkedSince) return;
    final checks = container.read(modUpdateChecksProvider.notifier);
    checks.state = {...checks.state, modId: removed};
  }

  void refused(_Refusal refusal) {
    final problem = refusal.problem;
    _log.warning('update not undone',
        error: refusal.error, stack: refusal.stack, fields: {'mod': modId, 'folder': folderId, 'reason': problem.name});
    // Another write running is the rule's to say, by leaving the row without Undo; it is not this press's failure.
    if (problem != UpdateUndoProblem.beingWritten) queue.markUndoFailed(seq, modId, problem);
  }

  if (container.read(modWritesInProgressProvider).contains(folderId)) {
    return refused((problem: UpdateUndoProblem.beingWritten, error: null, stack: null));
  }

  final _Refusal? refusal;
  try {
    refusal = await whileWritingMod(container, folderId, () => _write(container, jobNow, record, modId, markBack: markBack));
  } catch (error, stack) {
    // The mark itself was not taken, so nothing was written.
    return refused((problem: UpdateUndoProblem.notRead, error: error, stack: stack));
  }
  if (refusal != null) return refused(refusal);

  // After the rescan the write started.
  markBack();
  queue.markUndone(seq, modId);
  _log.info('update undone', fields: {'mod': modId, 'folder': folderId, 'by': record.takeOut == null ? 'restore' : 'take_out'});

  final repeat = result.patchAdded ? kUpdatesPatchRepeat : (result.end == UpdateModEnd.written ? kUpdatesDoneRepeat : null);
  if (repeat != null) {
    final library = {for (final mod in container.read(modsProvider)) mod.id: mod};
    container
        .read(notificationsProvider.notifier)
        .countDown(NotificationKind.done, repeat, updateModName(library[modId], jobNow() ?? job, modId));
  }
}

/// The press under the folder's mark: the rule read again from the disk, then the restore or the Take out. Null when it worked.
/// A throw while reading has changed nothing; a throw while writing may have stopped part-way.
/// [markBack] puts back the update mark the write removed, for a Take out that stopped part-way after the layer's record went.
Future<_Refusal?> _write(
  ProviderContainer container,
  DownloadJob? Function() jobNow,
  UpdateUndoRecord record,
  String modId, {
  required void Function() markBack,
}) async {
  final folderId = record.folderId;
  final ModManagerService service;
  final ModInfo mod;
  try {
    service = await container.read(modManagerServiceProvider.future);
    final modsPath = service.modsPath;
    final folder = modsPath == null || modsPath.isEmpty ? null : Directory(p.join(modsPath, folderId));
    final there = folder != null && await folder.exists();
    final blocked = updateUndoProblem(
      record: record,
      result: jobNow()?.resultFor(modId),
      // From the sidecar on disk: a folder replaced under the same name in a file manager has another uid, or none.
      folderUid: there ? await ModUid().read(folder) : null,
      snapshots: await container.read(snapshotServiceProvider).list(record.snapshot.modUid),
      // This press's own mark is counted in both.
      writesStarted: (container.read(modWritesStartedProvider)[folderId] ?? 0) - 1,
      beingWritten: modWritesRunning(container, folderId) > 1,
    );
    if (blocked != null) return (problem: blocked, error: null, stack: null);
    final listed = (await container.read(libraryProvider.future)).where((m) => m.id == folderId).firstOrNull;
    if (listed == null) return (problem: UpdateUndoProblem.folderGone, error: null, stack: null);
    // The origin from disk, which Take out plans against.
    mod = listed.copyWith(origin: await service.readModOrigin(folderId));
  } catch (error, stack) {
    return (problem: UpdateUndoProblem.notRead, error: error, stack: stack);
  }

  try {
    final problem = record.takeOut == null
        ? await _restore(container, mod, record)
        : await _takeOut(container, service, mod, record, markBack: markBack);
    return problem == null ? null : (problem: problem, error: null, stack: null);
  } catch (error, stack) {
    return (problem: UpdateUndoProblem.partWay, error: error, stack: stack);
  }
}

/// Puts [mod]'s folder back to the snapshot of [record], which takes a snapshot of the folder as it is first, and reads the library again.
Future<UpdateUndoProblem?> _restore(ProviderContainer container, ModInfo mod, UpdateUndoRecord record) async {
  final result = await restoreSnapshotFiles(container, mod: mod, snapshot: record.snapshot);
  try {
    await container.read(libraryProvider.notifier).rescan();
  } catch (error, stack) {
    // The folder is as the restore left it; only the library's view of it is behind.
    _log.warning('library not read again after an update was undone', error: error, stack: stack, fields: {'mod': mod.id});
    container.invalidate(libraryProvider);
  }
  return _problemOf(result.failure);
}

/// Takes the patch layer of [record] out of [mod]'s folder, with its own snapshot first, and puts back the dismissal the placement wrote on the mod's layer.
/// A Take out that stops part-way after the layer's record and the folder's verdict went puts back the dismissal and, through [markBack], the update mark too.
Future<UpdateUndoProblem?> _takeOut(
  ProviderContainer container,
  ModManagerService service,
  ModInfo mod,
  UpdateUndoRecord record, {
  required void Function() markBack,
}) async {
  final ModDownload? patch = mod.origin?.downloadOf(record.takeOut!);
  // The layer's record is gone though nothing was counted as writing the folder: a sidecar changed by hand.
  if (patch == null || patch.modId == null) return UpdateUndoProblem.writtenSince;
  final PatchRemoval? removal;
  try {
    removal = await preparePatchRemoval(container, mod: mod, patch: patch);
  } catch (error, stack) {
    _log.warning('patch removal not planned', error: error, stack: stack, fields: {'mod': mod.id});
    return UpdateUndoProblem.notRead;
  }
  if (removal == null) return UpdateUndoProblem.folderGone;
  try {
    if (removal.touchesFolder) {
      final result = await writePatchRemoval(container, removal);
      if (_problemOf(result.failure, partial: result.failed.isNotEmpty) case final problem?) {
        // Files left where they were still count as the layer taken out: its record and the folder's verdict are gone.
        if (result.success) {
          await _putDismissalBack(service, mod, record);
          markBack();
        }
        return problem;
      }
    } else {
      // The patch's files are gone already, so only its record goes; no file moves either way.
      final bool forgotten;
      try {
        forgotten = await forgetPatchRecord(container, removal);
      } catch (error, stack) {
        _log.warning('patch record not removed', error: error, stack: stack, fields: {'mod': mod.id});
        return UpdateUndoProblem.recordNotRemoved;
      }
      if (!forgotten) return UpdateUndoProblem.recordNotRemoved;
    }
    await _putDismissalBack(service, mod, record);
  } finally {
    container.invalidate(libraryProvider);
  }
  return null;
}

/// Puts back on [mod]'s own layer the dismissal it held before a patch put on top of it wrote one, when [record] has one.
Future<void> _putDismissalBack(ModManagerService service, ModInfo mod, UpdateUndoRecord record) async {
  final dismissal = record.baseDismissal;
  if (dismissal == null) return;
  try {
    final written = await service.updateModOrigin(
        mod.id, (current) => current?.withDismissal(subject: dismissal.layer, until: dismissal.until));
    if (!written.ok) throw StateError('origin not written');
  } catch (error, stack) {
    // The patch is out either way; a dismissal left behind only keeps the next check quiet about files it already listed.
    _log.warning('dismissal not put back after its patch was taken out', error: error, stack: stack, fields: {'mod': mod.id});
  }
}

/// What a restore's or a Take out's [failure] means for Undo; [partial] is a Take out that left some files where they were.
UpdateUndoProblem? _problemOf(UpdateApplyFailure? failure, {bool partial = false}) => switch (failure) {
      null when partial => UpdateUndoProblem.partWay,
      null => null,
      UpdateApplyFailure.snapshot => UpdateUndoProblem.notSaved,
      UpdateApplyFailure.modMissing => UpdateUndoProblem.folderGone,
      UpdateApplyFailure.copy || UpdateApplyFailure.layout => UpdateUndoProblem.partWay,
    };
