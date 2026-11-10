import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/update_apply/mod_activation_port.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// What `UpdateApplier` does to a download that is shaped like a patch, pinned as it is.
///
/// `_write` calls `_wipe` with no branch on the download's shape, so a patch-shaped file written as a base update leaves a folder holding the patch's own files and the recorded patch put back, and nothing of the mod.
/// The modal update flow accepts a patch-shaped base update and the applier clears the folder first, while the confirmation's warning says everything else in the folder is left as it is, which does not match what the wipe does.
/// The tests below pin the applier's behaviour and do not endorse it: a patch belongs in a folder as a layer, placed by `applyPatchInto`.
void main() {
  late TempLibrary temp;
  late UpdateApplier applier;
  late Directory incoming;

  /// A patch `.ini` for a mod it does not carry the files of: it names `Body.dds` and ships none of what it names.
  const patchIni = '[TextureOverrideBody]\nhash = 12345\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n';

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_patch_shaped_wipe_');
    applier = UpdateApplier(snapshots: temp.snapshots, activation: ModManagerActivationPort(temp.service));
    incoming = Directory(p.join(temp.root.path, 'extract', 'Ellen Fix'))..createSync(recursive: true);
    File(p.join(incoming.path, 'Ellen.ini')).writeAsStringSync(patchIni);

    temp.write('Ellen', 'Ellen.ini', '[TextureOverrideBody]\nhash = 111\nps-t0 = ResourceBody\n\n[ResourceBody]\nfilename = Body.dds\n');
    temp.write('Ellen', 'Body.dds', 'the base mod body');
    temp.write('Ellen', 'Hair.dds', 'the base mod hair');
    temp.write('Ellen', 'Textures/Extra.dds', 'a texture of the base mod');
  });

  Future<UpdatePreview> preview() =>
      applier.preview(modFolder: temp.modFolder('Ellen'), incomingFolders: [incoming.path]);

  /// The files the mod folder holds, relative and `/`-separated, without the sidecar.
  List<String> filesOfMod() => [
        for (final entity in temp.modFolder('Ellen').listSync(recursive: true))
          if (entity is File && !p.split(p.relative(entity.path, from: temp.modFolder('Ellen').path)).contains('.zzz-mod-manager'))
            p.posix.joinAll(p.split(p.relative(entity.path, from: temp.modFolder('Ellen').path))),
      ]..sort();

  test('the download counts as a patch: it names a file it does not ship', () async {
    expect((await preview()).incomingIsPatch, isTrue);
  });

  test('the applier wipes the mod for a patch-shaped base update, leaving only the patch\'s files', () async {
    final result = await applier.apply(
      modName: 'Ellen',
      modFolder: temp.modFolder('Ellen'),
      preview: await preview(),
    );

    expect(result.success, isTrue);
    expect(filesOfMod(), ['Ellen.ini'], reason: 'the wipe has no branch on the download shape, so Body.dds, Hair.dds and the texture are gone');
    expect(temp.read('Ellen', 'Ellen.ini'), patchIni);
    expect(result.droppedFiles, unorderedEquals(['Body.dds', 'Hair.dds', 'Textures/Extra.dds']));
    expect(temp.snapshotsOf('Ellen'), hasLength(1), reason: 'the snapshot taken first is the only place the rest of the mod is');
  });

  test('the applier leaves the incoming patch\'s files and the recorded patch put back, and nothing else', () async {
    temp.write('Ellen', 'Patch.dds', 'a patch laid over the base mod');

    final result = await applier.applyBaseThenPatch(
      modName: 'Ellen',
      modFolder: temp.modFolder('Ellen'),
      preview: await preview(),
      patchFiles: const ['Patch.dds'],
    );

    expect(result.success, isTrue);
    expect(filesOfMod(), ['Ellen.ini', 'Patch.dds']);
    expect(temp.read('Ellen', 'Patch.dds'), 'a patch laid over the base mod');
    expect(temp.read('Ellen', 'Body.dds'), isNull);
    expect(result.droppedFiles, isNot(contains('Patch.dds')), reason: 'the recorded patch was put back, not dropped');
  });
}
