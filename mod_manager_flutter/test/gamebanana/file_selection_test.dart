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

  group('fileWithId', () {
    GbMod profile(String fixture) =>
        GbMod.fromJson(parseObject(loadGbFixture(fixture)))!;

    test('finds the file a recorded id names', () {
      final mod = profile('mod_profile_531649');
      expect(fileWithId(mod.allFiles, 1732269)?.file, 'v77.zip');
    });

    test('finds an archived one, which is the whole point', () {
      // The opposite of `selectDefaultFile`'s rule, deliberately. A repair asks
      // for the version on disk, and that becomes archived the moment the
      // author publishes anything — this fixture has eight of them against six
      // current, so refusing archived files would make a repair impossible on
      // exactly the mods most likely to need one.
      final mod = profile('mod_profile_531649');
      final archived = fileWithId(mod.allFiles, 1694708);

      expect(archived?.file, 'v72.zip');
      expect(archived?.isArchived, isTrue);
      expect(selectDefaultFile(mod.allFiles).file?.idRow, isNot(1694708),
          reason: 'the same file is never something to preselect');
    });

    test('an id the page no longer carries is null, not the newest file', () {
      // GameBanana deletes file ids. Substituting the current file here would
      // silently turn a repair into an update, over a folder the user asked to
      // have put back as it was.
      final mod = profile('mod_profile_531649');
      expect(fileWithId(mod.allFiles, 999999), isNull);
    });

    test('a list that was never requested is null', () {
      expect(fileWithId(null, 1732269), isNull);
    });
  });

  group('how a file is named on screen', () {
    test('the filename is the title, never the author label', () {
      // This led with `_sDescription` and it was wrong: that field is free
      // text, not a name. A real captured file's is the whole sentence "Put it
      // in the folder with the mod (replace it)" — an instruction, standing
      // where the file's identity should be, with the filename nowhere on
      // screen.
      final f = file(1, version: '1.0', label: 'Main file');
      expect(fileDisplayName(f), 'f1.zip');
      expect(fileDisplayDetail(f), '1.0 · Main file');
    });

    test('the title falls back to the version, then the id', () {
      expect(fileDisplayName(GbFile(idRow: 1, version: '7.7')), '7.7');
      expect(fileDisplayName(const GbFile(idRow: 9)), '#9');
    });

    test('a file the author said nothing about has no second line', () {
      // Null rather than empty, so the caller draws no line at all instead of
      // a blank one.
      expect(fileDisplayDetail(file(2)), isNull);
      expect(fileDisplayDetail(file(2, label: '   ')), isNull);
    });

    test('either half alone is enough for the second line', () {
      expect(fileDisplayDetail(file(1, version: '7.7')), '7.7');
      expect(fileDisplayDetail(file(1, label: 'Main file')), 'Main file');
    });
  });
}
