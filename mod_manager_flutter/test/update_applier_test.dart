import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/mod_uid.dart';
import 'package:mod_manager_flutter/services/patch_placement.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// Real directories, not mocks. The whole point of the overwrite mechanism is
/// what it does to files on disk, and a fake filesystem would be asserting the
/// fake's semantics rather than `File.copy`'s.
void main() {
  late Directory tmp;
  late Directory mods;
  late Directory extracts;
  late SnapshotService snapshots;
  late _FakeActivation activation;
  late UpdateApplier applier;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_update_apply_test_');
    mods = Directory(p.join(tmp.path, 'mods'))..createSync(recursive: true);
    extracts = Directory(p.join(tmp.path, 'extract'))
      ..createSync(recursive: true);
    snapshots = SnapshotService(rootPath: p.join(tmp.path, 'backups'));
    activation = _FakeActivation();
    applier = UpdateApplier(snapshots: snapshots, activation: activation);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(Directory root, String relative, String contents) {
    final file = File(p.join(root.path, relative.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(Directory root, String relative) {
    final file = File(p.join(root.path, relative.replaceAll('/', p.separator)));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Directory modFolder(String name) =>
      Directory(p.join(mods.path, name))..createSync(recursive: true);

  Directory incoming(String name) =>
      Directory(p.join(extracts.path, name))..createSync(recursive: true);

  Future<UpdateApplyResult> run(
    String modName,
    Directory folder,
    List<Directory> sources, {
    ModIngest? ingest,
    bool deleteStale = true,
  }) async {
    final preview = await applier.preview(
      modFolder: folder,
      incomingFolders: sources.map((d) => d.path).toList(),
      ingest: ingest,
    );
    return applier.apply(
      modName: modName,
      modFolder: folder,
      preview: preview,
      deleteStaleInis: deleteStale,
    );
  }

  test('an update overwrites colliding files and leaves the rest alone', () async {
    // The whole reason overwrite was chosen over replace: `hand_merged.dds` is
    // a second download living in the folder, and replacing would destroy it.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    write(mod, 'hand_merged.dds', 'somebody else');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, [source]);

    expect(result.success, isTrue);
    expect(read(mod, 'Body.dds'), 'v2');
    expect(read(mod, 'hand_merged.dds'), 'somebody else');
  });

  test('the folder keeps its own name even when the archive renamed its own',
      () async {
    final mod = modFolder('My Ellen Skin');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen v2 FINAL');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    expect((await run('My Ellen Skin', mod, [source])).success, isTrue);
    expect(Directory(p.join(mods.path, 'My Ellen Skin')).existsSync(), isTrue);
    expect(Directory(p.join(mods.path, 'Ellen v2 FINAL')).existsSync(), isFalse);
  });

  test("the archive's own sidecar never overwrites the user's", () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    write(
      mod,
      '${AppConstants.modMetadataDirName}/metadata.json',
      '{"description":"mine"}',
    );

    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');
    write(
      source,
      '${AppConstants.modMetadataDirName}/metadata.json',
      '{"description":"a stranger"}',
    );

    expect((await run('Ellen', mod, [source])).success, isTrue);
    final sidecar =
        read(mod, '${AppConstants.modMetadataDirName}/metadata.json')!;
    expect(sidecar, contains('mine'));
    expect(sidecar, isNot(contains('a stranger')),
        reason: "the archive's copy must not reach the folder");
    // Not asserted as an exact string: the update gives the folder its identity
    // on the way past, so the sidecar it leaves is the user's plus a uid.
    expect(sidecar, contains('"uid"'));
  });

  test('a renamed upstream .ini is offered up and removed', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen');
    write(source, 'ellen_v2.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
    );
    expect(preview.staleInis.stale.map((s) => s.path), ['ellen.ini']);

    final result = await applier.apply(
      modName: 'Ellen',
      modFolder: mod,
      preview: preview,
      deleteStaleInis: true,
    );
    expect(result.removedInis, ['ellen.ini']);
    expect(read(mod, 'ellen.ini'), isNull);
    expect(read(mod, 'ellen_v2.ini'), isNotNull);
  });

  test('a stale .ini is deleted under its real, mixed-case name', () async {
    // The regression this whole `actualPaths` mechanism exists for. Every other
    // test here writes a lower-case `ellen.ini`, which is the one spelling that
    // happened to work — mod authors ship `Ellen.ini`, `Miyabi.ini`,
    // `MasterNico.ini`. Comparison is normalised (3DMigoto is
    // case-insensitive), so the path reaching `File` was lower-cased, `exists()`
    // answered false on Linux, nothing was deleted and nothing was reported:
    // the user consented, saw no error, and kept the two live `.ini` files the
    // rule exists to prevent.
    final mod = modFolder('Ellen');
    write(mod, 'Ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen');
    write(source, 'Ellen_v2.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, [source]);

    expect(result.removedInis, ['Ellen.ini'],
        reason: 'reported under the name the user actually has');
    expect(read(mod, 'Ellen.ini'), isNull);
    expect(read(mod, 'Ellen_v2.ini'), isNotNull);
  });

  test('the preview names leftovers as they are spelled on disk', () async {
    final mod = modFolder('Ellen');
    write(mod, 'Ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    final source = incoming('Ellen');
    write(source, 'Ellen_v2.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
    );
    // Normalised for comparing, real for showing — the confirmation quotes the
    // second, or it names a file the user does not have.
    expect(preview.staleInis.stale.single.path, 'ellen.ini');
    expect(preview.onDisk('ellen.ini'), 'Ellen.ini');
  });

  test('declining the prompt keeps the leftover .ini', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen');
    write(source, 'ellen_v2.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, [source], deleteStale: false);
    expect(result.removedInis, isEmpty);
    expect(read(mod, 'ellen.ini'), isNotNull);
  });

  test('an incoming patch is reported before anything is written', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen fix');
    write(source, 'ellen.ini', 'filename = Body.dds\nfilename = Hair.dds');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
    );
    expect(preview.incomingIsPatch, isTrue);
    expect(preview.patch.missing, ['body.dds', 'hair.dds']);
  });

  test('the mod is deactivated for the copy and put back afterwards', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    activation.active.add('Ellen');

    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, [source]);
    expect(result.reactivated, isTrue);
    expect(activation.log, ['deactivate:Ellen', 'activate:Ellen']);
    expect(activation.active, contains('Ellen'));
  });

  test('an inactive mod is never activated as a side effect', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');

    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');

    expect((await run('Ellen', mod, [source])).reactivated, isFalse);
    expect(activation.log, isEmpty);
  });

  test('a snapshot is taken before the write and holds the old files', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, [source]);
    final snapshot = result.snapshot!;
    expect(
      read(Directory(p.join(snapshot.directory.path, 'files')), 'Body.dds'),
      'v1',
    );
    expect(snapshot.reason, SnapshotReason.beforeUpdate);
    // Found by the folder's identity, which the update assigned on its way
    // past — not by its name, which is what a rename would take away.
    expect((await snapshots.list(snapshot.modUid)).length, 1);
    expect(snapshot.modName, 'Ellen', reason: 'what it was called at the time');
  });

  test('a snapshot survives the rename the app never sees', () async {
    // **The reason the store is keyed by uid at all.** Renaming a folder in a
    // file manager runs no hook, so a group named after the folder would be
    // stranded here — unreachable from "Restore a previous version…" *and*
    // exempt from pruning, because retention protects each group's newest
    // entry forever.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');

    final taken = (await run('Ellen', mod, [source])).snapshot!;

    // No rename call, no migration, nothing told: the folder simply moves.
    final renamed = Directory(p.join(mods.path, 'Ellen but better'));
    mod.renameSync(renamed.path);

    final uid = await ModUid().read(renamed);
    expect(uid, taken.modUid, reason: 'the identity travelled with the folder');
    expect((await snapshots.list(uid)).length, 1);
    expect(
      read(Directory(p.join(taken.directory.path, 'files')), 'Body.dds'),
      'v1',
      reason: 'and the way back is still the old files',
    );
  });

  test('a rename does not split one mod into two histories', () async {
    // The pruning half of the same property. Two name-groups each keep a
    // newest entry forever, so a mod renamed between updates would quietly
    // become exempt from the budget twice over.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');
    final first = (await run('Ellen', mod, [source])).snapshot!;

    final renamed = Directory(p.join(mods.path, 'Ellen but better'));
    mod.renameSync(renamed.path);
    final second = (await run('Ellen but better', renamed, [source])).snapshot!;

    expect(second.modUid, first.modUid);
    expect((await snapshots.listAll()).length, 2);
    expect((await snapshots.uidsWithSnapshots()), {first.modUid},
        reason: 'one mod, one group, whatever it has been called');
  });

  test('nothing is written when the snapshot cannot be taken', () async {
    // No snapshot, no write: there is no other way back from an overwrite, so
    // proceeding trades a recoverable failure for an unrecoverable one.
    final mod = modFolder('Ellen');
    write(mod, 'Body.dds', 'v1');
    final source = incoming('Ellen');
    write(source, 'Body.dds', 'v2');

    final blocked = UpdateApplier(
      snapshots: _RefusingSnapshots(rootPath: p.join(tmp.path, 'nope')),
      activation: activation,
    );
    final preview = await blocked.preview(
      modFolder: mod,
      incomingFolders: [source.path],
    );
    final result = await blocked.apply(
      modName: 'Ellen',
      modFolder: mod,
      preview: preview,
      deleteStaleInis: true,
    );

    expect(result.success, isFalse);
    expect(result.failure, UpdateApplyFailure.snapshot);
    expect(read(mod, 'Body.dds'), 'v1');
  });

  test('a copy that fails part-way still hands back its snapshot', () async {
    // The precondition the whole "restore the saved copy" recovery rests on,
    // and the one the UI reads to decide whether to refresh the rollback menu.
    // A half-copied folder with no reachable snapshot is the single worst state
    // this feature can produce.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'filename = Body.dds');
    write(mod, 'Body.dds', 'v1');
    final source = incoming('Ellen');
    write(source, 'ellen.ini', 'filename = Body.dds');
    write(source, 'Body.dds', 'v2');
    // A file the mod folder does not already have: overwriting an existing file
    // needs no *directory* write, so without this the copy succeeds against a
    // read-only folder and the test asserts nothing.
    write(source, 'Added.dds', 'v2');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
    );
    // **The identity first**, because assigning one is itself a write into this
    // folder: without it the read-only folder below fails at the snapshot step
    // instead, which is a different (and correct) refusal than the one under
    // test. A folder that has ever been snapshotted is already in this state.
    expect(await applier.uids.ensure(mod), isNotNull);
    // Read-only, so creating that new file throws. Skipped when the process can
    // write anyway (running as root), rather than asserting something untrue.
    await Process.run('chmod', ['500', mod.path]);
    addTearDown(() => Process.run('chmod', ['700', mod.path]));
    final writable = File(p.join(mod.path, 'probe'));
    try {
      writable.writeAsStringSync('x');
      writable.deleteSync();
      return; // permissions not enforced here — nothing to assert
    } catch (_) {
      // Good: the copy will fail.
    }

    final result = await applier.apply(
      modName: 'Ellen',
      modFolder: mod,
      preview: preview,
      deleteStaleInis: true,
    );

    expect(result.success, isFalse);
    expect(result.failure, UpdateApplyFailure.copy);
    expect(result.snapshot, isNotNull,
        reason: 'the failure message sends the user straight to this');
    expect(
      read(Directory(p.join(result.snapshot!.directory.path, 'files')),
          'Body.dds'),
      'v1',
    );
  });

  test('a combined install writes each folder back into its subfolder', () async {
    final mod = modFolder('Ellen Pack');
    write(mod, 'Skin/skin.ini', 'filename = Body.dds');
    write(mod, 'Skin/Body.dds', 'v1');
    write(mod, 'Dep/dep.dds', 'v1');

    final skin = incoming('Skin');
    write(skin, 'skin.ini', 'filename = Body.dds');
    write(skin, 'Body.dds', 'v2');
    final dep = incoming('Dep');
    write(dep, 'dep.dds', 'v2');

    final result = await run(
      'Ellen Pack',
      mod,
      [skin, dep],
      ingest: const ModIngest(
        mode: IngestMode.combined,
        folders: ['Skin', 'Dep'],
      ),
    );

    expect(result.success, isTrue);
    expect(read(mod, 'Skin/Body.dds'), 'v2');
    expect(read(mod, 'Dep/dep.dds'), 'v2');
  });

  test('an unreplayable layout refuses rather than guessing', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', 'x = 1');
    final a = incoming('Ellen');
    write(a, 'ellen.ini', 'x = 2');
    final b = incoming('previews');
    write(b, 'shot.png', 'x');

    final preview =
        await applier.preview(modFolder: mod, incomingFolders: [a.path, b.path]);
    expect(preview.canProceed, isFalse);

    final result = await applier.apply(
      modName: 'Ellen',
      modFolder: mod,
      preview: preview,
      deleteStaleInis: true,
    );
    expect(result.failure, UpdateApplyFailure.layout);
    expect(read(mod, 'ellen.ini'), 'x = 1');
  });

  test('a hotkey the new version moved is reported as before → after',
      () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', '[KeySkin]\nkey = F7\ntype = cycle');
    final source = incoming('Ellen');
    write(source, 'ellen.ini', '[KeySkin]\nkey = F9\ntype = cycle');

    final result = await run('Ellen', mod, [source]);
    final change = result.keybindChanges.single;
    expect(change.displayName, 'Skin');
    expect(change.before, 'F7');
    expect(change.after, 'F9');
  });

  test('a hotkey the new version left alone is not reported at all', () async {
    // The reason this is a diff and not an inventory: a list that appears after
    // every update, changed or not, is a list people learn to skip.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', '[KeySkin]\nkey = F7\ntype = cycle');
    final source = incoming('Ellen');
    write(source, 'ellen.ini', '[KeySkin]\nkey = F7\ntype = cycle\nx = 1');

    final result = await run('Ellen', mod, [source]);
    expect(result.keybindChanges, isEmpty);
  });

  group('rollback', () {
    test('puts the old files back and snapshots the current state first',
        () async {
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', 'filename = Body.dds');
      write(mod, 'Body.dds', 'v1');

      final source = incoming('Ellen');
      write(source, 'ellen.ini', 'filename = Body.dds');
      write(source, 'Body.dds', 'v2');
      final applied = await run('Ellen', mod, [source]);
      expect(read(mod, 'Body.dds'), 'v2');

      final restored = await applier.restore(
        modName: 'Ellen',
        modFolder: mod,
        snapshot: applied.snapshot!,
      );

      expect(restored.success, isTrue);
      expect(read(mod, 'Body.dds'), 'v1');
      expect(restored.snapshot!.reason, SnapshotReason.beforeRestore);
      // Both in one group, because both are of the same mod — the rollback did
      // not restore an older sidecar over the folder's identity and start a
      // second history under a new one.
      expect(restored.snapshot!.modUid, applied.snapshot!.modUid);
      expect((await snapshots.list(applied.snapshot!.modUid)).length, 2);
    });

    test('the folder keeps its identity through a rollback', () async {
      // **The way this feature could eat itself.** A snapshot is a complete
      // copy of the folder, sidecar included, and a restore overwrites with the
      // same semantics — so a sidecar restored over the live one takes the
      // folder's identity with it. Every snapshot in this store was taken after
      // its folder had a uid, which is what makes the restored one carry the
      // same identity rather than none.
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', 'filename = Body.dds');
      write(mod, 'Body.dds', 'v1');

      final source = incoming('Ellen');
      write(source, 'ellen.ini', 'filename = Body.dds');
      write(source, 'Body.dds', 'v2');
      final applied = await run('Ellen', mod, [source]);
      final uid = await ModUid().read(mod);
      expect(uid, applied.snapshot!.modUid);

      await applier.restore(
        modName: 'Ellen',
        modFolder: mod,
        snapshot: applied.snapshot!,
      );

      expect(await ModUid().read(mod), uid,
          reason: 'a rollback that dropped this would strand every saved '
              'version of the mod at the moment of recovery');
      expect((await snapshots.list(uid)).length, 2);
    });

    test('removes the .ini the newer version added, in reverse', () async {
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', 'filename = Body.dds');
      write(mod, 'Body.dds', 'v1');

      final source = incoming('Ellen');
      write(source, 'ellen_v2.ini', 'filename = Body.dds');
      write(source, 'Body.dds', 'v2');
      final applied = await run('Ellen', mod, [source]);
      expect(read(mod, 'ellen.ini'), isNull);

      await applier.restore(
        modName: 'Ellen',
        modFolder: mod,
        snapshot: applied.snapshot!,
      );
      expect(read(mod, 'ellen.ini'), isNotNull);
      expect(read(mod, 'ellen_v2.ini'), isNull);
    });
  });

  group('retention', () {
    test('prune leaves the newest and removes what the policy names', () async {
      final mod = modFolder('Ellen');
      write(mod, 'Body.dds', 'v1');
      for (var i = 0; i < 5; i++) {
        await snapshots.capture(
          modName: 'Ellen',
          modUid: 'ellen-uid',
          modFolder: mod,
          reason: SnapshotReason.beforeUpdate,
          now: DateTime.now().subtract(Duration(days: 200 - i)),
        );
      }
      expect((await snapshots.list('ellen-uid')).length, 5);

      final plan = await snapshots.prune();
      expect(plan.prune.length, 2);
      expect((await snapshots.list('ellen-uid')).length, 3);
    });

    test('a snapshot survives a missing manifest', () async {
      final mod = modFolder('Ellen');
      write(mod, 'Body.dds', 'v1');
      final taken = await snapshots.capture(
        modName: 'Ellen',
        modUid: 'ellen-uid',
        modFolder: mod,
        reason: SnapshotReason.beforeUpdate,
      );
      File(p.join(taken!.directory.path, 'manifest.json')).deleteSync();

      final listed = await snapshots.list('ellen-uid');
      expect(listed.length, 1);
      expect(listed.single.sizeBytes, greaterThan(0));
      expect(listed.single.modUid, 'ellen-uid',
          reason: 'the group it is in answers for which mod it is, so a '
              'manifest that cannot be read costs a display name and not the '
              'snapshot');
      expect(listed.single.modName, isEmpty);
    });
  });

  /// A **patch** written into a mod folder that already works.
  ///
  /// The same operation as an update and the same order, because it carries the
  /// same risk. What differs is only the copy: individual files, each where the
  /// target already keeps that name.
  group('applyPatchInto', () {
    /// Resolves and applies in one go, the way the install flow does.
    Future<UpdateApplyResult> applyPatch(
      String modName,
      Directory folder,
      Directory source,
    ) async {
      final incomingContents = await readFolderContents(source);
      final existing = await readFolderContents(folder);
      return applier.applyPatchInto(
        modName: modName,
        modFolder: folder,
        source: source,
        incoming: incomingContents,
        existing: existing,
        placement: resolvePatchPlacement(
          incoming: incomingContents.files,
          target: existing.files,
        ),
      );
    }

    test('a bare file replaces the one the target keeps in a subfolder',
        () async {
      // The failure this exists to prevent is silent: written at the root, the
      // file lands beside the mod, every reference still resolves to the
      // original, and nothing changes in the game with no error anywhere.
      final folder = modFolder('Ellen');
      write(folder, 'ellen.ini', '[TextureOverride]\nfilename = tex/body.dds');
      write(folder, 'tex/body.dds', 'original');

      final source = incoming('patch');
      write(source, 'body.dds', 'patched');

      final result = await applyPatch('Ellen', folder, source);

      expect(result.success, isTrue);
      expect(read(folder, 'tex/body.dds'), 'patched');
      expect(
        read(folder, 'body.dds'),
        isNull,
        reason: 'a copy at the root would be a file nothing reads',
      );
    });

    test('the wrapper is never nested inside the target', () async {
      // A rootless archive is wrapped in a folder named after the archive. Copy
      // that folder in and the patch does not apply *and* there are two live
      // `.ini` files, because a `filename` resolves beside its own `.ini`.
      final folder = modFolder('Ellen');
      write(folder, 'ellen.ini', 'x');
      write(folder, 'body.dds', 'original');

      final source = incoming('Ellen No Blur v2');
      write(source, 'body.dds', 'patched');

      await applyPatch('Ellen', folder, source);

      expect(read(folder, 'body.dds'), 'patched');
      expect(
        Directory(p.join(folder.path, 'Ellen No Blur v2')).existsSync(),
        isFalse,
      );
    });

    test('a file the target does not have is added where it sits', () async {
      final folder = modFolder('Ellen');
      write(folder, 'ellen.ini', 'x');

      final source = incoming('patch');
      write(source, 'extra/glow.dds', 'new');

      final result = await applyPatch('Ellen', folder, source);

      expect(result.success, isTrue);
      expect(read(folder, 'extra/glow.dds'), 'new');
    });

    test('nothing is written without a snapshot', () async {
      // The same trade an update refuses to make: there is no other way back
      // from an overwrite, so proceeding would turn a recoverable failure into
      // an unrecoverable one.
      final refusing = UpdateApplier(
        snapshots: _RefusingSnapshots(rootPath: p.join(tmp.path, 'backups')),
        activation: activation,
      );
      final folder = modFolder('Ellen');
      write(folder, 'body.dds', 'original');
      final source = incoming('patch');
      write(source, 'body.dds', 'patched');

      final contents = await readFolderContents(source);
      final existing = await readFolderContents(folder);
      final result = await refusing.applyPatchInto(
        modName: 'Ellen',
        modFolder: folder,
        source: source,
        incoming: contents,
        existing: existing,
        placement: resolvePatchPlacement(
          incoming: contents.files,
          target: existing.files,
        ),
      );

      expect(result.success, isFalse);
      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(read(folder, 'body.dds'), 'original');
    });

    test('the folder can be rolled back to before the patch', () async {
      // What the snapshot is *for*. A patch applied to the wrong mod is one
      // click from undone.
      final folder = modFolder('Ellen');
      write(folder, 'body.dds', 'original');
      final source = incoming('patch');
      write(source, 'body.dds', 'patched');

      final result = await applyPatch('Ellen', folder, source);
      expect(read(folder, 'body.dds'), 'patched');

      await applier.restore(
        modName: 'Ellen',
        modFolder: folder,
        snapshot: result.snapshot!,
      );
      expect(read(folder, 'body.dds'), 'original');
    });

    test('an unsettled placement writes nothing at all', () async {
      // Two variant subfolders holding the same name. Picking would be a guess
      // about which variant the user runs, invisible once written — so the
      // caller has to ask first, and passing the question through unanswered
      // must not be a way round that.
      final folder = modFolder('Ellen');
      write(folder, 'sfw/body.dds', 'sfw original');
      write(folder, 'nsfw/body.dds', 'nsfw original');
      final source = incoming('patch');
      write(source, 'body.dds', 'patched');

      final result = await applyPatch('Ellen', folder, source);

      expect(result.success, isFalse);
      expect(read(folder, 'sfw/body.dds'), 'sfw original');
      expect(read(folder, 'nsfw/body.dds'), 'nsfw original');
    });

    test('an active mod is deactivated and switched back on', () async {
      // For open file handles, never for link integrity — the same reason the
      // update path does it.
      final folder = modFolder('Ellen');
      write(folder, 'body.dds', 'original');
      final source = incoming('patch');
      write(source, 'body.dds', 'patched');
      activation.active.add('Ellen');

      final result = await applyPatch('Ellen', folder, source);

      expect(result.reactivated, isTrue);
      expect(activation.log, ['deactivate:Ellen', 'activate:Ellen']);
    });

    test('our own sidecar is never copied into the target', () async {
      // An archive can arrive carrying one. Copying it over would replace the
      // target's own description, gallery and — worse — its origin block.
      final folder = modFolder('Ellen');
      write(folder, 'body.dds', 'original');
      final source = incoming('patch');
      write(source, 'body.dds', 'patched');
      write(source, '${AppConstants.modMetadataDirName}/metadata.json',
          '{"description":"a stranger"}');

      await applyPatch('Ellen', folder, source);

      // A sidecar is there, and it is **ours**: the write gave the folder its
      // identity before snapshotting it. What must never arrive is the
      // archive's content.
      final sidecar =
          read(folder, '${AppConstants.modMetadataDirName}/metadata.json')!;
      expect(sidecar, isNot(contains('a stranger')));
      expect(sidecar, contains('"uid"'));
    });
  });
}

class _FakeActivation implements ModActivationPort {
  final Set<String> active = {};
  final List<String> log = [];

  @override
  Future<bool> isActive(String modName) async => active.contains(modName);

  @override
  Future<bool> activate(String modName) async {
    log.add('activate:$modName');
    active.add(modName);
    return true;
  }

  @override
  Future<bool> deactivate(String modName) async {
    log.add('deactivate:$modName');
    active.remove(modName);
    return true;
  }
}

/// Stands in for a full disk or a read-only app-data directory.
class _RefusingSnapshots extends SnapshotService {
  _RefusingSnapshots({required super.rootPath});

  @override
  Future<ModSnapshot?> capture({
    required String modName,
    required String modUid,
    required Directory modFolder,
    required SnapshotReason reason,
    String? version,
    String? versionLabel,
    DateTime? now,
  }) async =>
      null;
}
