import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';

/// The record of **what an install wrote**, and the one asymmetry in it.
///
/// A sidecar travels with its folder, so one can arrive from a stranger or from
/// a build that spells things differently. Every parse here has to survive that
/// without throwing — `ModOrigin.fromJson` never throws for any input, because a
/// throw would make the sidecar unreadable and it would then be replaced
/// wholesale on the next save.
void main() {
  group('the role of an unrecognised value', () {
    test('is `replaced`, which is the safe direction and not the weak one', () {
      // Every other lenient parse in this app resolves an unknown *downward*,
      // to the weakest claim. Here the weak answer is the dangerous one:
      // `added` licenses a delete, so a role we do not understand read as
      // `added` would remove a file that may be the mod's own. `replaced`
      // licenses a restore, which is skipped when nothing was stored.
      for (final raw in [
        'moved',
        'ADDED',
        '',
        null,
        42,
        <String>['added'],
      ]) {
        expect(
          InstalledFileRole.parse(raw),
          InstalledFileRole.replaced,
          reason: 'role $raw must not license a delete',
        );
      }
    });

    test('the two it does know are read exactly', () {
      expect(InstalledFileRole.parse('added'), InstalledFileRole.added);
      expect(InstalledFileRole.parse('replaced'), InstalledFileRole.replaced);
    });
  });

  group('one entry', () {
    test('round-trips', () {
      const file = InstalledFile(
        path: 'Textures/Body.dds',
        bytes: 5242880,
        role: InstalledFileRole.replaced,
      );

      expect(InstalledFile.fromJson(file.toJson()), file);
    });

    test('leaves `bytes` out when there is nothing to say', () {
      // Zero is "not read", not "empty file", so writing it would put a
      // measurement in the sidecar that nobody took.
      const file = InstalledFile(path: 'mod.ini');

      expect(file.toJson().containsKey('bytes'), isFalse);
      expect(InstalledFile.fromJson(file.toJson())?.bytes, 0);
    });

    test('a negative or non-numeric size reads as zero', () {
      expect(
        InstalledFile.fromJson({'path': 'a.ini', 'bytes': -4})?.bytes,
        0,
      );
      expect(
        InstalledFile.fromJson({'path': 'a.ini', 'bytes': 'lots'})?.bytes,
        0,
      );
    });

    test('an entry with no usable path is dropped, never kept as empty', () {
      // An empty path as a delete target resolves to the mod folder itself.
      expect(InstalledFile.fromJson({'role': 'added'}), isNull);
      expect(InstalledFile.fromJson({'path': ''}), isNull);
      expect(InstalledFile.fromJson({'path': 12}), isNull);
      expect(InstalledFile.fromJson('mod.ini'), isNull);
      expect(InstalledFile.fromJson(null), isNull);
    });
  });

  group('a list', () {
    test('drops the entries it cannot use and keeps the rest', () {
      final files = InstalledFile.parseList([
        {'path': 'mod.ini', 'role': 'added', 'bytes': 12},
        {'path': ''},
        'nonsense',
        {'path': 'Textures/Body.dds', 'role': 'replaced'},
      ]);

      expect(files.map((f) => f.path), ['mod.ini', 'Textures/Body.dds']);
    });

    test('anything that is not a list is no files at all', () {
      expect(InstalledFile.parseList(null), isEmpty);
      expect(InstalledFile.parseList('mod.ini'), isEmpty);
      expect(InstalledFile.parseList({'path': 'mod.ini'}), isEmpty);
    });
  });

  group('lifting to the mod root', () {
    test('a combined install\'s subfolder is prefixed onto every path', () {
      // The copy reports paths relative to the subfolder it wrote into, and a
      // record relative to that names a file the mod folder does not have.
      final lifted = installedFilesUnderPrefix(
        const [
          InstalledFile(path: 'Ellen.ini', bytes: 8),
          InstalledFile(path: 'Textures/Body.dds'),
        ],
        'EllenSkin',
      );

      expect(lifted.map((f) => f.path),
          ['EllenSkin/Ellen.ini', 'EllenSkin/Textures/Body.dds']);
      expect(lifted.first.bytes, 8, reason: 'the rest of the entry survives');
    });

    test('no prefix changes nothing', () {
      const files = [InstalledFile(path: 'Ellen.ini')];

      expect(installedFilesUnderPrefix(files, ''), same(files));
    });
  });
}
