import '../utils/zzz_characters.dart';
import 'mod_origin.dart';

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
    'origin',
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

  /// Where this mod came from — **machine-owned**, never sourced from `ModInfo`.
  ///
  /// Written by the app at ingest time and carried across saves from the file on
  /// disk. See [replaceUserFields] for why that distinction is structural rather
  /// than a convention.
  final ModOrigin? origin;

  /// **2** — the format that carries the `origin` block.
  ///
  /// Strictly, `origin` is an additive key and older builds tolerate it (they
  /// round-trip unrecognised keys through [extra] rather than stripping them),
  /// so nothing *breaks* without a bump. It is here because the version earns
  /// its keep as a statement about what wrote the file: a sidecar saying `2`
  /// with no `origin` means "written by a build that knows about origin — this
  /// mod is genuinely untracked", which is a different fact from a file that
  /// predates the concept, and only the version distinguishes them.
  ///
  /// **The converse does not hold, so don't read it backwards.**
  /// [replaceUserFields] carries the on-disk version across a save, so this
  /// build editing a legacy mod's description rewrites the file still stamped
  /// `1`. A `1` therefore means only "no origin block has ever been written
  /// here" — *not* "this build has never seen this mod", and in particular not
  /// "the offline backfill hasn't swept it yet". The backfill leaves a v1 file
  /// at v1 whenever it finds nothing derivable, which is the common case for a
  /// mod with no `source_url`.
  ///
  /// The rest of this release's metadata work — notably the offline backfill —
  /// lands as **2** as well. Version numbers describe formats users can actually
  /// receive, and nothing here has shipped yet, so the whole unreleased cycle is
  /// one format: a library goes from 1 to 2 in a single step and never observes
  /// anything in between. Bump again only after this ships.
  static const int currentSchemaVersion = 2;

  /// What a sidecar with no `schema_version` at all is assumed to be.
  ///
  /// Pinned to the literal first format, **not** [currentSchemaVersion]: the key
  /// has been written on every save since v1, so its absence means the file
  /// predates versioning entirely. Defaulting it to "current" would stamp the
  /// newest format onto the oldest files — precisely backwards, and it would
  /// quietly make the version untrustworthy for the one job it has.
  static const int assumedSchemaVersion = 1;

  const ModMetadata({
    this.schemaVersion = currentSchemaVersion,
    this.description,
    this.sourceUrl,
    this.tags = const [],
    this.characterId,
    this.images = const [],
    this.extra = const {},
    this.origin,
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
      origin == null &&
      extra.isEmpty;

  factory ModMetadata.fromJson(Map<String, dynamic> json) {
    final extra = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return ModMetadata(
      schemaVersion: json['schema_version'] as int? ?? assumedSchemaVersion,
      description: json['description'] as String?,
      sourceUrl: json['source_url'] as String?,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      characterId: json['character_id'] as String?,
      images: (json['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      origin: ModOrigin.fromJson(json['origin']),
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
      if (origin != null) 'origin': origin!.toJson(),
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
  /// (`schema_version`, `origin`) and unknown keys over from `this`.
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
      origin: origin, // machine-owned: from disk
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
    ModOrigin? origin,
  }) {
    return ModMetadata(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      description: description ?? this.description,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      tags: tags ?? this.tags,
      characterId: characterId ?? this.characterId,
      images: images ?? this.images,
      origin: origin ?? this.origin,
      extra: extra != null ? Map.unmodifiable(extra) : this.extra,
    );
  }

  /// Replaces the origin block outright, **including with null**.
  ///
  /// Separate from [copyWith] because `origin ?? this.origin` cannot express
  /// clearing — the same limitation `characterId` has. Clearing is not a corner
  /// case here: it is how an inbound block from someone else's sidecar is
  /// dropped, which is the one thing standing between a stranger's folder and a
  /// claim of exact confidence.
  ///
  /// Writing an origin also **advances `schema_version`**, because the version
  /// describes the file's contents: leaving a v1 stamp on a file that now holds
  /// an origin block would make the marker say the opposite of what is true.
  /// Uses a max rather than an assignment so a sidecar from a *newer* build is
  /// never downgraded on its way past us.
  ModMetadata withOrigin(ModOrigin? origin) => ModMetadata(
        schemaVersion: origin == null
            ? schemaVersion
            : (schemaVersion > currentSchemaVersion
                ? schemaVersion
                : currentSchemaVersion),
        description: description,
        sourceUrl: sourceUrl,
        tags: tags,
        characterId: characterId,
        images: images,
        origin: origin,
        extra: extra,
      );
}
