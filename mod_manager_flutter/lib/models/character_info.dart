import 'package:flutter/widgets.dart';

import 'keybind_info.dart';
import 'mod_origin.dart';

/// Модель даних для персонажа (also used for non-character categories, which
/// carry an [icon] instead of an [iconPath] portrait asset).
class CharacterInfo {
  final String id;
  final String name;
  final String? iconPath;
  final IconData? icon; // Material icon for built-in (non-character) categories.
  final List<ModInfo> skins;
  final CharacterKeybinds? keybinds;

  CharacterInfo({
    required this.id,
    required this.name,
    this.iconPath,
    this.icon,
    this.skins = const [],
    this.keybinds,
  });

  CharacterInfo copyWith({
    String? id,
    String? name,
    String? iconPath,
    IconData? icon,
    List<ModInfo>? skins,
    CharacterKeybinds? keybinds,
  }) {
    return CharacterInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      iconPath: iconPath ?? this.iconPath,
      icon: icon ?? this.icon,
      skins: skins ?? this.skins,
      keybinds: keybinds ?? this.keybinds,
    );
  }
}

/// Модель даних для скіна персонажа
class ModInfo {
  final String id;
  final String name;
  final String characterId;
  final bool isActive;

  /// Cover image (absolute path). Equals the first entry of [images] when set.
  final String? imagePath;
  final String? description;

  /// Link to the mod's source page (GameBanana or any URL).
  final String? sourceUrl;

  /// User tags.
  final List<String> tags;

  /// All gallery images (absolute paths); the first is the cover.
  final List<String> images;
  final bool isFavorite;
  final List<KeybindInfo>? keybinds;

  /// Where this mod came from, as read from its sidecar — **read-only here.**
  ///
  /// Machine-owned, and this is the one field on `ModInfo` that never travels
  /// back to disk. The save path reads the sidecar and calls
  /// [ModMetadata.replaceUserFields], which carries `origin` over from the file
  /// and takes no `origin` parameter, so there is no route by which a value set
  /// here could be persisted. Mutate it in memory and the change is simply lost
  /// on the next scan.
  ///
  /// That distinction is why carrying it here is safe. An earlier decision
  /// banned `origin` from `ModInfo` outright, because at the time `save()` built
  /// a fresh `ModMetadata` out of the runtime view — so an unrelated description
  /// edit rebuilt the sidecar without the block and silently erased it. That
  /// hole was closed structurally before anything wrote an origin block; the
  /// remaining alternative was for every status badge to re-read all ~80
  /// sidecars to redraw data the scan had already parsed and thrown away. See
  /// `docs/metadata-schema.md` §3.
  final ModOrigin? origin;

  ModInfo({
    required this.id,
    required this.name,
    required this.characterId,
    required this.isActive,
    this.imagePath,
    this.description,
    this.sourceUrl,
    this.tags = const [],
    this.images = const [],
    this.isFavorite = false,
    this.keybinds,
    this.origin,
  });

  ModInfo copyWith({
    String? id,
    String? name,
    String? characterId,
    bool? isActive,
    String? imagePath,
    String? description,
    String? sourceUrl,
    List<String>? tags,
    List<String>? images,
    bool? isFavorite,
    List<KeybindInfo>? keybinds,
    ModOrigin? origin,
  }) {
    return ModInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      characterId: characterId ?? this.characterId,
      isActive: isActive ?? this.isActive,
      imagePath: imagePath ?? this.imagePath,
      description: description ?? this.description,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      tags: tags ?? this.tags,
      images: images ?? this.images,
      isFavorite: isFavorite ?? this.isFavorite,
      keybinds: keybinds ?? this.keybinds,
      // Carried, not clearable — the mods screen rebuilds mods through
      // `copyWith` on every editorial action, and dropping the block there would
      // make a mod's status slot flicker to "untracked" until the next scan.
      origin: origin ?? this.origin,
    );
  }
}
