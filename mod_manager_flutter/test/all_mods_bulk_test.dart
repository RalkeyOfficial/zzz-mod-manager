import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/all_mods/all_mods_bulk.dart';

/// What a bulk Enable on the All mods page turns on, and what it leaves for the user to choose.
void main() {
  ModInfo mod(String name, {String characterId = 'ellen', bool active = false}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: active);

  List<String> ids(Iterable<ModInfo> mods) => [for (final m in mods) m.id];

  test('two mods of one agent with One at a time on are both left off', () {
    // Which one to keep is the user's choice, never the app's.
    final plan = planBulkEnable([mod('a'), mod('b')], const {});

    expect(plan.enable, isEmpty);
    expect(plan.leftOff.keys, ['ellen']);
    expect(ids(plan.leftOff['ellen']!), ['a', 'b']);
  });

  test('one mod per agent is enabled', () {
    final plan = planBulkEnable([mod('a'), mod('b', characterId: 'miyabi')], const {});

    expect(ids(plan.enable), ['a', 'b']);
    expect(plan.leftOff, isEmpty);
  });

  test('a category, One at a time off by default, enables together', () {
    final plan = planBulkEnable([mod('hud', characterId: 'cat_ui'), mod('font', characterId: 'cat_ui')], const {});

    expect(ids(plan.enable), ['hud', 'font']);
    expect(plan.leftOff, isEmpty);
  });

  test("an agent whose One at a time the user switched off enables together", () {
    final plan = planBulkEnable([mod('a'), mod('b')], const {'ellen': false});

    expect(ids(plan.enable), ['a', 'b']);
  });

  test('a mod already on is left as it is, and does not count against the others', () {
    final plan = planBulkEnable([mod('on', active: true), mod('b')], const {});

    expect(ids(plan.enable), ['b']);
    expect(plan.leftOff, isEmpty);
  });

  test('the left-off agent does not hold back another', () {
    final plan = planBulkEnable([mod('a'), mod('b'), mod('c', characterId: 'miyabi')], const {});

    expect(ids(plan.enable), ['c']);
    expect(plan.leftOff.keys, ['ellen']);
  });
}
