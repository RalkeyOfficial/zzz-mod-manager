import '../models/mod_metadata.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import '../utils/gamebanana_url.dart';
import '../utils/install_date_proxy.dart';

/// Resolves an install-date proxy for a mod folder. Injected so the decisions
/// below are testable with no filesystem at all.
typedef InstallDateProbe = Future<DateTime?> Function(String modFolder);

/// The offline backfill: recovering what an already-installed mod's origin
/// block *would* have said, from data already sitting on disk.
///
/// Everything installed before the origin block existed has none — the whole
/// pre-existing library — and without identity those mods are permanently
/// invisible to update checking. One thing is recoverable for free: `source_url`
/// is an existing user-editable field, and a `gamebanana.com/mods/<id>` link in
/// it yields the remote mod id. On a real 23-mod library, all 23 carried one.
///
/// **This is a sibling of the legacy migration, not an extension of it.**
/// `ModMetadataRepository.loadOrMigrate` returns early the moment a sidecar
/// exists, and the legacy path it falls through to builds its metadata from a
/// config character tag and an app-data image — neither of which can carry a
/// `source_url`. So the only branch this can usefully run on is the *early
/// return*: the mods that already have a sidecar. Hanging it off the legacy
/// migration instead would make it dead code.
///
/// Strictly local. Scans run offline on every launch, so nothing here may make
/// a request — which is also why `gameBananaModIdFromUrl` lives in `utils/`
/// rather than inside the API client.
///
/// Two rules shape every decision below:
///
/// - **It never displaces something better.** It never overrides an identity
///   the user confirmed or we established exactly, never raises a confidence,
///   and never replaces an observed `installed_at` with a derived one. A url
///   parse is a guess about a free-form field a human typed.
/// - **Nothing derivable means nothing written.** No empty sidecar, no marker,
///   no "already swept" flag — re-sniffing on the next scan costs one string
///   parse, and a user who never opens the marketplace should find no new files
///   inside their mods.
class OriginBackfill {
  const OriginBackfill({InstallDateProbe? installDateProbe})
      : _probe = installDateProbe ?? oldestFileMtime;

  final InstallDateProbe _probe;

  /// Tiers a url parse must never overrule. Both represent knowledge that did
  /// not come from `source_url`: `exact` was established by a download or a
  /// checksum match, `user` by the user confirming it in the resolve dialog.
  static const Set<OriginConfidence> _confirmedTiers = {
    OriginConfidence.exact,
    OriginConfidence.user,
  };

  /// Resolves the install-date proxy for [modFolder].
  ///
  /// Exposed rather than folded into a single `derive` step so the caller can
  /// re-check its decision after this — the walk is the one slow point on this
  /// path, and a sidecar can be rewritten underneath it.
  Future<DateTime?> probeInstallDate(String modFolder) => _probe(modFolder);

  /// The mod id to record, or null when there is nothing to do. Pure — this is
  /// the whole gate, and the part worth testing.
  static int? recoverableModId(ModMetadata metadata) {
    final parsed = gameBananaModIdFromUrl(metadata.sourceUrl);
    if (parsed == null) return null;

    final origin = metadata.origin;
    if (origin == null) return parsed;

    // The user declared this mod local ("not from GameBanana / it's my own").
    // Re-attaching a remote identity behind their back would undo an explicit
    // decision — and a stale `source_url` is exactly why they might have made
    // it. `tracking: off` is permanent until the user themselves reverses it.
    if (origin.tracking == OriginTracking.off) return null;

    // Nothing stored, or the url agrees with it: fill / leave alone.
    if (origin.modId == null) return parsed;
    if (origin.modId == parsed) return null;

    // The url now names a *different* mod than the one on record. Whether that
    // wins depends entirely on where the stored id came from:
    //
    // - `exact`/`user` — established by a download, a checksum match, or the
    //   user confirming it. A url parse must never overrule those.
    // - anything weaker — including our own earlier backfill — came from this
    //   very field, so it has to follow the field. Otherwise a user who pasted
    //   the wrong mod page once is stuck with it: correcting the url would be
    //   a silent no-op, and until §7.5's resolve dialog ships there is no other
    //   way to fix the binding.
    if (_confirmedTiers.contains(origin.modIdConfidence)) return null;
    return parsed;
  }

  /// Folds a recovered [modId] into [existing] (or builds a fresh block).
  /// Pure.
  ///
  /// Identity lands at [OriginConfidence.inferred] and never higher: it came
  /// from a free-form text field, so it may be a wrong paste, a collection
  /// link, or a different mod entirely. `inferred` may badge and suggest but
  /// can never drive an unattended overwrite, and it must be confirmed once
  /// before any update acts on it.
  ///
  /// **Version stays unknown.** Identity and version are separate unknowns that
  /// resolve independently: the archive is deleted after extraction, so there
  /// is nothing local left to match against the per-file checksums the remote
  /// publishes. Guessing a version from folder-name `_v2` tokens or `; version`
  /// comments is deliberately not done — mods embed ZZMI and game versions that
  /// are indistinguishable from mod versions, and a wrong stored version is
  /// worse than none.
  static ModOrigin merge({
    required ModOrigin? existing,
    required int modId,
    required DateTime? installedAt,
  }) {
    // An observed install date always beats a derived one, and keeps its own
    // proxy flag. We only claim a proxy when we actually supplied one.
    final hasObservedDate = existing?.installedAt != null;
    final resolvedAt = existing?.installedAt ?? installedAt;
    final isProxy = hasObservedDate
        ? existing!.installedAtIsProxy
        : installedAt != null;

    final base = existing ??
        // Provenance is genuinely unknown for a legacy mod — it may have been
        // downloaded by an old build, imported, or hand-copied into the library
        // — so it takes the least-privileged of the three, which is also what
        // `OriginProvenance.parse` falls back to. It is not the auto-update
        // gate (confidence is), so understating it costs nothing.
        const ModOrigin(provenance: OriginProvenance.importedFolder);

    // Re-pointing the folder at a *different* mod invalidates everything that
    // described the old one. A `file_id` and a version are meaningful only
    // relative to one mod page, so carrying them across a rebind would leave a
    // block asserting that mod B ships file 555 of mod A. `remote_missing` was
    // a fact about the old mod too. Written out longhand rather than through
    // `copyWith`, which cannot express clearing a field.
    final rebinding = existing?.modId != null && existing!.modId != modId;

    return ModOrigin(
      source: gameBananaSource,
      modId: modId,
      modIdConfidence: OriginConfidence.inferred,
      fileId: rebinding ? null : base.fileId,
      version: rebinding ? null : base.version,
      versionLabel: rebinding ? null : base.versionLabel,
      versionConfidence:
          rebinding ? OriginConfidence.unknown : base.versionConfidence,
      provenance: base.provenance,
      ingest: base.ingest,
      installedAt: resolvedAt,
      installedAtIsProxy: isProxy,
      baselineRemoteDate: rebinding ? null : base.baselineRemoteDate,
      // Survives a rebind on purpose: the hash is a fact about the archive we
      // extracted, not about which remote mod we currently think it is. That
      // is exactly what makes "bank now, cash in at resolution" work — it can
      // still be matched against the *new* mod's published checksums.
      archiveMd5: base.archiveMd5,
      tracking: base.tracking,
      remoteMissing: rebinding ? false : base.remoteMissing,
    );
  }
}
