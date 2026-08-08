/// The zero-network **"assume current"** bulk action — who it may touch, and
/// what it writes.
///
/// The per-mod escape hatch ("I don't know which file — I got it around then")
/// already exists in the resolve dialog. This is the same answer applied to a
/// whole library in one press, and it is the cheapest thing in the plan that
/// turns a dead legacy library into a working update-notification system: it
/// needs no network, no mod page and no knowledge from the user, and it records
/// an honest *date* rather than a fabricated version string.
///
/// Two rules decide **who it may touch**, and they live here rather than in the
/// dialog so they can be tested without one. (The other two rules the schema doc
/// lists are the dialog's: it states its size before acting, and it reports a
/// declined write as a decline rather than as a failure.)
///
/// - **Bulk acts only on precise handles.** A mod with no `mod_id` is excluded
///   outright. Identifying one means fuzzy-matching a folder name
///   (`Ellen final FIXED v2`, `bikini`, `mod`) against a search, and a
///   rubber-stamped wrong match would later let an "update" overwrite a mod
///   with an unrelated mod's files. That is a one-at-a-time, user-confirmed
///   decision forever.
/// - **It never overwrites a better answer.** Only a mod whose version is
///   genuinely `unknown` is eligible, and the check is re-run against the block
///   as freshly read from disk — see [bulkAssumeCurrent]. Applied blindly, this
///   would *downgrade* a mod resolved exactly to a guess.
/// Both are expressed as a **plan** rather than as work done, because the
/// confirmation has to name its own size before acting: the answer is usually
/// "nothing" or "most of the library", and a user expecting the first who gets
/// the second has had dozens of mods rewritten on a press.
library;

import '../models/character_info.dart';
import '../models/mod_origin.dart';
import 'origin_resolution.dart';
import 'origin_status.dart';

/// What one press would do, split into the three groups the confirmation has to
/// be able to name.
class BulkAssumeCurrentPlan {
  const BulkAssumeCurrentPlan({
    required this.eligible,
    required this.untracked,
    required this.undatable,
  });

  static const BulkAssumeCurrentPlan empty = BulkAssumeCurrentPlan(
    eligible: <ModInfo>[],
    untracked: <ModInfo>[],
    undatable: <ModInfo>[],
  );

  /// Identity known, version unknown, and an install date to use as a baseline.
  /// These are the ones that get written.
  final List<ModInfo> eligible;

  /// Needs attention but has no remote identity, so bulk may not touch it.
  /// Counted because "12 of your 47" is a very different offer from "47".
  final List<ModInfo> untracked;

  /// Tracked and versionless, but no install date could be derived — so there
  /// is nothing to compare future uploads against. `assumed_latest` without a
  /// baseline is a tier that compares against nothing at all.
  final List<ModInfo> undatable;

  bool get hasWork => eligible.isNotEmpty;

  /// Whether any baseline about to be written is a *derived* date rather than
  /// an observed one. The confirmation says so when it is, because a proxy can
  /// read early and the user is the only one who knows whether they hand-copied
  /// their library.
  bool get anyBaselineIsProxy =>
      eligible.any((m) => m.origin?.installedAtIsProxy ?? false);
}

/// Sorts [mods] into the three groups above. Pure, and deliberately over the
/// already-scanned list rather than the filesystem.
///
/// **Nothing is probed for a missing install date**, unlike the per-mod dialog.
/// That is not a shortcut: every path that can set `installed_at` from a folder
/// walk has already run one. The offline backfill probes every mod it gives an
/// identity to, the ingest paths record an observed date, and the resolve
/// dialog probes before it binds. So a tracked mod still missing the field is
/// one whose walk found no files at all, and re-walking it would return null
/// again. It is listed as [BulkAssumeCurrentPlan.undatable] instead of quietly
/// dropped.
BulkAssumeCurrentPlan planBulkAssumeCurrent(Iterable<ModInfo> mods) {
  final eligible = <ModInfo>[];
  final untracked = <ModInfo>[];
  final undatable = <ModInfo>[];

  for (final mod in mods) {
    switch (modOriginStatus(mod.origin)) {
      // A mod already tracked by date is *done*, not pending: re-applying the
      // action would rewrite the same baseline and make the count reappear
      // every time the user looked at it.
      case ModOriginStatus.none:
      case ModOriginStatus.versionGuessed:
        continue;
      case ModOriginStatus.untracked:
        untracked.add(mod);
      case ModOriginStatus.versionUnknown:
        if (mod.origin?.installedAt == null) {
          undatable.add(mod);
        } else {
          eligible.add(mod);
        }
    }
  }

  return BulkAssumeCurrentPlan(
    eligible: eligible,
    untracked: untracked,
    undatable: undatable,
  );
}

/// The transform each eligible mod is written through.
///
/// Passed straight to `ModMetadataRepository.updateOrigin`, so `current` is the
/// block **as it is on disk now** — not the one the plan was built from. The
/// eligibility check is therefore repeated here rather than trusted from the
/// plan, and returning null abandons that one mod's write.
///
/// That re-check is the guard that matters. A bulk pass writes N sidecars one
/// after another while a scan may be running, and applying `assumed_latest` to
/// a mod that has since been resolved exactly would **downgrade** it — turning
/// a known version into a guess, silently, in a batch nobody is watching
/// closely.
///
/// The baseline is read from the fresh block for the same reason.
ModOrigin? bulkAssumeCurrent(ModOrigin? current) {
  if (!bulkAssumeCurrentEligible(current)) return null;
  // No `remoteCreatedAt`: this action makes no requests, so the clamp against
  // the mod's own creation date that the per-mod dialog applies is simply not
  // available here. The baseline it writes is therefore unclamped, and the
  // update check must clamp when it fetches the profile — which is the more
  // correct place for it anyway, since the clamp is a fact about the mod page.
  return OriginResolution.assumeCurrent(current);
}

/// Whether the bulk action may act on this block. Shared by the planner and the
/// write path so the count and the writes cannot describe different mods.
bool bulkAssumeCurrentEligible(ModOrigin? origin) =>
    modOriginStatus(origin) == ModOriginStatus.versionUnknown &&
    origin?.installedAt != null;
