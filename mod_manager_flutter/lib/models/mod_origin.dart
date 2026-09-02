import 'installed_file.dart';
import 'mod_companion.dart';
import 'mod_download.dart';
import 'mod_ingest.dart';
import 'origin_enums.dart';

/// **What a mod folder holds and where it came from.**
///
/// A folder is a **stack of downloads** ([downloads]) — written bottom-up, each
/// laying files down over the ones below it — plus the handful of facts a folder
/// has exactly one of. That is the whole model, and the split between the two is
/// the only structural decision in it:
///
/// | On the folder | In the stack |
/// |---|---|
/// | [source], [provenance], [installedAt], [ingest], [tracking] | which mod, which file, how sure, which files it wrote, its dismissal |
///
/// **Nothing here is "the folder's own download".** The previous shape kept one
/// download in these fields and the rest in a companion list with a role
/// *relative* to it — and which one landed where was **install order**. Patch a
/// mod and the mod was primary; install the patch first and name the mod
/// afterwards and the patch was. The folders were physically identical and the
/// records were mirror images, so every feature downstream paid to undo it, and
/// "take this patch out" could not be expressed at all for one of the two
/// orderings. Here the ordering *is* the model: position is the role.
///
/// **Machine-owned.** Written by the app at ingest and carried across saves from
/// the file on disk — never sourced from `ModInfo`. Routing it through the
/// runtime view is exactly what would let an unrelated edit (a user changing a
/// description) reconstruct the sidecar without it and silently erase the block.
class ModOrigin {
  const ModOrigin({
    this.source,
    required this.provenance,
    this.ingest,
    this.installedAt,
    this.installedAtIsProxy = false,
    this.tracking = OriginTracking.auto,
    this.downloads = const <ModDownload>[],
  });

  /// Which service, e.g. `gamebanana`. Null when the mod isn't tracked.
  ///
  /// One folder, one service: a stack whose layers came from different sites is
  /// not a shape this app installs, and inventing a per-layer field for it would
  /// be a field with no writer.
  final String? source;

  /// Where the folder came from. Always known — we performed the ingest.
  final OriginProvenance provenance;

  /// How the archive became folders, and whether the bottom of the stack is
  /// missing (`patch_shaped`).
  ///
  /// A property of the **folder**: the layout is what the mod's own `.ini` paths
  /// were written against, and it is replayed when the bottom layer is updated.
  final ModIngest? ingest;

  /// When this mod was installed. One folder, one install date — a stack does
  /// not get one per layer, and the date belongs to the download the app
  /// performed.
  final DateTime? installedAt;

  /// True when [installedAt] was derived from file timestamps rather than
  /// observed. A backfilled proxy can read years early for a hand-copied
  /// library, so anything comparing dates needs to know which it has.
  final bool installedAtIsProxy;

  /// Whether this folder should be watched at all.
  ///
  /// **Per folder, never per layer.** "It's my own / not from GameBanana" is a
  /// statement about the folder, a per-layer mute would be a second switch on
  /// one card, and the installed-mods index depends on there being exactly one.
  final OriginTracking tracking;

  /// **The folder's downloads, bottom-most first.**
  ///
  /// Index 0 is what the folder fundamentally is; everything above it is written
  /// over what is below. Empty for a folder whose block records only how it got
  /// here — which is every mod the offline backfill could derive nothing about.
  ///
  /// One entry is the overwhelmingly common case. Two is a mod and a patch.
  /// Three is a mod and two patches, which needs no special handling anywhere
  /// precisely because the list is ordered.
  ///
  /// **A folder never holds two *independent* mods**, and that is a decision
  /// rather than a gap: a stack is a stack of overwrites, so downloads that do
  /// not overlap have no defined order and no meaning as layers. They would also
  /// share one on/off state, one snapshot and one set of `.ini` files. Wanting
  /// two mods handled together is a request for **grouping in the library**,
  /// which is a listing concern.
  final List<ModDownload> downloads;

  /// **What the folder is** — the bottom of the stack. Null when nothing is
  /// recorded.
  ///
  /// This is what "which mod is this?" means: a patch written on top modifies
  /// the mod, it does not replace which mod the folder is. The badge, the
  /// backfill and the resolve dialog all mean this one.
  ModDownload? get base => downloads.isEmpty ? null : downloads.first;

  /// Everything written over [base], bottom-most first.
  List<ModDownload> get patches =>
      downloads.length < 2 ? const <ModDownload>[] : downloads.sublist(1);

  /// The layer naming [modId], or null. Ids are deduplicated on read, so there
  /// is at most one.
  ModDownload? downloadOf(int modId) {
    for (final download in downloads) {
      if (download.modId == modId) return download;
    }
    return null;
  }

  /// This layer's index, or -1. The address of a layer for anything that has to
  /// act on the stack around it.
  int indexOf(int modId) {
    for (var i = 0; i < downloads.length; i++) {
      if (downloads[i].modId == modId) return i;
    }
    return -1;
  }

  /// Every layer that can be asked about — one with no mod id names no page.
  List<ModDownload> get trackable =>
      [for (final download in downloads) if (download.hasIdentity) download];

  /// Whether we know which remote mod this folder **is**.
  bool get hasIdentity => base?.hasIdentity ?? false;

  /// The folder holds more than one download, so an update to any of them has
  /// to work around the others.
  bool get isMixed => downloads.length > 1;

  /// **This folder is a patch and nobody has said what it patches.**
  ///
  /// The one question position cannot answer, which is why
  /// `ingest.patch_shaped` still exists: a stack of one cannot say whether
  /// something belongs *under* it. The flag is that claim, and
  /// [withBaseInserted] is what retires it.
  ///
  /// **The flag is the record and the depth is the answer.** `patch_shaped`
  /// says the folder's own ingest was a patch, which only an install can know
  /// and which never stops being true; a second layer says somebody has since
  /// named what it applies to. Writing the answer into the flag instead would
  /// make it unrecoverable, and undoing a wrong answer has to stay possible.
  ///
  /// The evidence was captured at install because that is the only moment a
  /// patch folder is legible — afterwards every reference resolves and the
  /// folder is indistinguishable from an ordinary one — and the missing half can
  /// only come from the person who assembled it.
  bool get needsBase =>
      (ingest?.patchShaped ?? false) && downloads.length < 2;

  /// The strongest thing this block can say about its bottom layer: we know
  /// exactly which remote file is installed, the user has not declared the mod
  /// their own, and the page is still there.
  ///
  /// Both axes must be `exact`, because knowing the mod but not the file is not
  /// enough to know what would replace it.
  ///
  /// **It has no reader in `lib/`, and that is not an oversight.** It was
  /// written as the gate for unattended auto-update, which is *refused* rather
  /// than unbuilt — no update is applied without the user present, because
  /// overwriting a live install in a scene with no standard means the person who
  /// has to repair it must be there when it happens. See
  /// `docs/applying-updates.md` §7.
  ///
  /// Kept because it is the one place the "`exact` on **both** axes" rule is
  /// written as code, and `test/mod_origin_test.dart` is what pins the tier
  /// table to it. Anything wanting "is this a guess?" wants
  /// [OriginConfidence.isConfirmed], which is a weaker and different line.
  bool get allowsUnattendedUpdate {
    final layer = base;
    return layer != null &&
        tracking == OriginTracking.auto &&
        !layer.remoteMissing &&
        layer.modIdConfidence.allowsUnattendedUpdate &&
        layer.versionConfidence.allowsUnattendedUpdate;
  }

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
  ///
  /// **The stack compares in order**, unlike the set it replaced: order is
  /// meaning now, so two layers swapped is a different folder and a rescan
  /// should say so.
  @override
  bool operator ==(Object other) =>
      other is ModOrigin &&
      other.source == source &&
      other.provenance == provenance &&
      other.ingest == ingest &&
      other.installedAt == installedAt &&
      other.installedAtIsProxy == installedAtIsProxy &&
      other.tracking == tracking &&
      _sameStack(other.downloads);

  bool _sameStack(List<ModDownload> other) {
    if (other.length != downloads.length) return false;
    for (var i = 0; i < downloads.length; i++) {
      if (other[i] != downloads[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        source,
        provenance,
        ingest,
        installedAt,
        installedAtIsProxy,
        tracking,
        Object.hashAll(downloads),
      );

  ModOrigin copyWith({
    String? source,
    OriginProvenance? provenance,
    ModIngest? ingest,
    DateTime? installedAt,
    bool? installedAtIsProxy,
    OriginTracking? tracking,
    List<ModDownload>? downloads,
  }) =>
      ModOrigin(
        source: source ?? this.source,
        provenance: provenance ?? this.provenance,
        ingest: ingest ?? this.ingest,
        installedAt: installedAt ?? this.installedAt,
        installedAtIsProxy: installedAtIsProxy ?? this.installedAtIsProxy,
        tracking: tracking ?? this.tracking,
        downloads: downloads ?? this.downloads,
      );

  /// [downloads] with the layer naming [modId] replaced by [update]'s result.
  ///
  /// **By id, and the position is untouched.** A layer's place in the stack is
  /// where its files physically sit; amending what we believe about it is not a
  /// reason to move it.
  ModOrigin withDownload(int modId, ModDownload Function(ModDownload) update) =>
      copyWith(downloads: [
        for (final download in downloads)
          if (download.modId == modId) update(download) else download,
      ]);

  /// [downloads] with the **bottom** layer replaced, creating one when the stack
  /// is empty.
  ///
  /// The write for anything that resolves what the folder *is* — the backfill
  /// and the resolve dialog's identity step — where an empty stack is the
  /// ordinary case rather than an error.
  ModOrigin withBase(ModDownload Function(ModDownload) update) => copyWith(
        downloads: downloads.isEmpty
            ? [update(const ModDownload())]
            : [
                update(downloads.first).copyWith(role: DownloadRole.base),
                ...patches,
              ],
      );

  /// [layer] inserted at the **bottom**, which is what naming the mod a
  /// patch-shaped folder applies to means.
  ///
  /// The roles are re-derived, so what used to be index 0 becomes a patch —
  /// with no field to update, because the field follows the position.
  ///
  /// **`patch_shaped` survives**: it records what the ingest was, and being told
  /// what that patch applies to does not change it. What the answer retires is
  /// [needsBase], which reads the flag *and* the depth — so the answer is the
  /// second layer's existence, and removing it asks again.
  ///
  /// **An empty stack gains a layer for the folder's own download**, unnamed,
  /// so the base has something to sit under. Without it the record would read
  /// as "this folder is that mod", which is the one thing it is not.
  ModOrigin withBaseInserted(ModDownload layer) => copyWith(
        downloads: _reroled([
          layer,
          if (downloads.isEmpty) const ModDownload() else ...downloads,
        ]),
      );

  /// [layer] added on top, replacing any layer that already names the same mod.
  ///
  /// **Deduplicated by mod id**: one folder can legitimately hold two different
  /// patches, and re-applying the same one must not list it twice. A layer with
  /// no id is always additive, since there is nothing to match it against.
  ModOrigin withLayerOnTop(ModDownload layer) => copyWith(
        downloads: _reroled([
          for (final download in downloads)
            if (layer.modId == null || download.modId != layer.modId) download,
          layer,
        ]),
      );

  /// The stack without the layer naming [modId], roles re-derived.
  ///
  /// Removing the bottom layer is expressible and is *not* refused here: it
  /// leaves a folder needing a base again, which is a state the app already
  /// describes ([needsBase]) and a caller may legitimately produce. Whether to
  /// offer it is that caller's judgement, not this type's.
  ModOrigin withoutDownload(int modId) => copyWith(
        downloads: _reroled([
          for (final download in downloads)
            if (download.modId != modId) download,
        ]),
      );

  /// A dismissal — or its undo, with a null [until] — recorded against **one
  /// layer**.
  ///
  /// One rule with more than one caller, and they must not disagree: the write
  /// and the re-fold that follows it. A dismissal is a statement about one mod
  /// page's releases, so applied to the wrong layer it silences nothing and
  /// stamps another mod's release date where it can go on to hide a finding that
  /// was never dismissed.
  ///
  /// A [subject] this block no longer carries changes nothing. Falling back to
  /// the bottom layer would dismiss the wrong mod's releases, and a verdict
  /// computed against a block that has since moved on is exactly when that
  /// happens.
  ModOrigin withDismissal({required int subject, required DateTime? until}) =>
      withDownload(
        subject,
        (download) => until == null
            ? download.withUpdatesUndismissed()
            : download.copyWith(updatesDismissedUntil: until),
      );

  /// Roles taken from the positions the list now has.
  static List<ModDownload> _reroled(List<ModDownload> stack) => [
        for (var i = 0; i < stack.length; i++)
          stack[i].copyWith(role: DownloadRole.forIndex(i)),
      ];

  /// Emits only what differs from the read-side defaults.
  ///
  /// Absence already means "default" on read, so writing `"tracking": "auto"`
  /// into every sidecar would add noise to a file users can open without adding
  /// information.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (source != null) 'source': source,
        'provenance': provenance.wire,
        if (ingest != null && !ingest!.isEmpty) 'ingest': ingest!.toJson(),
        if (installedAt != null)
          'installed_at': installedAt!.toUtc().toIso8601String(),
        if (installedAtIsProxy) 'installed_at_is_proxy': true,
        if (tracking != OriginTracking.auto) 'tracking': tracking.wire,
        // Absent rather than `[]`: a block that records only how the folder got
        // here is a real state, and an empty list adds nothing to it.
        if (downloads.isNotEmpty)
          'downloads': [for (final d in downloads) d.toJson()],
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
  /// and images.
  ///
  /// Returns null when the value isn't an object at all — machine-owned garbage
  /// is dropped rather than round-tripped, unlike genuinely unknown keys.
  static ModOrigin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ModOrigin(
      source: _string(raw['source']),
      provenance: OriginProvenance.parse(raw['provenance']),
      ingest: ModIngest.fromJson(raw['ingest']),
      installedAt: _date(raw['installed_at']),
      installedAtIsProxy: raw['installed_at_is_proxy'] == true,
      tracking: OriginTracking.parse(raw['tracking']),
      downloads: raw.containsKey('downloads')
          ? _stack(raw['downloads'])
          : migrateFlatBlock(raw),
    );
  }

  /// Parses the stack, dropping every entry it cannot use.
  ///
  /// - **An unusable entry goes and the list survives.** A sidecar can arrive
  ///   from a stranger holding anything; one bad entry must not cost the others,
  ///   and none of them may cost the folder's own facts.
  /// - **A repeated mod id keeps the lower layer.** Kept, the second would have
  ///   the check ask one page twice and report two verdicts for one folder — and
  ///   the lower one is the one whose files the upper would have overwritten.
  /// - **An entry that knows nothing is still kept**, and that is the one rule
  ///   here that would be wrong in the old shape. A companion with no identity
  ///   was worthless, because a companion *was* an identity. A layer with no
  ///   identity and no file list still carries its **position** — "there is a
  ///   download here and we know nothing about it" — and dropping it would
  ///   renumber everything above it, turning a patch into the thing it was
  ///   written over.
  static List<ModDownload> _stack(Object? raw) {
    if (raw is! List) return const <ModDownload>[];
    final parsed = <ModDownload>[];
    final seen = <int>{};
    for (final entry in raw) {
      final download = ModDownload.fromJson(entry, index: parsed.length);
      if (download == null) continue;
      if (download.modId case final id? when !seen.add(id)) continue;
      parsed.add(download);
    }
    return parsed;
  }

  /// Reads a sidecar written in the **flat** shape — identity on the block
  /// itself plus a `companions` list with roles relative to it — as a stack.
  ///
  /// A read-side migration with no version bump and no write of its own: the
  /// next save emits the stack, so a folder upgrades the first time anything
  /// touches it. The flat shape never shipped (2.2.2 predates the whole origin
  /// block), so the only sidecars in it were written by development builds.
  ///
  /// **The order is the one `folderDownloads` already derived** to undo the
  /// asymmetry at read time — mod-half first, then patches — which is what makes
  /// this lossless rather than a guess: a `base` companion means the flat
  /// block's own identity was the patch, so it goes above.
  static List<ModDownload> migrateFlatBlock(Map<Object?, Object?> raw) {
    final own = ModDownload(
      modId: ModDownload.fromJson({'mod_id': raw['mod_id']}, index: 0)?.modId,
      modIdConfidence: OriginConfidence.parse(raw['mod_id_confidence']),
      fileId: _int(raw['file_id']),
      version: _string(raw['version']),
      versionLabel: _string(raw['version_label']),
      versionConfidence: OriginConfidence.parse(raw['version_confidence']),
      archiveMd5: _string(raw['archive_md5']),
      baselineRemoteDate: _date(raw['baseline_remote_date']),
      remoteMissing: raw['remote_missing'] == true,
      updatesDismissedUntil: _date(raw['updates_dismissed_until']),
      // The folder's own download's files lived on `ingest`; they belong to the
      // layer that wrote them. Read out of the raw map rather than through
      // `ModIngest`, which no longer carries them — a vestigial field kept only
      // for one migration is a field somebody starts writing again.
      files: InstalledFile.parseList(
        raw['ingest'] is Map ? (raw['ingest'] as Map)['files'] : null,
      ),
    );
    if (!own.hasIdentity && !own.hasFileRecord && raw['companions'] == null) {
      return const <ModDownload>[];
    }

    final below = <ModDownload>[];
    final above = <ModDownload>[];
    final companions = raw['companions'];
    if (companions is List) {
      for (final entry in companions) {
        final companion = ModCompanion.fromJson(entry);
        if (companion == null) continue;
        if (companion.modId == own.modId) continue;
        final layer = ModDownload(
          modId: companion.modId,
          modIdConfidence: companion.modIdConfidence,
          fileId: companion.fileId,
          version: companion.version,
          versionLabel: companion.versionLabel,
          versionConfidence: companion.versionConfidence,
          archiveMd5: companion.archiveMd5,
          baselineRemoteDate: companion.baselineRemoteDate,
          remoteMissing: companion.remoteMissing,
          updatesDismissedUntil: companion.updatesDismissedUntil,
          files: companion.files,
        );
        (companion.role == CompanionRole.base ? below : above).add(layer);
      }
    }
    return _reroled([...below, own, ...above]);
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
