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
    this.updatesDismissedUntil,
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

  /// "I have seen what this mod published up to here, and I don't want it."
  ///
  /// A **date rather than a file id**, so that it expires by itself: an update
  /// check stays quiet about anything published at or before this instant, and
  /// speaks again the moment the author publishes something newer. A dismissal
  /// keyed on a file id would either be permanent or need re-dismissing per
  /// variant, and neither is what "not this one" means.
  ///
  /// Deliberately *not* a `tracking: "off"`: that answer says the mod is not
  /// from GameBanana at all and silences it forever. This one keeps the mod
  /// tracked and keeps the next release loud.
  final DateTime? updatesDismissedUntil;

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

  /// Value equality over **every** field, deliberately.
  ///
  /// It exists for one caller — the mods screen's "did anything actually
  /// change?" guard, which decides whether a rescan is allowed to push new state
  /// into `charactersProvider`. That guard used to compare `ModInfo` field by
  /// hand-written field, and the origin block was simply missing from the list:
  /// a mod resolved through the resolve dialog was re-read from disk correctly,
  /// judged unchanged, and its card kept showing the amber "needs attention"
  /// mark until the tab was switched away and back.
  ///
  /// So this is exhaustive rather than "the fields something renders today".
  /// Narrowing it to the four the status slot happens to read would recreate the
  /// same bug the first time anything renders a fifth.
  @override
  bool operator ==(Object other) =>
      other is ModOrigin &&
      other.source == source &&
      other.modId == modId &&
      other.modIdConfidence == modIdConfidence &&
      other.fileId == fileId &&
      other.version == version &&
      other.versionLabel == versionLabel &&
      other.versionConfidence == versionConfidence &&
      other.provenance == provenance &&
      other.ingest == ingest &&
      other.installedAt == installedAt &&
      other.installedAtIsProxy == installedAtIsProxy &&
      other.baselineRemoteDate == baselineRemoteDate &&
      other.archiveMd5 == archiveMd5 &&
      other.tracking == tracking &&
      other.remoteMissing == remoteMissing &&
      other.updatesDismissedUntil == updatesDismissedUntil;

  @override
  int get hashCode => Object.hash(
        source,
        modId,
        modIdConfidence,
        fileId,
        version,
        versionLabel,
        versionConfidence,
        provenance,
        ingest,
        installedAt,
        installedAtIsProxy,
        baselineRemoteDate,
        archiveMd5,
        tracking,
        remoteMissing,
        updatesDismissedUntil,
      );

  /// Points this block at remote mod [modId] at [confidence], clearing whatever
  /// only described the *previous* mod.
  ///
  /// **The clearing is the rule, and it lives here so there is one copy of it.**
  /// A `file_id`, a version, a version label and a baseline date are meaningful
  /// only relative to one mod page; carrying them across a rebind would leave a
  /// block asserting that mod B ships file 555 of mod A — and `remote_missing`
  /// was a fact about the old mod too. Two paths rebind (the offline backfill
  /// when a corrected `source_url` names a different mod, and the resolve dialog
  /// when the user says "no, it's this one"), and a rule this easy to get subtly
  /// wrong must not be written twice.
  ///
  /// [archiveMd5] deliberately survives: the hash is a fact about the archive we
  /// extracted, not about which remote mod we currently think it is. That is
  /// exactly what lets a banked hash be matched against the *new* mod's
  /// published checksums.
  ///
  /// Written out longhand rather than through [copyWith], which cannot express
  /// clearing a field.
  ModOrigin boundTo({
    required int modId,
    required OriginConfidence confidence,
    required String source,
  }) {
    final rebinding = this.modId != null && this.modId != modId;
    return ModOrigin(
      source: source,
      modId: modId,
      modIdConfidence: confidence,
      fileId: rebinding ? null : fileId,
      version: rebinding ? null : version,
      versionLabel: rebinding ? null : versionLabel,
      versionConfidence:
          rebinding ? OriginConfidence.unknown : versionConfidence,
      provenance: provenance,
      ingest: ingest,
      installedAt: installedAt,
      installedAtIsProxy: installedAtIsProxy,
      baselineRemoteDate: rebinding ? null : baselineRemoteDate,
      archiveMd5: archiveMd5,
      tracking: tracking,
      remoteMissing: rebinding ? false : remoteMissing,
      // A dismissal is a statement about one mod page's releases, so it means
      // nothing once the folder points at a different mod.
      updatesDismissedUntil: rebinding ? null : updatesDismissedUntil,
    );
  }

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
        if (updatesDismissedUntil != null)
          'updates_dismissed_until':
              updatesDismissedUntil!.toUtc().toIso8601String(),
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
      updatesDismissedUntil: _date(raw['updates_dismissed_until']),
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
    DateTime? updatesDismissedUntil,
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
        updatesDismissedUntil:
            updatesDismissedUntil ?? this.updatesDismissedUntil,
      );

  /// The block after this mod's files were **replaced in place** by a file the
  /// app downloaded and wrote itself.
  ///
  /// Longhand rather than [copyWith] for the same reason [boundTo] is: the
  /// interesting part is what gets *cleared*, and `copyWith` cannot express it.
  /// Three fields go, and each one would otherwise be a lie about the folder as
  /// it now stands:
  ///
  /// - **`baseline_remote_date`** — "I don't know which file, I got it around
  ///   then". We now know exactly which file, so a date-based comparison would
  ///   be a weaker answer sitting beside a stronger one.
  /// - **`updates_dismissed_until`** — the user waved away an update and has now
  ///   taken it. Keeping the dismissal would silence the *next* release too,
  ///   since it is stored as a date at or after this file's.
  /// - **`remote_missing`** — we just fetched the page and a file off it.
  ///
  /// [OriginProvenance.downloaded] is asserted rather than preserved, and that
  /// is honest even for a folder originally imported by hand: whatever it was
  /// before, the bytes in it now came from an archive this app fetched and
  /// extracted. Both confidences reach `exact` on the same grounds a marketplace
  /// install does — the user picked this row of this mod's file list and we
  /// wrote exactly that file id — which is what makes the folder eligible for
  /// unattended updates later.
  ///
  /// [tracking] survives untouched. It is the user's own statement about whether
  /// this mod should be watched at all, and an update is not a reason to
  /// overrule it.
  ModOrigin updatedTo({
    required String source,
    required int modId,
    required int fileId,
    String? version,
    String? versionLabel,
    String? archiveMd5,
    ModIngest? ingest,
    required DateTime installedAt,
  }) =>
      ModOrigin(
        source: source,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
        ingest: ingest ?? this.ingest,
        installedAt: installedAt,
        // Observed, not proxied: we watched it happen.
        archiveMd5: archiveMd5 ?? this.archiveMd5,
        tracking: tracking,
      );

  /// Clears [updatesDismissedUntil], which [copyWith] cannot express.
  ModOrigin withUpdatesUndismissed() => ModOrigin(
        source: source,
        modId: modId,
        modIdConfidence: modIdConfidence,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        provenance: provenance,
        ingest: ingest,
        installedAt: installedAt,
        installedAtIsProxy: installedAtIsProxy,
        baselineRemoteDate: baselineRemoteDate,
        archiveMd5: archiveMd5,
        tracking: tracking,
        remoteMissing: remoteMissing,
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
