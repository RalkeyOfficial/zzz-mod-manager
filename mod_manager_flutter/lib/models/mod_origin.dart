import 'mod_companion.dart';
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
    this.companions = const <ModCompanion>[],
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

  /// **The other downloads in this folder**, when the user has named any.
  ///
  /// A mod folder is frequently two downloads — a patch plus the mod it patches
  /// — and the fields above describe exactly one of them. In the common
  /// ordering they describe the *patch*, so a check against them reports
  /// nothing newer while the mod the folder actually contains goes versions
  /// ahead. This is the rest of the folder.
  ///
  /// Empty is the overwhelmingly common case and is never written to disk. The
  /// second identity can only come from the user: they assembled the folder by
  /// hand, possibly from a source this app never saw. See
  /// `ModCompanion` for why it is a narrower type than this one.
  final List<ModCompanion> companions;

  /// The companion filling [role], or null. First match — the list is
  /// deduplicated by mod id on read, so there is at most one per mod.
  ModCompanion? companionOfRole(CompanionRole role) {
    for (final companion in companions) {
      if (companion.role == role) return companion;
    }
    return null;
  }

  /// This folder is recorded as holding a **patch** and nobody has said what it
  /// patches — so the app knows the folder is two things and can only ask about
  /// one of them.
  ///
  /// The one state the resolve dialog can clear and nothing else can: the
  /// evidence was captured at install (`ingest.patch_shaped`) because that is
  /// the only moment a patch folder is legible, and the missing half can only
  /// come from the person who assembled it.
  bool get needsCompanion =>
      (ingest?.patchShaped ?? false) &&
      companionOfRole(CompanionRole.base) == null;

  /// The strongest thing this block can say: we know exactly which remote file
  /// is installed here, the user has not declared the mod their own, and the
  /// page is still there.
  ///
  /// Both axes must be `exact`, because knowing the mod but not the file is not
  /// enough to know what would replace it.
  ///
  /// **It has no reader in `lib/`, and that is not an oversight.** It was
  /// written as the gate for unattended auto-update, which is *refused* rather
  /// than unbuilt — no update is applied without the user present, because
  /// overwriting a live install in a scene with no standard means the person
  /// who has to repair it must be there when it happens. See
  /// `docs/applying-updates.md` §7.
  ///
  /// Kept because it is the one place the "`exact` on **both** axes" rule is
  /// written as code, and `test/mod_origin_test.dart` is what pins the tier
  /// table to it. Anything wanting "is this a guess?" wants
  /// [OriginConfidence.isConfirmed], which is a weaker and different line.
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
      other.updatesDismissedUntil == updatesDismissedUntil &&
      _sameCompanions(other.companions);

  /// Order-independent, because the list is a **set of identities**: rewriting
  /// it in a different order is not a change the user can see, and a rescan
  /// that judged it one would rebuild the grid for nothing.
  bool _sameCompanions(List<ModCompanion> other) {
    if (other.length != companions.length) return false;
    for (final companion in companions) {
      if (!other.contains(companion)) return false;
    }
    return true;
  }

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
        Object.hashAllUnordered(companions),
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
      // **Companions survive a rebind.** What changed is our belief about the
      // primary, not the folder's contents — the other download is still in
      // there and the entry is still true.
      //
      // Except when the folder is rebound *onto* one of them: that is the user
      // saying the companion was the folder's real subject all along, and
      // keeping the entry would leave the block claiming one mod twice, once in
      // each role.
      companions: [
        for (final companion in companions)
          if (companion.modId != modId) companion,
      ],
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
        // Absent rather than `[]`: every sidecar in existence lacks this key,
        // and writing an empty list into all of them is churn saying nothing.
        if (companions.isNotEmpty)
          'companions': [for (final c in companions) c.toJson()],
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
    final modId = _int(raw['mod_id']);
    return ModOrigin(
      source: _string(raw['source']),
      modId: modId,
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
      companions: _companions(raw['companions'], primaryModId: modId),
    );
  }

  /// Parses the companion list, dropping every entry it cannot use.
  ///
  /// Three rules, and each removes an entry that would otherwise make the
  /// update check ask a wrong question:
  ///
  /// - **Unusable entries go, the list survives.** A sidecar travels with its
  ///   folder and can arrive from a stranger holding anything; one bad entry
  ///   must not cost the others, and none of them may cost the primary block.
  /// - **A companion naming the primary goes.** It is not a second thing in the
  ///   folder, it is the same thing said twice — and kept, it would have the
  ///   check ask one page twice and report two verdicts for one mod.
  /// - **A repeated mod id keeps the first.** Same reason, between companions.
  static List<ModCompanion> _companions(
    Object? raw, {
    required int? primaryModId,
  }) {
    if (raw is! List) return const <ModCompanion>[];
    final parsed = <ModCompanion>[];
    final seen = <int>{if (primaryModId != null) primaryModId};
    for (final entry in raw) {
      final companion = ModCompanion.fromJson(entry);
      if (companion == null) continue;
      if (!seen.add(companion.modId)) continue;
      parsed.add(companion);
    }
    return parsed;
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
    List<ModCompanion>? companions,
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
        companions: companions ?? this.companions,
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
        // **Companions survive an update**, because overwrite copies over the
        // folder and touches nothing else — the other download's files are
        // still in there. They may now be *inert*: an update can replace a
        // patch's `.ini`, which §5 of `docs/applying-updates.md` names as an
        // accepted loss paid for by the snapshot. "Installed and possibly no
        // longer applied" is not "not installed", and dropping the entry would
        // lose the only record of what that snapshot holds.
        companions: companions,
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
        // Untouched: this clears the *primary's* dismissal, and a companion
        // carries its own precisely so the two cannot silence each other.
        companions: companions,
      );

  /// A dismissal — or its undo, with a null [until] — recorded against **one
  /// identity**. [subject] names a companion, or is null for the folder's own.
  ///
  /// One rule with more than one caller, and they must not disagree: the write
  /// and the re-fold that follows it. A dismissal is a statement about one mod
  /// page's releases, so applied to the primary a companion's dismissal
  /// silences nothing and stamps another mod's release date onto this block —
  /// where it can go on to hide a finding that was never dismissed.
  ///
  /// A [subject] this block no longer carries changes nothing. Falling back to
  /// the primary would dismiss the wrong mod's releases, and a verdict computed
  /// against a block that has since moved on is exactly when that happens.
  ModOrigin withDismissal({required int? subject, required DateTime? until}) {
    if (subject == null) {
      return until == null
          ? withUpdatesUndismissed()
          : copyWith(updatesDismissedUntil: until);
    }
    return copyWith(companions: [
      for (final companion in companions)
        if (companion.modId != subject)
          companion
        else if (until != null)
          companion.copyWith(updatesDismissedUntil: until)
        else
          companion.withUpdatesUndismissed(),
    ]);
  }

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
