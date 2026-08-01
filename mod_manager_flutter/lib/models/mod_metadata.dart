import '../utils/zzz_characters.dart';

/// Portable, per-mod metadata stored inside the mod's own folder
/// (`<mod>/.zzz-mod-manager/metadata.json`) so it travels with the mod when it
/// is shared or renamed. This is the source of truth for everything intrinsic
/// to a mod; per-install state (active link, favorite) stays in config.json.
///
/// Note there is deliberately no `==`/`hashCode`: compare field-by-field or via
/// [toJson]. If equality is ever added, [extra] needs a deep comparison
/// (`DeepCollectionEquality`) or it silently degrades to reference identity.
class ModMetadata {
  /// Keys this build understands. Everything else found in the sidecar lands in
  /// [extra] and is written back verbatim.
  ///
  /// **Adding a typed field means adding its key here.** Miss it and the field
  /// round-trips through [extra] as well, shadowing the typed one.
  static const Set<String> knownKeys = {
    'schema_version',
    'description',
    'source_url',
    'tags',
    'character_id',
    'images',
  };

  /// Schema version, so the on-disk format can evolve without breaking old files.
  final int schemaVersion;

  /// Free-form description.
  final String? description;

  /// Link to the mod's source page (GameBanana or any URL).
  final String? sourceUrl;

  /// Arbitrary user tags.
  final List<String> tags;

  /// Character this mod is assigned to (moved here from config.json).
  final String? characterId;

  /// Image paths **relative to the mod folder root** (e.g.
  /// `.zzz-mod-manager/images/01.png`, or a shipped `Preview.png`). The first
  /// entry is treated as the cover.
  final List<String> images;

  /// Sidecar keys this build doesn't recognise — a newer version's fields, or
  /// another tool's. Carried through reads and writes untouched so an older
  /// build never strips a newer one's data. Opaque: never inspected, and never
  /// holding a key in [knownKeys].
  ///
  /// Unmodifiable on every path data actually arrives through — [fromJson] and
  /// [copyWith] both wrap it, and the default is a const literal — so mutating
  /// it throws rather than silently editing a map shared with another instance.
  final Map<String, dynamic> extra;

  static const int currentSchemaVersion = 1;

  const ModMetadata({
    this.schemaVersion = currentSchemaVersion,
    this.description,
    this.sourceUrl,
    this.tags = const [],
    this.characterId,
    this.images = const [],
    this.extra = const {},
  });

  /// True when there is nothing worth persisting. Unknown keys count as content:
  /// they're someone else's data and dropping them is exactly what [extra]
  /// exists to prevent.
  bool get isEmpty =>
      (description == null || description!.isEmpty) &&
      (sourceUrl == null || sourceUrl!.isEmpty) &&
      tags.isEmpty &&
      (characterId == null || characterId!.isEmpty) &&
      images.isEmpty &&
      extra.isEmpty;

  factory ModMetadata.fromJson(Map<String, dynamic> json) {
    final extra = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return ModMetadata(
      schemaVersion: json['schema_version'] as int? ?? currentSchemaVersion,
      description: json['description'] as String?,
      sourceUrl: json['source_url'] as String?,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      characterId: json['character_id'] as String?,
      images: (json['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      extra: Map.unmodifiable(extra),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      if (description != null) 'description': description,
      if (sourceUrl != null) 'source_url': sourceUrl,
      'tags': tags,
      if (characterId != null) 'character_id': characterId,
      'images': images,
      // Unknown keys last, so existing files keep their familiar ordering.
      // Filtered against [knownKeys] rather than against what was emitted
      // above: a null description means the key is genuinely absent and must
      // not be resurrected from a stale entry here.
      for (final entry in extra.entries)
        if (!knownKeys.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Replaces every user-editable field wholesale — so clearing a description
  /// or URL actually removes it — while carrying machine-owned fields
  /// (`schema_version`, and later the origin block) and unknown keys over from
  /// `this`.
  ///
  /// **Call this on the copy read from disk**, not on a fresh instance: `this`
  /// is the only source for the fields being preserved.
  ///
  /// Every parameter is required on purpose. A new user-editable field breaks
  /// the build at each save site (which is what you want — a forgotten one is
  /// erased on the first edit), while a new machine-owned field needs no change
  /// here at all, because this method never touches those.
  ///
  /// [characterId] is normalised through [storedCharacterId], so callers may
  /// hand over the runtime `"unknown"` placeholder without it reaching disk.
  /// Keeping that here rather than at each call site means a future save path
  /// (the marketplace install) can't reintroduce the placeholder by omission.
  ModMetadata replaceUserFields({
    required String? description,
    required String? sourceUrl,
    required List<String> tags,
    required String? characterId,
    required List<String> images,
  }) {
    return ModMetadata(
      schemaVersion: schemaVersion, // machine-owned: from disk
      extra: extra, // unknown: from disk
      description: description,
      sourceUrl: sourceUrl,
      tags: tags,
      characterId: storedCharacterId(characterId),
      images: images,
    );
  }

  ModMetadata copyWith({
    int? schemaVersion,
    String? description,
    String? sourceUrl,
    List<String>? tags,
    String? characterId,
    List<String>? images,
    Map<String, dynamic>? extra,
  }) {
    return ModMetadata(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      description: description ?? this.description,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      tags: tags ?? this.tags,
      characterId: characterId ?? this.characterId,
      images: images ?? this.images,
      extra: extra != null ? Map.unmodifiable(extra) : this.extra,
    );
  }
}
