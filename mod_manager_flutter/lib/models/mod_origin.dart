import 'mod_ingest.dart';
import 'origin_enums.dart';

/// Where a mod came from, which remote file it is, and how sure we are.
///
/// **Machine-owned.** It is written by the app at ingest time and carried across
/// saves from the file on disk — never sourced from `ModInfo`. Routing it
/// through the runtime view is exactly what would let an unrelated edit (the
/// user changing a description) reconstruct the sidecar without it and silently
/// erase the block.
///
/// Identity ("which remote mod is this?") and version ("which file of it?")
/// resolve independently and carry **separate** confidences: identity is often
/// recoverable offline by parsing a stored url, while version almost never is,
/// because the archive is deleted after extraction.
class ModOrigin {
  const ModOrigin({
    this.source,
    this.modId,
    this.modIdConfidence = OriginConfidence.unknown,
    this.fileId,
    this.version,
    this.versionLabel,
    this.versionConfidence = OriginConfidence.unknown,
    required this.provenance,
    this.ingest,
    this.installedAt,
    this.installedAtIsProxy = false,
    this.baselineRemoteDate,
    this.archiveMd5,
    this.tracking = OriginTracking.auto,
    this.remoteMissing = false,
  });

  /// Which service, e.g. `gamebanana`. Null when the mod isn't tracked.
  final String? source;

  /// The remote mod id — a stable handle to re-query, far more reliable than a
  /// user-editable url.
  final int? modId;

  final OriginConfidence modIdConfidence;

  /// Which *file* of that mod is installed. A mod publishes many.
  final int? fileId;

  /// The installed version string, when known.
  final String? version;

  /// The file's free-text variant label ("white hair ver", "Full Mod").
  /// Distinct from [version]; conflating them makes two variants of one release
  /// look like two releases.
  final String? versionLabel;

  final OriginConfidence versionConfidence;

  /// Where the folder came from. Always known — we performed the ingest.
  final OriginProvenance provenance;

  /// How the archive became folders.
  final ModIngest? ingest;

  /// When this mod was installed.
  final DateTime? installedAt;

  /// True when [installedAt] was derived from file timestamps rather than
  /// observed. A backfilled proxy can read years early for a hand-copied
  /// library, so anything comparing dates needs to know which it has.
  final bool installedAtIsProxy;

  /// For [OriginConfidence.assumedLatest]: only flag remote files newer than
  /// this.
  final DateTime? baselineRemoteDate;

  /// md5 of the archive this was extracted from.
  ///
  /// A **matching key, never an integrity or authenticity claim** — see
  /// `services/archive_hash.dart`. Null-or-exact: a miss teaches us nothing and
  /// costs nothing.
  final String? archiveMd5;

  final OriginTracking tracking;

  /// The mod is gone upstream (private, trashed or withheld). Read from the
  /// remote's explicit flags rather than inferred from a 404, and distinct from
  /// the author merely flagging it superseded.
  final bool remoteMissing;

  /// Whether an unattended update may overwrite this mod's files.
  ///
  /// Both axes must be exact: knowing the mod but not the file is not enough to
  /// know what to replace it with.
  bool get allowsUnattendedUpdate =>
      tracking == OriginTracking.auto &&
      !remoteMissing &&
      modIdConfidence.allowsUnattendedUpdate &&
      versionConfidence.allowsUnattendedUpdate;

  /// Whether we know which remote mod this is at all.
  bool get hasIdentity => modId != null;

  /// Emits only what differs from the read-side defaults.
  ///
  /// Absence already means "default" on read, so writing `"remote_missing":
  /// false` and `"version_confidence": "unknown"` into every sidecar would add
  /// noise to a file users can open, without adding information.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (source != null) 'source': source,
        if (modId != null) 'mod_id': modId,
        if (modIdConfidence != OriginConfidence.unknown)
          'mod_id_confidence': modIdConfidence.wire,
        if (fileId != null) 'file_id': fileId,
        if (version != null) 'version': version,
        if (versionLabel != null) 'version_label': versionLabel,
        if (versionConfidence != OriginConfidence.unknown)
          'version_confidence': versionConfidence.wire,
        'provenance': provenance.wire,
        if (ingest != null && !ingest!.isEmpty) 'ingest': ingest!.toJson(),
        if (installedAt != null)
          'installed_at': installedAt!.toUtc().toIso8601String(),
        if (installedAtIsProxy) 'installed_at_is_proxy': true,
        if (baselineRemoteDate != null)
          'baseline_remote_date': baselineRemoteDate!.toUtc().toIso8601String(),
        if (archiveMd5 != null) 'archive_md5': archiveMd5,
        if (tracking != OriginTracking.auto) 'tracking': tracking.wire,
        if (remoteMissing) 'remote_missing': true,
      };

  /// Parses a stored block. **Never throws, for any input.**
  ///
  /// This matters more than it looks. A sidecar travels with its mod folder, so
  /// one can arrive from a stranger carrying anything at all — including
  /// `"mod_id": "123"`. A cast that threw here would propagate out through
  /// `ModMetadata.fromJson` into `ModMetadataService.read`, which catches and
  /// returns null; because that method cannot distinguish "missing" from
  /// "corrupt", the sidecar would then be treated as absent and **replaced
  /// wholesale on the next save**, destroying the user's own description, tags
  /// and images. Typing this field is what opens that path; parsing
  /// defensively is what closes it.
  ///
  /// Returns null when the value isn't an object at all — machine-owned garbage
  /// is dropped rather than round-tripped, unlike genuinely unknown keys.
  static ModOrigin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ModOrigin(
      source: _string(raw['source']),
      modId: _int(raw['mod_id']),
      modIdConfidence: OriginConfidence.parse(raw['mod_id_confidence']),
      fileId: _int(raw['file_id']),
      version: _string(raw['version']),
      versionLabel: _string(raw['version_label']),
      versionConfidence: OriginConfidence.parse(raw['version_confidence']),
      provenance: OriginProvenance.parse(raw['provenance']),
      ingest: ModIngest.fromJson(raw['ingest']),
      installedAt: _date(raw['installed_at']),
      installedAtIsProxy: raw['installed_at_is_proxy'] == true,
      baselineRemoteDate: _date(raw['baseline_remote_date']),
      archiveMd5: _string(raw['archive_md5']),
      tracking: OriginTracking.parse(raw['tracking']),
      remoteMissing: raw['remote_missing'] == true,
    );
  }

  ModOrigin copyWith({
    String? source,
    int? modId,
    OriginConfidence? modIdConfidence,
    int? fileId,
    String? version,
    String? versionLabel,
    OriginConfidence? versionConfidence,
    OriginProvenance? provenance,
    ModIngest? ingest,
    DateTime? installedAt,
    bool? installedAtIsProxy,
    DateTime? baselineRemoteDate,
    String? archiveMd5,
    OriginTracking? tracking,
    bool? remoteMissing,
  }) =>
      ModOrigin(
        source: source ?? this.source,
        modId: modId ?? this.modId,
        modIdConfidence: modIdConfidence ?? this.modIdConfidence,
        fileId: fileId ?? this.fileId,
        version: version ?? this.version,
        versionLabel: versionLabel ?? this.versionLabel,
        versionConfidence: versionConfidence ?? this.versionConfidence,
        provenance: provenance ?? this.provenance,
        ingest: ingest ?? this.ingest,
        installedAt: installedAt ?? this.installedAt,
        installedAtIsProxy: installedAtIsProxy ?? this.installedAtIsProxy,
        baselineRemoteDate: baselineRemoteDate ?? this.baselineRemoteDate,
        archiveMd5: archiveMd5 ?? this.archiveMd5,
        tracking: tracking ?? this.tracking,
        remoteMissing: remoteMissing ?? this.remoteMissing,
      );

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    // Tolerated rather than trusted: a hand-edited or foreign sidecar may hold
    // the string form, and refusing it loudly would cost the user their file.
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
