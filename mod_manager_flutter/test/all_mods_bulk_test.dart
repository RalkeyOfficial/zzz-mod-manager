import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/all_mods/all_mods_bulk.dart';

/// What a bulk Enable on the All mods page turns on, and what it leaves for the user to choose.
void main() {
  ModInfo mod(String name, {String characterId = 'ellen', bool active = false}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: active);

  List<String> ids(Iterable<ModInfo> mods) => [for (final m in mods) m.id];

  /// With Settings' One active mod per character on, as it starts.
  BulkEnablePlan plan(List<ModInfo> selected, [Map<String, bool> choices = const {}, bool agentsDefault = true]) =>
      planBulkEnable(selected, choices, agentsDefault: agentsDefault);

  test('two mods of one agent with One at a time on are both left off', () {
    // Which one to keep is the user's choice, never the app's.
    final result = plan([mod('a'), mod('b')]);

    expect(result.enable, isEmpty);
    expect(result.leftOff.keys, ['ellen']);
    expect(ids(result.leftOff['ellen']!), ['a', 'b']);
  });

  test('one mod per agent is enabled', () {
    final result = plan([mod('a'), mod('b', characterId: 'miyabi')]);

    expect(ids(result.enable), ['a', 'b']);
    expect(result.leftOff, isEmpty);
  });

  test('a category, One at a time off by default, enables together', () {
    final result = plan([mod('hud', characterId: 'cat_ui'), mod('font', characterId: 'cat_ui')]);

    expect(ids(result.enable), ['hud', 'font']);
    expect(result.leftOff, isEmpty);
  });

  test("an agent whose One at a time the user switched off enables together", () {
    final result = plan([mod('a'), mod('b')], const {'ellen': false});

    expect(ids(result.enable), ['a', 'b']);
  });

  test("with Settings' default off, an agent the user hasn't switched enables together", () {
    final result = plan([mod('a'), mod('b')], const {}, false);

    expect(ids(result.enable), ['a', 'b']);
    expect(result.leftOff, isEmpty);
  });

  test("with Settings' default off, an agent the user switched on is still left off", () {
    final result = plan([mod('a'), mod('b')], const {'ellen': true}, false);

    expect(result.enable, isEmpty);
    expect(ids(result.leftOff['ellen']!), ['a', 'b']);
  });

  test('a mod already on is left as it is, and does not count against the others', () {
    final result = plan([mod('on', active: true), mod('b')]);

    expect(ids(result.enable), ['b']);
    expect(result.leftOff, isEmpty);
  });

  test('the left-off agent does not hold back another', () {
    final result = plan([mod('a'), mod('b'), mod('c', characterId: 'miyabi')]);

    expect(ids(result.enable), ['c']);
    expect(result.leftOff.keys, ['ellen']);
  });
}
