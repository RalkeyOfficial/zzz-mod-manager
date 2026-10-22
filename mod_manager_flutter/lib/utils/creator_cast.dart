import 'package:flutter/foundation.dart';

import '../models/gamebanana/gamebanana.dart';
import '../services/gamebanana/remote_mod_metadata.dart';
import 'marketplace_providers.dart';
import 'zzz_characters.dart';

/// Who or what a mod on a creator's page is for: one character tile, and the name its card's byline shows.
///
/// A Character Skins mod is its character, mapped from the category as an install maps it
/// ([RemoteModMetadata.characterIdForCategory]); a skin whose category maps to no roster character is its category.
/// A mod of any other type, UI, Misc or Bangboo, is that type, whichever of its children it is filed under.
@immutable
class CreatorGroup {
  const CreatorGroup._(this.key, {this.characterId, this.name, this.labelKey});

  /// A roster character.
  factory CreatorGroup.character(CharacterData character) =>
      CreatorGroup._('character:${character.id}', characterId: character.id, name: character.fullName);

  /// A Character Skins child that is no roster character, under its GameBanana name.
  factory CreatorGroup.category(GbCategoryRef category) =>
      CreatorGroup._('category:${category.idRow ?? category.name}', name: category.name ?? '#${category.idRow}');

  /// A type other than Character Skins, under its type chip's label, or the root's own name for a root the chips
  /// don't know.
  factory CreatorGroup.type(int rootId, String? rootName) => switch (kTypeChipLabelKeys[rootId]) {
    final key? => CreatorGroup._('type:$rootId', labelKey: key),
    null => CreatorGroup._('type:$rootId', name: rootName ?? '#$rootId'),
  };

  /// A record that names no category at all.
  static const CreatorGroup unfiled = CreatorGroup._('unfiled', labelKey: 'library.list.unassigned');

  /// Identifies the tile.
  final String key;

  /// The roster id, for a character: its portrait and its element.
  final String? characterId;

  /// The name, or null when [labelKey] is to be looked up.
  final String? name;
  final String? labelKey;

  @override
  bool operator ==(Object other) => other is CreatorGroup && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The roster character each category name maps to, worked out once per name: the mapping runs a pattern per roster
/// term, and the page asks for the group of every loaded mod on each build, in the tile filter and on each card.
final Map<String?, String?> _characterOfCategory = {};

/// How many category names have been mapped since the last [resetCreatorCastCache], for the test that holds the
/// mapping to one per name.
@visibleForTesting
int get creatorCategoryLookups => _lookups;
int _lookups = 0;

@visibleForTesting
void resetCreatorCastCache() {
  _characterOfCategory.clear();
  _lookups = 0;
}

String? _characterIdFor(String? categoryName) => _characterOfCategory.putIfAbsent(categoryName, () {
  _lookups++;
  return RemoteModMetadata.characterIdForCategory(categoryName);
});

/// The group [mod] belongs to on a creator's page.
CreatorGroup creatorGroupOf(GbMod mod) {
  final category = mod.displayCategory;
  final root = mod.rootCategory ?? mod.superCategory;
  // A profile filed directly under a root has no parent: its category is the root.
  final rootId = root?.idRow ?? (kTypeChipLabelKeys.containsKey(category?.idRow) ? category?.idRow : null);
  // The type first, so a Bangboo or a UI mod is never taken for a character whose name its category happens to hold.
  if (rootId != null && rootId != kCharacterSkinsCategoryId) {
    return CreatorGroup.type(rootId, root?.name ?? category?.name);
  }
  final characterId = _characterIdFor(category?.name);
  if (characterId != null) {
    if (characterById(characterId) case final character?) return CreatorGroup.character(character);
  }
  if (category != null && category.idRow != kCharacterSkinsCategoryId) return CreatorGroup.category(category);
  return CreatorGroup.unfiled;
}

/// One tile of a creator's page: a group and how many of the mods are in it.
typedef CreatorTile = ({CreatorGroup group, int count});

/// The tiles for [mods]: one per group, most mods first, and groups with as many by name, as [label] names them.
List<CreatorTile> creatorCast(Iterable<GbMod> mods, String Function(CreatorGroup group) label) {
  final counts = <CreatorGroup, int>{};
  for (final mod in mods) {
    final group = creatorGroupOf(mod);
    counts[group] = (counts[group] ?? 0) + 1;
  }
  final tiles = [for (final entry in counts.entries) (group: entry.key, count: entry.value)];
  tiles.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : label(a.group).toLowerCase().compareTo(label(b.group).toLowerCase());
  });
  return tiles;
}
