import 'installed_file.dart';
import 'origin_enums.dart';

/// What one companion download is, relative to the folder's primary.
///
/// **An unrecognised value parses to null and the entry is dropped**, never to
/// a default. Role decides which page the update check treats as the folder's
/// patch and which as the mod it patches, so a future build inventing a third
/// value must not have it read as one of the two this build acts on.
///
/// **These two are the whole set, and that is a decision rather than a gap.**
/// Both describe one relationship — two halves of one thing, one written over
/// the other — which is the only reason a folder holds two downloads. A folder
/// holding two *independent* mods is a shape the app does not support: they
/// share one on/off state, one snapshot and one set of `.ini` files, so
/// activating, updating or rolling back either one acts on both. Wanting two
/// mods handled together is a request for **grouping in the library**, which is
/// a listing concern and belongs nowhere near this sidecar.
enum CompanionRole {
  /// The mod the folder's primary download patches.
  base('base'),

  /// A patch applied into a folder whose primary is the mod itself — the
  /// reverse ordering, produced by an explicit "apply as a patch to…" install.
  patch('patch');

  const CompanionRole(this.wire);

  final String wire;

  static CompanionRole? parse(Object? raw) {
    if (raw is! String) return null;
    for (final role in CompanionRole.values) {
      if (role.wire == raw) return role;
    }
    return null;
  }
}

/// **Migration only.** The shape a sidecar's second download used to be written
/// in, kept so `ModOrigin.migrateFlatBlock` can read one.
///
/// Nothing else may use it, and nothing writes it. A folder is a **stack** now —
/// `ModDownload`, ordered bottom-up, where position is the role — because this
/// shape's role was *relative* to whichever download happened to be installed
/// first, and the same pair of mods therefore produced mirror-image records for
/// two people who did the same thing in a different order. The compensation for
/// that ran through the update check, the write routing, the peer list and the
/// badge, and one operation — taking a patch back out — could not be expressed
/// at all for one of the two orderings.
///
/// The doc below describes the old shape, and is kept because the migration has
/// to know what each field meant.
///
/// ---
///
/// A **second remote identity inside one mod folder**.
///
/// A mod folder is frequently two downloads — a patch plus the mod it patches —
/// and exactly one `origin` block describes it. In the common ordering that
/// block names the *patch*, so a check against it reports nothing newer while
/// the mod the folder actually contains goes versions ahead. This is the other
/// half: what else is in there, and which page to ask about it.
///
/// **It is not a second [ModOrigin], and the six fields it does not carry are
/// the reason.** Each of them describes *this folder's ingest*, and a companion
/// is a statement about a different download that we did not perform:
///
/// - `provenance` — describes how we put the folder here; we didn't put this
///   part of it here.
/// - `ingest` — there was no ingest. The user dragged the files in, or an
///   "apply as a patch to…" install wrote them into a folder that already
///   existed.
/// - `installed_at` / `installed_at_is_proxy` — the folder has one install
///   date, not two.
/// - `source` — one folder, one service. Inherited from the primary block.
/// - `tracking` — "not from GameBanana / it's my own" is a statement about the
///   **folder**. A per-companion mute is a second switch on one card, and the
///   installed-mods index depends on there being exactly one.
///
/// What is left is a remote identity plus what is known about which file of it,
/// and the three per-identity facts that genuinely differ between the two
/// downloads: a baseline date, whether that page has gone, and whether the user
/// has waved its releases away.
class ModCompanion {
  const ModCompanion({
    required this.role,
    required this.modId,
    this.modIdConfidence = OriginConfidence.unknown,
    this.fileId,
    this.version,
    this.versionLabel,
    this.versionConfidence = OriginConfidence.unknown,
    this.archiveMd5,
    this.baselineRemoteDate,
    this.remoteMissing = false,
    this.updatesDismissedUntil,
    this.files = const [],
  });

  final CompanionRole role;

  /// **Required and non-null.** A companion with no identity is nothing — there
  /// is no page to ask about, and the entry costs a line in the sidecar to say
  /// so.
  final int modId;

  /// Normally [OriginConfidence.user]: only the person who assembled the folder
  /// can say what else is in it. [OriginConfidence.exact] is reachable on one
  /// path only — an install that wrote these bytes itself into an existing mod
  /// folder.
  final OriginConfidence modIdConfidence;

  final int? fileId;
  final String? version;
  final String? versionLabel;
  final OriginConfidence versionConfidence;

  /// Present only when we performed the download. Null for an identity the user
  /// named after the fact, which is the common case — the archive is long gone.
  final String? archiveMd5;

  /// "I don't know which file of this one either." Per identity, because the
  /// two downloads arrived at different times.
  final DateTime? baselineRemoteDate;

  final bool remoteMissing;

  /// Per identity, and that is the point: waving away the patch's release must
  /// not silence the base mod's, which is the whole failure this feature
  /// exists to fix.
  final DateTime? updatesDismissedUntil;

  /// **Which files in the folder are this download's**, sized and marked by
  /// whether each went over something — see [InstalledFile].
  ///
  /// Per companion rather than one list on the folder, because a flat list
  /// cannot say whose a file is and one folder can legitimately hold two
  /// patches (which is why [withAppliedPatch] dedupes by mod id). Without the
  /// attribution only "remove every patch" is expressible.
  ///
  /// This is not one of the six fields a companion deliberately does not carry.
  /// Each of those describes *this folder's ingest* — how we came to put the
  /// folder here — and a companion is a statement about a download we did not
  /// perform. What files it laid down is a fact about that download itself.
  ///
  /// **Only ever non-empty where the app wrote the bytes**, which is the install
  /// prompt's `role: patch`. A companion the user named after the fact describes
  /// files somebody moved in by hand: the app never saw them arrive, cannot say
  /// which of the folder's files are theirs, and must not guess — so the list
  /// stays empty and the surfaces that need it degrade honestly.
  final List<InstalledFile> files;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role.wire,
        'mod_id': modId,
        if (modIdConfidence != OriginConfidence.unknown)
          'mod_id_confidence': modIdConfidence.wire,
        if (fileId != null) 'file_id': fileId,
        if (version != null) 'version': version,
        if (versionLabel != null) 'version_label': versionLabel,
        if (versionConfidence != OriginConfidence.unknown)
          'version_confidence': versionConfidence.wire,
        if (archiveMd5 != null) 'archive_md5': archiveMd5,
        if (baselineRemoteDate != null)
          'baseline_remote_date': baselineRemoteDate!.toUtc().toIso8601String(),
        if (remoteMissing) 'remote_missing': true,
        if (updatesDismissedUntil != null)
          'updates_dismissed_until':
              updatesDismissedUntil!.toUtc().toIso8601String(),
        if (files.isNotEmpty)
          'files': [for (final file in files) file.toJson()],
      };

  /// Parses one entry. **Never throws, and returns null for anything it cannot
  /// use** — the caller drops it and keeps the rest of the list.
  ///
  /// Two things make an entry unusable, and both are identity rather than
  /// detail: no parseable `mod_id`, and no recognised `role`. Everything else
  /// degrades to absence, because an entry that still names a page is worth
  /// keeping — the check can ask it and the resolve dialog can fill in the rest.
  ///
  /// A nested `companions` key is ignored rather than parsed: one level, no
  /// tree. A companion describes a download in this folder; it does not get to
  /// describe a folder of its own.
  static ModCompanion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final role = CompanionRole.parse(raw['role']);
    final modId = _int(raw['mod_id']);
    if (role == null || modId == null) return null;
    return ModCompanion(
      role: role,
      modId: modId,
      modIdConfidence: OriginConfidence.parse(raw['mod_id_confidence']),
      fileId: _int(raw['file_id']),
      version: _string(raw['version']),
      versionLabel: _string(raw['version_label']),
      versionConfidence: OriginConfidence.parse(raw['version_confidence']),
      archiveMd5: _string(raw['archive_md5']),
      baselineRemoteDate: _date(raw['baseline_remote_date']),
      remoteMissing: raw['remote_missing'] == true,
      updatesDismissedUntil: _date(raw['updates_dismissed_until']),
      files: InstalledFile.parseList(raw['files']),
    );
  }

  ModCompanion copyWith({
    CompanionRole? role,
    int? modId,
    OriginConfidence? modIdConfidence,
    int? fileId,
    String? version,
    String? versionLabel,
    OriginConfidence? versionConfidence,
    String? archiveMd5,
    DateTime? baselineRemoteDate,
    bool? remoteMissing,
    DateTime? updatesDismissedUntil,
    List<InstalledFile>? files,
  }) =>
      ModCompanion(
        role: role ?? this.role,
        modId: modId ?? this.modId,
        modIdConfidence: modIdConfidence ?? this.modIdConfidence,
        fileId: fileId ?? this.fileId,
        version: version ?? this.version,
        versionLabel: versionLabel ?? this.versionLabel,
        versionConfidence: versionConfidence ?? this.versionConfidence,
        archiveMd5: archiveMd5 ?? this.archiveMd5,
        baselineRemoteDate: baselineRemoteDate ?? this.baselineRemoteDate,
        remoteMissing: remoteMissing ?? this.remoteMissing,
        updatesDismissedUntil:
            updatesDismissedUntil ?? this.updatesDismissedUntil,
        files: files ?? this.files,
      );

  /// Clears [updatesDismissedUntil], which [copyWith] cannot express.
  ModCompanion withUpdatesUndismissed() => ModCompanion(
        role: role,
        modId: modId,
        modIdConfidence: modIdConfidence,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        archiveMd5: archiveMd5,
        baselineRemoteDate: baselineRemoteDate,
        remoteMissing: remoteMissing,
        files: files,
      );

  /// Value equality over **every** field, for the reason [ModOrigin] has it:
  /// the mods screen's rescan guard compares the whole block, so a field left
  /// out here is a card that goes on rendering its old verdict after a write
  /// that actually succeeded.
  @override
  bool operator ==(Object other) =>
      other is ModCompanion &&
      other.role == role &&
      other.modId == modId &&
      other.modIdConfidence == modIdConfidence &&
      other.fileId == fileId &&
      other.version == version &&
      other.versionLabel == versionLabel &&
      other.versionConfidence == versionConfidence &&
      other.archiveMd5 == archiveMd5 &&
      other.baselineRemoteDate == baselineRemoteDate &&
      other.remoteMissing == remoteMissing &&
      other.updatesDismissedUntil == updatesDismissedUntil &&
      _sameFiles(other.files, files);

  static bool _sameFiles(List<InstalledFile> a, List<InstalledFile> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        role,
        modId,
        modIdConfidence,
        fileId,
        version,
        versionLabel,
        versionConfidence,
        archiveMd5,
        baselineRemoteDate,
        remoteMissing,
        updatesDismissedUntil,
        Object.hashAll(files),
      );

  @override
  String toString() => 'ModCompanion(${role.wire} #$modId)';

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    // Tolerated rather than trusted, as on the primary block: a hand-edited or
    // foreign sidecar may hold the string form.
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
