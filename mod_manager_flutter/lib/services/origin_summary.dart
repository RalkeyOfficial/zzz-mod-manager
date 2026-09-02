/// What a mod's origin block currently *claims*, folded into the two lines the
/// resolve dialog shows before offering to change anything.
///
/// This exists because the dialog was write-only about its own subject. It read
/// `mod_id` to decide what to fetch and `installed_at` to rank files, and never
/// read `file_id`, `version_confidence` or `baseline_remote_date` at all — so a
/// mod the user had already resolved opened looking exactly like one they had
/// never touched, with no row marked and nothing stating what was on record.
/// The one question the dialog could not answer was the one its own title asks.
///
/// Pure, and separate from the widget for the usual reason: what is easy to get
/// wrong here is not the layout but *how strong a claim each tier is allowed to
/// sound*. "You chose this" and "we guessed from your source link" describe the
/// same field at different tiers, and the difference is the whole point.
library;

import '../models/mod_download.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';

/// How the recorded identity was arrived at.
enum IdentitySummary {
  /// No `mod_id` at all — the dialog is in its search state.
  none,

  /// Derived from the user's `source_url` by the offline backfill. A guess
  /// about a free-form field a human typed.
  inferred,

  /// The user picked this mod page in this dialog.
  confirmed,

  /// We downloaded the mod through the marketplace.
  downloaded,
}

/// What the block says about *which file* is installed.
enum VersionSummary {
  /// Nothing recorded. The amber state.
  none,

  /// A file id and version are on record because we fetched exactly that file.
  downloaded,

  /// A file id is on record because the archive's md5 matched its checksum.
  /// A **matching key, never an integrity claim** — the wording must never
  /// drift toward "verified".
  checksumMatched,

  /// The user picked the file from the list.
  chosen,

  /// A guess we recorded and labelled as one. Nothing writes this yet; the bulk
  /// resolution pass will.
  guessed,

  /// No file — only a baseline date, from "I don't know which file".
  dateOnly,
}

/// The two lines, plus the values they need to name.
class OriginSummary {
  const OriginSummary({
    required this.identity,
    required this.version,
    this.fileId,
    this.versionLabel,
    this.baseline,
  });

  static const OriginSummary empty = OriginSummary(
    identity: IdentitySummary.none,
    version: VersionSummary.none,
  );

  final IdentitySummary identity;
  final VersionSummary version;

  /// The recorded file, so the file list can mark that row as the one on
  /// record — distinct from the rows it merely suggests.
  final int? fileId;

  /// `version` and `version_label` joined for display, or null when neither is
  /// recorded. A file id with no version string is normal: GameBanana's
  /// `_sVersion` is routinely null on every file of a mod.
  final String? versionLabel;

  /// The date [VersionSummary.dateOnly] compares against. **Read from the block
  /// rather than recomputed** — the per-mod dialog clamps its baseline to the
  /// mod's creation date, so the stored value can legitimately differ from the
  /// install date the dialog would derive today, and quoting the wrong one
  /// would state a rule that isn't in force.
  final DateTime? baseline;

  /// Whether there is anything on record worth showing at all.
  bool get isEmpty =>
      identity == IdentitySummary.none && version == VersionSummary.none;
}

/// Folds **one download** into what a dialog should say about it.
///
/// One fold for every layer of the stack, which is what keeps "on record" and
/// "our best guess" from coming to mean different things depending on which
/// half of a mixed folder is being described.
///
/// [provenance] is the folder's, and it is the one thing here that is not the
/// layer's own: it separates the two routes to `exact` on the version axis.
///
/// Deliberately says nothing about `tracking: "off"` — that mod gets its own
/// notice and never reaches this panel.
OriginSummary summarizeDownload(
  ModDownload? download, {
  OriginProvenance provenance = OriginProvenance.importedFolder,
}) {
  if (download == null) return OriginSummary.empty;

  final identity = switch (download.modId) {
    null => IdentitySummary.none,
    _ => switch (download.modIdConfidence) {
        // `exact` on the identity axis is only ever written by a download: the
        // marketplace knows the mod id before the first byte. A checksum match
        // raises the *version* axis, never this one, because a hash identifies
        // a file and GameBanana offers no reverse lookup from one to its mod.
        OriginConfidence.exact => IdentitySummary.downloaded,
        OriginConfidence.user => IdentitySummary.confirmed,
        OriginConfidence.inferred ||
        OriginConfidence.assumedLatest ||
        OriginConfidence.unknown =>
          IdentitySummary.inferred,
      },
  };

  final version = switch (download.versionConfidence) {
    OriginConfidence.unknown => VersionSummary.none,
    OriginConfidence.assumedLatest => VersionSummary.dateOnly,
    OriginConfidence.inferred => VersionSummary.guessed,
    OriginConfidence.user => VersionSummary.chosen,
    // Both routes to `exact` record a file id, and they are different facts:
    // we fetched it, or its bytes matched. Provenance is what separates them,
    // and the wording has to as well — "byte-identical to your archive" is a
    // claim about a match, not about having obtained the file ourselves.
    //
    // **A layer's own archive hash is the better witness where it has one.**
    // A patch the app wrote into a hand-imported folder is a file we fetched,
    // and the folder's provenance would have called it a checksum match.
    OriginConfidence.exact =>
      provenance.isOurDownload || download.archiveMd5 != null
          ? VersionSummary.downloaded
          : VersionSummary.checksumMatched,
  };

  return OriginSummary(
    identity: identity,
    version: version,
    fileId: download.fileId,
    versionLabel: _joinVersion(download.version, download.versionLabel),
    baseline: download.baselineRemoteDate,
  );
}

/// The fold for **what the folder is** — its bottom layer.
///
/// A convenience over [summarizeDownload], and the one every surface that asks
/// "which mod is this?" wants: a patch written on top modifies the mod, it does
/// not change which mod the folder is.
OriginSummary summarizeOrigin(ModOrigin? origin) => origin == null
    ? OriginSummary.empty
    : summarizeDownload(origin.base, provenance: origin.provenance);

String? _joinVersion(String? version, String? label) {
  final parts = [
    if (version case final v? when v.isNotEmpty) v,
    if (label case final l? when l.isNotEmpty) l,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
