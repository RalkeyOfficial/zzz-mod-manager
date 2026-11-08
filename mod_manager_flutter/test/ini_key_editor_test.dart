import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/ini_key_editor.dart';
import 'package:mod_manager_flutter/services/ini_parser_service.dart';
import 'package:path/path.dart' as p;

/// **The key editor changes the `key` line it was asked to and no other byte**, and keeps the author's key in a
/// comment so it can be put back (`docs/key-editing.md`).
void main() {
  // A real mod's file, written with Windows line endings.
  final crlfFixture = File('test/fixtures/ini/miyabi_student.ini').readAsStringSync();
  final fixture = crlfFixture.replaceAll('\r\n', '\n');

  String edit(String text, List<IniKeyEdit> edits) => IniKeyEditor.apply(text, edits).text;

  group('changing a key', () {
    test('rewrites the key line and leaves a marker with the old value above it', () {
      final result = edit(fixture, [const SetKey('KeyHair', 0, 'ctrl 1')]);

      expect(result, fixture.replaceFirst('key = 8\n', ';zenith: key = 8\nkey = ctrl 1\n'));
    });

    test('adds the marker once and keeps it on the second change', () {
      final first = edit(fixture, [const SetKey('KeyHair', 0, 'ctrl 1')]);
      final second = edit(first, [const SetKey('KeyHair', 0, 'alt 2')]);

      expect(second, fixture.replaceFirst('key = 8\n', ';zenith: key = 8\nkey = alt 2\n'));
    });

    test('takes the marker out when the key goes back to the author\'s', () {
      final changed = edit(fixture, [const SetKey('KeyHair', 0, 'ctrl 1')]);

      expect(edit(changed, [const SetKey('KeyHair', 0, 'VK_8')]), fixture.replaceFirst('key = 8\n', 'key = VK_8\n'));
      expect(edit(changed, [const SetKey('KeyHair', 0, '8')]), fixture);
    });

    test('a key that is the same combination written another way is no change', () {
      const text = '[KeyA]\nkey = CTRL VK_F1\n';

      expect(edit(text, [const SetKey('KeyA', 0, 'ctrl VK_F1')]), text);
      expect(edit(text, [const SetKey('KeyA', 0, 'VK_F1 ctrl')]), text);
    });

    test('keeps the line endings of a real Windows file', () {
      expect(crlfFixture, contains('\r\n'));
      expect(
        edit(crlfFixture, [const SetKey('KeyHair', 0, 'ctrl 1')]),
        crlfFixture.replaceFirst('key = 8\r\n', ';zenith: key = 8\r\nkey = ctrl 1\r\n'),
      );
    });

    test('keeps Windows line endings, line by line', () {
      const text = '[KeyA]\r\nkey = 1\r\ncondition = 2\r\n';

      expect(edit(text, [const SetKey('KeyA', 0, '3')]), '[KeyA]\r\n;zenith: key = 1\r\nkey = 3\r\ncondition = 2\r\n');
    });

    test('keeps mixed line endings and a missing final one', () {
      // The marker takes the ending of the key line, or the file's first one when the key line has none.
      expect(
        edit('[KeyA]\ncondition = 2\r\nkey = 1', [const SetKey('KeyA', 0, '3')]),
        '[KeyA]\ncondition = 2\r\n;zenith: key = 1\nkey = 3',
      );
      expect(
        edit('[KeyA]\nkey = 1\r\ncondition = 2\n', [const SetKey('KeyA', 0, '3')]),
        '[KeyA]\n;zenith: key = 1\r\nkey = 3\r\ncondition = 2\n',
      );
    });

    test('keeps the spelling of Key and the spacing around the equals sign', () {
      expect(edit('[KeyA]\nKey=VK_UP\n', [const SetKey('KeyA', 0, '2')]), '[KeyA]\n;zenith: key = VK_UP\nKey=2\n');
      expect(
        edit('[KeyA]\n  KEY   =  5\n', [const SetKey('KeyA', 0, '2')]),
        '[KeyA]\n  ;zenith: key = 5\n  KEY   =  2\n',
      );
    });

    test('keeps the comment after the value', () {
      expect(
        edit('[KeyA]\nkey = 8 ; hair\n', [const SetKey('KeyA', 0, 'ctrl 1')]),
        '[KeyA]\n;zenith: key = 8\nkey = ctrl 1 ; hair\n',
      );
    });

    test('finds a section by its occurrence, not by the first of its name', () {
      const text = '[KeySwap]\nkey = 1\n\n[KeySwap]\nkey = 2\n';

      expect(
        edit(text, [const SetKey('KeySwap', 1, '9')]),
        '[KeySwap]\nkey = 1\n\n[KeySwap]\n;zenith: key = 2\nkey = 9\n',
      );
    });

    test('a section with no key line, or no such section, is left out and reported', () {
      const text = '[KeyA]\ntype = cycle\n';
      final result = IniKeyEditor.apply(text, [const SetKey('KeyA', 0, '1'), const SetKey('KeyB', 0, '1')]);

      expect(result.text, text);
      expect(result.missing, hasLength(2));
    });

    test('several changes in one file do not move each other', () {
      const text = '[KeyA]\nkey = 1\n\n[KeyB]\nkey = 2\n\n[KeyC]\nkey = 3\n';

      expect(
        edit(text, [const SetKey('KeyC', 0, '9'), const SetKey('KeyA', 0, '7')]),
        '[KeyA]\n;zenith: key = 1\nkey = 7\n\n[KeyB]\nkey = 2\n\n[KeyC]\n;zenith: key = 3\nkey = 9\n',
      );
    });

    test('lines it was not asked about stay as they are, hand edits included', () {
      const text = '; mine\n[KeyA]\nkey = 1\n  condition=  \$x==1   \n\n[Other]\nkey = not a key section\n';

      expect(
        edit(text, [const SetKey('KeyA', 0, '2')]),
        '; mine\n[KeyA]\n;zenith: key = 1\nkey = 2\n  condition=  \$x==1   \n\n[Other]\nkey = not a key section\n',
      );
    });
  });

  group('the markers and the commented-out sections a file holds', () {
    test('inspect reads the author\'s key from a marker', () {
      final changed = edit(fixture, [const SetKey('KeyHair', 0, 'ctrl 1')]);
      final state = IniKeyEditor.inspect(changed);

      expect(state.markerFor('KeyHair', 0), '8');
      expect(state.markerFor('KeyHair', 1), isNull);
      expect(IniKeyEditor.inspect(fixture).markers, isEmpty);
    });
  });

  group('Remove and Restore', () {
    test('Remove comments the whole section out and nothing else', () {
      final result = edit(fixture, [const Unbind('KeyHair', 0)]);

      expect(
        result,
        fixture.replaceFirst(
          '[KeyHair]\nkey = 8\ncondition = \$active == 1\ntype = cycle\n\$hair = 0,1\n',
          ';zenith: [KeyHair]\n;zenith: key = 8\n;zenith: condition = \$active == 1\n;zenith: type = cycle\n;zenith: \$hair = 0,1\n',
        ),
      );
    });

    test('a removed section is no longer a key, and is listed as a block', () {
      final result = edit(fixture, [const Unbind('KeyHair', 0)]);
      final state = IniKeyEditor.inspect(result);

      expect(state.blocks.map((b) => (b.section, b.key)), [('KeyHair', '8')]);
    });

    test('Restore brings the section back byte for byte', () {
      final removed = edit(fixture, [const Unbind('KeyHair', 0)]);

      expect(edit(removed, [const RestoreBlock(0)]), fixture);
    });

    test('Remove then Restore keeps CRLF files as they were', () {
      final text = fixture.replaceAll('\n', '\r\n');

      expect(edit(edit(text, [const Unbind('KeyHair', 0)]), [const RestoreBlock(0)]), text);
    });

    test('Restore with a key writes it, and with the author\'s key leaves no marker', () {
      final edited = edit(fixture, [const SetKey('KeyHair', 0, 'ctrl 1')]);
      final removed = edit(edited, [const Unbind('KeyHair', 0)]);

      // The block's author key is the marker's, so that is what the row offers and what comes back.
      expect(IniKeyEditor.inspect(removed).blocks.single.key, '8');
      expect(edit(removed, [const RestoreBlock(0, key: '8')]), fixture);
      expect(
        edit(removed, [const RestoreBlock(0, key: 'alt 3')]),
        fixture.replaceFirst('key = 8\n', ';zenith: key = 8\nkey = alt 3\n'),
      );
    });

    test('Remove and Restore leave the sections around them alone, whichever is first', () {
      const text = '[KeyA]\nkey = 1\n\n[KeyB]\nkey = 2\n\n[KeyC]\nkey = 3\n';
      final removed = edit(text, [const Unbind('KeyB', 0), const Unbind('KeyA', 0)]);

      expect(removed, ';zenith: [KeyA]\n;zenith: key = 1\n\n;zenith: [KeyB]\n;zenith: key = 2\n\n[KeyC]\nkey = 3\n');
      expect(edit(removed, [const RestoreBlock(1), const RestoreBlock(0)]), text);
    });

    test('a hand edit made between Remove and Restore is kept', () {
      final removed = edit(fixture, [const Unbind('KeyHair', 0)]);
      final handEdited = removed.replaceFirst(';zenith: type = cycle', ';zenith: type = cycle ; my note');

      expect(edit(handEdited, [const RestoreBlock(0)]), contains('type = cycle ; my note'));
    });

    test('the parser no longer sees a removed section as a key', () async {
      final dir = Directory.systemTemp.createTempSync('zzz_ini_editor_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'mod.ini'))..writeAsStringSync(edit(fixture, [const Unbind('KeyHair', 0)]));

      expect(await IniParserService().parseIniFile(file.path, modFolder: dir.path), isEmpty);
    });
  });

  group('the parser and the editor agree', () {
    test('on a value with a comment after it', () async {
      final dir = Directory.systemTemp.createTempSync('zzz_ini_editor_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'mod.ini'))
        ..writeAsStringSync('[KeyA]\nkey = 8 ; note\n[KeyB] ; hmm\nKey=2\n');

      final keys = await IniParserService().parseIniFile(file.path, modFolder: dir.path);

      expect(
        [for (final k in keys) (k.section, k.keyValue, k.file, k.occurrence)],
        [('KeyA', '8', 'mod.ini', 0), ('KeyB', '2', 'mod.ini', 0)],
      );
    });

    test('on which occurrence a section is, counting sections that are not keys', () async {
      final dir = Directory.systemTemp.createTempSync('zzz_ini_editor_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'mod.ini'))..writeAsStringSync('[Key]\nkey = 1\n[Key]\nkey = 2\n');

      final keys = await IniParserService().parseIniFile(file.path, modFolder: dir.path);

      expect([for (final k in keys) (k.occurrence, k.keyValue)], [(0, '1'), (1, '2')]);
      expect(edit('[Key]\nkey = 1\n[Key]\nkey = 2\n', [const SetKey('Key', 1, '9')]), contains('key = 9'));
      expect(edit('[Key]\nkey = 1\n[Key]\nkey = 2\n', [const SetKey('Key', 1, '9')]), contains('\nkey = 1\n'));
    });

    test('a non-key section\'s lines do not leak into the next key section', () async {
      final dir = Directory.systemTemp.createTempSync('zzz_ini_editor_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'mod.ini'))..writeAsStringSync('[Constants]\nglobal = 1\n[KeyA]\nkey = 2\n');

      final keys = await IniParserService().parseIniFile(file.path, modFolder: dir.path);

      expect(keys.single.keys, {'key': '2'});
    });
  });

  group('files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('zzz_ini_files_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File ini(String name, List<int> bytes) => File(p.join(dir.path, name))..writeAsBytesSync(bytes);

    test('writes through a temporary file, which is gone afterwards', () async {
      final file = ini('mod.ini', utf8.encode(fixture));

      final result = await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyHair', 0, 'ctrl 1')]);

      expect(result.status, IniWriteStatus.written);
      expect(file.readAsStringSync(), contains('key = ctrl 1'));
      expect(dir.listSync().map((e) => p.basename(e.path)), ['mod.ini']);
    });

    test('keeps the byte-order mark', () async {
      final file = ini('mod.ini', [0xEF, 0xBB, 0xBF, ...utf8.encode('[KeyA]\nkey = 1\n')]);

      await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyA', 0, '2')]);

      expect(file.readAsBytesSync().take(3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(file.readAsBytesSync().skip(3).toList()), '[KeyA]\n;zenith: key = 1\nkey = 2\n');
    });

    test('keeps text that is not ASCII', () async {
      final file = ini('mod.ini', utf8.encode('; Привіт\n[KeyA]\nkey = 1\n'));

      await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyA', 0, '2')]);

      expect(file.readAsStringSync(), '; Привіт\n[KeyA]\n;zenith: key = 1\nkey = 2\n');
    });

    test('refuses a file that is not UTF-8, and leaves it as it is', () async {
      final bytes = [...latin1.encode('[KeyA]\nkey = 1\n; caf'), 0xE9, 0x0A];
      final file = ini('mod.ini', bytes);

      final result = await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyA', 0, '2')]);

      expect(result.status, IniWriteStatus.notUtf8);
      expect(result.problem, isTrue);
      expect(file.readAsBytesSync(), bytes);
      expect(await IniKeyFiles.inspect(file.path), isNull);
    });

    test('a file that already says what was asked is not rewritten', () async {
      final file = ini('mod.ini', utf8.encode('[KeyA]\nkey = 1\n'));
      final before = file.lastModifiedSync();

      final result = await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyA', 0, '1')]);

      expect(result.status, IniWriteStatus.unchanged);
      expect(file.lastModifiedSync(), before);
    });

    test('a write that cannot land leaves the original whole', () async {
      final file = ini('mod.ini', utf8.encode('[KeyA]\nkey = 1\n'));
      // Something is where the temporary file goes.
      Directory(p.join(dir.path, '.mod.ini.zenith.tmp')).createSync();

      final result = await IniKeyFiles.write(file.path, 'mod.ini', [const SetKey('KeyA', 0, '2')]);

      expect(result.status, IniWriteStatus.failed);
      expect(file.readAsStringSync(), '[KeyA]\nkey = 1\n');
    });

    test('reports the edits it found no place for', () async {
      final file = ini('mod.ini', utf8.encode('[KeyA]\nkey = 1\n'));

      final result = await IniKeyFiles.write(file.path, 'mod.ini', [
        const SetKey('KeyA', 0, '2'),
        const SetKey('Gone', 0, '3'),
      ]);

      expect(result.status, IniWriteStatus.written);
      expect(result.missing, hasLength(1));
      expect(result.problem, isTrue);
    });
  });
}
