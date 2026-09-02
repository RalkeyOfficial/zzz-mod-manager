import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

/// **Base first, then patch** — writing a mod that is two downloads, in order.
///
/// The rule is one sentence: the base defines where files live, and the patch is
/// placed over it. Everything here is about the half of that which fails
/// *silently* if it is skipped:
///
/// ```
///   folder holds the patch:  Body.dds                  (patch author's layout)
///   base archive ships:      ellen.ini, Textures/Body.dds
///
///   base written, patch left where it was:
///       Body.dds           ← the patch, referenced by nothing
///       Textures/Body.dds  ← the base, and this is what ellen.ini loads
/// ```
///
/// Nothing is missing, nothing errors, the folder looks complete, and the patch
/// does nothing. So the patch's files have to move onto the base's layout after
/// the base lands — and that is what this operation is for.
///
/// The **snapshot is the aside**: it holds a full copy of the folder taken before
/// anything is written, so the patch's files are read back from there rather than
/// copied to a second temporary place.
class _FakeActivation implements ModActivationPort {
  final Set<String> active = {};
  final List<String> log = [];

  @override
  Future<bool> isActive(String modName) async => active.contains(modName);

  @override
  Future<bool> activate(String modName) async {
    log.add('activate:$modName');
    return active.add(modName);
  }

  @override
  Future<bool> deactivate(String modName) async {
    log.add('deactivate:$modName');
    return active.remove(modName);
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

void main() {
  late Directory tmp;
  late Directory mods;
  late Directory extracts;
  late SnapshotService snapshots;
  late _FakeActivation activation;
  late UpdateApplier applier;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zzz_base_then_patch_');
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

  String modIni(String filename) =>
      '[TextureOverrideBody]\nps-t0 = R\n\n[R]\nfilename = $filename\n';

  /// The whole operation: preview the base against the folder with the patch's
  /// files discounted, then write base-then-patch.
  Future<UpdateApplyResult> run(
    String modName,
    Directory folder,
    List<Directory> baseSources, {
    required List<String> patchFiles,
    ModIngest? ingest,
    bool deleteStale = true,
  }) async {
    final preview = await applier.preview(
      modFolder: folder,
      incomingFolders: baseSources.map((d) => d.path).toList(),
      ingest: ingest,
      excluding: patchFiles,
    );
    return applier.applyBaseThenPatch(
      modName: modName,
      modFolder: folder,
      preview: preview,
      patchFiles: patchFiles,
      deleteStaleInis: deleteStale,
    );
  }

  group('the ordering', () {
    test('the patch ends up where the base keeps that file', () async {
      // The worked example above, and the reason this operation exists.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result = await run('Ellen Fix', mod, [base],
          patchFiles: ['Body.dds']);

      expect(result.success, isTrue);
      expect(read(mod, 'Textures/Body.dds'), 'patched',
          reason: 'the patch wins the collision — that is what a patch is');
      expect(read(mod, 'Body.dds'), isNull,
          reason: 'and it does not also stay at its own path, where nothing '
              'would ever read it');
      expect(read(mod, 'ellen.ini'), isNotNull,
          reason: 'the base brought its own loader');
    });

    test('a patch file the base does not have keeps its own path', () async {
      // A patch may legitimately add a texture the base never shipped.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Glow.dds', 'extra');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['Glow.dds']);

      expect(result.success, isTrue);
      expect(read(mod, 'Glow.dds'), 'extra');
    });

    test('the base keeps every file the patch does not replace', () async {
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');
      write(base, 'Textures/Hair.dds', 'base hair');

      await run('Ellen Fix', mod, [base], patchFiles: ['Body.dds']);

      expect(read(mod, 'Textures/Hair.dds'), 'base hair');
    });

    test('it reports where the patch now lives', () async {
      // What the caller writes back to `ingest.patch_files`. Without it the next
      // rebuild looks for the patch at the path it had before this one moved it.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['Body.dds']);

      expect(result.patchFiles, ['Textures/Body.dds'],
          reason: 'on-disk spelling, because that is what opens the file');
    });

    test('the real spelling of a path is what gets touched', () async {
      // 3DMigoto is case-insensitive and the comparison has to be, but a
      // lower-cased path handed to `File` opens nothing on Linux.
      final mod = modFolder('Ellen Fix');
      write(mod, 'BodyA.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'Ellen.ini', modIni('Textures/BodyA.dds'));
      write(base, 'Textures/BodyA.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['BodyA.dds']);

      expect(result.success, isTrue);
      expect(read(mod, 'Textures/BodyA.dds'), 'patched');
      expect(result.patchFiles, ['Textures/BodyA.dds']);
    });
  });

  group('what it refuses', () {
    test('no snapshot, no write', () async {
      // The same trade `apply` and `applyPatchInto` refuse to make: this
      // overwrites a live folder and deletes the patch's files from it.
      applier = UpdateApplier(
        snapshots: _RefusingSnapshots(rootPath: p.join(tmp.path, 'backups')),
        activation: activation,
      );
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['Body.dds']);

      expect(result.success, isFalse);
      expect(result.failure, UpdateApplyFailure.snapshot);
      expect(read(mod, 'Body.dds'), 'patched', reason: 'untouched');
      expect(read(mod, 'Textures/Body.dds'), isNull);
    });

    test('a target that keeps the same name twice is refused before any write',
        () async {
      // The placement cannot be settled — picking would be a guess about which
      // variant the user runs — and the refusal has to come *before* the base is
      // written, or the folder is left with the patch deleted and no way to
      // place it back.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'sfw/ellen.ini', modIni('Body.dds'));
      write(base, 'sfw/Body.dds', 'base sfw');
      write(base, 'nsfw/ellen.ini', modIni('Body.dds'));
      write(base, 'nsfw/Body.dds', 'base nsfw');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['Body.dds']);

      expect(result.success, isFalse);
      expect(result.failure, UpdateApplyFailure.layout);
      expect(read(mod, 'Body.dds'), 'patched',
          reason: 'nothing was written, so nothing was lost');
      expect(read(mod, 'sfw/Body.dds'), isNull);
      expect(activation.log, isEmpty, reason: 'and it never went offline');
    });

    test('a mod folder that is gone is refused', () async {
      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Body.dds'));
      write(base, 'Body.dds', 'base');

      final result = await run(
        'Missing',
        Directory(p.join(mods.path, 'Missing')),
        [base],
        patchFiles: const ['Body.dds'],
      );

      expect(result.failure, UpdateApplyFailure.modMissing);
    });
  });

  group('a record that has drifted', () {
    test('a patch file that is no longer there is skipped and named', () async {
      // The record says what the app wrote; the user can have deleted it since.
      // Resurrecting it from the snapshot would undo their edit.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result = await run('Ellen Fix', mod, [base],
          patchFiles: ['Body.dds', 'Hair.dds']);

      expect(result.success, isTrue);
      expect(read(mod, 'Textures/Body.dds'), 'patched');
      expect(result.missingPatchFiles, ['Hair.dds']);
      expect(result.patchFiles, ['Textures/Body.dds'],
          reason: 'the new record names only what is actually there');
    });

    test('an empty record writes the base and says the patch is gone',
        () async {
      // A folder from before the record existed. The base update is what the
      // user asked for and it still happens; the caller is the one that has to
      // have said the patch cannot be put back.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'hand merged');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Body.dds'));
      write(base, 'Body.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: const []);

      expect(result.success, isTrue);
      expect(read(mod, 'Body.dds'), 'base',
          reason: 'with nothing recorded as the patch, this is an ordinary '
              'overwrite — which is why the caller must say so first');
      expect(result.patchFiles, isEmpty);
    });
  });

  group('the folder goes offline for it', () {
    test('an active mod is deactivated and put back', () async {
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');
      activation.active.add('Ellen Fix');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final result =
          await run('Ellen Fix', mod, [base], patchFiles: ['Body.dds']);

      expect(result.reactivated, isTrue);
      expect(activation.log, ['deactivate:Ellen Fix', 'activate:Ellen Fix']);
      expect(activation.active, contains('Ellen Fix'));
    });
  });

  group('the patch is not part of the base update', () {
    test('the patch\'s own .ini is never offered as a stale leftover',
        () async {
      // `fix.ini` belongs to the other download. Offered for deletion it reads
      // as "the update renamed this", and accepting it deletes the patch.
      final mod = modFolder('Ellen Fix');
      write(mod, 'fix.ini', modIni('Body.dds'));
      write(mod, 'Body.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen.ini', modIni('Textures/Body.dds'));
      write(base, 'Textures/Body.dds', 'base');

      final preview = await applier.preview(
        modFolder: mod,
        incomingFolders: [base.path],
        excluding: ['fix.ini', 'Body.dds'],
      );

      expect(preview.staleInis.stale, isEmpty);
    });

    test('a stale .ini of the base itself is still offered', () async {
      // The exclusion must not blind the rule to the base's own leftovers.
      final mod = modFolder('Ellen Fix');
      write(mod, 'ellen.ini', modIni('Body.dds'));
      write(mod, 'Body.dds', 'base v1');
      write(mod, 'Patch.dds', 'patched');

      final base = incoming('Ellen');
      write(base, 'ellen_v2.ini', modIni('Body.dds'));
      write(base, 'Body.dds', 'base v2');

      final preview = await applier.preview(
        modFolder: mod,
        incomingFolders: [base.path],
        excluding: ['Patch.dds'],
      );

      expect(preview.staleInis.stale.map((ini) => ini.path),
          contains('ellen.ini'));
    });

    test('the folder is judged as if the patch were not in it', () async {
      // Every rule downstream compares `incoming` against `existing`, and the
      // patch belongs to neither: it is going back on top afterwards.
      final mod = modFolder('Ellen Fix');
      write(mod, 'Body.dds', 'patched');

      final preview = await applier.preview(
        modFolder: mod,
        incomingFolders: [incoming('Ellen').path],
        excluding: ['Body.dds'],
      );

      expect(preview.existing.files, isEmpty);
    });
  });

  group('FolderContents.without', () {
    test('it drops a path from every spelling it is held in', () async {
      final mod = modFolder('Ellen');
      write(mod, 'Ellen.ini', modIni('Body.dds'));
      write(mod, 'Body.dds', 'x');

      final contents = await readFolderContents(mod);
      final trimmed = contents.without(const ['Ellen.ini']);

      expect(trimmed.files, {'body.dds'});
      expect(trimmed.iniPaths, isEmpty);
      expect(trimmed.iniContents, isEmpty);
      expect(trimmed.actualPaths.keys, {'body.dds'});
      expect(trimmed.references.references, isEmpty,
          reason: 'the references came from that .ini, so they go with it');
    });

    test('it takes either spelling of the path', () async {
      // Callers hold the on-disk spelling — that is what a record stores.
      final mod = modFolder('Ellen');
      write(mod, 'BodyA.dds', 'x');

      final contents = await readFolderContents(mod);

      expect(contents.without(const ['BodyA.dds']).files, isEmpty);
      expect(contents.without(const ['bodya.dds']).files, isEmpty);
    });

    test('nothing to drop is the same walk', () async {
      final mod = modFolder('Ellen');
      write(mod, 'Body.dds', 'x');

      final contents = await readFolderContents(mod);
      expect(contents.without(const []).files, contents.files);
    });
  });
}
