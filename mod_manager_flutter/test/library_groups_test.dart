import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/categories.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import 'support/library_override.dart';

/// The rows of the Library's character list: which row a mod is filed under, which row is on screen, what each row
/// counts, and the One at a time default per row.
void main() {
  ModInfo mod(String id, String characterId, {bool active = false}) =>
      ModInfo(id: id, name: id, characterId: characterId, isActive: active);

  ProviderContainer containerWith(List<ModInfo> mods) {
    final container = ProviderContainer(overrides: [libraryOf(mods)]);
    addTearDown(container.dispose);
    return container;
  }

  group('libraryGroupOf', () {
    test('a roster id is its own row, spelled the roster way', () {
      expect(libraryGroupOf('ellen'), 'ellen');
      expect(libraryGroupOf('Ellen'), 'ellen');
    });

    test('a legacy id files under the character it was renamed to', () {
      expect(libraryGroupOf('quinqiy'), 'qingyi');
    });

    test('a built-in category is its own row', () {
      for (final category in builtInCategories) {
        expect(libraryGroupOf(category.id), category.id);
      }
    });

    test('an unassigned or unrecognised id falls under unknown', () {
      expect(libraryGroupOf(''), unknownCharacterId);
      expect(libraryGroupOf(unknownCharacterId), unknownCharacterId);
      expect(libraryGroupOf('cat_shaders'), unknownCharacterId);
      expect(libraryGroupOf('someone_removed'), unknownCharacterId);
    });

    test('the rows are the agents, then the categories, then unknown', () {
      expect(libraryGroupIds, [
        ...zzzCharacterIds,
        'cat_ui',
        'cat_texture',
        'cat_audio',
        'cat_misc',
        unknownCharacterId,
      ]);
    });
  });

  group('One at a time', () {
    test('is on by default for an agent and off for a category', () {
      expect(isOneAtATime(const {}, 'ellen'), isTrue);
      for (final category in builtInCategories) {
        expect(isOneAtATime(const {}, category.id), isFalse, reason: category.id);
      }
    });

    test('unassigned mods have no switch and never turn each other off', () {
      expect(hasOneAtATime(unknownCharacterId), isFalse);
      expect(isOneAtATime(const {}, unknownCharacterId), isFalse);
      expect(isOneAtATime(const {unknownCharacterId: true}, unknownCharacterId), isFalse);
      expect(hasOneAtATime('ellen'), isTrue);
      expect(hasOneAtATime('cat_ui'), isTrue);
    });

    test('a stored choice wins over the default', () {
      expect(isOneAtATime(const {'ellen': false}, 'ellen'), isFalse);
      expect(isOneAtATime(const {'cat_ui': true}, 'cat_ui'), isTrue);
      expect(isOneAtATime(const {'cat_ui': true}, 'cat_audio'), isFalse, reason: 'a choice is per group');
    });
  });

  group('which mods turning one on turns off', () {
    final library = [
      mod('Maid', 'ellen'),
      mod('School', 'ellen', active: true),
      mod('Beach', 'ellen', active: true),
      mod('Swimsuit', 'ellen'),
      mod('Kimono', 'miyabi', active: true),
      mod('Hud', 'cat_ui', active: true),
      mod('Loose', '', active: true),
    ];

    test("the group's other mods that are on, and nothing else", () {
      expect(modsToSwitchOff(library, library.first, const {}), {'School', 'Beach'});
    });

    test('never the mod itself', () {
      final on = mod('School', 'ellen');
      expect(modsToSwitchOff(library, on, const {}), {'Beach'});
    });

    test('nothing when the press turns the mod off', () {
      expect(modsToSwitchOff(library, library[1], const {}), isEmpty);
    });

    test('nothing with the switch off for the group', () {
      expect(modsToSwitchOff(library, library.first, const {'ellen': false}), isEmpty);
      expect(modsToSwitchOff(library, mod('Font', 'cat_ui'), const {}), isEmpty, reason: 'off by default for a category');
    });

    test('a category with the switch on turns its own mods off', () {
      expect(modsToSwitchOff(library, mod('Font', 'cat_ui'), const {'cat_ui': true}), {'Hud'});
    });

    test('a legacy id counts with the character it was renamed to, both ways', () {
      final withLegacy = [mod('Old', 'quinqiy', active: true), mod('New', 'qingyi', active: true)];
      expect(modsToSwitchOff(withLegacy, mod('Newer', 'qingyi'), const {}), {'Old', 'New'});
      expect(modsToSwitchOff(withLegacy, mod('Older', 'quinqiy'), const {}), {'Old', 'New'});
    });

    test('unassigned mods never turn each other off', () {
      expect(modsToSwitchOff(library, mod('Other loose', ''), const {unknownCharacterId: true}), isEmpty);
    });
  });

  group('the row on screen', () {
    test('is the one picked, even with no mods', () {
      final container = containerWith([mod('a', 'ellen')]);
      container.read(selectedCharacterIdProvider.notifier).state = 'miyabi';
      expect(container.read(currentCharacterIdProvider), 'miyabi');
    });

    test('is otherwise the first agent in roster order with a mod', () {
      final container = containerWith([mod('a', 'miyabi'), mod('b', 'cat_ui'), mod('c', 'ellen')]);
      expect(container.read(currentCharacterIdProvider), 'ellen');
    });

    test('is the first category with a mod when no agent has one', () {
      final container = containerWith([mod('a', 'cat_audio'), mod('b', 'cat_ui')]);
      expect(container.read(currentCharacterIdProvider), 'cat_ui');
    });

    test('is unknown when only unassigned mods exist', () {
      final container = containerWith([mod('a', unknownCharacterId)]);
      expect(container.read(currentCharacterIdProvider), unknownCharacterId);
    });

    test('is the first agent when the library is empty', () {
      expect(containerWith(const []).read(currentCharacterIdProvider), zzzCharacterIds.first);
    });

    test("holds the row's mods, a legacy id included", () {
      final container = containerWith([mod('a', 'qingyi'), mod('b', 'quinqiy'), mod('c', 'ellen')]);
      container.read(selectedCharacterIdProvider.notifier).state = 'qingyi';
      expect(container.read(currentCharacterSkinsProvider).map((m) => m.id), ['a', 'b']);
    });
  });

  group('row counts', () {
    test('count mods and active mods per row, and leave out rows with none', () {
      final container = containerWith([
        mod('a', 'ellen', active: true),
        mod('b', 'ellen'),
        mod('c', 'cat_ui', active: true),
        mod('d', ''),
      ]);
      final counts = container.read(libraryGroupCountsProvider);

      expect(counts.keys, unorderedEquals(['ellen', 'cat_ui', unknownCharacterId]));
      expect(counts['ellen']!.mods, 2);
      expect(counts['ellen']!.active, 1);
      expect(counts['cat_ui']!.mods, 1);
      expect(counts['cat_ui']!.active, 1);
      expect(counts[unknownCharacterId]!.mods, 1);
      expect(counts.containsKey('miyabi'), isFalse);
    });

    test('count updates from the last check, an ignored one left out', () {
      final container = containerWith([mod('a', 'ellen'), mod('b', 'ellen'), mod('c', 'miyabi')]);
      container.read(modUpdateChecksProvider.notifier).state = {
        'a': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        'b': const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true),
        'c': const UpdateCheck(outcome: UpdateOutcome.upToDate),
      };
      final counts = container.read(libraryGroupCountsProvider);

      expect(counts['ellen']!.updates, 1);
      expect(counts['miyabi']!.updates, 0);
    });
  });

  group('roster', () {
    test('every agent but the two Proxies has an attribute, a specialty and a faction', () {
      // Fill in the attribute and drop the id from here once it is announced.
      const unannounced = {'sunbringer'};
      expect(zzzCharactersData.where((c) => c.isProxy).map((c) => c.id), ['belle', 'wise']);
      for (final c in zzzCharactersData) {
        expect(c.faction, isNotNull, reason: '${c.id} has no faction');
        if (c.isProxy) {
          expect(c.attribute, isNull, reason: c.id);
          expect(c.specialty, isNull, reason: c.id);
          continue;
        }
        if (unannounced.contains(c.id)) {
          expect(c.attribute, isNull, reason: '${c.id} has an attribute now; drop it from unannounced');
        } else {
          expect(c.attribute, isNotNull, reason: '${c.id} has no attribute');
        }
        expect(c.specialty, isNotNull, reason: '${c.id} has no specialty');
      }
    });

    test('the full name is the real name only where it lengthens the brief one', () {
      expect(characterById('ellen')!.fullName, 'Ellen Joe');
      expect(characterById('seed')!.fullName, 'Seed', reason: "Flora doesn't contain Seed");
      expect(characterById('nekomata')!.fullName, 'Nekomata', reason: "Nekomiya Mana doesn't contain Nekomata");
      expect(characterById('astra')!.fullName, 'Astra Yao', reason: 'no real name');
    });

    test('initials take two words, or two letters of one', () {
      expect(nameInitials('Ellen Joe'), 'EJ');
      expect(nameInitials('Qingyi'), 'QI');
      expect(nameInitials('Soldier 0 - Anby'), 'S0');
      expect(nameInitials('x'), 'X');
      expect(nameInitials('  '), '?');
    });
  });
}
