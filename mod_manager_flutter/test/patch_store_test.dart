import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/patch_store.dart';
import 'package:path/path.dart' as path;

/// **The mod's own files a patch wrote over**, kept so the patch can be taken
/// back out.
///
/// It lives inside the mod folder, which is the decision worth restating: the
/// filesystem then handles rename, move, delete and copy, where an `<appData>`
/// store keyed by folder name would need four hooks and a sweep — and already
/// leaks in the snapshot feature, whose orphaned groups are both unreachable and
/// exempt from pruning.
void main() {
  const store = PatchStore();
  const patchId = 605460;

  late Directory root;
  late Directory modFolder;

  setUp(() {
    root = Directory.systemTemp.createTempSync('patch_store_test_');
    modFolder = Directory(path.join(root.path, 'Ellen Swimsuit'))..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String contents) {
    final file = File(path.join(modFolder.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(String relative) {
    final file = File(path.join(modFolder.path, relative));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  List<String> storedFiles() {
    final dir = PatchStore.directoryFor(modFolder, patchId);
    if (!dir.existsSync()) return const [];
    return [
      for (final entity in dir.listSync(recursive: true))
        if (entity is File) path.relative(entity.path, from: dir.path),
    ]..sort();
  }

  Future<bool> keep(String relative) => store.keep(
        modFolder: modFolder,
        patchModId: patchId,
        relativePath: relative,
      );

  test('keeps the mod\'s file and reports that there is now a way back',
      () async {
    write('Textures/Body.dds', 'the mod');

    expect(await keep('Textures/Body.dds'), isTrue);
    expect(storedFiles(), ['Textures/Body.dds.orig']);
  });

  test('nothing in here is named like something the loader looks for',
      () async {
    // The reason §5 refuses an in-folder *snapshot*: a verbatim copy holds a
    // loadable `ellen.ini`, the active symlink makes it reachable, and the
    // loader reads the old hotkeys alongside the new ones. A patch replacing
    // the base's `.ini` is the common case, so this store would hold exactly
    // that file — and must not hold it under that name.
    write('Ellen.ini', '[Key]');
    write('ShaderFixes/thing.hlsl', 'code');

    await keep('Ellen.ini');
    await keep('ShaderFixes/thing.hlsl');

    for (final stored in storedFiles()) {
      expect(stored, endsWith('.orig'));
      expect(path.extension(stored), isNot('.ini'));
    }
  });

  test('a path nothing occupied keeps nothing, and says so', () async {
    // The patch is adding a file rather than displacing one, and an `added`
    // entry needs no original.
    expect(await keep('New.ini'), isFalse);
    expect(storedFiles(), isEmpty);
  });

  group('the first displacement wins', () {
    test('a second keep at the same path leaves the original alone', () async {
      // **The rule that makes a patch update safe.** Updating a patch overwrites
      // the *previous patch's* file, not the mod's — so a second keep would
      // replace the base's original with a patch file, and removing the patch
      // would then restore the patch.
      write('Body.dds', 'the mod');
      await keep('Body.dds');

      write('Body.dds', 'patch v1');
      expect(await keep('Body.dds'), isTrue, reason: 'still recoverable');

      await store.restore(
        modFolder: modFolder,
        patchModId: patchId,
        relativePath: 'Body.dds',
      );
      expect(read('Body.dds'), 'the mod');
    });

    test('a path the new version reaches first is still kept', () async {
      // A patch version that displaces more of the mod than the last one did
      // stays reversible.
      write('Body.dds', 'the mod');
      await keep('Body.dds');
      write('Face.dds', 'the mod\'s face');

      expect(await keep('Face.dds'), isTrue);
      expect(storedFiles(), ['Body.dds.orig', 'Face.dds.orig']);
    });
  });

  test('restoring puts it back where it came from', () async {
    write('Textures/Body.dds', 'the mod');
    await keep('Textures/Body.dds');
    write('Textures/Body.dds', 'the patch');

    expect(
      await store.restore(
        modFolder: modFolder,
        patchModId: patchId,
        relativePath: 'Textures/Body.dds',
      ),
      isTrue,
    );
    expect(read('Textures/Body.dds'), 'the mod');
  });

  test('a restore leaves the stored copy in place', () async {
    // A restore that failed part-way must not have eaten the thing it was
    // restoring; the caller drops the whole store when the removal finishes.
    write('Body.dds', 'the mod');
    await keep('Body.dds');

    await store.restore(
      modFolder: modFolder,
      patchModId: patchId,
      relativePath: 'Body.dds',
    );

    expect(storedFiles(), ['Body.dds.orig']);
  });

  test('restoring something never kept fails rather than inventing a file',
      () async {
    expect(
      await store.restore(
        modFolder: modFolder,
        patchModId: patchId,
        relativePath: 'Body.dds',
      ),
      isFalse,
    );
    expect(read('Body.dds'), isNull);
  });

  test('two patches in one folder never read each other\'s originals',
      () async {
    // The same reason their registries are per companion: a folder can hold two
    // patches, and one flat store could not say whose an original is.
    write('Body.dds', 'the mod');
    await keep('Body.dds');
    write('Body.dds', 'patch A');
    await store.keep(
      modFolder: modFolder,
      patchModId: 611203,
      relativePath: 'Body.dds',
    );

    await store.restore(
      modFolder: modFolder,
      patchModId: 611203,
      relativePath: 'Body.dds',
    );
    expect(read('Body.dds'), 'patch A');

    await store.restore(
      modFolder: modFolder,
      patchModId: patchId,
      relativePath: 'Body.dds',
    );
    expect(read('Body.dds'), 'the mod');
  });

  group('discarding', () {
    test('removes one patch\'s store and leaves the other', () async {
      write('Body.dds', 'the mod');
      await keep('Body.dds');
      await store.keep(
        modFolder: modFolder,
        patchModId: 611203,
        relativePath: 'Body.dds',
      );

      await store.discard(modFolder: modFolder, patchModId: patchId);

      expect(storedFiles(), isEmpty);
      expect(await PatchStore.idsIn(modFolder), {611203});
    });

    test('discarding what is not there is not an error', () async {
      await store.discard(modFolder: modFolder, patchModId: patchId);
      expect(await PatchStore.idsIn(modFolder), isEmpty);
    });

    test('an ingest drops every store, because nothing explains them', () async {
      // `copyDirectory` carries `.zzz-mod-manager/` wholesale on ingest while
      // the inbound origin block is always dropped — so the bytes arrive with
      // nothing left saying which patch they belong to.
      write('Body.dds', 'the mod');
      await keep('Body.dds');
      await store.keep(
        modFolder: modFolder,
        patchModId: 611203,
        relativePath: 'Body.dds',
      );

      await store.discardAll(modFolder);

      expect(await PatchStore.idsIn(modFolder), isEmpty);
      expect(read('Body.dds'), 'the mod', reason: 'the mod itself is untouched');
    });
  });

  test('a folder with no store at all lists nothing', () async {
    expect(await PatchStore.idsIn(modFolder), isEmpty);
    expect(
      await store.holds(
        modFolder: modFolder,
        patchModId: patchId,
        relativePath: 'Body.dds',
      ),
      isFalse,
    );
  });
}
