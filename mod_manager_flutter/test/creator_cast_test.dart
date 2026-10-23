import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/utils/creator_cast.dart';

import 'support/fixtures.dart';

/// The character tiles of a creator's page, built from real `Generic_Submitter` listings: Exce (member 2307694), 24
/// mods across 20 characters and two Bangboo skins, and summersby (3549585), whose UI and Other/Misc mods are filed
/// directly under the root.
void main() {
  List<GbMod> listing(String name) => parseEnvelope(loadGbFixture(name), GbMod.fromJson).records;

  String label(CreatorGroup group) =>
      group.name ??
      switch (group.labelKey) {
        'marketplace.type_bangboo' => 'Bangboo',
        'marketplace.type_ui' => 'UI',
        'marketplace.type_misc' => 'Misc',
        final key => key!,
      };

  test('every character category of a real listing maps to a roster character', () {
    // The canary: a Character Skins child that maps to nothing would be a tile under its GameBanana name, with no
    // portrait, and the byline would name the category rather than the character.
    final mods = listing('mod_index_submitter_2307694');
    final skins = mods.where((m) => m.rootCategory?.idRow == 30305);
    expect(skins, hasLength(22));
    for (final mod in skins) {
      expect(creatorGroupOf(mod).characterId, isNotNull, reason: mod.subCategory?.name);
      expect(RemoteModMetadata.characterIdForMod(mod), creatorGroupOf(mod).characterId, reason: mod.subCategory?.name);
    }
    // And the other half: a mod of another type maps to no agent, whatever its category is called.
    final others = mods.where((m) => m.rootCategory?.idRow != 30305);
    expect(others, hasLength(2));
    for (final mod in others) {
      expect(RemoteModMetadata.characterIdForMod(mod), isNull, reason: mod.subCategory?.name);
    }
  });

  test('tiles are one per character or type, most mods first, ties by name', () {
    final cast = creatorCast(listing('mod_index_submitter_2307694'), label);
    expect(cast.fold<int>(0, (sum, tile) => sum + tile.count), 24);
    expect(cast.take(4).map((t) => (label(t.group), t.count)), [
      ('Jane Doe', 3),
      // The two Bangboo skins, Eous and Resonaboo, are one tile under the type chip's label.
      ('Bangboo', 2),
      ('Tsukishiro Yanagi', 2),
      ('Astra Yao', 1),
    ]);
    final ones = [for (final t in cast.skip(3)) label(t.group).toLowerCase()];
    expect(ones, [...ones]..sort(), reason: 'the single-mod tiles are in name order');
    expect(cast.where((t) => t.group.characterId == null).map((t) => label(t.group)), ['Bangboo']);
  });

  test('a mod filed directly under a root is that type', () {
    final cast = creatorCast(listing('mod_index_submitter_3549585'), label);
    expect(cast.map((t) => (label(t.group), t.count)), [
      ('Misc', 5),
      ('UI', 2),
      ('Ellen Joe', 1),
      // The roster's name for the character, as the Library shows it, not GameBanana's "Nekomiya Mana".
      ('Nekomata', 1),
    ]);
  });

  test("a profile's category and parent group the same as a listing's", () {
    const misc = GbMod(idRow: 1, category: GbCategoryRef(idRow: 29874, name: 'Other/Misc'));
    const ellen = GbMod(
      idRow: 2,
      category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'),
      superCategory: GbCategoryRef(idRow: 30305, name: 'Character Skins'),
    );
    expect(creatorGroupOf(misc).key, 'type:29874');
    expect(creatorGroupOf(ellen).characterId, 'ellen');
  });

  test("a Bangboo or UI category whose name holds an agent's term is its type, never that agent", () {
    const bangbooCategory = GbCategoryRef(idRow: 30711, name: "Von Lycaon's Bangboo");
    const uiCategory = GbCategoryRef(idRow: 30396, name: 'Ellen Joe HUD');
    // The names alone read as agents, which is what the type has to win against.
    expect(RemoteModMetadata.characterIdForCategory(bangbooCategory.name), 'lycaon');
    expect(RemoteModMetadata.characterIdForCategory(uiCategory.name), 'ellen');

    final mods = [
      // A listing names the root, a profile the parent.
      const GbMod(idRow: 1, subCategory: bangbooCategory, rootCategory: GbCategoryRef(idRow: 30702)),
      const GbMod(idRow: 2, category: bangbooCategory, superCategory: GbCategoryRef(idRow: 30702)),
      const GbMod(idRow: 3, subCategory: uiCategory, rootCategory: GbCategoryRef(idRow: 30395)),
      const GbMod(idRow: 4, category: uiCategory, superCategory: GbCategoryRef(idRow: 30395)),
    ];
    for (final mod in mods) {
      expect(creatorGroupOf(mod).characterId, isNull, reason: 'mod ${mod.idRow}');
      expect(creatorGroupOf(mod).key, 'type:${mod.typeCategoryId}', reason: 'mod ${mod.idRow}');
      // The mod page and the install read the same.
      expect(RemoteModMetadata.characterIdForMod(mod), isNull, reason: 'mod ${mod.idRow}');
      expect(RemoteModMetadata.fromMod(mod).characterId, isNull, reason: 'mod ${mod.idRow}');
    }
  });

  test('a record that names no type maps to no agent, whatever its category is called', () {
    const typeless = GbMod(idRow: 1, category: GbCategoryRef(idRow: 30306, name: 'Ellen Joe'));
    expect(typeless.typeCategoryId, isNull);
    expect(RemoteModMetadata.characterIdForMod(typeless), isNull);
    expect(creatorGroupOf(typeless).characterId, isNull);
  });

  test('the type is read from the parent when a listing root carries no id', () {
    const mod = GbMod(
      idRow: 1,
      category: GbCategoryRef(name: 'Ellen Joe HUD'),
      rootCategory: GbCategoryRef(name: 'UI'),
      superCategory: GbCategoryRef(idRow: kUiCategoryId, name: 'UI'),
    );
    expect(mod.typeCategoryId, kUiCategoryId);
    expect(RemoteModMetadata.characterIdForMod(mod), isNull);
  });

  test("a category's character is worked out once, however many mods and builds ask", () {
    // The page asks for every loaded mod's group on each build, in the tile filter and on each card: up to 1000
    // mods, and the mapping runs a pattern per roster term.
    resetCreatorCastCache();
    final mods = listing('mod_index_submitter_2307694');
    for (var build = 0; build < 3; build++) {
      creatorCast(mods, label);
      mods.forEach(creatorGroupOf);
    }
    final names = {
      for (final mod in mods)
        if (mod.rootCategory?.idRow == 30305) mod.displayCategory?.name,
    };
    expect(creatorCategoryLookups, names.length);
  });
}
