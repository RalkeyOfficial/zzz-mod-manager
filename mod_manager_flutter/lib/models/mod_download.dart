import '../services/log/logger.dart';
import 'installed_file.dart';
import 'origin_enums.dart';

/// One tag rather than a logger per model: a role that disagrees with its
/// position is a fact about a **file**, and a reader chasing it wants every such
/// line together.
final Logger _log = Logger('sidecar');

/// Where a download sits in the folder's stack.
///
/// **Position is the truth and this tag is a check on it.** The list is ordered
/// bottom-up, so index 0 is [base] and everything above it is a [patch]; the tag
/// is written from the position every time. On read, a tag that disagrees with
/// its index **loses** — and says so in the log, which is the whole reason it is
/// stored. A sidecar is a file users can open and share, so a hand edit that
/// reorders the list would otherwise change what every entry means in silence.
///
/// It is also what makes the file legible. `"role": "patch"` on the second entry
/// tells a reader what the ordering means without them having to know the rule.
enum DownloadRole {
  /// The bottom of the stack — what everything above it is written over.
  ///
  /// **Not the same as "is a whole mod".** For a folder the app recognised as
  /// patch-shaped and whose real base nobody has named, the patch is the bottom
  /// of the stack that exists and carries this role; `ingest.patch_shaped` is
  /// the separate fact that the folder's own ingest was a patch. Position
  /// cannot express that, so the flag does — and it survives being told what
  /// the patch applies to, because what was ingested does not change.
  base('base'),

  /// Written over what is below it, replacing some of those files and adding
  /// others.
  patch('patch');

  const DownloadRole(this.wire);

  final String wire;

  /// The role an entry at [index] must have.
  static DownloadRole forIndex(int index) =>
      index == 0 ? DownloadRole.base : DownloadRole.patch;

  /// Null for anything unrecognised, so a disagreement is distinguishable from
  /// a value this build has never heard of. Both lose to the index either way.
  static DownloadRole? parse(Object? raw) {
    if (raw is! String) return null;
    for (final role in DownloadRole.values) {
      if (role.wire == raw) return role;
    }
    return null;
  }
}

/// **One download in a mod folder**: which remote file it is, how sure we are,
/// and which files it laid down.
///
/// A mod folder is a **stack of downloads** — written bottom-up, each laying
/// files down and overwriting what the ones below it put there. That is the
/// whole physical truth of a mixed folder, and this is one layer of it.
///
/// Every layer carries the same fields. There is no reduced type for "the other
/// ones", because there is no privileged one: which download a person happened
/// to install first is not a fact about the folder, and a model that recorded it
/// as one made the same pair of mods read differently for two users who did the
/// same thing in a different order.
///
/// What stays **outside** this list, on [ModOrigin] itself, is what a folder has
/// exactly one of: the service, how it got here, when it was installed, the
/// archive layout to replay, and whether the user wants it watched at all. A
/// per-layer mute would be a second switch on one card, and the installed-mods
/// index depends on there being exactly one.
class ModDownload {
  const ModDownload({
    this.role = DownloadRole.base,
    this.modId,
    this.modIdConfidence = OriginConfidence.unknown,
    this.fileId,
    this.version,
    this.versionLabel,
    this.versionConfidence = OriginConfidence.unknown,
    this.archiveMd5,
    this.baselineRemoteDate,
    this.remoteMissing = false,
    this.updatesDismissedUntil,
    this.files = const <InstalledFile>[],
  });

  /// Redundant with this entry's index — see [DownloadRole].
  final DownloadRole role;

  /// The remote mod id, or null when nobody knows which mod this is.
  ///
  /// **Nullable on every layer, including a patch.** A patch the app wrote into
  /// a folder from a local archive has no page — but the install still knows
  /// exactly which files it laid down, so the layer is worth recording: it gets
  /// set aside when the base updates and it can be taken back out. What it
  /// cannot do is be checked for updates, and that follows from the null rather
  /// than needing to be said anywhere else.
  final int? modId;

  final OriginConfidence modIdConfidence;

  /// Which *file* of that mod this is. A mod publishes many.
  final int? fileId;

  final String? version;

  /// The author's free-text variant marker ("white hair ver"). **Never
  /// conflated with [version]** — that makes two variants of one release look
  /// like two releases.
  final String? versionLabel;

  final OriginConfidence versionConfidence;

  /// md5 of the archive this layer came from. A **matching key, never an
  /// integrity claim**. Null for bytes the app did not fetch.
  final String? archiveMd5;

  /// For [OriginConfidence.assumedLatest]: only flag remote files newer than
  /// this. Per layer, because the two downloads arrived at different times.
  final DateTime? baselineRemoteDate;

  /// This layer's page is gone upstream. Read from the remote's explicit flags,
  /// never inferred from a 404.
  final bool remoteMissing;

  /// "I have seen what this mod published up to here and I don't want it."
  ///
  /// Per layer, and that is the point: waving away the patch's release must not
  /// silence the mod it patches.
  final DateTime? updatesDismissedUntil;

  /// **Which files in the folder this layer put there**, sized and marked by
  /// whether each went over something — see [InstalledFile].
  ///
  /// What makes the stack actionable rather than merely descriptive: it is how a
  /// layer is set aside for an update to the one below it, and how it is taken
  /// back out. Empty means **unknown**, never "this layer wrote nothing" —
  /// everything installed before the record existed has none, and it cannot be
  /// reconstructed, since a folder assembled from two downloads looks exactly
  /// like one that came from a single archive.
  final List<InstalledFile> files;

  /// Whether this layer can be asked about at all.
  bool get hasIdentity => modId != null;

  /// Whether the app knows which of the folder's files are this layer's.
  bool get hasFileRecord => files.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role.wire,
        if (modId != null) 'mod_id': modId,
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

  /// Parses one layer at [index], whose role it takes from that index.
  ///
  /// **Never throws, and returns null only for something that is not an object
  /// at all.** Unlike the old companion type there is no identity requirement:
  /// a layer with no mod id is a download nobody can name, which is a thing that
  /// happens and is worth recording. What makes an entry worthless is carrying
  /// neither an identity nor a file list, and that is checked by the caller,
  /// which is the only place that knows what the other entries hold.
  static ModDownload? fromJson(Object? raw, {required int index}) {
    if (raw is! Map) return null;
    final declared = DownloadRole.parse(raw['role']);
    final actual = DownloadRole.forIndex(index);
    if (declared != null && declared != actual) {
      _log.warning('a recorded download role disagrees with its position',
          fields: {
            'index': index,
            'declared': declared.wire,
            'position': actual.wire,
          });
    }
    return ModDownload(
      // The index wins, always. See [DownloadRole].
      role: actual,
      modId: _int(raw['mod_id']),
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

  ModDownload copyWith({
    DownloadRole? role,
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
      ModDownload(
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

  /// Points this layer at [modId], clearing whatever only described the mod it
  /// used to name.
  ///
  /// **The clearing is the rule and this is its one copy.** A file id, a
  /// version, a label and a baseline are meaningful only relative to one mod
  /// page; carried across a rebind they leave a record asserting that mod B
  /// ships file 555 of mod A. `remote_missing` was a fact about the old mod, and
  /// a dismissal is a statement about the old mod's releases.
  ///
  /// [archiveMd5] survives on purpose: the hash is a fact about the archive we
  /// extracted, not about which mod we currently believe it to be — which is
  /// exactly what lets a banked hash be matched against the **new** mod's
  /// published checksums.
  ///
  /// So do [files]: they name what is on disk, and disk did not change because
  /// somebody corrected a record.
  ModDownload boundTo({
    required int modId,
    required OriginConfidence confidence,
  }) {
    final rebinding = this.modId != null && this.modId != modId;
    return ModDownload(
      role: role,
      modId: modId,
      modIdConfidence: confidence,
      fileId: rebinding ? null : fileId,
      version: rebinding ? null : version,
      versionLabel: rebinding ? null : versionLabel,
      versionConfidence:
          rebinding ? OriginConfidence.unknown : versionConfidence,
      archiveMd5: archiveMd5,
      baselineRemoteDate: rebinding ? null : baselineRemoteDate,
      remoteMissing: rebinding ? false : remoteMissing,
      updatesDismissedUntil: rebinding ? null : updatesDismissedUntil,
      files: files,
    );
  }

  /// This layer after the app downloaded and wrote a file over it.
  ///
  /// Longhand rather than [copyWith] because the interesting half is what gets
  /// **cleared**, which `copyWith` cannot express. Three fields go and each
  /// would otherwise be a lie about the folder as it now stands:
  ///
  /// - **`baselineRemoteDate`** — "I don't know which file, I got it around
  ///   then". We now know exactly which file, so a date comparison would be a
  ///   weaker answer sitting beside a stronger one.
  /// - **`updatesDismissedUntil`** — they waved an update away and have now
  ///   taken it. Stored as a date at or after this file's, keeping it silences
  ///   the *next* release too.
  /// - **`remoteMissing`** — we just fetched the page and a file off it.
  ///
  /// Both confidences reach `exact` on the same grounds a marketplace install
  /// does: the user picked this row of this mod's file list and we wrote exactly
  /// that file id.
  ModDownload updatedTo({
    required int modId,
    required int fileId,
    String? version,
    String? versionLabel,
    String? archiveMd5,
    List<InstalledFile>? files,
  }) =>
      ModDownload(
        role: role,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: OriginConfidence.exact,
        archiveMd5: archiveMd5 ?? this.archiveMd5,
        // **Null keeps the old list.** A caller that cannot say what it wrote
        // knows less than the record does, and an empty list would claim this
        // layer put nothing in the folder.
        files: files ?? this.files,
      );

  /// Clears [updatesDismissedUntil], which [copyWith] cannot express.
  ModDownload withUpdatesUndismissed() => ModDownload(
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

  /// Value equality over **every** field.
  ///
  /// [ModOrigin] needs it for the mods screen's "did anything actually change?"
  /// guard, which compares the whole block to decide whether a rescan may push
  /// new state. A field left out here is a card that goes on showing its old
  /// verdict after a write that succeeded.
  @override
  bool operator ==(Object other) =>
      other is ModDownload &&
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
  String toString() =>
      'ModDownload(${role.wire}${modId == null ? '' : ' #$modId'})';

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
