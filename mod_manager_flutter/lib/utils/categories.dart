import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'zzz_characters.dart';

/// A mod category. Characters are categories too (resolved via the ZZZ roster in
/// [zzzCharactersData]); the entries here are the built-in *non-character*
/// categories. A mod's category is stored in `ModInfo.characterId` /
/// metadata `character_id` / config `mod_character_tags` — characters and
/// categories share that one id namespace, so no storage change is needed.
class CategoryData {
  final String id; // e.g. 'cat_ui' — `cat_` prefix avoids clashing with
  // character ids (bare names) and synthetic ids ('all'/'__other__').
  final String labelKey; // l10n key, e.g. 'categories.ui'
  final IconData icon;

  const CategoryData({
    required this.id,
    required this.labelKey,
    required this.icon,
  });
}

/// The fixed set of non-character categories. Unlike characters these have no
/// auto-detection aliases — they are only ever assigned manually.
const List<CategoryData> builtInCategories = [
  CategoryData(id: 'cat_ui', labelKey: 'categories.ui', icon: Icons.web_asset),
  CategoryData(
    id: 'cat_texture',
    labelKey: 'categories.texture',
    icon: Icons.texture,
  ),
  CategoryData(
    id: 'cat_audio',
    labelKey: 'categories.audio',
    icon: Icons.audiotrack,
  ),
  CategoryData(
    id: 'cat_misc',
    labelKey: 'categories.misc',
    icon: Icons.category,
  ),
];

/// Whether [id] is one of the built-in non-character categories.
bool isBuiltInCategory(String id) => builtInCategories.any((c) => c.id == id);

/// The built-in category with this [id], or null (e.g. for character ids).
CategoryData? builtInCategoryById(String id) {
  for (final c in builtInCategories) {
    if (c.id == id) return c;
  }
  return null;
}

/// The Material icon for a built-in category, or null for characters / unknown
/// ids (those render a portrait asset instead).
IconData? categoryIcon(String id) => builtInCategoryById(id)?.icon;

/// The row of the Library's character list a mod belongs under: its roster id, its built-in category, or
/// [unknownCharacterId] for an unassigned mod and for an id neither knows (one left behind by a roster rename).
String libraryGroupOf(String characterId) {
  final character = characterById(characterId);
  if (character != null) return character.id;
  if (isBuiltInCategory(characterId)) return characterId;
  return unknownCharacterId;
}

/// Every row of the character list, in the order the fallback page is looked for: the agents, the built-in
/// categories, then unassigned mods. The list itself shows the categories and Unassigned first.
List<String> get libraryGroupIds => [
  ...zzzCharacterIds,
  for (final c in builtInCategories) c.id,
  unknownCharacterId,
];

/// Display name for any category id — a built-in category's localized label, or
/// a character's roster display name (falling back to the id itself).
String categoryDisplayName(String id, AppLocalizations loc) {
  final builtIn = builtInCategoryById(id);
  if (builtIn != null) return loc.t(builtIn.labelKey);
  return getCharacterDisplayName(id);
}
