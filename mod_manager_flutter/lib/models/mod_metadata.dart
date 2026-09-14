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
  ///
  /// `source_url` is here for the opposite reason, and it is the one key this
  /// build reads and never writes: leaving it out would make every existing
  /// file's copy an unknown key, preserved forever by the very rule above. See
  /// [sourceUrl].
  static const Set<String> knownKeys = {
    'schema_version',
    'uid',
    'description',
    'source_url',
    'tags',
    'character_id',
    'images',
    'origin',
  };

  /// Schema version, so the on-disk format can evolve without breaking old files.
  final int schemaVersion;

  /// **This folder's identity, for the things that have to outlive its name.**
  ///
  /// Opaque, machine-owned, and never parsed — 32 hex characters from
  /// `Random.secure()`. Its only job is to be the same string tomorrow.
  ///
  /// The folder name cannot do that job. It is the install identity everything
  /// else keys by (`active_mods`, `favorite_mods`, `mod_character_tags`), and
  /// **renaming outside the app is not an event this app can see** — no hook
  /// runs, so anything filed under the old name is stranded silently. Saved
  /// versions are the one thing where that costs gigabytes, so they key by this
  /// instead and a rename becomes a non-event, in the app or out of it.
  ///
  /// Written **at install**, and given to a library that predates identities on
  /// the scan that reads it (`ModUid`, `loadOrMigrate`). An inbound one is
  /// dropped rather than inherited, exactly as [origin] is: a shared folder
  /// arrives carrying its author's, and keeping it would hand two mods one
  /// history. Null only for a folder that cannot be written.
  ///
  /// Two things it deliberately does not fix, because the folder name is the
  /// right identity for them: per-install state in `config.json` (a rename
  /// through the app migrates it, and an outside rename costs a favourite star
  /// rather than a library), and telling apart two copies of one folder made
  /// **outside** the app — those carry one uid, and the scan would have to
  /// notice.
  final String? uid;

  /// Free-form description.
  final String? description;

  /// **Read from the file, and written back only while nothing else names the
  /// mod** — the one input the offline backfill has.
  ///
  /// It was the mod's page as a user-editable link, which is a second answer to
  /// "which mod is this?" beside `origin.mod_id` — one the user could edit and
  /// which drove nothing, while the one that drives the update check could not
  /// be edited at all. The block answers it now, and every surface that shows a
  /// link derives it from there (`utils/url_utils.dart`).
  ///
  /// What survives is the migration: a sidecar written before the block existed
  /// carries this, and `OriginBackfill` parses a `mod_id` out of it
  /// ([`origin-tracking.md`](../../docs/origin-tracking.md) §3). So the key
  /// leaves a file the moment the block names a mod, and stays in one where it
  /// does not — a url naming no mod page is kept rather than discarded, since a
  /// later build may parse what this one cannot, and dropping it while it is
  /// still the only candidate would end the migration mid-scan.
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
    this.uid,
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
  ///
  /// [sourceUrl] does not count, because nothing here would write it: a file
  /// holding only that has nothing this build would put back.
  bool get isEmpty =>
      (description == null || description!.isEmpty) &&
      tags.isEmpty &&
      (characterId == null || characterId!.isEmpty) &&
      images.isEmpty &&
      origin == null &&
      // A folder whose only content is its identity is still worth a sidecar:
      // the identity is what its saved versions are filed under, and losing it
      // strands them where nothing can ever claim them again.
      uid == null &&
      extra.isEmpty;

  factory ModMetadata.fromJson(Map<String, dynamic> json) {
    final extra = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return ModMetadata(
      schemaVersion: json['schema_version'] as int? ?? assumedSchemaVersion,
      uid: json['uid'] as String?,
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
      if (uid != null) 'uid': uid,
      if (description != null) 'description': description,
      // **Kept only while it is still the only thing that names the mod.** Once
      // the block carries an id the key has done its job and leaves the file on
      // this save; until then dropping it would throw away the backfill's only
      // input — and a user's edit landing mid-scan is exactly when that
      // happens. See [sourceUrl].
      if (sourceUrl != null && origin?.base?.modId == null)
        'source_url': sourceUrl,
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
  /// erased on the first edit).
  ///
  /// **A new machine-owned field has to be carried here explicitly**, because
  /// this builds a fresh instance: one left off the list defaults to null and
  /// is erased the first time anyone edits a description. That is the hole
  /// `ModInfo.origin`'s doc describes having already been paid for once, and
  /// [sourceUrl] is carried on the same terms — an edit landing before the
  /// backfill has run must not take its only input away.
  ///
  /// [characterId] is normalised through [storedCharacterId], so callers may
  /// hand over the runtime `"unknown"` placeholder without it reaching disk.
  /// Keeping that here rather than at each call site means a future save path
  /// (the marketplace install) can't reintroduce the placeholder by omission.
  ModMetadata replaceUserFields({
    required String? description,
    required List<String> tags,
    required String? characterId,
    required List<String> images,
  }) {
    return ModMetadata(
      schemaVersion: schemaVersion, // machine-owned: from disk
      uid: uid, // machine-owned: from disk
      origin: origin, // machine-owned: from disk
      sourceUrl: sourceUrl, // legacy input: from disk, see [sourceUrl]
      extra: extra, // unknown: from disk
      description: description,
      tags: tags,
      characterId: storedCharacterId(characterId),
      images: images,
    );
  }

  ModMetadata copyWith({
    int? schemaVersion,
    String? uid,
    String? description,
    List<String>? tags,
    String? characterId,
    List<String>? images,
    Map<String, dynamic>? extra,
    ModOrigin? origin,
  }) {
    return ModMetadata(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      uid: uid ?? this.uid,
      description: description ?? this.description,
      sourceUrl: sourceUrl, // no parameter: nothing in this build sets one
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
        uid: uid,
        description: description,
        sourceUrl: sourceUrl,
        tags: tags,
        characterId: characterId,
        images: images,
        origin: origin,
        extra: extra,
      );
}
