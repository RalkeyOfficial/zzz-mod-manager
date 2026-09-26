import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_placement.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// **An update leaves the new version in the folder and nothing else.**
///
/// Real directories, because the claim is about files on disk: the folder is wiped before the copy,
/// so a renamed `.ini` cannot double the mod's hotkeys and a dropped shader cannot go on being applied — and nothing decides which files were whose.
/// A patch recorded on top is the one thing put back, and the sidecar the one thing the wipe leaves.
/// A patch's own update is the exception, since it sits over a base that stays: those cases are the last group.
class _FakeActivation implements ModActivationPort {
  final Set<String> active = {};

  @override
  Future<bool> isActive(String modName) async => active.contains(modName);

  @override
  Future<bool> activate(String modName) async => active.add(modName);

  @override
  Future<bool> deactivate(String modName) async => active.remove(modName);
}

void main() {
  late Directory tmp;
  late Directory mods;
  late Directory extracts;
  late UpdateApplier applier;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_update_drops_');
    mods = Directory(p.join(tmp.path, 'mods'))..createSync(recursive: true);
    extracts = Directory(p.join(tmp.path, 'extract'))
      ..createSync(recursive: true);
    applier = UpdateApplier(
      snapshots: SnapshotService(rootPath: p.join(tmp.path, 'backups')),
      activation: _FakeActivation(),
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  void write(Directory root, String relative, String contents) {
    final file = File(p.join(root.path, relative.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  bool has(Directory root, String relative) =>
      File(p.join(root.path, relative.replaceAll('/', p.separator)))
          .existsSync();

  String? read(Directory root, String relative) {
    final file = File(p.join(root.path, relative.replaceAll('/', p.separator)));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Directory modFolder(String name) =>
      Directory(p.join(mods.path, name))..createSync(recursive: true);

  Directory incoming(String name) =>
      Directory(p.join(extracts.path, name))..createSync(recursive: true);

  String modIni(String filename) =>
      '[TextureOverrideBody]\nps-t0 = R\n\n[R]\nfilename = $filename\n';

  /// Preview, then write base-then-patch.
  Future<UpdateApplyResult> run(
    String modName,
    Directory folder,
    Directory source, {
    List<String> patchFiles = const <String>[],
  }) async {
    final preview = await applier.preview(
      modFolder: folder,
      incomingFolders: [source.path],
    );
    return applier.applyBaseThenPatch(
      modName: modName,
      modFolder: folder,
      preview: preview,
      patchFiles: patchFiles,
    );
  }

  test('a file the new version no longer ships is gone', () async {
    // `ShaderFixes/glow.hlsl` is referenced by no `.ini` in the folder, and left
    // in place it would be copied into ZZMI's shader folder on the next enable.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');
    write(mod, 'ShaderFixes/glow.hlsl', 'old shader');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source);

    expect(result.success, isTrue);
    expect(read(mod, 'Body.dds'), 'v2');
    expect(has(mod, 'ShaderFixes/glow.hlsl'), isFalse);
    expect(Directory(p.join(mod.path, 'ShaderFixes')).existsSync(), isFalse,
        reason: 'an empty ShaderFixes/ would look like the mod still ships shaders');
    expect(result.droppedFiles, ['ShaderFixes/glow.hlsl']);
  });

  test('a file the app never wrote goes with the old version', () async {
    // A second mod merged in by hand. Nothing decides whether it was the old
    // version's or the user's: the folder is emptied, and the snapshot has it.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'somebody_elses.ini', modIni('Theirs.dds'));
    write(mod, 'Textures/Theirs.dds', 'a whole other mod');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source);

    expect(has(mod, 'somebody_elses.ini'), isFalse);
    expect(has(mod, 'Textures/Theirs.dds'), isFalse);
    expect(Directory(p.join(mod.path, 'Textures')).existsSync(), isFalse);
    expect(result.droppedFiles,
        unorderedEquals(['somebody_elses.ini', 'Textures/Theirs.dds']));
    final saved = Directory(p.join(result.snapshot!.directory.path, 'files'));
    expect(read(saved, 'Textures/Theirs.dds'), 'a whole other mod');
  });

  test('the sidecar is the one thing the wipe leaves', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, '.zzz-mod-manager/metadata.json', '{"description":"mine"}');
    write(mod, '.zzz-mod-manager/images/01.png', 'cover');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    final result = await run('Ellen', mod, source);

    expect(result.success, isTrue);
    expect(read(mod, '.zzz-mod-manager/metadata.json'), contains('mine'));
    expect(read(mod, '.zzz-mod-manager/images/01.png'), 'cover');
    expect(result.droppedFiles, isEmpty,
        reason: 'the sidecar is not the old version, so it is not reported as removed');
  });

  test('the patch in the folder comes back onto the new layout', () async {
    // The wipe takes the patch's `Body.dds` with everything else; the record
    // names it, so it is read back from the snapshot and placed where the new
    // base keeps that file.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'the patch');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Textures/Body.dds'));
    write(source, 'Textures/Body.dds', 'v2 base');

    final result = await run('Ellen', mod, source, patchFiles: ['Body.dds']);

    expect(result.success, isTrue);
    expect(read(mod, 'Textures/Body.dds'), 'the patch');
    expect(has(mod, 'Body.dds'), isFalse);
    expect(result.droppedFiles, isEmpty);
  });

  test('a renamed .ini is gone without being asked about', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'ellen_v2.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source);

    expect(result.success, isTrue);
    expect(has(mod, 'ellen.ini'), isFalse);
    expect(has(mod, 'ellen_v2.ini'), isTrue);
    expect(result.droppedFiles, ['ellen.ini']);
  });

  test('a texture the new .ini still names but the archive omits goes too',
      () async {
    // The author shipped the `.ini` and none of the assets it points at. The
    // folder holds what the archive holds, and nothing else; if the mod is
    // broken by that, the archive is what broke it and the snapshot is the way
    // back.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    final result = await run('Ellen', mod, source);

    expect(has(mod, 'Body.dds'), isFalse);
    expect(result.droppedFiles, ['Body.dds']);
  });

  test('what went is reported under its real spelling', () async {
    final mod = modFolder('Ellen');
    write(mod, 'Ellen.ini', modIni('Body.dds'));
    write(mod, 'Textures/BodyA.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'Ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source);

    expect(has(mod, 'Textures/BodyA.dds'), isFalse);
    expect(result.droppedFiles, ['Textures/BodyA.dds']);
  });

  group('a patch update', () {
    /// The real round trip: install the patch, then write a new version of it
    /// over the folder with the first one's record in hand.
    Future<UpdateApplyResult> applyPatch(
      String modName,
      Directory folder,
      Directory source, {
      int? patchModId,
      List<InstalledFile> recorded = const <InstalledFile>[],
    }) async {
      final incoming = await readFolderContents(source);
      final existing = await readFolderContents(folder);
      return applier.applyPatchInto(
        modName: modName,
        modFolder: folder,
        source: source,
        incoming: incoming,
        existing: existing,
        placement: resolvePatchPlacement(
          incoming: incoming.files,
          target: existing.files,
        ),
        patchModId: patchModId,
        recorded: recorded,
      );
    }

    test('the mod\'s own file comes back where the patch stops writing',
        () async {
      // The rule that differs from the base's. A file the patch wrote over is
      // the *mod's*, and the mod is still supposed to have it — so this is a
      // restore where an update to the bottom layer would be a delete.
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
      write(mod, 'Textures/Body.dds', 'the mod');
      write(mod, 'Textures/Hair.dds', 'the mod hair');

      final v1 = incoming('patch v1');
      write(v1, 'Body.dds', 'patch v1 body');
      write(v1, 'Hair.dds', 'patch v1 hair');
      final first = await applyPatch('Ellen', mod, v1, patchModId: 605460);

      expect(read(mod, 'Textures/Body.dds'), 'patch v1 body');

      // The new version only touches the hair.
      final v2 = incoming('patch v2');
      write(v2, 'Hair.dds', 'patch v2 hair');
      final second = await applyPatch('Ellen', mod, v2,
          patchModId: 605460, recorded: first.writtenFiles);

      expect(second.success, isTrue);
      expect(read(mod, 'Textures/Hair.dds'), 'patch v2 hair');
      expect(read(mod, 'Textures/Body.dds'), 'the mod',
          reason: 'not deleted, and not left as the old patch had it');
      expect(second.restoredFiles, ['Textures/Body.dds']);
      expect(second.droppedFiles, isEmpty);
    });

    test('a file the patch added and no longer ships is deleted', () async {
      // Nothing was underneath it, so there is nothing to put back.
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
      write(mod, 'Textures/Body.dds', 'the mod');

      final v1 = incoming('patch v1');
      write(v1, 'Body.dds', 'patch v1 body');
      write(v1, 'Glow.dds', 'patch v1 extra');
      final first = await applyPatch('Ellen', mod, v1, patchModId: 605460);

      final v2 = incoming('patch v2');
      write(v2, 'Body.dds', 'patch v2 body');
      final second = await applyPatch('Ellen', mod, v2,
          patchModId: 605460, recorded: first.writtenFiles);

      expect(has(mod, 'Glow.dds'), isFalse);
      expect(second.droppedFiles, ['Glow.dds']);
      expect(second.restoredFiles, isEmpty);
    });

    test('a displaced file with no original kept is left alone', () async {
      // A folder patched before the store existed, or one whose store could not
      // be written. Deleting would leave a hole where the mod's file was.
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
      write(mod, 'Textures/Body.dds', 'the mod');

      final v1 = incoming('patch v1');
      write(v1, 'Body.dds', 'patch v1 body');
      // No id, so nothing was ever stored under one.
      final first = await applyPatch('Ellen', mod, v1);

      final v2 = incoming('patch v2');
      write(v2, 'Hair.dds', 'patch v2 hair');
      final second = await applyPatch('Ellen', mod, v2,
          patchModId: 605460, recorded: first.writtenFiles);

      expect(read(mod, 'Textures/Body.dds'), 'patch v1 body',
          reason: 'the patched file stays: taking it away leaves nothing');
      expect(second.droppedFiles, isEmpty);
      expect(second.restoredFiles, isEmpty);
    });

    test('a file it adds keeps the name its author gave it', () async {
      // What the removal above works from. The folder has no spelling to offer
      // for a path it does not hold, and the normalised key is lower-cased — so
      // the record has to fall back to the archive's own name, or every later
      // removal is aimed at a file nobody has.
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
      write(mod, 'Textures/Body.dds', 'the mod');

      final patch = incoming('patch v1');
      write(patch, 'Glow.dds', 'patch extra');
      final result = await applyPatch('Ellen', mod, patch, patchModId: 605460);

      expect(has(mod, 'Glow.dds'), isTrue);
      expect([for (final file in result.writtenFiles) file.path], ['Glow.dds']);
    });

    test('a first install has no record and removes nothing', () async {
      final mod = modFolder('Ellen');
      write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
      write(mod, 'Textures/Body.dds', 'the mod');

      final patch = incoming('patch v1');
      write(patch, 'Body.dds', 'patch body');
      final result = await applyPatch('Ellen', mod, patch, patchModId: 605460);

      expect(result.droppedFiles, isEmpty);
      expect(result.restoredFiles, isEmpty);
      expect(read(mod, 'Textures/Body.dds'), 'patch body');
    });
  });

  test('the snapshot still holds what was removed', () async {
    // The wipe is a write like any other, so it is covered by the same
    // promise: the copy taken first is the way back.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'ShaderFixes/glow.hlsl', 'old shader');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    final result = await run('Ellen', mod, source);

    final saved = Directory(p.join(result.snapshot!.directory.path, 'files'));
    expect(read(saved, 'ShaderFixes/glow.hlsl'), 'old shader');
  });
}
