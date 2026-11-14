import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/downloads_panel.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/components/update_run_words.dart' show kUpdatesDoneRepeat, kUpdatesPatchRepeat;
import 'package:mod_manager_flutter/screens/updates/updates_page.dart';
import 'package:mod_manager_flutter/screens/components/update_undo_action.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:mod_manager_flutter/services/backup/retention.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart' show UpdateWriteStep;
import 'package:mod_manager_flutter/services/update_apply/update_run_stages.dart';
import 'package:mod_manager_flutter/services/update_apply/update_undo.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart';
import 'support/held_write.dart';
import 'support/localized_harness.dart';
import 'support/log_capture.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/seeded_queue.dart';
import 'support/temp_library.dart';
import 'support/update_jobs.dart';

/// A queue the test puts the job in once its unpack has run, as the host hands it to the install lane.
class _Queue extends SeededQueue {
  _Queue() : super(const []);

  void hold(DownloadJob job) => state = [job];

  /// Told each step of a folder's write as it starts, before the queue is.
  void Function(UpdateWriting writing)? onWriteStep;

  @override
  void reportWriteStep(int seq, UpdateWriting writing) {
    onWriteStep?.call(writing);
    super.reportWriteStep(seq, writing);
  }
}

/// The temp library's snapshot store, with the failures a test turns on.
class _Snapshots extends SnapshotService {
  _Snapshots(String rootPath) : super(rootPath: rootPath);

  /// The mods whose snapshot is refused for space.
  final Set<String> refuseFor = {};

  /// The mods whose next snapshot alone is refused for space.
  final Set<String> refuseOnceFor = {};

  /// While set, listing a mod's snapshots throws, as an unreadable backups folder does.
  bool listThrows = false;

  /// While set, a restore's copy fails, as a full disk does.
  bool restoreFails = false;

  /// Run once by the next prune, which a write runs after its folder's own write has ended.
  Future<void> Function()? onNextPrune;

  /// Told each snapshot taken, once it is, before the write that took it goes on.
  void Function(String modName, SnapshotReason reason)? onTaken;

  @override
  Future<SnapshotAttempt> take({
    required String modName,
    required String modUid,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async {
    if (refuseFor.contains(modName) || refuseOnceFor.remove(modName)) {
      return const SnapshotAttempt.refused(SnapshotNoRoom(requiredBytes: 2, availableBytes: 1));
    }
    final attempt = await super.take(
      modName: modName,
      modUid: modUid,
      modFolder: modFolder,
      reason: reason,
      version: version,
      versionLabel: versionLabel,
      now: now,
    );
    onTaken?.call(modName, reason);
    return attempt;
  }

  /// Run once as the next listing starts.
  void Function()? onNextList;

  @override
  Future<List<ModSnapshot>> list(String? modUid) async {
    final hook = onNextList;
    onNextList = null;
    hook?.call();
    if (listThrows) throw const FileSystemException('backups unreadable');
    return super.list(modUid);
  }

  @override
  Future<bool> restoreInto(ModSnapshot snapshot, Directory modFolder) async =>
      restoreFails ? false : super.restoreInto(snapshot, modFolder);

  @override
  Future<RetentionPlan> prune() async {
    final hook = onNextPrune;
    onNextPrune = null;
    await hook?.call();
    return super.prune();
  }
}

/// Undo on an update run's finished row (`docs/update-runs.md` §8): the rule that decides whether it is offered, and what it does to the folder,
/// the sidecar, the update mark, the job and the counted card, against a real library in a temp directory.
void main() {
  group('the rule (updateUndoProblem)', () {
    final taken = DateTime.utc(2026, 8, 12, 10);
    ModSnapshot snapshot(String id, DateTime at) =>
        ModSnapshot(modName: 'Ellen', modUid: 'u1', id: id, takenAt: at, sizeBytes: 1, directory: Directory('/nonexistent/$id'));
    final own = snapshot('s1', taken);
    final record = UpdateUndoRecord(folderId: 'Ellen', snapshot: own, writesStarted: 4);
    final written = UpdateModResult.written(baseOf('Ellen', 100));

    UpdateUndoProblem? rule({
      UpdateUndoRecord? withRecord,
      bool noRecord = false,
      UpdateModResult? result,
      String? folderUid = 'u1',
      List<ModSnapshot>? snapshots,
      bool unread = false,
      int? writesStarted = 4,
      bool beingWritten = false,
    }) =>
        updateUndoProblem(
          record: noRecord ? null : withRecord ?? record,
          result: result ?? written,
          folderUid: folderUid,
          snapshots: unread ? null : snapshots ?? [own, snapshot('s0', taken.subtract(const Duration(days: 1)))],
          writesStarted: writesStarted,
          beingWritten: beingWritten,
        );

    test('offered while the job\'s snapshot is the newest, the counter has not moved and the folder is the same mod', () {
      expect(rule(), isNull);
    });

    test('nothing to undo: no record of the write, the job gone from the list, or undone already', () {
      expect(rule(noRecord: true), UpdateUndoProblem.nothingToUndo);
      expect(rule(result: written.withUndo(undone: true)), UpdateUndoProblem.nothingToUndo);
    });

    test('not offered while something writes the folder', () {
      expect(rule(beingWritten: true), UpdateUndoProblem.beingWritten);
    });

    test('not offered for a folder gone, renamed or holding another mod', () {
      expect(rule(folderUid: null), UpdateUndoProblem.folderGone, reason: 'gone, or a folder with no uid, which cannot be shown to be the same mod');
      expect(rule(folderUid: 'u2'), UpdateUndoProblem.folderGone);
    });

    test('not offered once the counter moved, whatever moved it', () {
      expect(rule(writesStarted: 5), UpdateUndoProblem.writtenSince);
      expect(rule(writesStarted: null), UpdateUndoProblem.writtenSince);
    });

    test('not offered while the snapshots are not read: the rule fails closed', () {
      expect(rule(unread: true), UpdateUndoProblem.unknown);
    });

    test('not offered once the job\'s snapshot is gone, or one as new or newer exists', () {
      expect(rule(snapshots: [snapshot('s0', taken.subtract(const Duration(days: 1)))]), UpdateUndoProblem.snapshotGone);
      expect(rule(snapshots: [snapshot('s2', taken.add(const Duration(seconds: 1))), own]), UpdateUndoProblem.writtenSince);
      expect(rule(snapshots: [own, snapshot('s3', taken)]), UpdateUndoProblem.writtenSince, reason: 'a tie is not the newest');
    });
  });

  group('the press (undoUpdate)', () {
    const modName = 'Ellen';
    const ini = '[TextureOverrideBody]\nhash = 1\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n';
    const patchIni = '[TextureOverrideBody]\nhash = 2\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n';
    final aug = DateTime.utc(2026, 8, 12);

    late TempLibrary temp;
    late RecordingService service;
    late _Snapshots snapshots;
    late ProviderContainer container;
    late _Queue queue;
    late Directory archives;

    setUp(() async {
      temp = await TempLibrary.create(prefix: 'zzz_update_undo_');
      service = RecordingService(temp);
      snapshots = _Snapshots(temp.snapshots.rootPath);
      queue = _Queue();
      container = ProviderContainer(overrides: [
        modManagerServiceProvider.overrideWith((ref) async => service),
        snapshotServiceProvider.overrideWithValue(snapshots),
        downloadQueueProvider.overrideWith(() => queue),
      ]);
      addTearDown(container.dispose);
      archives = Directory(p.join(temp.root.path, 'archives'))..createSync();
    });

    File zip(String name, Map<String, String> files) {
      final archive = Archive();
      for (final entry in files.entries) {
        final bytes = entry.value.codeUnits;
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      return File(p.join(archives.path, name))..writeAsBytesSync(ZipEncoder().encode(archive)!);
    }

    ModOrigin origin(String name, {int modId = 100, String? group}) => originFixture(
          modId: modId,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
          ingest: ModIngest(folders: [name], siblingGroup: group),
        );

    Future<void> installed(String name, {int modId = 100, String? group}) async {
      temp.write(name, '$name.ini', ini);
      temp.write(name, 'Body.dds', 'v1');
      await temp.writeOrigin(name, origin(name, modId: modId, group: group));
    }

    UpdateCheck mark(int remoteId) => UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          installedFile: GbFile(idRow: 1, file: 'old.zip', dateAdded: aug),
          newerFiles: [GbFile(idRow: 2, file: 'new.zip', dateAdded: DateTime.utc(2026, 9, 1))],
          subject: DownloadKey.base(remoteId),
        );

    DownloadJob landed(File archive, List<UpdateMod> mods, {List<GbFile> published = const []}) => DownloadJob(
          seq: 1,
          request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/2')),
          intent: DownloadIntent.update,
          subject: mods.first.modId,
          file: GbFile(idRow: 2, file: 'update.zip', dateAdded: DateTime.utc(2026, 9, 1)),
          state: DownloadJobState.updating,
          updateStep: UpdateStep.unpacking,
          result: DownloadResult(file: archive, totalBytes: archive.lengthSync()),
          update: UpdateTask(mods: mods, published: published),
        );

    /// Runs [job] through both stages, with [answers] given at its question when it stops at one, and settles it in the queue.
    Future<DownloadJob> run(DownloadJob job, {Map<String, UpdateModAnswer> answers = const {}}) async {
      var result = await prepareUpdateJob(container, job);
      if (result case UpdateStageAsks(:final prepared)) {
        var kept = prepared! as UpdateRunKept;
        for (final MapEntry(key: modId, value: answer) in answers.entries) {
          kept = kept.withAnswer(modId, answer);
        }
        result = await prepareUpdateJob(container, job.copyWith(prepared: kept));
      }
      final ready = result as UpdateStageReady;
      addTearDown(() => ArchiveService.deleteExtraction((ready.prepared! as UpdateRunKept).unpackedFolders));
      final writing = job.copyWith(updateStep: UpdateStep.writing, prepared: ready.prepared);
      // Built first, so the job can be put in it.
      container.read(downloadQueueProvider);
      queue.hold(writing);
      queue.settleUpdate(1, await writeUpdateJob(container, writing));
      return container.read(downloadQueueProvider).single;
    }

    /// The rule for [modId] of the job, once the library and the folder's snapshots are read.
    Future<UpdateUndoProblem?> offered(String modId) async {
      final sub = container.listen(updateUndoProvider((seq: 1, modId: modId)), (_, _) {});
      addTearDown(sub.close);
      await container.read(libraryProvider.future);
      final record = updateUndoRecordOf(container.read(downloadQueueProvider).single, modId);
      if (record != null) await container.read(modSnapshotListProvider(record.snapshot.modUid).future);
      return sub.read();
    }

    DownloadJob job() => container.read(downloadQueueProvider).single;

    Future<DownloadJob> plainUpdate() async {
      await installed(modName);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark(100)};
      final done = await run(landed(zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'}), [baseOf(modName, 100, heldFileId: 1)]));
      expect(done.outcome, JobOutcome.updated);
      expect(temp.read(modName, 'Body.dds'), 'v2');
      expect(container.read(modUpdateChecksProvider).containsKey(modName), isFalse, reason: 'the write removed the mark');
      return done;
    }

    test('Undo of a base update puts the files, the sidecar and the mark back, saves the folder first, and the row stays', () async {
      final done = await plainUpdate();
      final record = updateUndoRecordOf(done, modName)!;
      expect(record.takeOut, isNull, reason: 'a base update is restored, not taken out');
      expect(temp.snapshotsOf(modName), [record.snapshot.id]);
      expect(await offered(modName), isNull);
      // A file put in by hand after the update: a restore puts the folder back as the snapshot has it.
      temp.write(modName, 'notes.txt', 'mine');

      await undoUpdate(container, 1, modName);

      expect(temp.read(modName, 'Body.dds'), 'v1');
      expect(temp.has(modName, 'notes.txt'), isFalse, reason: 'a file added by hand since the snapshot goes too');
      expect((await service.readModOrigin(modName))!.downloads.single.fileId, 1, reason: 'the record is back on the old file');
      final snapshots = await temp.snapshots.list(temp.uidOf(modName));
      expect(snapshots, hasLength(2), reason: 'the folder as it was is saved first, so the Undo can be undone');
      expect(snapshots.first.reason, SnapshotReason.beforeRestore);
      expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue, reason: 'the mark the write removed is back');
      expect(job().resultFor(modName)!.undone, isTrue);
      expect(job().outcome, JobOutcome.undone);
      expect(container.read(modWritesInProgressProvider), isEmpty);
      expect(await offered(modName), UpdateUndoProblem.nothingToUndo, reason: 'undone once');
    });

    test('a second press while the first is running finds its mark, so it does nothing and stores nothing', () async {
      await plainUpdate();
      await offered(modName);
      final capture = LogCapture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));

      await Future.wait([undoUpdate(container, 1, modName), undoUpdate(container, 1, modName)]);

      expect(job().resultFor(modName)!.undone, isTrue);
      expect(job().resultFor(modName)!.undoProblem, isNull, reason: 'the second press is not read as a write by something else');
      expect(temp.snapshotsOf(modName), hasLength(2), reason: 'one restore, which saved the folder once');
      expect(capture.records.where((r) => r.message == 'update undone'), hasLength(1));
      expect([for (final r in capture.records) if (r.message == 'update not undone') r.fields['reason']], ['beingWritten']);
    });

    test('the merged "N mods updated" card counts the undone mod off', () async {
      await plainUpdate();
      final notify = container.read(notificationsProvider.notifier);
      NotificationRepeat counted(String name) =>
          NotificationRepeat(kUpdatesDoneRepeat, subjects: [name], title: (count) => '$count mods updated');
      notify.done('Ellen updated', body: 'The 12 Aug file is kept as a snapshot.', repeat: counted('Ellen'));
      notify.done('Miyabi updated', body: 'The 12 Aug file is kept as a snapshot.', repeat: counted('Miyabi'));
      notify.done('Nicole updated', body: 'The 12 Aug file is kept as a snapshot.', repeat: counted('Nicole'));
      expect(container.read(notificationsProvider).single.title, '3 mods updated');
      await offered(modName);

      await undoUpdate(container, 1, modName);

      final card = container.read(notificationsProvider).single;
      expect(card.title, '2 mods updated');
      expect(card.subjects, ['Miyabi', 'Nicole']);
    });

    group("Couldn't undo, with its reason, and the folder left as it is", () {
      test('the folder was written since: plain Updated, and a press says so', () async {
        await plainUpdate();
        await whileWritingMod(container, modName, () async {});
        expect(await offered(modName), UpdateUndoProblem.writtenSince);

        await undoUpdate(container, 1, modName);
        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.writtenSince);
        expect(job().resultFor(modName)!.undone, isFalse);
        expect(temp.read(modName, 'Body.dds'), 'v2');
        expect(container.read(modUpdateChecksProvider).containsKey(modName), isFalse, reason: 'no mark comes back');
      });

      test('the folder is being written: the press stores no failure, and the rule leaves the row without Undo', () async {
        await plainUpdate();
        await offered(modName);
        final held = holdWrite(container, modName);
        expect(await offered(modName), UpdateUndoProblem.beingWritten);

        await undoUpdate(container, 1, modName);
        await held.release();
        expect(job().resultFor(modName)!.undoProblem, isNull, reason: 'a write running is not a lasting failure of the press');
        expect(temp.read(modName, 'Body.dds'), 'v2');
        expect(await offered(modName), UpdateUndoProblem.writtenSince, reason: 'the write that ran moved the counter');
      });

      test("a write that starts after the press's first check is found under the folder's mark, and the press does nothing", () async {
        await plainUpdate();
        await offered(modName);
        HeldWrite? held;
        // The press reads the folder's snapshots under its mark, after its first check let it through.
        snapshots.onNextList = () => held = holdWrite(container, modName);

        await undoUpdate(container, 1, modName);
        await held!.release();

        expect(job().resultFor(modName)!.undoProblem, isNull, reason: 'a write running is not a lasting failure of the press');
        expect(job().resultFor(modName)!.undone, isFalse);
        expect(temp.read(modName, 'Body.dds'), 'v2');
        expect(temp.snapshotsOf(modName), hasLength(1), reason: 'nothing was saved, since nothing was written');
      });

      test('the snapshot was pruned', () async {
        final done = await plainUpdate();
        final record = updateUndoRecordOf(done, modName)!;
        expect(await temp.snapshots.delete(record.snapshot), isTrue);
        container.invalidate(modBackupsProvider);
        expect(await offered(modName), UpdateUndoProblem.snapshotGone);

        await undoUpdate(container, 1, modName);
        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.snapshotGone);
        expect(temp.read(modName, 'Body.dds'), 'v2');
        expect(temp.snapshotsOf(modName), isEmpty, reason: 'nothing was saved, since nothing was written');
      });

      test('the folder was renamed', () async {
        await plainUpdate();
        temp.modFolder(modName).renameSync(p.join(temp.mods.path, 'Ellen Renamed'));
        container.invalidate(libraryProvider);
        expect(await offered(modName), UpdateUndoProblem.folderGone);

        await undoUpdate(container, 1, modName);
        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.folderGone);
        expect(temp.modFolder(modName).existsSync(), isFalse, reason: 'no folder of the old name is made');
        expect(temp.read('Ellen Renamed', 'Body.dds'), 'v2');
      });
    });

    DownloadJob patchJob() => landed(
          zip('patch.zip', {'Ellen Fix/Ellen.ini': patchIni}),
          [baseOf(modName, 100, heldFileId: 1, dismissUpTo: DateTime.utc(2026, 9, 1))],
          published: [GbFile(idRow: 2, dateAdded: DateTime.utc(2026, 9, 1))],
        );

    test('Undo of a patch put on top is Take out: the patch goes, the files stay, the base dismissal and the mark come back', () async {
      await installed(modName);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark(100)};
      final done = await run(patchJob(), answers: {modName: const PlaceAsPatch(modName)});
      expect(done.outcome, JobOutcome.patchAdded);
      expect(temp.read(modName, 'Ellen.ini'), patchIni);
      expect((await service.readModOrigin(modName))!.downloads.first.updatesDismissedUntil, isNotNull);
      final record = updateUndoRecordOf(done, modName)!;
      expect(record.takeOut, const DownloadKey.patch(100));
      container.read(notificationsProvider.notifier).done('Patch added to Ellen',
          body: 'Your files stay.', repeat: NotificationRepeat(kUpdatesPatchRepeat, subjects: ['Ellen']));
      expect(await offered(modName), isNull);

      await undoUpdate(container, 1, modName);

      expect(temp.read(modName, 'Ellen.ini'), ini, reason: "the mod's own file is back where the patch had it");
      expect(temp.read(modName, 'Body.dds'), 'v1');
      final stack = (await service.readModOrigin(modName))!.downloads;
      expect(stack, hasLength(1), reason: 'the layer the update added is gone');
      expect(stack.single.updatesDismissedUntil, isNull, reason: 'the dismissal the layer held at the press, none');
      expect(temp.snapshotsOf(modName), hasLength(2), reason: 'Take out saves the folder first');
      expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue);
      expect(job().resultFor(modName)!.undone, isTrue);
      expect(container.read(notificationsProvider), isEmpty, reason: 'the card counted only this mod');
    });

    test('a Take out of a patch put on top that stops part-way still puts the base dismissal and the mark back', () async {
      await installed(modName);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark(100)};
      await run(patchJob(), answers: {modName: const PlaceAsPatch(modName)});
      expect(await offered(modName), isNull);
      // Past the Take out's snapshot, the place of the mod's own file is a folder, so that file cannot come back.
      snapshots.onTaken = (name, reason) {
        if (reason != SnapshotReason.beforePatchRemoval) return;
        final file = File(p.join(temp.modFolder(modName).path, 'Ellen.ini'))..deleteSync();
        Directory(file.path).createSync();
        File(p.join(file.path, 'keep')).writeAsStringSync('x');
      };

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.partWay, reason: 'the row says it stopped part-way');
      expect(job().resultFor(modName)!.undone, isFalse);
      final stack = (await service.readModOrigin(modName))!.downloads;
      expect(stack, hasLength(1), reason: "the layer's record went with the files that did move");
      expect(stack.single.updatesDismissedUntil, isNull, reason: 'the dismissal the layer held at the press, none');
      expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue, reason: 'the mark the placement removed is back');
    });

    test('a patch put into another mod keeps its write on the job, and Take out is offered from the mod it was for', () async {
      await installed(modName);
      await installed('Miyabi', modId: 200);
      // The file the patch replaces, so it has a place in Miyabi's folder.
      temp.write('Miyabi', 'Ellen.ini', ini);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark(100)};
      final done = await run(patchJob(), answers: {modName: const PlaceAsPatch('Miyabi')});
      expect(done.outcome, JobOutcome.skipped);
      expect(done.resultFor(modName)!.skipReason, UpdateSkipReason.patchAddedElsewhere);
      expect(temp.read('Miyabi', 'Ellen.ini'), patchIni);
      final record = updateUndoRecordOf(done, modName)!;
      expect(record.folderId, 'Miyabi', reason: 'the folder the patch went into');
      expect(record.takeOut, const DownloadKey.patch(100));
      expect(record.baseDismissal, isNull, reason: "the mod's own layer was not dismissed");
      expect(await offered(modName), isNull);

      await undoUpdate(container, 1, modName);

      expect(temp.read('Miyabi', 'Ellen.ini'), ini, reason: "Miyabi's own file is back where the patch had it");
      expect(temp.read('Miyabi', 'Body.dds'), 'v1');
      expect((await service.readModOrigin('Miyabi'))!.downloads, hasLength(1));
      expect(temp.read(modName, 'Ellen.ini'), ini, reason: 'the mod the update was for was never written');
      expect(job().resultFor(modName)!.undone, isTrue);
      expect(container.read(modUpdateChecksProvider)[modName]?.hasUpdate, isTrue, reason: 'it kept its mark throughout');
    });

    test("a patch placed over the same patch's earlier version is restored, not taken out, so the earlier version comes back", () async {
      await installed(modName);
      temp.write('Miyabi', 'Ellen.ini', '$ini; earlier patch\n');
      temp.write('Miyabi', 'Body.dds', 'm1');
      await temp.writeOrigin(
        'Miyabi',
        originFixture(
          modId: 200,
          modIdConfidence: OriginConfidence.exact,
          fileId: 7,
          patches: [patchFixture(modId: 100, fileId: 1, files: const [InstalledFile(path: 'Ellen.ini', role: InstalledFileRole.replaced)])],
        ),
      );
      final done = await run(patchJob(), answers: {modName: const PlaceAsPatch('Miyabi')});
      expect(temp.read('Miyabi', 'Ellen.ini'), patchIni);
      final record = updateUndoRecordOf(done, modName)!;
      expect(record.takeOut, isNull, reason: 'Take out would remove the earlier version too');
      expect(await offered(modName), isNull);

      await undoUpdate(container, 1, modName);

      expect(temp.read('Miyabi', 'Ellen.ini'), '$ini; earlier patch\n');
      expect((await service.readModOrigin('Miyabi'))!.downloads.last.fileId, 1, reason: 'the earlier version is on record again');
      expect(job().resultFor(modName)!.undone, isTrue);
    });

    test('a sibling group has an Undo per folder: one undone leaves the other updated and still undoable', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      final done = await run(landed(
        zip('group.zip', {
          'Ellen/Ellen.ini': ini,
          'Ellen/Body.dds': 'v2',
          'Miyabi/Miyabi.ini': ini,
          'Miyabi/Body.dds': 'v2',
        }),
        [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
      ));
      expect(done.outcome, JobOutcome.updated);
      expect(updateUndoRecordOf(done, 'Ellen')!.folderId, 'Ellen');
      expect(updateUndoRecordOf(done, 'Miyabi')!.folderId, 'Miyabi');
      expect(await offered('Miyabi'), isNull);

      await undoUpdate(container, 1, 'Miyabi');

      expect(temp.read('Miyabi', 'Body.dds'), 'v1');
      expect(temp.read('Ellen', 'Body.dds'), 'v2', reason: 'each folder has its own snapshot and its own Undo');
      expect(job().resultFor('Miyabi')!.undone, isTrue);
      expect(job().resultFor('Ellen')!.undone, isFalse);
      expect(job().outcome, JobOutcome.updated);
      expect(await offered('Ellen'), isNull, reason: "undoing Miyabi did not write Ellen's folder");
    });

    test('the finished detail: the hotkeys the write changed, the files it dropped and the folders it left out', () async {
      await installed(modName);
      temp.write(modName, 'Ellen.ini', '[KeySwap]\nkey = F7\n$ini');
      temp.write(modName, 'Old.dds', 'gone');
      final done = await run(landed(
        zip('detail.zip', {
          'Ellen/Ellen.ini': '[KeySwap]\nkey = F8\n$ini',
          'Ellen/Body.dds': 'v2',
          'Previews/one.png': 'png',
        }),
        [baseOf(modName, 100, heldFileId: 1)],
      ));
      final report = done.report! as UpdateReport;
      final own = report.writeFor(modName)!.result;
      expect(own.droppedFiles, contains('Old.dds'));
      expect(own.keybindChanges.single.before, 'F7');
      expect(own.keybindChanges.single.after, 'F8');
      expect(report.leftOut, ['Previews']);
    });

    test('a character change by dropping the card on a row counts as a write, so Undo is not offered over it', () async {
      await plainUpdate();
      expect(await offered(modName), isNull);

      expect(await retagMod(container, modName, 'miyabi'), isTrue);

      expect(await offered(modName), UpdateUndoProblem.writtenSince);
      await undoUpdate(container, 1, modName);
      expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.writtenSince);
      expect(temp.read(modName, 'Body.dds'), 'v2');
      expect((await service.getModsInfo()).singleWhere((m) => m.id == modName).characterId, 'miyabi',
          reason: 'the character the user chose stays');
    });

    test("Settings' Automatic tagging counts as a write, so Undo is not offered over the tag it wrote", () async {
      await plainUpdate();
      expect(await offered(modName), isNull);
      final before = container.read(modWritesStartedProvider)[modName];

      expect(await autoTagLibrary(container), {modName: 'ellen'});

      expect(container.read(modWritesStartedProvider)[modName], before! + 1);
      expect(await offered(modName), UpdateUndoProblem.writtenSince);
      await undoUpdate(container, 1, modName);
      expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.writtenSince);
      expect(temp.read(modName, 'Body.dds'), 'v2');
      expect((await service.getModsInfo()).singleWhere((m) => m.id == modName).characterId, 'ellen', reason: 'the tag stays');
    });

    test('a patch put into a folder with no record is restored, not taken out: it became that folder\'s base', () async {
      await installed(modName);
      // A folder made by hand: no sidecar, so nothing records what it holds.
      temp.write('Miyabi', 'Ellen.ini', ini);
      temp.write('Miyabi', 'Body.dds', 'm1');
      final done = await run(patchJob(), answers: {modName: const PlaceAsPatch('Miyabi')});
      expect(temp.read('Miyabi', 'Ellen.ini'), patchIni);
      final record = updateUndoRecordOf(done, modName)!;
      expect(record.takeOut, isNull, reason: 'the patch is the bottom of that stack, which Take out cannot remove');
      expect(await offered(modName), isNull);

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undoProblem, isNull);
      expect(job().resultFor(modName)!.undone, isTrue);
      expect(temp.read('Miyabi', 'Ellen.ini'), ini);
      expect(temp.read('Miyabi', 'Body.dds'), 'm1');
    });

    test('a write between the job\'s base write of a folder and its placement into it leaves no Undo of the base', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      // An Ignore, after the base write's mark has let go and before the placement, whose snapshot would then be refused for space.
      snapshots.onNextPrune = () async {
        await whileWritingMod(container, 'Ellen', () async {});
        snapshots.refuseFor.add('Ellen');
      };
      final done = await run(
        landed(
          zip('placing.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Miyabi/Ellen.ini': '$ini; fix\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Ellen')!.end, UpdateModEnd.written);
      expect(done.resultFor('Miyabi')!.skipReason, UpdateSkipReason.beingWritten,
          reason: 'the placement sees the write by something else since the job\'s own');
      expect(updateUndoRecordOf(done, 'Ellen')!.writesStarted, isNot(container.read(modWritesStartedProvider)['Ellen']));
      expect(await offered('Ellen'), UpdateUndoProblem.writtenSince);
    });

    test('a folder takes one placement per job: a second placement into it writes nothing and is skipped', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      await installed('Nicole', modId: 300);
      temp.write('Nicole', 'Ellen.ini', ini);
      temp.write('Nicole', 'Miyabi.ini', ini);
      final done = await run(
        landed(
          zip('two.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Nicole'), 'Miyabi': const PlaceAsPatch('Nicole')},
      );
      expect(done.resultFor('Ellen')!.patchedInto, 'Nicole');
      final miyabi = done.resultFor('Miyabi')!;
      expect(miyabi.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(miyabi.alongWith, 'Nicole', reason: 'the folder the file was going into');
      expect(miyabi.changedBy, (modId: 'Ellen', partWay: false));
      expect(miyabi.patchedInto, isNull, reason: 'nothing of it was written');
      expect(temp.read('Nicole', 'Ellen.ini'), '$ini; one\n', reason: "Ellen's placement stays the layer's last version");
      expect(temp.read('Nicole', 'Miyabi.ini'), ini, reason: "Nicole's own file");
      expect(temp.snapshotsOf('Nicole'), hasLength(1), reason: 'one write of the folder');
      expect(updateUndoRecordOf(done, 'Miyabi'), isNull);
      expect(await offered('Ellen'), isNull, reason: 'the counter did not move after the first placement, and its snapshot is the newest');
    });

    test('a placement on top of a mod of the job and one into it: the first in the job places, the second is skipped', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      temp.write('Ellen', 'Miyabi.ini', ini);
      final done = await run(
        landed(
          zip('top.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Ellen'), 'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Ellen')!.patchAdded, isTrue);
      final miyabi = done.resultFor('Miyabi')!;
      expect(miyabi.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(miyabi.alongWith, 'Ellen');
      expect(miyabi.patchedInto, isNull);
      expect(temp.read('Ellen', 'Ellen.ini'), '$ini; one\n');
      expect(temp.read('Ellen', 'Miyabi.ini'), ini);
      expect(await offered('Ellen'), isNull);
    });

    test('with the mod placed into second in the job, the placement into it goes first and its own is skipped', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      temp.write('Ellen', 'Miyabi.ini', ini);
      final done = await run(
        landed(
          zip('top.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Miyabi', 100, heldFileId: 1), baseOf('Ellen', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Ellen'), 'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Miyabi')!.patchedInto, 'Ellen');
      final ellen = done.resultFor('Ellen')!;
      expect(ellen.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(ellen.alongWith, 'Ellen');
      expect(ellen.changedBy, (modId: 'Miyabi', partWay: false), reason: "Miyabi's placement went into Ellen's folder");
      expect(ellen.patchAdded, isFalse);
      expect(temp.read('Ellen', 'Miyabi.ini'), '$ini; two\n');
      expect(temp.read('Ellen', 'Ellen.ini'), ini);
    });

    test('with that placement stopped part-way, the mod placed into is skipped as left part-way by it', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      temp.write('Ellen', 'Miyabi.ini', ini);
      // Past the snapshot, Miyabi's file's place in Ellen's folder is a folder, so the copy into it fails.
      queue.onWriteStep = (writing) {
        if (writing.modId != 'Ellen' || writing.step != UpdateWriteStep.replacingFiles) return;
        queue.onWriteStep = null;
        File(p.join(temp.modFolder('Ellen').path, 'Miyabi.ini')).deleteSync();
        Directory(p.join(temp.modFolder('Ellen').path, 'Miyabi.ini')).createSync();
      };
      final done = await run(
        landed(
          zip('top.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Miyabi', 100, heldFileId: 1), baseOf('Ellen', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Ellen'), 'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Miyabi')!.failure?.kind, UpdateFailureKind.writtenPartway);
      final ellen = done.resultFor('Ellen')!;
      expect(ellen.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(ellen.changedBy, (modId: 'Miyabi', partWay: true));
    });

    test('a placement that stopped part-way leaves its folder to no later placement of the job', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      await installed('Nicole', modId: 300);
      temp.write('Nicole', 'Ellen.ini', ini);
      temp.write('Nicole', 'Miyabi.ini', ini);
      // Past the snapshot, Ellen's file's place in Nicole's folder is a folder, so the copy into it fails.
      queue.onWriteStep = (writing) {
        if (writing.modId != 'Nicole' || writing.step != UpdateWriteStep.replacingFiles) return;
        queue.onWriteStep = null;
        File(p.join(temp.modFolder('Nicole').path, 'Ellen.ini')).deleteSync();
        Directory(p.join(temp.modFolder('Nicole').path, 'Ellen.ini')).createSync();
      };
      final done = await run(
        landed(
          zip('two.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Nicole'), 'Miyabi': const PlaceAsPatch('Nicole')},
      );
      expect(done.resultFor('Ellen')!.failure?.kind, UpdateFailureKind.writtenPartway);
      final miyabi = done.resultFor('Miyabi')!;
      expect(miyabi.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(miyabi.alongWith, 'Nicole');
      expect(miyabi.changedBy, (modId: 'Ellen', partWay: true));
      expect(temp.read('Nicole', 'Miyabi.ini'), ini);
      expect(temp.snapshotsOf('Nicole'), hasLength(1), reason: "the failed placement's snapshot stays the newest");
    });

    test('a base write that stopped part-way leaves its folder to no placement of the job', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      // Past Ellen's snapshot, the archive's folder for her is gone, so the copy from it fails.
      queue.onWriteStep = (writing) {
        if (writing.modId != 'Ellen' || writing.step != UpdateWriteStep.replacingFiles) return;
        queue.onWriteStep = null;
        Directory(job().updateKept!.unpacked!.folders.singleWhere((f) => p.basename(f) == 'Ellen')).deleteSync(recursive: true);
      };
      final done = await run(
        landed(
          zip('placing.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Miyabi/Ellen.ini': '$ini; fix\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Ellen')!.failure?.kind, UpdateFailureKind.writtenPartway);
      final miyabi = done.resultFor('Miyabi')!;
      expect(miyabi.skipReason, UpdateSkipReason.changedByThisUpdate);
      expect(miyabi.alongWith, 'Ellen');
      expect(miyabi.changedBy, (modId: 'Ellen', partWay: true), reason: "Ellen's own base write");
      expect(temp.snapshotsOf('Ellen'), hasLength(1), reason: "the base write's snapshot stays the newest");
    });

    test("a base write that ended does not stop a placement into its folder: the update and its patch", () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      final done = await run(
        landed(
          zip('placing.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Miyabi/Ellen.ini': '$ini; fix\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Miyabi': const PlaceAsPatch('Ellen')},
      );
      expect(done.resultFor('Ellen')!.end, UpdateModEnd.written);
      expect(done.resultFor('Miyabi')!.patchedInto, 'Ellen');
      expect(temp.read('Ellen', 'Body.dds'), 'v2');
      expect(temp.read('Ellen', 'Ellen.ini'), '$ini; fix\n');
    });

    test('a placement refused for snapshot space wrote nothing, so the next placement into that folder goes ahead', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      await installed('Nicole', modId: 300);
      temp.write('Nicole', 'Ellen.ini', ini);
      temp.write('Nicole', 'Miyabi.ini', ini);
      snapshots.refuseOnceFor.add('Nicole');
      final done = await run(
        landed(
          zip('two.zip', {'Ellen/Ellen.ini': '$ini; one\n', 'Miyabi/Miyabi.ini': '$ini; two\n'}),
          [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        ),
        answers: {'Ellen': const PlaceAsPatch('Nicole'), 'Miyabi': const PlaceAsPatch('Nicole')},
      );
      expect(done.resultFor('Ellen')!.failure?.kind, UpdateFailureKind.noSpace);
      expect(done.resultFor('Miyabi')!.patchedInto, 'Nicole');
      expect(temp.read('Nicole', 'Ellen.ini'), ini);
      expect(temp.read('Nicole', 'Miyabi.ini'), '$ini; two\n');
    });

    test('the folders the archive left out are those no written folder took', () async {
      await installed('Ellen', group: 'g1');
      await installed('Miyabi', group: 'g1');
      snapshots.refuseFor.add('Miyabi');
      final done = await run(landed(
        zip('group.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Miyabi/Miyabi.ini': ini, 'Miyabi/Body.dds': 'v2'}),
        [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
      ));
      expect(done.resultFor('Ellen')!.end, UpdateModEnd.written);
      expect(done.resultFor('Miyabi')!.end, UpdateModEnd.failed);
      expect(done.updateReport!.leftOut, ['Miyabi'], reason: "Miyabi's folder of the archive was not installed");
    });

    test('a newer verdict a check stored since the update is not overwritten by the mark Undo puts back', () async {
      await plainUpdate();
      const newer = UpdateCheck(outcome: UpdateOutcome.upToDate, subject: DownloadKey.base(100));
      container.read(modUpdateChecksProvider.notifier).state = {modName: newer};
      await offered(modName);

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undone, isTrue);
      expect(container.read(modUpdateChecksProvider)[modName], same(newer));
    });

    test("Take out of a patch whose files are already gone drops its record and reads the library again", () async {
      await installed(modName);
      await installed('Miyabi', modId: 200);
      temp.write('Miyabi', 'Ellen.ini', ini);
      await run(patchJob(), answers: {modName: const PlaceAsPatch('Miyabi')});
      expect(await offered(modName), isNull);
      // The patch's one file, deleted by hand: nothing moves, only the record goes.
      File(p.join(temp.modFolder('Miyabi').path, 'Ellen.ini')).deleteSync();
      expect((await container.read(libraryProvider.future)).singleWhere((m) => m.id == 'Miyabi').origin!.downloads, hasLength(2));

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undone, isTrue);
      expect((await service.readModOrigin('Miyabi'))!.downloads, hasLength(1));
      expect((await container.read(libraryProvider.future)).singleWhere((m) => m.id == 'Miyabi').origin!.downloads, hasLength(1),
          reason: 'the library is read again after the record changed');
    });

    test('a folder replaced under the same name since is read from its sidecar, and Undo writes nothing into it', () async {
      await plainUpdate();
      expect(await offered(modName), isNull, reason: 'the library is read and cached');
      // Replaced in a file manager: the library still has the old folder cached.
      temp.modFolder(modName).renameSync(p.join(temp.mods.path, 'Ellen Old'));
      temp.write(modName, 'Other.ini', ini);

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.folderGone);
      expect(temp.has(modName, 'Body.dds'), isFalse, reason: 'nothing of the snapshot was written into the other folder');
      expect(temp.read(modName, 'Other.ini'), ini);
    });

    test('a snapshot list being read again counts as not read, so Undo is not offered meanwhile', () async {
      final done = await plainUpdate();
      final uid = updateUndoRecordOf(done, modName)!.snapshot.modUid;
      final sub = container.listen(updateUndoProvider((seq: 1, modId: modName)), (_, _) {});
      addTearDown(sub.close);
      await container.read(libraryProvider.future);
      await container.read(modSnapshotListProvider(uid).future);
      expect(sub.read(), isNull);

      container.invalidate(modBackupsProvider);
      expect(sub.read(), UpdateUndoProblem.unknown);
      await container.read(modSnapshotListProvider(uid).future);
      expect(sub.read(), isNull);
    });

    group("a press that did nothing says why, by where it stopped", () {
      test("the snapshots could not be read: nothing was changed", () async {
        await plainUpdate();
        await offered(modName);
        snapshots.listThrows = true;

        await undoUpdate(container, 1, modName);

        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.notRead);
        expect(temp.read(modName, 'Body.dds'), 'v2');
        expect(temp.snapshotsOf(modName), hasLength(1), reason: 'nothing was saved, since nothing was written');
      });

      test("the folder could not be saved first: nothing was changed", () async {
        await plainUpdate();
        await offered(modName);
        snapshots.refuseFor.add(modName);

        await undoUpdate(container, 1, modName);

        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.notSaved);
        expect(temp.read(modName, 'Body.dds'), 'v2');
      });

      test('the restore stopped part-way', () async {
        await plainUpdate();
        await offered(modName);
        snapshots.restoreFails = true;

        await undoUpdate(container, 1, modName);

        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.partWay);
        expect(job().resultFor(modName)!.undone, isFalse);
        expect(temp.snapshotsOf(modName), hasLength(2), reason: 'the folder was saved before the copy failed');
      });

      test("a patch's record that could not be removed, when its files were gone already: no file moved", () async {
        await installed(modName);
        await installed('Miyabi', modId: 200);
        temp.write('Miyabi', 'Ellen.ini', ini);
        await run(patchJob(), answers: {modName: const PlaceAsPatch('Miyabi')});
        await offered(modName);
        File(p.join(temp.modFolder('Miyabi').path, 'Ellen.ini')).deleteSync();
        service.failOriginWrites = true;

        await undoUpdate(container, 1, modName);

        expect(job().resultFor(modName)!.undoProblem, UpdateUndoProblem.recordNotRemoved);
        expect(temp.read('Miyabi', 'Body.dds'), 'v1');
      });
    });

    group('Undo pressed on screen', () {
      /// Runs the update and reads what the rule reads, before the first frame: a read the frame starts would wait on the test's fake clock.
      Future<void> updated(WidgetTester t) => t.runAsync(() async {
            await plainUpdate();
            await container.read(libraryProvider.future);
            final snapshots = modSnapshotListProvider(updateUndoRecordOf(job(), modName)!.snapshot.modUid);
            final sub = container.listen(snapshots, (_, _) {});
            addTearDown(sub.close);
            await container.read(snapshots.future);
          });

      /// Presses [undo] and waits for the press to end, which copies files and reads the library again.
      Future<void> press(WidgetTester t, Finder undo) async {
        await tapWithIo(t, undo);
        await t.runAsync(() async {
          for (var i = 0; i < 200 && !job().resultFor(modName)!.undone && job().resultFor(modName)!.undoProblem == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await t.pump();
      }

      testWidgets("the Updates page's row: the folder is put back and the row reads Undone", (t) async {
        await updated(t);
        await loadTableFonts(t);
        await pumpLocalized(
          t,
          LibraryActionsHost(
            updateFetcher: (_) async => throw StateError('no fetch expected'),
            originWriter: (_, _) async => OriginWriteResult.writeFailed,
            child: UpdatesPage(onOpenPage: (_) {}, onShowUpdate: (_) {}),
          ),
          container: container,
          surfaceSize: const Size(1400, 1000),
          settle: false,
        );
        await t.pump();
        expectBuilt(UpdatesPage);
        final row = find.byKey(const ValueKey(modName));
        final undo = find.descendant(of: row, matching: find.text('Undo'));
        expect(undo, findsOneWidget);

        await press(t, undo);

        expect(temp.read(modName, 'Body.dds'), 'v1');
        expect(job().resultFor(modName)!.undone, isTrue);
        expect(find.descendant(of: row, matching: find.text('Undone')), findsOneWidget);
        expect(find.descendant(of: row, matching: find.text('back on the 2026-08-12 file')), findsOneWidget);
      });

      testWidgets("the Downloads panel's Finished row: the folder is put back and the line reads Undone", (t) async {
        await updated(t);
        await pumpLocalized(
          t,
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: DownloadsPanel.width, height: 1000, child: DownloadsPanel(clock: () => aug)),
          ),
          container: container,
          surfaceSize: const Size(1200, 1100),
          settle: false,
        );
        await t.pump();
        expectBuilt(DownloadsPanel);
        final undo = find.widgetWithText(OutlinedButton, 'Undo');
        expect(undo, findsOneWidget);

        await press(t, undo);

        expect(temp.read(modName, 'Body.dds'), 'v1');
        expect(find.textContaining('Undone · back on the 2026-08-12 file'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Undo'), findsNothing);
      });

      /// A shared archive's job of Ellen and Miyabi: Ellen is written, and Miyabi's copy then fails part-way, so the job fails.
      /// Read as [updated] reads, before the first frame.
      Future<void> failedForMiyabi(WidgetTester t) => t.runAsync(() async {
            await installed(modName, group: 'g1');
            await installed('Miyabi', group: 'g1');
            container.read(modUpdateChecksProvider.notifier).state = {modName: mark(100), 'Miyabi': mark(100)};
            queue.onWriteStep = (writing) {
              if (writing.modId != 'Miyabi' || writing.step != UpdateWriteStep.replacingFiles) return;
              queue.onWriteStep = null;
              Directory(job().updateKept!.unpacked!.folders.singleWhere((f) => p.basename(f) == 'Miyabi')).deleteSync(recursive: true);
            };
            final done = await run(landed(
              zip('shared.zip', {
                'Ellen/Ellen.ini': ini,
                'Ellen/Body.dds': 'v2',
                'Miyabi/Miyabi.ini': ini,
                'Miyabi/Body.dds': 'v2',
              }),
              [baseOf(modName, 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
            ));
            expect(done.state, DownloadJobState.failed);
            expect(done.resultFor(modName)!.end, UpdateModEnd.written);
            expect(done.resultFor('Miyabi')!.failure?.kind, UpdateFailureKind.writtenPartway);
            expect(temp.read(modName, 'Body.dds'), 'v2');
            await container.read(libraryProvider.future);
            final snapshots = modSnapshotListProvider(updateUndoRecordOf(job(), modName)!.snapshot.modUid);
            final sub = container.listen(snapshots, (_, _) {});
            addTearDown(sub.close);
            await container.read(snapshots.future);
          });

      testWidgets("a written mod of a job that failed for another: Undo on its Updates row puts its folder back, and the job stays failed",
          (t) async {
        await failedForMiyabi(t);
        await loadTableFonts(t);
        await pumpLocalized(
          t,
          LibraryActionsHost(
            updateFetcher: (_) async => throw StateError('no fetch expected'),
            originWriter: (_, _) async => OriginWriteResult.writeFailed,
            child: UpdatesPage(onOpenPage: (_) {}, onShowUpdate: (_) {}),
          ),
          container: container,
          surfaceSize: const Size(1400, 1000),
          settle: false,
        );
        await t.pump();
        expectBuilt(UpdatesPage);
        final row = find.byKey(const ValueKey(modName));
        final undo = find.descendant(of: row, matching: find.text('Undo'));
        expect(undo, findsOneWidget);

        await press(t, undo);

        expect(temp.read(modName, 'Body.dds'), 'v1');
        expect(job().resultFor(modName)!.undone, isTrue);
        expect(find.descendant(of: row, matching: find.text('Undone')), findsOneWidget);
        expect(job().state, DownloadJobState.failed);
        expect(job().resultFor('Miyabi')!.failure?.kind, UpdateFailureKind.writtenPartway);
      });

      testWidgets("a written mod of a job that failed for another: Undo on its line under the panel's failed row puts its folder back",
          (t) async {
        await failedForMiyabi(t);
        await pumpLocalized(
          t,
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: DownloadsPanel.width, height: 1000, child: DownloadsPanel(clock: () => aug)),
          ),
          container: container,
          surfaceSize: const Size(1200, 1100),
          settle: false,
        );
        await t.pump();
        expectBuilt(DownloadsPanel);
        expect(find.text('NEEDS YOUR ATTENTION · 1'), findsOneWidget);
        expect(find.textContaining('Ellen: Updated · the 2026-08-12 file is a snapshot'), findsOneWidget);
        final undo = find.widgetWithText(TextButton, 'Undo');
        expect(undo, findsOneWidget);

        await press(t, undo);

        expect(temp.read(modName, 'Body.dds'), 'v1');
        expect(find.textContaining('Ellen: Undone · back on the 2026-08-12 file'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Undo'), findsNothing);
        expect(job().state, DownloadJobState.failed);
        expect(find.text('NEEDS YOUR ATTENTION · 1'), findsOneWidget, reason: 'the failed row stays where it was');
      });
    });

    test("a patch layer's new version is restored, not taken out, so its earlier version comes back", () async {
      const patchPage = 300;
      temp.write(modName, '$modName.ini', ini);
      temp.write(modName, 'Body.dds', 'p1');
      await temp.writeOrigin(
        modName,
        originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
          ingest: const ModIngest(folders: [modName], patchFiles: ['Body.dds']),
          patches: [
            patchFixture(
              modId: patchPage,
              fileId: 9,
              files: const [InstalledFile(path: 'Body.dds', role: InstalledFileRole.replaced)],
            ),
          ],
        ),
      );
      final done = await run(landed(zip('fix.zip', {'Fix/Body.dds': 'p2'}), [patchOf(modName, patchPage, heldFileId: 9)]));
      expect(done.resultFor(modName)!.end, UpdateModEnd.written);
      expect(temp.read(modName, 'Body.dds'), 'p2');
      expect(updateUndoRecordOf(done, modName)!.takeOut, isNull);
      expect(await offered(modName), isNull);

      await undoUpdate(container, 1, modName);

      expect(job().resultFor(modName)!.undone, isTrue);
      expect(temp.read(modName, 'Body.dds'), 'p1');
      expect((await service.readModOrigin(modName))!.downloads.last.fileId, 9, reason: 'the earlier version is on record again');
    });
  });

  group('the write counter (whileWritingModCounted)', () {
    test("a write alone has its count; one that starts while another runs has none", () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final (_, alone) = await whileWritingModCounted(container, 'Ellen', () async {});
      expect(alone, 1);

      final held = holdWrite(container, 'Ellen');
      final (_, overlapped) = await whileWritingModCounted(container, 'Ellen', () async {});
      await held.release();
      expect(overlapped, isNull, reason: 'Undo is never offered over a write this one overlapped');
    });
  });
}
