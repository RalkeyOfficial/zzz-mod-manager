import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_prepare.dart';
import 'package:mod_manager_flutter/services/update_apply/update_run_stages.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/held_write.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/seeded_queue.dart';
import 'support/temp_library.dart';
import 'support/update_jobs.dart';

/// An update run's two stages against a real library in a temp directory:
/// the unpack and preview with the questions it stops at,
/// and the write with what it reads again first (`docs/update-runs.md` §6 "Staleness at the write") and what came of each mod of the job.
void main() {
  const modName = 'Ellen';
  const ini = '[TextureOverrideBody]\nhash = 1\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n';

  late TempLibrary temp;
  late RecordingService service;
  late ProviderContainer container;
  late Directory archives;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_update_run_');
    service = RecordingService(temp);
    container = ProviderContainer(overrides: service.overrides);
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

  File plainZip() => zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'});

  ModOrigin origin({List<String> folders = const [modName], List<ModDownload> patches = const []}) => originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: ModIngest(folders: folders),
        patches: patches,
      );

  Future<void> installed({ModOrigin? recorded}) async {
    temp.write(modName, 'Ellen.ini', ini);
    temp.write(modName, 'Body.dds', 'v1');
    await temp.writeOrigin(modName, recorded ?? origin());
  }

  /// The job as the queue hands it to the unpack lane: its file landed as [archive].
  /// By default it is Ellen's base, picked while its record named the file [origin] records.
  DownloadJob landed(File archive, {List<UpdateMod>? mods, DateTime? published}) => DownloadJob(
        seq: 1,
        request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/2')),
        intent: DownloadIntent.update,
        subject: modName,
        file: GbFile(idRow: 2, file: 'ellen2.zip', dateAdded: published),
        state: DownloadJobState.updating,
        updateStep: UpdateStep.unpacking,
        result: DownloadResult(file: archive, totalBytes: archive.lengthSync()),
        update: UpdateTask(mods: mods ?? [baseOf(modName, 100, heldFileId: 1)]),
      );

  /// The job as the queue hands it to the install lane, with what the unpack lane kept.
  DownloadJob unpacked(DownloadJob job, UpdateStageReady ready) =>
      job.copyWith(updateStep: UpdateStep.writing, prepared: ready.prepared);

  Future<void> deleteKept(Object? kept) => ArchiveService.deleteExtraction((kept! as UpdateRunKept).unpackedFolders);

  Future<UpdateStageReady> prepared(DownloadJob job, {ProviderContainer? within}) async {
    final result = await prepareUpdateJob(within ?? container, job);
    expect(result, isA<UpdateStageReady>());
    final ready = result as UpdateStageReady;
    addTearDown(() => deleteKept(ready.prepared));
    return ready;
  }

  UpdateModResult resultFor(UpdateStageResult result, String modId) => switch (result) {
        UpdateStageWritten(:final results) ||
        UpdateStageSkipped(:final results) ||
        UpdateStageFailed(:final results) =>
          results.firstWhere((r) => r.mod.modId == modId),
        _ => fail('$result carries no results'),
      };

  test('a plain update is unpacked, previewed and written, and the archive goes once unpacked', () async {
    await installed();
    final archive = plainZip();
    final job = landed(archive);

    final ready = await prepared(job);
    expect(archive.existsSync(), isFalse);
    expect(temp.read(modName, 'Body.dds'), 'v1', reason: 'nothing is written before the write');

    final written = await writeUpdateJob(container, unpacked(job, ready));
    expect((written as UpdateStageWritten).outcome, JobOutcome.updated);
    expect(resultFor(written, modName).end, UpdateModEnd.written);
    expect(temp.read(modName, 'Body.dds'), 'v2');
    expect(temp.snapshotsOf(modName), hasLength(1));
  });

  group('the unpack stops at a question', () {
    test('a patch-shaped download, which is never written', () async {
      await installed();
      final result = await prepareUpdateJob(container, landed(zip('patch.zip', {'Ellen Fix/Ellen.ini': ini})));
      final asks = result as UpdateStageAsks;
      addTearDown(() => deleteKept(asks.prepared));
      expect(asks.wait.question, UpdateQuestionKind.patchShaped);
      expect((asks.prepared! as UpdateRunKept).unpackedFolders, isNotEmpty,
          reason: 'the job holds its unpacked folders while it waits');
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test('a patch in the folder that nothing records', () async {
      await installed(recorded: origin(patches: [patchFixture(fileId: 9)]));
      final result = await prepareUpdateJob(container, landed(plainZip()));
      final asks = result as UpdateStageAsks;
      addTearDown(() => deleteKept(asks.prepared));
      expect(asks.wait.question, UpdateQuestionKind.unrecordedPatch);
    });

    final sevenZip = ['7z', '7za'].map((tool) {
      try {
        final which = Process.runSync('which', [tool]);
        return which.exitCode == 0 ? which.stdout.toString().trim() : null;
      } catch (_) {
        return null;
      }
    }).whereType<String>().firstOrNull;

    test('a locked archive, before anything is unpacked, and the archive is kept for the password', () async {
      await installed();
      final source = Directory(p.join(temp.root.path, 'src', modName))..createSync(recursive: true);
      File(p.join(source.path, 'Ellen.ini')).writeAsStringSync(ini);
      final archive = p.join(archives.path, 'locked.7z');
      final made = Process.runSync(sevenZip!, ['a', '-pSECRET-1', '-mhe=on', archive, source.path]);
      expect(made.exitCode, 0, reason: made.stderr.toString());

      final result = await prepareUpdateJob(container, landed(File(archive)));
      expect((result as UpdateStageAsks).wait.question, UpdateQuestionKind.password);
      expect(result.wait.passwordFailed, isFalse);
      expect(File(archive).existsSync(), isTrue);
    }, skip: sevenZip == null ? 'no 7-Zip on this system' : false);
  });

  group('the unpack fails', () {
    test('an archive that is not one stays, and the failure is the mod\'s own', () async {
      await installed();
      final broken = File(p.join(archives.path, 'broken.zip'))..writeAsStringSync('not a zip');
      final failure = ((await prepareUpdateJob(container, landed(broken))) as UpdateStageFailed).failure;
      expect(failure.kind, UpdateFailureKind.unpackFailed);
      expect(failure.haltsRun, isFalse);
      expect(broken.existsSync(), isTrue);
    });

    test('an unpack with no mod folder in it fails as nothing to install, and its directory goes', () async {
      await installed();
      // An empty zip is refused by the extractor itself; this is the unpack such an archive would leave.
      final root = Directory.systemTemp.createTempSync('zzz_archive_extract_empty_');
      final job = landed(plainZip()).copyWith(
        prepared: UpdateRunKept(unpacked: UpdateUnpacked(root: root, folders: const [], archiveMd5: null)),
      );
      final result = await prepareUpdateJob(container, job);
      expect((result as UpdateStageFailed).failure.kind, UpdateFailureKind.nothingToInstall);
      expect(root.existsSync(), isFalse);
    });
  });

  group('at the write', () {
    test('an unpack that is gone fails before anything is turned off or cleared', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      await deleteKept(ready.prepared);

      final result = await writeUpdateJob(container, unpacked(job, ready));
      final failure = (result as UpdateStageFailed).failure;
      expect(failure.kind, UpdateFailureKind.unpackGone);
      expect(failure.haltsRun, isFalse);
      expect(temp.read(modName, 'Body.dds'), 'v1');
      expect(temp.snapshotsOf(modName), isEmpty);
    });

    test('a mod gone from the library is skipped, and nothing is written', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      temp.deleteMod(modName);

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.modGone);
      expect(temp.has(modName, 'Body.dds'), isFalse);
    });

    test('a folder renamed meanwhile is skipped as renamed, and nothing is written', () async {
      await installed();
      final uid = (await container.read(libraryProvider.future)).firstWhere((m) => m.id == modName).uid;
      expect(uid, isNotNull, reason: 'a scanned mod has a uid');
      final job = landed(plainZip(), mods: [UpdateMod(modId: modName, layer: const DownloadKey.base(100), uid: uid)]);
      final ready = await prepared(job);

      temp.modFolder(modName).renameSync(p.join(temp.mods.path, 'Ellen Renamed'));
      container.invalidate(libraryProvider);

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.folderRenamed);
      expect(temp.read('Ellen Renamed', 'Body.dds'), 'v1');
    });

    test('a verdict changed since the unpack is a new question', () async {
      await installed();
      final job = landed(zip('two.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Extras/Other.ini': ini}));
      final ready = await prepared(job);
      // Restored to a version recorded with other folders while the job waited.
      await temp.writeOrigin(modName, origin(folders: const ['Ellen Old']));

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageAsks).wait.question, UpdateQuestionKind.folders);
      expect(temp.read(modName, 'Body.dds'), 'v1');

      // The question carries what the picker offers, and the pick goes back through the same unpack.
      final kept = result.prepared! as UpdateRunKept;
      addTearDown(() => deleteKept(kept));
      final question = kept.foldersQuestion!;
      expect(question.problem, UpdateLayoutProblem.layoutChanged);
      expect([for (final c in question.choices) c.name], unorderedEquals(['Ellen', 'Extras']));
      final ellen = question.choices.firstWhere((c) => c.name == 'Ellen').path;
      final picked = kept.withPickedFolders([ellen]);
      expect(picked.foldersQuestion, isNull, reason: 'an answered question is no longer kept');
      final again = await prepareUpdateJob(container, job.copyWith(prepared: picked));
      expect(again, isA<UpdateStageReady>());
    });

    test("a write tells the queue the part it has started, and a mod that was off is never 'linked in'", () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      final writing = unpacked(job, ready);
      final seeded = ProviderContainer(
        overrides: [...service.overrides, downloadQueueProvider.overrideWith(() => SeededQueue([writing]))],
      );
      addTearDown(seeded.dispose);
      final steps = <UpdateWriteStep>[];
      seeded.listen(downloadQueueProvider, (_, jobs) {
        final step = jobs.single.writing?.step;
        if (step != null && (steps.isEmpty || steps.last != step)) steps.add(step);
      });

      await writeUpdateJob(seeded, writing);
      expect(steps, [UpdateWriteStep.savingSnapshot, UpdateWriteStep.replacingFiles]);
    });

    test('a folder the host passes as being written is skipped', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);

      final result = await writeUpdateJob(container, unpacked(job, ready), skip: {modName});
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.beingWritten);
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test('a folder something else started writing is skipped, read by the stage itself', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      final restore = holdWrite(container, modName);

      final result = await writeUpdateJob(container, unpacked(job, ready));
      await restore.release();
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.beingWritten);
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test('a mod whose update was ignored while the job waited is skipped, and nothing is written', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      container.read(modUpdateChecksProvider.notifier).state = {
        modName: const UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          dismissed: true,
          subject: DownloadKey.base(100),
        ),
      };

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.ignoredMeanwhile);
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test('a dismissal on the sidecar that reaches the picked file is an Ignore too, and it is kept', () async {
      await installed();
      final until = DateTime.utc(2026, 3, 1);
      final job = landed(plainZip(), published: until);
      final ready = await prepared(job);
      await temp.writeOrigin(modName, origin().copyBase(updatesDismissedUntil: until));

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.ignoredMeanwhile);
      expect(temp.read(modName, 'Body.dds'), 'v1');
      expect((await service.readModOrigin(modName))?.updatesDismissedUntil, until);
    });

    group('a dismissal is read against the one the layer held at the press', () {
      final jan1 = DateTime.utc(2026, 1, 1);
      final jan5 = DateTime.utc(2026, 1, 5);

      // SFW v2 of Jan 1 and NSFW v2 of Jan 5 were ignored, NSFW v3 brought the mod back, and the user picked SFW v2.
      Future<DownloadJob> pickedOverIgnore() async {
        await installed(recorded: origin().copyBase(updatesDismissedUntil: jan5));
        final job = landed(
          plainZip(),
          published: jan1,
          mods: [UpdateMod(modId: modName, layer: const DownloadKey.base(100), heldFileId: 1, heldDismissedUntil: jan5)],
        );
        return unpacked(job, await prepared(job));
      }

      test('one already there at the press is not an Ignore: the picked file is written', () async {
        final result = await writeUpdateJob(container, await pickedOverIgnore());
        expect(result, isA<UpdateStageWritten>());
        expect(temp.read(modName, 'Body.dds'), 'v2');
      });

      test('one raised since the press is, and it is kept', () async {
        final job = await pickedOverIgnore();
        final feb2 = DateTime.utc(2026, 2, 2);
        await temp.writeOrigin(modName, origin().copyBase(updatesDismissedUntil: feb2));

        final result = await writeUpdateJob(container, job);
        expect((result as UpdateStageSkipped).reason, UpdateSkipReason.ignoredMeanwhile);
        expect(temp.read(modName, 'Body.dds'), 'v1');
        expect((await service.readModOrigin(modName))?.updatesDismissedUntil, feb2);
      });
    });

    test('a layer that named no file at the press and names one now is already updated, not written back', () async {
      // Marked current by date: the record names no file.
      await installed(
        recorded: originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          ingest: const ModIngest(folders: [modName]),
        ),
      );
      final job = landed(plainZip(), mods: [baseOf(modName, 100)]);
      final ready = await prepared(job);
      // A newer file through the one-mod window, which records it and drops the folder's verdict.
      await temp.writeOrigin(modName, origin().copyBase(fileId: 3));
      temp.write(modName, 'Body.dds', 'v3');

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.alreadyUpdated);
      expect(temp.read(modName, 'Body.dds'), 'v3');
    });

    test('a write by something else that starts after the stage began reading skips the folder', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);

      final result = writeUpdateJob(container, unpacked(job, ready));
      // Started and ended while the stage reads, so it is neither running at the folder's turn nor seen by the reads
      // that came before it landed.
      await whileWritingMod(container, modName, () async {});
      expect(container.read(modWritesInProgressProvider), isEmpty, reason: 'the other write has ended');

      expect(((await result) as UpdateStageSkipped).reason, UpdateSkipReason.beingWritten);
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test("a base and then its patch, picked in one press, both write: the run's own write is not something else's",
        () async {
      const patchPage = 605460;
      final patchFiles = [const InstalledFile(path: 'Body.dds', role: InstalledFileRole.replaced)];
      await installed(
        recorded: originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
          ingest: const ModIngest(folders: [modName], patchFiles: ['Body.dds']),
          patches: [patchFixture(fileId: 9, files: patchFiles)],
        ),
      );

      final base = landed(plainZip());
      final baseResult = await writeUpdateJob(container, unpacked(base, await prepared(base)));
      expect(resultFor(baseResult, modName).end, UpdateModEnd.written);

      // The folder's next job is unpacked and written only once the base's job has ended.
      final patch = landed(zip('fix.zip', {'Fix/Body.dds': 'p2'}), mods: [patchOf(modName, patchPage, heldFileId: 9)]);
      final patchResult = await writeUpdateJob(container, unpacked(patch, await prepared(patch)));
      expect(resultFor(patchResult, modName).end, UpdateModEnd.written);
      expect(temp.read(modName, 'Body.dds'), 'p2');
    });

    test('a layer written by something else meanwhile is skipped as already updated, not written back', () async {
      await installed();
      final job = landed(plainZip(), mods: [const UpdateMod(modId: modName, layer: DownloadKey.base(100), heldFileId: 1)]);
      final ready = await prepared(job);
      // A newer file written through the one-mod window: the record moves on and the folder's mark goes.
      await temp.writeOrigin(modName, origin().copyBase(fileId: 3));
      temp.write(modName, 'Body.dds', 'v3');

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.alreadyUpdated);
      expect(resultFor(result, modName).alongWith, isNull);
      expect(temp.read(modName, 'Body.dds'), 'v3');
    });

    test('a layer whose record changed while the verdict still offers the update is written', () async {
      await installed();
      final job = landed(plainZip(), mods: [const UpdateMod(modId: modName, layer: DownloadKey.base(100), heldFileId: 1)]);
      final ready = await prepared(job);
      // Restored to an older file meanwhile: the update is still wanted.
      await temp.writeOrigin(modName, origin().copyBase(fileId: 0));
      container.read(modUpdateChecksProvider.notifier).state = {
        modName: const UpdateCheck(outcome: UpdateOutcome.updateAvailable, subject: DownloadKey.base(100)),
      };

      final result = await writeUpdateJob(container, unpacked(job, ready));
      expect(result, isA<UpdateStageWritten>());
      expect(temp.read(modName, 'Body.dds'), 'v2');
    });

    test('a mod another job of the run wrote reads as updated along with that job\'s mod', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);
      final writing = unpacked(job, ready);
      final other = updateJob(5, state: DownloadJobState.done, mods: [baseOf('Miyabi', 100), baseOf(modName, 100)])
          .copyWith(modResults: [UpdateModResult.written(baseOf('Miyabi', 100)), UpdateModResult.written(baseOf(modName, 100))]);
      final seeded = ProviderContainer(
        overrides: [...service.overrides, downloadQueueProvider.overrideWith(() => SeededQueue([other, writing]))],
      );
      addTearDown(seeded.dispose);
      // That job's write recorded the file this job holds.
      await temp.writeOrigin(modName, origin().copyBase(fileId: 2));

      final result = await writeUpdateJob(seeded, writing);
      expect((result as UpdateStageSkipped).reason, UpdateSkipReason.alreadyUpdated);
      expect(resultFor(result, modName).alongWith, 'Miyabi');
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });

    test('a patch layer\'s write keeps the verdict it drops as the mark it removed', () async {
      const patchPage = 605460;
      temp.write(modName, 'Ellen.ini', ini);
      temp.write(modName, 'Body.dds', 'v1');
      await temp.writeOrigin(
        modName,
        origin(patches: [
          patchFixture(fileId: 9, files: const [InstalledFile(path: 'Body.dds', role: InstalledFileRole.replaced)]),
        ]),
      );
      const verdict = UpdateCheck(outcome: UpdateOutcome.updateAvailable, subject: DownloadKey.patch(patchPage));
      container.read(modUpdateChecksProvider.notifier).state = {modName: verdict};
      final job = landed(zip('fix.zip', {'Fix/Body.dds': 'p2'}), mods: [patchOf(modName, patchPage, heldFileId: 9)]);
      final ready = await prepared(job);

      final result = await writeUpdateJob(container, unpacked(job, ready));
      final report = (result as UpdateStageWritten).report! as UpdateReport;
      expect(temp.read(modName, 'Body.dds'), 'p2');
      expect(report.removedMarks[modName], same(verdict), reason: 'the Updates row reads the same after the write');
      expect(container.read(modUpdateChecksProvider), isNot(contains(modName)));
    });

    test('no room for the snapshot halts the run, with both figures, and nothing is written', () async {
      await installed();
      final job = landed(plainZip());
      final ready = await prepared(job);

      final full = ProviderContainer(overrides: [
        ...service.overrides,
        snapshotServiceProvider.overrideWithValue(
          SnapshotService(rootPath: p.join(temp.root.path, 'backups'), freeSpace: (_) async => 1),
        ),
      ]);
      addTearDown(full.dispose);
      final failure = ((await writeUpdateJob(full, unpacked(job, ready))) as UpdateStageFailed).failure;
      expect(failure.kind, UpdateFailureKind.noSpace);
      expect(failure.haltsRun, isTrue);
      expect(failure.availableBytes, 1);
      expect(failure.requiredBytes, greaterThan(1));
      expect(temp.read(modName, 'Body.dds'), 'v1');
    });
  });

  test('how a folder\'s failed write is called: a copy that failed part-way and a snapshot halt the run', () {
    UpdateApplyResult failed(UpdateApplyFailure failure, {SnapshotNoRoom? room}) =>
        UpdateApplyResult.failed(failure, snapshotNoRoom: room);
    expect(updateFailureOf(failed(UpdateApplyFailure.copy)).kind, UpdateFailureKind.writtenPartway);
    expect(updateFailureOf(failed(UpdateApplyFailure.snapshot)).kind, UpdateFailureKind.snapshotFailed);
    final noRoom = updateFailureOf(
        failed(UpdateApplyFailure.snapshot, room: const SnapshotNoRoom(requiredBytes: 9, availableBytes: 3)));
    expect((noRoom.kind, noRoom.requiredBytes, noRoom.availableBytes), (UpdateFailureKind.noSpace, 9, 3));
    expect(updateFailureOf(failed(UpdateApplyFailure.layout)).kind, UpdateFailureKind.refused);
    for (final halting in [UpdateApplyFailure.copy, UpdateApplyFailure.snapshot]) {
      expect(updateFailureOf(failed(halting)).haltsRun, isTrue, reason: halting.name);
    }
  });

  group('a job of several mods says what came of each', () {
    final published = DateTime(2026, 1, 1);
    const names = ['Ellen', 'Miyabi', 'Soukaku', 'Nicole'];

    ModOrigin groupOrigin(String name, {int fileId = 1}) => originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          versionConfidence: OriginConfidence.exact,
          ingest: ModIngest(folders: [name], siblingGroup: 'g1'),
        );

    /// Ellen, Miyabi and Soukaku of one archive; Nicole is already on the file, so the group refuses her.
    Future<void> group({String bigOne = ''}) async {
      for (final name in names) {
        temp.write(name, '$name.ini', ini);
        temp.write(name, 'Body.dds', name == bigOne ? 'v1' * 40000 : 'v1');
        await temp.writeOrigin(name, groupOrigin(name, fileId: name == 'Nicole' ? 2 : 1));
      }
    }

    File groupZip() => zip('group.zip', {
          for (final name in names) ...{'$name/$name.ini': ini, '$name/Body.dds': 'v2'},
        });

    DownloadJob job(List<String> picked) => landed(
          groupZip(),
          mods: [for (final name in picked) baseOf(name, 100, heldFileId: name == 'Nicole' ? 2 : 1)],
          published: published,
        );

    test('a pick joined by its file that the archive\'s group does not list is refused, and the rest written',
        () async {
      await installed();
      temp.write('Rina', 'Rina.ini', ini);
      final mixed = job([modName, 'Rina']);
      final ready = await prepared(mixed);

      final result = await writeUpdateJob(container, unpacked(mixed, ready));
      expect(result, isA<UpdateStageWritten>());
      expect(resultFor(result, modName).end, UpdateModEnd.written);
      expect(resultFor(result, 'Rina').end, UpdateModEnd.refused);
      expect(temp.read('Rina', 'Rina.ini'), ini, reason: 'nothing is written into it');
    });

    test('a busy sibling is skipped and one already on the file says so, while the others are written', () async {
      await group();
      final picks = job(['Ellen', 'Miyabi', 'Soukaku', 'Nicole']);
      final ready = await prepared(picks);

      final result = await writeUpdateJob(container, unpacked(picks, ready), skip: {'Soukaku'});
      expect(result, isA<UpdateStageWritten>());
      expect(resultFor(result, 'Ellen').end, UpdateModEnd.written);
      expect(resultFor(result, 'Miyabi').end, UpdateModEnd.written);
      expect(resultFor(result, 'Soukaku').skipReason, UpdateSkipReason.beingWritten);
      // Her record already names this file, so there is nothing to write.
      expect(resultFor(result, 'Nicole').skipReason, UpdateSkipReason.alreadyUpdated);
      expect(temp.read('Soukaku', 'Body.dds'), 'v1');
      expect(temp.read('Nicole', 'Body.dds'), 'v1');
    });

    test('a folder something else starts writing while the one before it is written is skipped at its turn',
        () async {
      await group();
      final picks = job(['Ellen', 'Miyabi']);
      final ready = await prepared(picks);
      HeldWrite? restore;
      final watching = container.listen<Set<String>>(modWritesInProgressProvider, (_, writing) {
        if (writing.contains('Ellen') && restore == null) {
          scheduleMicrotask(() => restore = holdWrite(container, 'Miyabi'));
        }
      });
      addTearDown(watching.close);

      final result = await writeUpdateJob(container, unpacked(picks, ready));
      await restore?.release();
      expect(restore, isNotNull);
      expect(resultFor(result, 'Ellen').end, UpdateModEnd.written);
      expect(resultFor(result, 'Miyabi').skipReason, UpdateSkipReason.beingWritten);
      expect(temp.read('Miyabi', 'Body.dds'), 'v1');
    });

    // Each picked sibling carries its own preview, and the confirmation a run does not show checked every one of them.
    test('a picked sibling whose download is shaped like a patch stops the job, and nothing is written', () async {
      await group();
      File halfZip() => zip('half.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Miyabi/Miyabi.ini': ini});

      final alone = await prepared(job(['Ellen']).copyWith(result: DownloadResult(file: halfZip(), totalBytes: 1)));
      expect(alone, isA<UpdateStageReady>(), reason: 'Ellen\'s own preview is a plain update');

      final both = landed(
        halfZip(),
        mods: [baseOf('Ellen', 100, heldFileId: 1), baseOf('Miyabi', 100, heldFileId: 1)],
        published: published,
      );
      final result = await prepareUpdateJob(container, both);
      final asks = result as UpdateStageAsks;
      addTearDown(() => deleteKept(asks.prepared));
      expect(asks.wait.question, UpdateQuestionKind.patchShaped);

      // The same at the write, from a preview made again then.
      final again = await writeUpdateJob(container, both.copyWith(updateStep: UpdateStep.writing, prepared: asks.prepared));
      expect((again as UpdateStageAsks).wait.question, UpdateQuestionKind.patchShaped);
      expect(temp.read('Ellen', 'Body.dds'), 'v1');
      expect(temp.read('Miyabi', 'Body.dds'), 'v1');
    });

    test('a picked sibling whose folder holds a patch nothing records stops the job', () async {
      await group();
      await temp.writeOrigin('Miyabi', originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: ['Miyabi'], siblingGroup: 'g1'),
        patches: [patchFixture(fileId: 9)],
      ));

      final result = await prepareUpdateJob(container, job(['Ellen', 'Miyabi']));
      final asks = result as UpdateStageAsks;
      addTearDown(() => deleteKept(asks.prepared));
      expect(asks.wait.question, UpdateQuestionKind.unrecordedPatch);
      expect(temp.read('Miyabi', 'Body.dds'), 'v1');
    });

    test('a group that fails part-way keeps the folders that were written as written', () async {
      await group(bigOne: 'Miyabi');
      final picks = job(['Ellen', 'Miyabi']);
      final tight = ProviderContainer(overrides: [
        ...service.overrides,
        // Room for Ellen's snapshot and not Miyabi's.
        snapshotServiceProvider.overrideWithValue(
          SnapshotService(rootPath: p.join(temp.root.path, 'backups'), freeSpace: (_) async => 20000),
        ),
      ]);
      addTearDown(tight.dispose);
      final ready = await prepared(picks, within: tight);

      final result = await writeUpdateJob(tight, unpacked(picks, ready));
      final failure = (result as UpdateStageFailed).failure;
      expect(failure.kind, UpdateFailureKind.noSpace);
      expect(resultFor(result, 'Ellen').end, UpdateModEnd.written);
      expect(resultFor(result, 'Miyabi').end, UpdateModEnd.failed);
      expect(temp.read('Ellen', 'Body.dds'), 'v2');
      expect(temp.read('Miyabi', 'Body.dds'), startsWith('v1'));
    });
  });
}
