import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/update_flow_outcome.dart';
import 'package:mod_manager_flutter/services/update_apply/sibling_group.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';
import 'package:mod_manager_flutter/services/update_apply/update_prepare.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// `prepareUpdate` and `writeUpdate` against a real library in a temp directory: the questions an update finds, none for a plain one, and what a write reports.
void main() {
  const modName = 'Ellen';
  const patchId = 605460;

  /// An `.ini` and the file it names: a mod that stands on its own.
  const ini = '[TextureOverrideBody]\nhash = 1\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n';

  late TempLibrary temp;
  late RecordingService service;
  late ProviderContainer container;
  late Directory archives;

  /// Every unpack the preparations made, so a question answered without unpacking again is told apart from one that did.
  late List<UpdateUnpacked> unpacks;

  /// What the preparations reported, in order: the unpack, and the start of the reading of its folders.
  late List<String> calls;

  setUp(() async {
    calls = [];
    temp = await TempLibrary.create(prefix: 'zzz_update_prepare_');
    service = RecordingService(temp);
    container = ProviderContainer(overrides: service.overrides);
    addTearDown(container.dispose);
    archives = Directory(p.join(temp.root.path, 'archives'))..createSync();
    unpacks = [];
  });

  /// A zip of [files] in [archives], paths relative to the archive's root.
  File zip(String name, Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = entry.value.codeUnits;
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return File(p.join(archives.path, name))..writeAsBytesSync(ZipEncoder().encode(archive)!);
  }

  /// The mod folder as an installed mod, with [origin] on disk when there is one.
  Future<ModInfo> installed({ModOrigin? origin}) async {
    temp.write(modName, 'Ellen.ini', ini);
    temp.write(modName, 'Body.dds', 'v1');
    if (origin != null) await temp.writeOrigin(modName, origin);
    return ModInfo(id: modName, name: modName, characterId: 'ellen', isActive: false, origin: origin);
  }

  ModOrigin recordedOrigin({List<ModDownload> patches = const []}) => originFixture(
        modId: 100,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1,
        versionConfidence: OriginConfidence.exact,
        ingest: const ModIngest(folders: [modName]),
        patches: patches,
      );

  UpdateRequest requestFor(
    ModInfo mod, {
    bool flattensPatch = false,
    bool placeAsPatch = false,
    bool previewSiblings = false,
    int remoteModId = 100,
    int fileId = 2,
    DateTime? dateAdded,
  }) =>
      UpdateRequest(
        mod: mod,
        modsPath: temp.mods.path,
        remoteModId: remoteModId,
        file: GbFile(idRow: fileId, file: 'ellen$fileId.zip', dateAdded: dateAdded),
        flattensPatch: flattensPatch,
        placeAsPatch: placeAsPatch,
        asCompanion: placeAsPatch,
        previewSiblings: previewSiblings,
      );

  Future<UpdatePrepareResult> prepare(
    UpdateRequest request,
    File archive, {
    String? password,
    FoldersAnswer? foldersAnswer,
  }) =>
      prepareUpdate(
        container,
        request,
        archive: archive,
        password: password,
        foldersAnswer: foldersAnswer,
        onUnpacked: (made) {
          unpacks.add(made);
          calls.add('unpacked');
          // Whatever the unpack made is deleted when the test ends.
          addTearDown(() => deleteExtraction(made.root));
        },
        onPreviewing: () => calls.add('previewing'),
      );

  group('prepareUpdate asks nothing of a plain update', () {
    test('and reports no question', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(requestFor(mod), zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'}));

      expect(result, isA<PreparedFolders>());
      final prepared = result as PreparedFolders;
      expect(prepared.questions, isEmpty);
      expect(prepared.primary.canProceed, isTrue);
      expect(prepared.group.targets, isEmpty);
      expect(prepared.picked, isNull);
      expect(temp.read(modName, 'Body.dds'), 'v1', reason: 'nothing is written before the write');
    });

    test('and writes nothing to the mod folder or the library while it looks', () async {
      final mod = await installed(origin: recordedOrigin());
      await prepare(requestFor(mod), zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'}));

      expect(temp.snapshotsOf(modName), isEmpty);
      expect(container.read(modWritesStartedProvider), isEmpty);
    });
  });

  group('prepareUpdate says when it starts reading the folders', () {
    test('after the unpack, once, for a plain update', () async {
      final mod = await installed(origin: recordedOrigin());
      await prepare(requestFor(mod), zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'}));

      expect(calls, ['unpacked', 'previewing']);
    });

    test('after the unpack, for a patch placement', () async {
      final mod = await installed(origin: recordedOrigin());
      await prepare(requestFor(mod, placeAsPatch: true, remoteModId: patchId, fileId: 3), zip('patch.zip', {'Ellen Fix/Patch.dds': 'v2'}));

      expect(calls, ['unpacked', 'previewing']);
    });

    test('not for an archive that does not unpack, which is not read at all', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(requestFor(mod), zip('empty.zip', {}));

      expect(result, isA<UpdateUnpackFailed>(), reason: 'an archive with nothing in it does not unpack');
      expect(calls, isEmpty);
    });

    test('not for an unpack with no folders, which has nothing to read', () async {
      final mod = await installed(origin: recordedOrigin());
      const nothing = UpdateUnpacked(root: null, folders: [], archiveMd5: null);
      final result = await prepare(
        requestFor(mod),
        zip('unused.zip', {}),
        foldersAnswer: const FoldersAnswer(unpacked: nothing, folders: []),
      );

      expect(result, isA<UpdateNothingToInstall>());
      expect(calls, isEmpty);
    });

    test('not for a password question, and not again for the answer to a folders question', () async {
      final mod = await installed();
      final archive = zip('two.zip', {'Ellen/Ellen.ini': ini, 'Ellen previews/preview.png': 'png'});
      final question = ((await prepare(requestFor(mod), archive)) as UpdateAsks).question as FoldersQuestion;
      expect(calls, ['unpacked', 'previewing'], reason: 'the question is found while reading');

      await prepare(requestFor(mod), archive, foldersAnswer: question.answer([question.choices.first.path]));

      expect(calls, ['unpacked', 'previewing']);
    });
  });

  group('prepareUpdate finds each question', () {
    test('the layout is unknown, and the answer carries on without unpacking again', () async {
      final mod = await installed();
      final archive = zip('two.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'Ellen previews/preview.png': 'png'});

      final asked = await prepare(requestFor(mod), archive);
      expect(asked, isA<UpdateAsks>());
      final question = (asked as UpdateAsks).question as FoldersQuestion;
      expect(question.problem, UpdateLayoutProblem.layoutUnknown);
      expect(question.choices.map((c) => c.name), unorderedEquals(['Ellen', 'Ellen previews']));
      expect(unpacks, hasLength(1));

      final ellen = question.choices.firstWhere((c) => c.name == 'Ellen').path;
      archive.deleteSync();
      final answered = await prepare(requestFor(mod), archive, foldersAnswer: question.answer([ellen]));

      expect(answered, isA<PreparedFolders>(), reason: 'the archive is gone, so this is the unpack from before');
      expect(unpacks, hasLength(1), reason: 'the answer unpacks nothing again');
      final prepared = answered as PreparedFolders;
      expect(prepared.picked?.folders, ['Ellen']);
      expect(prepared.primary.preview.layout.mappings.single.source, 'Ellen');
    });

    test('the layout changed', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(
        requestFor(mod),
        zip('renamed.zip', {'Ellen A/Ellen.ini': ini, 'Ellen A/Body.dds': 'v2', 'Ellen B/Other.ini': ini}),
      );

      final question = (result as UpdateAsks).question as FoldersQuestion;
      expect(question.problem, UpdateLayoutProblem.layoutChanged);
      expect(question.choices, hasLength(2));
    });

    test('the download is shaped like a patch', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(requestFor(mod), zip('patch.zip', {'Ellen Fix/Ellen.ini': ini}));

      final prepared = result as PreparedFolders;
      expect(prepared.questions.single, isA<PatchShapedQuestion>());
      expect((prepared.questions.single as PatchShapedQuestion).assessment.looksLikePatch, isTrue);
    });

    test('folders of the archive are left out', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(
        requestFor(mod),
        zip('unused.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2', 'previews/preview.png': 'png'}),
      );

      final prepared = result as PreparedFolders;
      expect((prepared.questions.single as UnusedFoldersQuestion).folders, ['previews']);
    });

    test('a patch in the folder is not recorded, so the write would take it', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(
        requestFor(mod, flattensPatch: true),
        zip('plain.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v2'}),
      );

      expect((result as PreparedFolders).questions.single, isA<UnrecordedPatchQuestion>());
    });

    test('the questions come in the order a confirmation states them', () async {
      final mod = await installed(origin: recordedOrigin());
      final result = await prepare(
        requestFor(mod, flattensPatch: true),
        zip('all.zip', {'Ellen/Ellen.ini': ini, 'previews/preview.png': 'png'}),
      );

      expect((result as PreparedFolders).questions.map((q) => q.runtimeType), [
        PatchShapedQuestion,
        UnusedFoldersQuestion,
        UnrecordedPatchQuestion,
      ]);
    });

    test('an archive that is not one is reported, with nothing unpacked', () async {
      final mod = await installed(origin: recordedOrigin());
      final broken = File(p.join(archives.path, 'broken.zip'))..writeAsStringSync('this is not a zip');

      expect(await prepare(requestFor(mod), broken), isA<UpdateUnpackFailed>());
      expect(broken.existsSync(), isTrue, reason: 'the archive stays where it is');
    });

    group('the archive is locked', () {
      final sevenZip = () {
        try {
          final found = Process.runSync('which', ['7z']);
          return found.exitCode == 0 ? found.stdout.toString().trim() : null;
        } catch (_) {
          return null;
        }
      }();

      File locked() {
        final source = Directory(p.join(temp.root.path, 'src', 'Ellen'))..createSync(recursive: true);
        File(p.join(source.path, 'Ellen.ini')).writeAsStringSync(ini);
        File(p.join(source.path, 'Body.dds')).writeAsStringSync('v2');
        final archive = p.join(archives.path, 'locked.zip');
        final made = Process.runSync(sevenZip!, ['a', '-tzip', '-pSECRET', archive, source.path]);
        expect(made.exitCode, 0, reason: made.stderr.toString());
        return File(archive);
      }

      test('with no password given', () async {
        final mod = await installed(origin: recordedOrigin());
        final result = await prepare(requestFor(mod), locked());

        final question = (result as UpdateAsks).question as PasswordQuestion;
        expect(question.failed, isFalse);
        expect(unpacks, isEmpty, reason: 'nothing was unpacked');
      }, skip: sevenZip == null ? '7z not installed' : null);

      test('with a password that does not open it', () async {
        final mod = await installed(origin: recordedOrigin());
        final result = await prepare(requestFor(mod), locked(), password: 'wrong');

        expect(((result as UpdateAsks).question as PasswordQuestion).failed, isTrue);
      }, skip: sevenZip == null ? '7z not installed' : null);

      test('and the right one carries on to the preview', () async {
        final mod = await installed(origin: recordedOrigin());
        final result = await prepare(requestFor(mod), locked(), password: 'SECRET');

        expect(result, isA<PreparedFolders>());
        expect((result as PreparedFolders).questions, isEmpty);
      }, skip: sevenZip == null ? '7z not installed' : null);
    });

    test('a patch layer is placed over the base, and asks nothing', () async {
      temp.write(modName, 'Textures/Patch.dds', 'v1');
      final mod = await installed(
        origin: recordedOrigin(patches: [
          patchFixture(modId: patchId, files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)]),
        ]),
      );
      final result = await prepare(
        requestFor(mod, placeAsPatch: true, remoteModId: patchId, fileId: 3),
        zip('patch.zip', {'Ellen Fix/Patch.dds': 'v2'}),
      );

      final prepared = result as PreparedPatch;
      expect(prepared.questions, isEmpty);
      expect(prepared.placement.mapping, {'patch.dds': 'textures/patch.dds'}, reason: 'by basename, onto the base layout');
    });
  });

  group('writeUpdate', () {
    /// What happened, in order: the folders, the steps, and the end of the writing.
    late List<String> events;
    late List<bool> markedWhileStepping;

    setUp(() {
      events = [];
      markedWhileStepping = [];
    });

    Future<UpdateReport> write(UpdatePrepared prepared) => writeUpdate(
          container,
          prepared,
          targets: prepared is PreparedFolders ? [prepared.primary] : const [],
          onFolder: (mod, index, total) => events.add('folder ${mod.id} $index/$total'),
          onStep: (mod, step) {
            events.add('step ${step.name}');
            markedWhileStepping.add(container.read(modWritesInProgressProvider).contains(mod.id));
          },
          onWritesDone: () => events.add('done'),
        );

    Future<PreparedFolders> preparedUpdate(ModInfo mod, {String body = 'v2'}) async {
      final result = await prepare(requestFor(mod), zip('update.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': body}));
      return result as PreparedFolders;
    }

    test('reports the steps in order for a mod that was off, with no linking', () async {
      final mod = await installed(origin: recordedOrigin());
      final report = await write(await preparedUpdate(mod));

      expect(events, ['folder Ellen 1/1', 'step savingSnapshot', 'step replacingFiles', 'done']);
      expect(markedWhileStepping, everyElement(isTrue), reason: 'the mod is marked as being written while its steps run');
      expect(container.read(modWritesInProgressProvider), isEmpty);
      expect(report.applied.single.result.success, isTrue);
      expect(report.outcome.changed, isTrue);
      expect(report.outcome.soleFailure, isNull);
      expect(temp.read(modName, 'Body.dds'), 'v2');
      expect(temp.snapshotsOf(modName), hasLength(1));
      expect(temp.originOf(modName)?.fileId, 2, reason: 'the new file is recorded');
    });

    test('adds linking it in for a mod that was on', () async {
      final mod = await installed(origin: recordedOrigin());
      expect(await temp.service.activateMod(modName), isTrue);
      final report = await write(await preparedUpdate(mod));

      expect(events, ['folder Ellen 1/1', 'step savingSnapshot', 'step replacingFiles', 'step linking', 'done']);
      expect(report.applied.single.result.reactivated, isTrue);
    });

    test('takes the update mark off what it wrote, and hands the mark back in the report', () async {
      final mod = await installed(origin: recordedOrigin());
      const mark = UpdateCheck(outcome: UpdateOutcome.updateAvailable);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark, 'Other': mark};
      final report = await write(await preparedUpdate(mod));

      expect(container.read(modUpdateChecksProvider).keys, ['Other']);
      expect(report.removedMarks, {modName: mark});
      expect(report.outcome.settledMarks, {modName});
    });

    test('leaves the mark alone for a repair, which settles nothing', () async {
      final mod = await installed(origin: recordedOrigin());
      const mark = UpdateCheck(outcome: UpdateOutcome.updateAvailable);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark};
      final prepared = await prepareUpdate(
        container,
        UpdateRequest(
          mod: mod,
          modsPath: temp.mods.path,
          remoteModId: 100,
          file: const GbFile(idRow: 1),
          reinstall: true,
        ),
        archive: zip('same.zip', {'Ellen/Ellen.ini': ini, 'Ellen/Body.dds': 'v1 again'}),
        onUnpacked: (made) => addTearDown(() => deleteExtraction(made.root)),
      );
      final report = await write(prepared as PreparedFolders);

      expect(container.read(modUpdateChecksProvider), {modName: mark});
      expect(report.removedMarks, isEmpty);
    });

    test('a copy that fails after the folder was cleared is reported as a failure after a change', () async {
      final mod = await installed(origin: recordedOrigin());
      temp.write(modName, 'Hand merged.dds', 'mine');
      const mark = UpdateCheck(outcome: UpdateOutcome.updateAvailable);
      container.read(modUpdateChecksProvider.notifier).state = {modName: mark};
      final prepared = await preparedUpdate(mod);
      // The unpack is gone by the time the copy reaches for it, which fails after the wipe.
      prepared.unpacked.root!.deleteSync(recursive: true);

      final report = await write(prepared);

      final failure = report.outcome.soleFailure!;
      expect(failure.mod.id, modName);
      expect(failure.result.failure, UpdateApplyFailure.copy);
      expect(failure.result.snapshot, isNotNull, reason: 'the snapshot taken first is the way back');
      expect(temp.has(modName, 'Hand merged.dds'), isFalse, reason: 'the folder had been cleared');
      expect(report.outcome.changed, isTrue);
      expect(outcomeOfGroupWrite(report.applied), UpdateFlowOutcome.failedAfterChange);
      expect(container.read(modUpdateChecksProvider), {modName: mark}, reason: 'a failed write needs its mark more than before');
      expect(report.removedMarks, isEmpty);
      expect(events.last, 'done');
      expect(temp.snapshotsOf(modName), hasLength(1));
    });

    test('a mod that left before the write is a failure with nothing changed', () async {
      final mod = await installed(origin: recordedOrigin());
      final prepared = await preparedUpdate(mod);
      temp.deleteMod(modName);

      final report = await write(prepared);

      expect(report.applied.single.result.failure, UpdateApplyFailure.modMissing);
      expect(report.outcome.changed, isFalse);
      expect(outcomeOfGroupWrite(report.applied), UpdateFlowOutcome.failed);
      expect(events, ['folder Ellen 1/1', 'done'], reason: 'no step is reported for a write that never started');
    });

    test('places a patch layer by basename, and records it against its own layer', () async {
      temp.write(modName, 'Textures/Patch.dds', 'v1');
      final mod = await installed(
        origin: recordedOrigin(patches: [
          patchFixture(modId: patchId, files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)]),
        ]),
      );
      final prepared = await prepare(
        requestFor(mod, placeAsPatch: true, remoteModId: patchId, fileId: 3),
        zip('patch.zip', {'Ellen Fix/Patch.dds': 'v2'}),
      );

      final report = await write(prepared as PreparedPatch);

      expect(events, ['step savingSnapshot', 'step replacingFiles', 'done']);
      expect(report.applied.single.result.success, isTrue);
      expect(report.outcome.changed, isTrue);
      expect(report.removedMarks, isEmpty, reason: 'the caller drops the folder\'s verdict for a patch');
      expect(temp.read(modName, 'Textures/Patch.dds'), 'v2');
      expect(temp.read(modName, 'Body.dds'), 'v1', reason: 'the base stays where it is');
      expect(temp.originOf(modName)?.downloadOf(DownloadKey.patch(patchId))?.fileId, 3);
    });

    test('reports no linking for a mod that stays off because another was turned on meanwhile', () async {
      final mod = await installed(origin: recordedOrigin());
      expect(await temp.service.activateMod(modName), isTrue);
      final prepared = await preparedUpdate(mod);

      final steps = <UpdateWriteStep>[];
      final report = await writeUpdate(container, prepared, targets: [prepared.primary], onStep: (written, step) {
        steps.add(step);
        // One at a time turns the mod off while its folder is being written.
        if (step == UpdateWriteStep.replacingFiles) expect(turnOffDuringWrite(container, written.id), isTrue);
      });

      expect(steps, [UpdateWriteStep.savingSnapshot, UpdateWriteStep.replacingFiles]);
      expect(report.applied.single.result.success, isTrue);
      expect(report.applied.single.result.reactivated, isFalse);
      expect(await temp.service.isModActive(modName), isFalse);
    });

    test('a progress callback that throws costs the write nothing, and the mod is turned on again', () async {
      final mod = await installed(origin: recordedOrigin());
      expect(await temp.service.activateMod(modName), isTrue);
      final prepared = await preparedUpdate(mod);

      final report = await writeUpdate(
        container,
        prepared,
        targets: [prepared.primary],
        onStep: (_, step) => throw StateError('progress broke at ${step.name}'),
      );

      final result = report.applied.single.result;
      expect(result.success, isTrue);
      expect(result.snapshot, isNotNull);
      expect(result.reactivated, isTrue);
      expect(await temp.service.isModActive(modName), isTrue);
      expect(temp.read(modName, 'Body.dds'), 'v2');
    });

    test('a base write that fails after the clear reports linking when it turns the mod back on', () async {
      final mod = await installed(origin: recordedOrigin());
      expect(await temp.service.activateMod(modName), isTrue);
      final prepared = await preparedUpdate(mod);
      prepared.unpacked.root!.deleteSync(recursive: true);

      final steps = <UpdateWriteStep>[];
      final report = await writeUpdate(container, prepared, targets: [prepared.primary], onStep: (_, step) => steps.add(step));

      expect(report.applied.single.result.failure, UpdateApplyFailure.copy);
      expect(steps, [UpdateWriteStep.savingSnapshot, UpdateWriteStep.replacingFiles, UpdateWriteStep.linking]);
      expect(await temp.service.isModActive(modName), isTrue, reason: 'the failed write puts the mod back');
    });

    test('a patch placement that fails reports linking when it turns the mod back on', () async {
      temp.write(modName, 'Textures/Patch.dds', 'v1');
      final mod = await installed(
        origin: recordedOrigin(patches: [
          patchFixture(modId: patchId, files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)]),
        ]),
      );
      expect(await temp.service.activateMod(modName), isTrue);
      final prepared = await prepare(
        requestFor(mod, placeAsPatch: true, remoteModId: patchId, fileId: 3),
        zip('patch.zip', {'Ellen Fix/Patch.dds': 'v2'}),
      ) as PreparedPatch;
      File(p.join(prepared.source.path, 'Patch.dds')).deleteSync();

      final steps = <UpdateWriteStep>[];
      final report = await writeUpdate(container, prepared, targets: const [], onStep: (_, step) => steps.add(step));

      expect(report.applied.single.result.failure, UpdateApplyFailure.copy);
      expect(steps, [UpdateWriteStep.savingSnapshot, UpdateWriteStep.replacingFiles, UpdateWriteStep.linking]);
      expect(await temp.service.isModActive(modName), isTrue);
    });

    group('a write that throws', () {
      late _FailingActivity failing;

      setUp(() {
        failing = _FailingActivity(temp);
        container = ProviderContainer(overrides: failing.overrides);
        addTearDown(container.dispose);
      });

      test('brings the progress window down once for a base', () async {
        final mod = await installed(origin: recordedOrigin());
        final prepared = await preparedUpdate(mod);
        failing.failIsActive = true;

        await expectLater(write(prepared), throwsStateError);

        expect(events, ['folder Ellen 1/1', 'done']);
        expect(container.read(modWritesInProgressProvider), isEmpty);
      });

      test('brings the progress window down once for a patch', () async {
        temp.write(modName, 'Textures/Patch.dds', 'v1');
        final mod = await installed(
          origin: recordedOrigin(patches: [
            patchFixture(modId: patchId, files: const [InstalledFile(path: 'Textures/Patch.dds', role: InstalledFileRole.added)]),
          ]),
        );
        final prepared = await prepare(
          requestFor(mod, placeAsPatch: true, remoteModId: patchId, fileId: 3),
          zip('patch.zip', {'Ellen Fix/Patch.dds': 'v2'}),
        );
        failing.failIsActive = true;

        await expectLater(write(prepared as PreparedPatch), throwsStateError);

        expect(events, ['done']);
        expect(temp.read(modName, 'Textures/Patch.dds'), 'v1', reason: 'nothing was written');
      });
    });
  });

  group('the archive also installed other mods', () {
    final published = DateTime(2026, 1, 1);
    const names = ['Ellen', 'Miyabi', 'Soukaku', 'Nicole'];

    ModOrigin groupOrigin(String name, {int fileId = 1, DateTime? dismissedUntil, bool recorded = true}) => originFixture(
          modId: 100,
          modIdConfidence: OriginConfidence.exact,
          fileId: fileId,
          versionConfidence: OriginConfidence.exact,
          ingest: ModIngest(folders: recorded ? [name] : const [], siblingGroup: 'g1'),
          updatesDismissedUntil: dismissedUntil,
        );

    /// Ellen is updated. Miyabi is offered ticked, Soukaku is offered unticked because its updates were ignored, and Nicole is already on the file.
    /// [recordedLayout] false leaves Ellen with no layout on record, which is what asks the folders question.
    Future<ModInfo> library({bool recordedLayout = true}) async {
      final origins = {
        'Ellen': groupOrigin('Ellen', recorded: recordedLayout),
        'Miyabi': groupOrigin('Miyabi'),
        'Soukaku': groupOrigin('Soukaku', dismissedUntil: DateTime(2026, 2, 1)),
        'Nicole': groupOrigin('Nicole', fileId: 2),
      };
      for (final entry in origins.entries) {
        temp.write(entry.key, '${entry.key}.ini', ini);
        temp.write(entry.key, 'Body.dds', 'v1');
        await temp.writeOrigin(entry.key, entry.value);
      }
      return ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false, origin: origins['Ellen']);
    }

    File groupZip([List<String> folders = names]) => zip('group.zip', {
          for (final name in folders) ...{'$name/$name.ini': ini, '$name/Body.dds': 'v2'},
        });

    Future<PreparedFolders> prepared(ModInfo mod, [File? archive]) async =>
        await prepare(requestFor(mod, previewSiblings: true, dateAdded: published), archive ?? groupZip()) as PreparedFolders;

    test('are offered, with the ones that start unticked, the ones refused and the folders left out', () async {
      final group = (await prepared(await library())).group;

      expect(group.targets.map((t) => t.mod.id), unorderedEquals(['Miyabi', 'Soukaku']));
      expect({for (final t in group.targets) t.mod.id: t.startsAccepted}, {'Miyabi': true, 'Soukaku': false});
      expect(group.targets.firstWhere((t) => t.mod.id == 'Soukaku').caution, SiblingCaution.dismissed);
      expect({for (final t in group.targets) t.mod.id: t.preview.layout.mappings.single.source}, {'Miyabi': 'Miyabi', 'Soukaku': 'Soukaku'});
      expect(group.refused.map((r) => (r.mod.id, r.reason)), [('Nicole', SiblingRefusal.alreadyCurrent)]);
      expect(group.otherFolders, ['Nicole'], reason: 'a refused member\'s folder is left out');
    });

    test('are not looked for when the request leaves them out', () async {
      final mod = await library();
      final result = await prepare(requestFor(mod, dateAdded: published), groupZip()) as PreparedFolders;

      expect(result.group.targets, isEmpty);
      expect(result.group.refused, isEmpty);
    });

    test('see the layout the user picked for the primary, so a folder both claim is refused for both', () async {
      final mod = await library(recordedLayout: false);
      final archive = groupZip(['Ellen', 'Miyabi']);
      final asked = (await prepare(requestFor(mod, previewSiblings: true, dateAdded: published), archive) as UpdateAsks).question
          as FoldersQuestion;

      Future<PreparedFolders> picking(String folder) async => await prepare(
            requestFor(mod, previewSiblings: true, dateAdded: published),
            archive,
            foldersAnswer: asked.answer([asked.choices.firstWhere((c) => c.name == folder).path]),
          ) as PreparedFolders;

      final ellen = await picking('Ellen');
      expect(ellen.group.targets.map((t) => t.mod.id), ['Miyabi']);

      expect(ellen.primary.canProceed, isTrue);
      expect(ellen.primary.refusal, isNull);

      final miyabi = await picking('Miyabi');
      expect(miyabi.group.targets, isEmpty);
      expect(miyabi.primary.refusal, SiblingRefusal.sourceCollision);
      expect(miyabi.primary.canProceed, isFalse, reason: 'the group refused the primary\'s folder');
      expect(miyabi.primary.startsAccepted, isFalse);
      expect({for (final r in miyabi.group.refused) r.mod.id: r.reason}, containsPair('Miyabi', SiblingRefusal.sourceCollision));
      expect({for (final r in miyabi.group.refused) r.mod.id: r.reason}, containsPair('Ellen', SiblingRefusal.sourceCollision));
      expect(unpacks, hasLength(1));
    });

    test('are written only into the targets the caller passes, and a refused primary or none is rejected', () async {
      final mod = await library(recordedLayout: false);
      final archive = groupZip(['Ellen', 'Miyabi']);
      final asked = (await prepare(requestFor(mod, previewSiblings: true, dateAdded: published), archive) as UpdateAsks).question
          as FoldersQuestion;
      final refusedPrimary = await prepare(
        requestFor(mod, previewSiblings: true, dateAdded: published),
        archive,
        foldersAnswer: asked.answer([asked.choices.firstWhere((c) => c.name == 'Miyabi').path]),
      ) as PreparedFolders;
      var done = 0;

      await expectLater(
        writeUpdate(container, refusedPrimary, targets: const [], onWritesDone: () => done++),
        throwsArgumentError,
        reason: 'nothing is chosen for the caller',
      );
      await expectLater(
        writeUpdate(container, refusedPrimary, targets: [refusedPrimary.primary], onWritesDone: () => done++),
        throwsArgumentError,
        reason: 'a folder the group refused is not written',
      );

      expect(done, 0);
      expect(temp.read('Ellen', 'Body.dds'), 'v1');
      expect(temp.snapshotsOf('Ellen'), isEmpty);
    });

    group('written together', () {
      late List<String> events;

      setUp(() => events = []);

      Future<UpdateReport> write(UpdatePrepared prepared, List<UpdateTarget> targets) => writeUpdate(
            container,
            prepared,
            targets: targets,
            onFolder: (mod, index, total) => events.add('folder ${mod.id} $index/$total'),
            onStep: (mod, step) => events.add('${mod.id} ${step.name}'),
            onWritesDone: () => events.add('done'),
          );

      const mark = UpdateCheck(outcome: UpdateOutcome.updateAvailable);

      test('folder by folder in the order given, each with its own snapshot, record and marks', () async {
        final preparedUpdate = await prepared(await library());
        UpdateTarget target(String id) => id == 'Ellen' ? preparedUpdate.primary : preparedUpdate.group.targets.firstWhere((t) => t.mod.id == id);
        container.read(modUpdateChecksProvider.notifier).state = {for (final name in names) name: mark};
        expect(await container.read(modBackupsProvider.future), isEmpty, reason: 'cached before the write');

        final report = await write(preparedUpdate, [target('Miyabi'), target('Ellen'), target('Soukaku')]);

        expect(events, [
          'folder Miyabi 1/3', 'Miyabi savingSnapshot', 'Miyabi replacingFiles',
          'folder Ellen 2/3', 'Ellen savingSnapshot', 'Ellen replacingFiles',
          'folder Soukaku 3/3', 'Soukaku savingSnapshot', 'Soukaku replacingFiles',
          'done',
        ]);
        expect(report.applied.map((a) => a.mod.id), ['Miyabi', 'Ellen', 'Soukaku']);
        expect(report.applied.every((a) => a.result.success), isTrue);
        expect(report.outcome.soleFailure, isNull);
        for (final name in ['Miyabi', 'Ellen', 'Soukaku']) {
          expect(temp.read(name, 'Body.dds'), 'v2', reason: name);
          expect(temp.snapshotsOf(name), hasLength(1), reason: name);
          expect(temp.originOf(name)?.fileId, 2, reason: name);
        }
        expect(temp.read('Nicole', 'Body.dds'), 'v1', reason: 'not in the targets');
        expect(service.keysDropped, ['Miyabi', 'Ellen', 'Soukaku']);
        expect(container.read(modUpdateChecksProvider).keys, ['Nicole']);
        expect(report.removedMarks.keys, unorderedEquals(['Miyabi', 'Ellen', 'Soukaku']));
        expect(await container.read(modBackupsProvider.future), {for (final name in ['Miyabi', 'Ellen', 'Soukaku']) temp.uidOf(name)!},
            reason: 'the rollback list is read again after the writes');
      });

      test('one folder failing after its files moved leaves the others written and keeps only its own mark', () async {
        final preparedUpdate = await prepared(await library());
        final miyabi = preparedUpdate.group.targets.firstWhere((t) => t.mod.id == 'Miyabi');
        container.read(modUpdateChecksProvider.notifier).state = {for (final name in names) name: mark};
        // Miyabi's folder of the archive is gone by the time its copy reaches for it, which fails after the wipe.
        Directory(miyabi.preview.sources.values.single).deleteSync(recursive: true);

        final report = await write(preparedUpdate, [preparedUpdate.primary, miyabi, preparedUpdate.group.targets.firstWhere((t) => t.mod.id == 'Soukaku')]);

        expect(report.applied.map((a) => (a.mod.id, a.result.failure)), [
          ('Ellen', null),
          ('Miyabi', UpdateApplyFailure.copy),
          ('Soukaku', null),
        ]);
        expect(report.outcome.changed, isTrue);
        expect(report.outcome.soleFailure, isNull, reason: 'the failure is one of several attempts');
        expect(outcomeOfGroupWrite(report.applied), UpdateFlowOutcome.written);
        expect(temp.read('Ellen', 'Body.dds'), 'v2');
        expect(temp.read('Soukaku', 'Body.dds'), 'v2', reason: 'the write went on after the failure');
        expect(temp.has('Miyabi', 'Body.dds'), isFalse, reason: 'its folder had been cleared');
        expect(temp.snapshotsOf('Miyabi'), hasLength(1));
        expect(temp.originOf('Miyabi')?.fileId, 1, reason: 'a failed write records nothing');
        expect(service.keysDropped, ['Ellen', 'Miyabi', 'Soukaku']);
        expect(container.read(modUpdateChecksProvider).keys, unorderedEquals(['Miyabi', 'Nicole']));
        expect(await container.read(modBackupsProvider.future), contains(temp.uidOf('Miyabi')));
      });
    });
  });
}

/// A service whose reading of which mods are on can be made to throw, as a library on a drive that went away does.
class _FailingActivity extends RecordingService {
  _FailingActivity(super.temp);

  bool failIsActive = false;

  @override
  Future<bool> isModActive(String modName) async {
    if (failIsActive) throw StateError('the links cannot be read');
    return super.isModActive(modName);
  }
}
