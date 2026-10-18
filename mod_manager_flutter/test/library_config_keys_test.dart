import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `mod_notes` and `one_at_a_time` in `config.json` (`docs/library-screen.md` §10, §11).
///
/// "Next session" is a fresh service with empty preferences over the same file, then `loadFromFile`.
void main() {
  late Directory temp;
  File configFile() => File('${temp.path}/config.json');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_library_config_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<ConfigService> build() async => ConfigService(await SharedPreferences.getInstance(), configFile: configFile());

  Future<ConfigService> nextSession() async {
    SharedPreferences.setMockInitialValues({});
    final next = await build();
    expect(await next.loadFromFile(), isTrue);
    return next;
  }

  Future<Map<String, dynamic>> readFile() async =>
      jsonDecode(await configFile().readAsString()) as Map<String, dynamic>;

  group('mod notes', () {
    test('reach config.json and survive into a fresh session', () async {
      final config = await build();
      expect(await config.setModNote('Ellen Maid', 'use with the white hairpin'), isTrue);

      expect((await readFile())['mod_notes'], {'Ellen Maid': 'use with the white hairpin'});
      expect((await nextSession()).modNotes, {'Ellen Maid': 'use with the white hairpin'});
    });

    test('text that is empty once trimmed removes the entry', () async {
      final config = await build();
      await config.setModNote('Ellen Maid', 'keep');
      await config.setModNote('Miyabi Kimono', 'also keep');

      expect(await config.setModNote('Ellen Maid', '  \n '), isTrue);
      expect(config.modNotes, {'Miyabi Kimono': 'also keep'});
      expect((await readFile())['mod_notes'], {'Miyabi Kimono': 'also keep'});
    });

    test('clearing a note that was never written succeeds and changes nothing', () async {
      final config = await build();
      expect(await config.setModNote('Ellen Maid', ''), isTrue);
      expect(config.modNotes, isEmpty);
    });

    test('a rename moves the note to the new folder name', () async {
      final config = await build();
      await config.setModNote('Ellen Maid', 'the good one');

      expect(await config.migrateModName('Ellen Maid', 'Ellen Maid v2'), isTrue);
      expect(config.modNotes, {'Ellen Maid v2': 'the good one'});
      expect((await nextSession()).modNotes, {'Ellen Maid v2': 'the good one'});
    });
  });

  group('one at a time', () {
    test('reaches config.json and survives into a fresh session', () async {
      final config = await build();
      expect(await config.setOneAtATime('ellen', false), isTrue);
      expect(await config.setOneAtATime('cat_ui', true), isTrue);

      expect((await readFile())['one_at_a_time'], {'ellen': false, 'cat_ui': true});
      expect((await nextSession()).oneAtATime, {'ellen': false, 'cat_ui': true});
    });

    test('is empty until a group is switched', () async {
      expect((await build()).oneAtATime, isEmpty);
    });
  });

  test('a wrong-typed entry in a hand-written file costs that entry only', () async {
    await configFile().writeAsString(jsonEncode({
      'mod_notes': {'Ellen Maid': 'ok', 'Broken': 3, 'Empty': ''},
      'one_at_a_time': {'ellen': false, 'cat_ui': 'yes', 'miyabi': true},
    }));

    final config = await build();
    expect(await config.loadFromFile(), isTrue);

    expect(config.modNotes, {'Ellen Maid': 'ok'});
    expect(config.oneAtATime, {'ellen': false, 'miyabi': true});
  });

  test('a key that is not a JSON object is not imported', () async {
    await configFile().writeAsString(jsonEncode({
      'mod_notes': ['Ellen Maid'],
      'one_at_a_time': true,
    }));

    final config = await build();
    expect(await config.loadFromFile(), isTrue);

    expect(config.modNotes, isEmpty);
    expect(config.oneAtATime, isEmpty);
  });
}
