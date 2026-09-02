import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// **An update removes what the last version wrote and the new one does not.**
///
/// Real directories, because the claim is about files on disk: an overwrite only
/// ever adds and replaces, so before this the leftovers stayed and went on being
/// loaded — a renamed `.ini` doubling the mod's hotkeys, a dropped shader still
/// applied. What makes removing them safe is that each download records the
/// files it laid down, so nothing here is inferred from the folder.
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

  List<InstalledFile> recordOf(List<String> paths) => [
        for (final path in paths)
          InstalledFile(path: path, role: InstalledFileRole.replaced),
      ];

  /// Preview against the folder's record, then write.
  Future<UpdateApplyResult> run(
    String modName,
    Directory folder,
    Directory source, {
    List<String> recorded = const <String>[],
    List<String> patchFiles = const <String>[],
    bool deleteStale = true,
  }) async {
    final preview = await applier.preview(
      modFolder: folder,
      incomingFolders: [source.path],
      excluding: patchFiles,
      recorded: recordOf(recorded),
    );
    return applier.applyBaseThenPatch(
      modName: modName,
      modFolder: folder,
      preview: preview,
      patchFiles: patchFiles,
      deleteStaleInis: deleteStale,
    );
  }

  test('a file the new version no longer ships is removed', () async {
    // The case nothing else in this app can detect: `ShaderFixes/glow.hlsl` is
    // referenced by no `.ini` in the folder, so the stale-`.ini` rule is blind
    // to it and it stays applied in the game forever.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');
    write(mod, 'ShaderFixes/glow.hlsl', 'old shader');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source,
        recorded: ['ellen.ini', 'Body.dds', 'ShaderFixes/glow.hlsl']);

    expect(result.success, isTrue);
    expect(read(mod, 'Body.dds'), 'v2', reason: 'the ordinary overwrite');
    expect(has(mod, 'ShaderFixes/glow.hlsl'), isFalse);
    expect(result.droppedFiles, ['ShaderFixes/glow.hlsl']);
  });

  test('the directory it was the last file in goes with it', () async {
    // The visible half. A mod folder holding an empty `ShaderFixes/` looks like
    // it still ships shaders, and nobody can tell by looking.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'ShaderFixes/glow.hlsl', 'old shader');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    await run('Ellen', mod, source,
        recorded: ['ellen.ini', 'ShaderFixes/glow.hlsl']);

    expect(Directory(p.join(mod.path, 'ShaderFixes')).existsSync(), isFalse);
  });

  test('a directory still holding something is left alone', () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Textures/Body.dds'));
    write(mod, 'Textures/Body.dds', 'v1');
    write(mod, 'Textures/mine.dds', 'i put this here');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    await run('Ellen', mod, source,
        recorded: ['ellen.ini', 'Textures/Body.dds']);

    expect(read(mod, 'Textures/mine.dds'), 'i put this here');
    expect(Directory(p.join(mod.path, 'Textures')).existsSync(), isTrue);
  });

  test('a file nothing recorded writing is never touched', () async {
    // A second mod merged in by hand. The record is the licence to delete, and
    // there is none for this file.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'somebody_elses.ini', modIni('Theirs.dds'));
    write(mod, 'Theirs.dds', 'a whole other mod');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result =
        await run('Ellen', mod, source, recorded: ['ellen.ini', 'Body.dds']);

    expect(read(mod, 'Theirs.dds'), 'a whole other mod');
    expect(read(mod, 'somebody_elses.ini'), isNotNull);
    expect(result.droppedFiles, isEmpty);
  });

  test('a mod with no record still only overwrites', () async {
    // Every mod installed before the record existed. It has to keep behaving
    // exactly as it did.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Extra.dds', 'from v1');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source);

    expect(result.droppedFiles, isEmpty);
    expect(read(mod, 'Extra.dds'), 'from v1');
  });

  test('the patch in the folder keeps the file the base gave up', () async {
    // The base recorded `Body.dds` and the new version drops it — but a patch
    // has since written its own over that path, so the file there now is the
    // patch's. Deleting it is the destruction overwrite exists to avoid.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'the patch');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Textures/Body.dds'));
    write(source, 'Textures/Body.dds', 'v2 base');

    final result = await run(
      'Ellen',
      mod,
      source,
      recorded: ['ellen.ini', 'Body.dds'],
      patchFiles: ['Body.dds'],
    );

    expect(result.success, isTrue);
    expect(read(mod, 'Textures/Body.dds'), 'the patch',
        reason: 'placed onto the new layout, not deleted as the base\'s own');
    expect(result.droppedFiles, isEmpty);
  });

  test('a renamed .ini is removed without being asked about', () async {
    // The record settles what the stale-`.ini` rule could only infer, so the
    // question is not put to the user — and declining it no longer keeps a file
    // the record says is gone. The old prompt is what is left for the folders
    // that have no record.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'ellen_v2.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
      recorded: recordOf(['ellen.ini', 'Body.dds']),
    );

    expect(preview.dropped.remove, ['ellen.ini']);
    expect(preview.staleInis.stale, isEmpty,
        reason: 'asking about a file that is going either way is not a choice');

    final result = await applier.apply(
      modName: 'Ellen',
      modFolder: mod,
      preview: preview,
      deleteStaleInis: false,
    );

    expect(result.success, isTrue);
    expect(has(mod, 'ellen.ini'), isFalse);
    expect(has(mod, 'ellen_v2.ini'), isTrue);
  });

  test('a second mod\'s .ini is still only ever offered, never removed',
      () async {
    // The same folder, without a record for the other download. It reaches the
    // inference, which refuses it — and this is the case that makes the
    // inference worth keeping.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'theirs.ini', modIni('Theirs.dds'));
    write(mod, 'Theirs.dds', 'a whole other mod');

    final source = incoming('Ellen v2');
    write(source, 'ellen_v2.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final preview = await applier.preview(
      modFolder: mod,
      incomingFolders: [source.path],
      recorded: recordOf(['ellen.ini', 'Body.dds']),
    );

    expect(preview.dropped.remove, ['ellen.ini']);
    expect(preview.staleInis.keptUndecidable, ['theirs.ini']);
  });

  test('a texture the new .ini still names but the archive omits stays',
      () async {
    // The author replaced only the `.ini` and shipped none of the assets it
    // points at — common enough that the stale-`.ini` rule is built around it.
    // Deleting `Body.dds` here would break the mod on the update.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'Body.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    final result =
        await run('Ellen', mod, source, recorded: ['ellen.ini', 'Body.dds']);

    expect(read(mod, 'Body.dds'), 'v1');
    expect(result.droppedFiles, isEmpty);
  });

  test('a recorded file the user deleted first is not reported as removed',
      () async {
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source,
        recorded: ['ellen.ini', 'Deleted_By_Hand.dds']);

    expect(result.droppedFiles, isEmpty,
        reason: 'a summary naming a file nothing touched is a small lie');
  });

  test('the real spelling is what gets deleted', () async {
    // A lower-cased path deletes nothing on Linux, silently, and reports a file
    // the user does not have — the same mistake the stale-`.ini` removal made.
    final mod = modFolder('Ellen');
    write(mod, 'Ellen.ini', modIni('Body.dds'));
    write(mod, 'Textures/BodyA.dds', 'v1');

    final source = incoming('Ellen v2');
    write(source, 'Ellen.ini', modIni('Body.dds'));
    write(source, 'Body.dds', 'v2');

    final result = await run('Ellen', mod, source,
        recorded: ['Ellen.ini', 'Textures/BodyA.dds']);

    expect(has(mod, 'Textures/BodyA.dds'), isFalse);
    expect(result.droppedFiles, ['Textures/BodyA.dds']);
  });

  test('the snapshot still holds what was removed', () async {
    // The removal is a write like any other, so it is covered by the same
    // promise: the copy taken first is the way back.
    final mod = modFolder('Ellen');
    write(mod, 'ellen.ini', modIni('Body.dds'));
    write(mod, 'ShaderFixes/glow.hlsl', 'old shader');

    final source = incoming('Ellen v2');
    write(source, 'ellen.ini', modIni('Body.dds'));

    final result = await run('Ellen', mod, source,
        recorded: ['ellen.ini', 'ShaderFixes/glow.hlsl']);

    final saved = Directory(p.join(result.snapshot!.directory.path, 'files'));
    expect(read(saved, 'ShaderFixes/glow.hlsl'), 'old shader');
  });
}
