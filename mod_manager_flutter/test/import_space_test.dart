import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:mod_manager_flutter/services/import_result.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// **An install that cannot fit is refused before it copies anything.**
///
/// This is the third and last write of an install, and the only one on the
/// user's own mod disk. Half-copying leaves a folder that looks installed and
/// is missing files, which the app then scans, badges and offers to update.
///
/// Real directories rather than a fake filesystem: what is under test is a copy
/// and a refusal to copy, so the bytes on disk are the assertion. Only the free
/// space is injected — a test cannot fill a volume to ask the question.
void main() {
  late Directory temp;
  late Directory modsDir;
  late Directory sourceDir;
  late ConfigService config;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_import_space_test_');
    modsDir = await Directory(path.join(temp.path, 'mods')).create();
    sourceDir = await Directory(path.join(temp.path, 'src')).create();
    final zzmiDir = await Directory(path.join(temp.path, 'zzmi')).create();

    SharedPreferences.setMockInitialValues({});
    config = ConfigService(
      await SharedPreferences.getInstance(),
      configFile: File(path.join(temp.path, 'config.json')),
    );
    await config.setPaths(modsDir.path, zzmiDir.path);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  ModManagerService serviceWith({required int? free, List<String>? asked}) =>
      ModManagerService(
        config,
        freeSpace: (p) async {
          asked?.add(p);
          return free;
        },
      );

  /// A mod-shaped folder of exactly [bytes], spread over two files so the walk
  /// has to add rather than take one length.
  Future<String> sourceFolder(String name, {int bytes = 1000}) async {
    final folder = await Directory(path.join(sourceDir.path, name)).create();
    final half = bytes ~/ 2;
    await File(path.join(folder.path, 'mod.ini')).writeAsString('x' * half);
    await File(path.join(folder.path, 'body.dds'))
        .writeAsString('y' * (bytes - half));
    return folder.path;
  }

  List<String> modsInLibrary() => modsDir
      .listSync()
      .map((e) => path.basename(e.path))
      .toList()
    ..sort();

  test('an import that does not fit copies nothing', () async {
    final folder = await sourceFolder('Ellen Swimsuit', bytes: 1000);

    final result = await serviceWith(free: 999).importMods([folder]);

    expect(result.failure, ImportFailure.notEnoughSpace);
    expect(result.requiredBytes, 1000);
    expect(result.availableBytes, 999);
    expect(result.imported, isEmpty);
    expect(modsInLibrary(), isEmpty,
        reason: 'a refusal must not leave half a mod in the library');
  });

  test('an import that fits exactly is copied', () async {
    // The boundary in the direction that matters: refusing an install that fits
    // leaves the user with no way to install it at all.
    final folder = await sourceFolder('Ellen Swimsuit', bytes: 1000);

    final result = await serviceWith(free: 1000).importMods([folder]);

    expect(result.failure, isNull);
    expect(result.imported, ['Ellen Swimsuit']);
  });

  test('several folders are weighed together', () async {
    // One install, so it fits or it does not. Copying the first and refusing
    // the second would leave a mod's dependency folder missing.
    final first = await sourceFolder('Ellen Swimsuit', bytes: 600);
    final second = await sourceFolder('Ellen Cheongsam', bytes: 600);

    final result = await serviceWith(free: 1000).importMods([first, second]);

    expect(result.requiredBytes, 1200);
    expect(modsInLibrary(), isEmpty);
  });

  test('a folder the library already has is not counted', () async {
    // It is skipped by the copy, so counting it would refuse an install over
    // space nothing was going to use.
    final existing = await sourceFolder('Ellen Swimsuit', bytes: 1000);
    await Directory(path.join(modsDir.path, 'Ellen Swimsuit')).create();
    final fresh = await sourceFolder('Ellen Cheongsam', bytes: 500);

    final result = await serviceWith(free: 600).importMods([existing, fresh]);

    expect(result.failure, isNull);
    expect(result.imported, ['Ellen Cheongsam']);
  });

  test('the volume asked about is the mods folder', () async {
    // Not the temp directory the files are sitting in, which on most Linux
    // desktops is a tmpfs and a different volume entirely.
    final folder = await sourceFolder('Ellen Swimsuit');
    final asked = <String>[];

    await serviceWith(free: 1 << 30, asked: asked).importMods([folder]);

    expect(asked, [modsDir.path]);
  });

  test('an unknown free space imports anyway', () async {
    final folder = await sourceFolder('Ellen Swimsuit');

    final result = await serviceWith(free: null).importMods([folder]);

    expect(result.imported, ['Ellen Swimsuit']);
  });

  test('a combined mod is refused the same way, and creates no folder',
      () async {
    final first = await sourceFolder('Ellen Swimsuit', bytes: 600);
    final second = await sourceFolder('Ellen Extras', bytes: 600);

    final result = await serviceWith(free: 1000)
        .importCombinedMod([first, second], 'Ellen Swimsuit Set');

    expect(result.failure, ImportFailure.notEnoughSpace);
    expect(result.requiredBytes, 1200);
    expect(modsInLibrary(), isEmpty,
        reason: 'the mod folder is created after the check, not before');
  });

  test('a duplicate is not a failure', () async {
    // The distinction the result type exists for: "you already have this" is
    // not the same answer as "it would not fit", and both install nothing.
    final folder = await sourceFolder('Ellen Swimsuit');
    await Directory(path.join(modsDir.path, 'Ellen Swimsuit')).create();

    final result = await serviceWith(free: 1 << 30).importMods([folder]);

    expect(result.imported, isEmpty);
    expect(result.failure, isNull);
  });

  test('no library configured is its own answer', () async {
    await config.setPaths('', '');

    final result = await serviceWith(free: 1 << 30).importMods(['/nowhere']);

    expect(result.failure, ImportFailure.libraryNotConfigured);
  });
}
