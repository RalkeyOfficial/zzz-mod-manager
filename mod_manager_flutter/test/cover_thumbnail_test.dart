import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/cover_thumbnail.dart';
import 'package:path/path.dart' as path;

/// Where a cover's thumbnail is looked for, and which file a card ends up
/// decoding. The mapping is what keeps the writer and every reader agreeing
/// without a field in the model.
void main() {
  late Directory mod;

  setUp(() {
    mod = Directory.systemTemp.createTempSync('zzz_thumb_test_');
  });

  tearDown(() {
    if (mod.existsSync()) mod.deleteSync(recursive: true);
  });

  String managed(String name) =>
      path.join(mod.path, '.zzz-mod-manager', 'images', name);
  String thumbnail(String name) =>
      path.join(mod.path, '.zzz-mod-manager', 'thumbnails', name);

  group('thumbnailPathFor', () {
    test('a managed image maps to a png beside it under its own number', () {
      expect(thumbnailPathFor(managed('03.jpg')), thumbnail('03.png'));
    });

    test('a file the author shipped never maps', () {
      // The app writes nothing beside a mod author's own files, and a mapping
      // for one would send the reader probing outside the sidecar.
      expect(thumbnailPathFor(path.join(mod.path, 'Preview.png')), isNull);
      expect(
        thumbnailPathFor(path.join(mod.path, 'images', 'Preview.png')),
        isNull,
        reason: 'an `images` folder of the mod itself is not ours',
      );
    });
  });

  group('coverFileFor', () {
    test('prefers the thumbnail when it is on disk', () {
      File(managed('01.png')).createSync(recursive: true);
      File(thumbnail('01.png')).createSync(recursive: true);

      expect(coverFileFor(managed('01.png'))!.path, thumbnail('01.png'));
    });

    test('falls back to the image when there is no thumbnail', () {
      File(managed('01.png')).createSync(recursive: true);

      expect(coverFileFor(managed('01.png'))!.path, managed('01.png'));
    });

    test('answers nothing when neither exists', () {
      expect(coverFileFor(managed('01.png')), isNull);
    });

    test('a shipped preview is read as it is', () {
      final preview = path.join(mod.path, 'Preview.png');
      File(preview).createSync();

      expect(coverFileFor(preview)!.path, preview);
    });
  });
}
