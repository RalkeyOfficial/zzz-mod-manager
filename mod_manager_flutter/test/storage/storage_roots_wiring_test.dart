import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/storage/storage_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import '../support/temp_library.dart';

/// The chain from the configured library to the folder the Storage tab measures.
///
/// It gets its own file because the bug it exists to catch is invisible from
/// either end: `modsPathProvider` was declared, never written by anything, and
/// read only here — so the roots were built from an empty string and every
/// storage test that overrode the scanner passed while the tab reported "no
/// folder set" over a perfectly good library.
void main() {
  test('the configured library reaches modsPathProvider', () async {
    final library = await TempLibrary.create();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await ApiService.initialize(container: container);

    expect(container.read(modsPathProvider), library.mods.path);
  });

  test('and from there into the roots the scan walks', () async {
    final library = await TempLibrary.create();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await ApiService.initialize(container: container);

    expect(container.read(storageRootsProvider).modsLibrary?.path,
        library.mods.path);
  });

  test('repointing the library repoints the roots', () async {
    final library = await TempLibrary.create();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await ApiService.initialize(container: container);

    // A plain directory rather than a second `TempLibrary`: creating one calls
    // `useLibraryForTests`, which drops the container on purpose, and the thing
    // under test here is exactly that the container gets told.
    final moved = Directory.systemTemp.createTempSync('zzz_moved_library_');
    addTearDown(() {
      if (moved.existsSync()) moved.deleteSync(recursive: true);
    });

    await ApiService.updateConfig(
      modsPath: moved.path,
      saveModsPath: library.saveMods.path,
    );

    expect(container.read(storageRootsProvider).modsLibrary?.path, moved.path);
  });

  test('no library configured leaves the roots saying so, not empty-stringed',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Never hydrated: the default is '', which must read as "not set" rather
    // than as a folder at the process's working directory.
    expect(container.read(storageRootsProvider).modsLibrary, isNull);
  });
}
