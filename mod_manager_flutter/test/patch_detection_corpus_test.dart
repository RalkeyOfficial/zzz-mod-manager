import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_detection.dart';

/// The patch rule against **real extracted archives**, when they are present.
///
/// Skipped unless `ZZZ_PATCH_CORPUS` points at a directory laid out as
/// `<corpus>/<name>/…` — one extracted archive per subdirectory. The archives
/// are hundreds of megabytes and are nobody's business to check in, so this
/// cannot be a normal test; it exists so the numbers in
/// `docs/applying-updates.md` §2 can be re-derived rather than trusted.
///
/// ```
/// ZZZ_PATCH_CORPUS=/path/to/extracted flutter test \
///   test/patch_detection_corpus_test.dart
/// ```
void main() {
  final root = Platform.environment['ZZZ_PATCH_CORPUS'];

  test(
    'every archive in the corpus gets the expected verdict',
    () async {
      final dir = Directory(root!);
      final results = <String, PatchAssessment>{};

      for (final entity in dir.listSync()) {
        if (entity is! Directory) continue;
        final contents = await readFolderContents(entity);
        if (!contents.hasIni) continue;
        results[entity.path.split(Platform.pathSeparator).last] =
            assessPatchShape(
          references: contents.references,
          files: contents.files,
          directories: contents.directories,
          hasIni: true,
        );
      }

      expect(results, isNotEmpty, reason: 'corpus at $root held no mods');

      // Printed rather than asserted against a hard-coded list: the corpus is
      // whatever the person running it downloaded. What the reader is checking
      // is that the *partial* mods come out false.
      for (final entry in results.entries) {
        final a = entry.value;
        // ignore: avoid_print
        print('${a.looksLikePatch ? "PATCH " : "mod   "} '
            '${entry.key}: references=${a.required} '
            'present=${a.presentResources} missing=${a.missing.length} '
            'unreferenced=${a.unreferenced}');
      }

      // The one invariant that holds for any corpus: a download carrying
      // content is never a patch.
      for (final entry in results.entries) {
        if (entry.value.presentResources > 0) {
          expect(entry.value.looksLikePatch, isFalse, reason: entry.key);
        }
      }
    },
    skip: root == null
        ? 'set ZZZ_PATCH_CORPUS to a directory of extracted mod archives'
        : false,
  );
}
