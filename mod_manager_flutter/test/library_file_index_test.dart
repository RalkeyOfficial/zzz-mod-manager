import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/library_file_index.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library_index_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> write(String relative) async {
    final file = File(path.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString('x');
  }

  test('names come back without their paths, lower-cased', () async {
    await write('Ellen/Textures/EllenBodyADiffuse.dds');
    await write('Ellen/Ellen.ini');

    final index =
        await readLibraryFileNames(modIds: ['Ellen'], modsPath: root.path);

    expect(index['Ellen'], {'ellenbodyadiffuse.dds', 'ellen.ini'});
  });

  test('our own sidecar folder is not part of the mod', () async {
    await write('Ellen/body.dds');
    await write('Ellen/${AppConstants.modMetadataDirName}/cover.png');
    await write('Ellen/${AppConstants.modMetadataDirName}/metadata.json');

    final index =
        await readLibraryFileNames(modIds: ['Ellen'], modsPath: root.path);

    expect(index['Ellen'], {'body.dds'});
  });

  test('a missing folder is empty, never absent', () async {
    final index = await readLibraryFileNames(
      modIds: ['gone', 'also gone'],
      modsPath: root.path,
    );

    expect(index.keys, ['gone', 'also gone']);
    expect(index['gone'], isEmpty);
  });

  test('every mod asked for is answered, in the order asked', () async {
    await write('b/body.dds');
    await write('a/hair.dds');

    final index = await readLibraryFileNames(
      modIds: ['b', 'a', 'c'],
      modsPath: root.path,
    );

    expect(index.keys.toList(), ['b', 'a', 'c']);
  });
}
