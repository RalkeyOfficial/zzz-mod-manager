import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/services/gamebanana/file_selection.dart';

import '../support/fixtures.dart';

/// The default-selection rule, which decides whether the download button may
/// preselect a file. It exists to stop the app installing a demo or a patcher
/// when the user meant the mod, so the interesting cases are all "does it
/// correctly refuse".
void main() {
  GbFile file(int id, {String? version, String? label, bool archived = false}) {
    return GbFile(
      idRow: id,
      file: 'f$id.zip',
      version: version,
      description: label,
      isArchived: archived,
    );
  }

  group('selectDefaultFile', () {
    test('a null list is "not loaded", not "no files"', () {
      // The distinction is load-bearing: null means the response never carried
      // _aFiles, and concluding "this mod has nothing to download" from a
      // request that didn't ask would be wrong in the most confusing way.
      final result = selectDefaultFile(null);
      expect(result.hasDefault, isFalse);
      expect(result.reason, FileDefaultReason.notLoaded);
    });

    test('an empty list is genuinely no files', () {
      expect(selectDefaultFile(const []).reason, FileDefaultReason.noFiles);
    });

    test('a single file is preselected', () {
      final only = file(1, version: '1.0');
      final result = selectDefaultFile([only]);
      expect(result.file, same(only));
      expect(result.reason, FileDefaultReason.soleFile);
    });

    test('two files never default, however tempting the versions look', () {
      final result = selectDefaultFile([
        file(1, version: '1.0'),
        file(2, version: '2.0'),
      ]);
      expect(result.hasDefault, isFalse);
      expect(result.reason, FileDefaultReason.ambiguous);
    });

    test('archived files are not candidates', () {
      // A superseded file must never be the default — that would deliberately
      // install an old release.
      final current = file(1);
      final result = selectDefaultFile([
        current,
        file(2, archived: true),
        file(3, archived: true),
      ]);
      expect(result.file, same(current));
      expect(result.reason, FileDefaultReason.soleFile);
    });

    test('a list of nothing but archived files is no files', () {
      final result = selectDefaultFile([file(1, archived: true)]);
      expect(result.hasDefault, isFalse);
      expect(result.reason, FileDefaultReason.noFiles);
    });
  });

  group('against real captured profiles', () {
    GbMod profile(String fixture) =>
        GbMod.fromJson(parseObject(loadGbFixture(fixture)))!;

    test('a mod mixing a main file, patchers and demos refuses to default', () {
      // RabbitFX publishes six current files at once: "Main file" 7.7, two
      // "Fixer" utilities at 1.0, and three unversioned demo archives. Both a
      // highest-version guess and a newest-upload guess would silently pick for
      // the user here, and the demos are exactly what they must not get.
      final mod = profile('mod_profile_531649');
      expect(mod.files!.length, 6);

      final result = selectDefaultFile(mod.files);
      expect(result.hasDefault, isFalse);
      expect(result.reason, FileDefaultReason.ambiguous);
    });

    test('a version history with no _sVersion at all refuses to default', () {
      // This is the case that rules out a version-string comparison outright:
      // all ten files carry _sVersion: null and put the version in
      // _sDescription ("v3.4", "v3.3", …) — the field that is otherwise the
      // variant label. Version and variant are not separable here.
      final mod = profile('mod_profile_rated');
      expect(mod.files!.length, 10);
      expect(mod.files!.every((f) => f.version == null), isTrue,
          reason: '_sVersion is null on every file of this real mod');
      expect(mod.files!.every((f) => (f.description ?? '').isNotEmpty), isTrue,
          reason: 'the version lives in _sDescription instead');

      expect(selectDefaultFile(mod.files).reason, FileDefaultReason.ambiguous);
    });
  });

  group('fileDisplayLabel', () {
    test('prefers the author label over the version string', () {
      // _sDescription is what actually distinguishes rows in the wild.
      expect(
        fileDisplayLabel(file(1, version: '1.0', label: 'Main file')),
        'Main file',
      );
    });

    test('falls back to the version, then the filename, then the id', () {
      expect(fileDisplayLabel(file(1, version: '7.7')), '7.7');
      expect(fileDisplayLabel(file(2)), 'f2.zip');
      expect(fileDisplayLabel(const GbFile(idRow: 9)), '#9');
    });

    test('blank strings count as absent, not as a label', () {
      expect(fileDisplayLabel(file(1, version: '1.0', label: '   ')), '1.0');
    });
  });
}
