/// The zero-network **"assume current"** bulk action — who it may touch, and
/// what it writes.
///
/// The per-mod escape hatch ("I don't know which file — I got it around then")
/// already exists in the resolve dialog. This is the same answer applied to the
/// mods ticked in the All mods table in one press, and it is the cheapest way to
/// turn a legacy library into a working update-notification system: it needs no
/// network, no mod page and no knowledge from the user, and it records an honest
/// *date* rather than a fabricated version string.
///
/// Two rules decide **who it may touch**, and they live here rather than in the
/// dialog so they can be tested without one. (The other two rules
/// `docs/origin-tracking.md` §6 lists are the dialog's: it lists every mod it
/// would write before acting, and it reports a declined write as a decline
/// rather than as a failure.)
///
/// - **Bulk acts only on precise handles.** A mod with no `mod_id` is excluded
///   outright. Identifying one means fuzzy-matching a folder name
///   (`Ellen final FIXED v2`, `bikini`, `mod`) against a search, and a
///   rubber-stamped wrong match would later let an "update" overwrite a mod
///   with an unrelated mod's files. That is a one-at-a-time, user-confirmed
///   decision forever.
/// - **It never overwrites a better answer.** Only a mod whose base alone asks
///   "Which file?" is eligible, and the check is re-run against the block as
///   freshly read from disk — see [bulkAssumeCurrent]. Applied blindly, this
///   would *downgrade* a mod resolved exactly to a guess.
/// Both are expressed as a **plan** rather than as work done, because the
/// confirmation has to name its own size before acting: the answer is usually
/// "nothing" or "most of the selection", and a user expecting the first who
/// gets the second has had dozens of mods rewritten on a press.
library;

import '../models/character_info.dart';
import '../models/mod_download.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import 'origin_resolution.dart';
import 'origin_status.dart';

/// What one press would do, split into the groups the confirmation has to be
/// able to name: the mods it writes, and the three kinds it leaves as they are.
class BulkAssumeCurrentPlan {
  const BulkAssumeCurrentPlan({
    required this.eligible,
    required this.untracked,
    required this.undatable,
    this.elsewhere = const <ModInfo>[],
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

  /// Asks something a date for the base can't answer: a base mod nobody named, or which file of a patch is installed.
  /// Settled in the tracking screen. Marking the base would turn a known file into a date and leave the question.
  final List<ModInfo> elsewhere;

  bool get hasWork => eligible.isNotEmpty;

  /// Whether any baseline about to be written is a *derived* date rather than
  /// an observed one. The confirmation says so when it is, because a proxy can
  /// read early and the user is the only one who knows whether they hand-copied
  /// their library.
  bool get anyBaselineIsProxy =>
      eligible.any((m) => m.origin?.installedAtIsProxy ?? false);
}

/// Sorts [mods] into the groups above. Pure, and deliberately over the
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
  final elsewhere = <ModInfo>[];

  for (final mod in mods) {
    switch (modOriginStatus(mod.origin)) {
      // A mod already tracked by date is *done*, not pending: re-applying the
      // action would rewrite the same baseline and make the count reappear
      // every time the user looked at it.
      case ModOriginStatus.none:
      case ModOriginStatus.versionGuessed:
      // Not reachable from `modOriginStatus`, which folds only the origin
      // block — "an update is published" comes from a check nobody has run
      // here. Listed rather than defaulted so that if this ever *does* become
      // an origin state, the compiler asks what a bulk rewrite should do with
      // it instead of quietly skipping it.
      case ModOriginStatus.updateAvailable:
        continue;
      case ModOriginStatus.untracked:
        untracked.add(mod);
      // A folder whose base mod nobody named is settled in the tracking
      // dialog, not here: a date for one layer leaves it asking.
      case ModOriginStatus.secondIdentityUnknown:
        elsewhere.add(mod);
      case ModOriginStatus.versionUnknown:
        if (!_onlyBaseAsks(mod.origin)) {
          elsewhere.add(mod);
        } else if (!bulkAssumeCurrentEligible(mod.origin)) {
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
    elsewhere: elsewhere,
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
    _onlyBaseAsks(origin) &&
    origin?.installedAt != null;

/// Whether "Which file?" is asked of the base alone. It is also asked when the
/// base's file is known and a patch's isn't, and the date this action writes
/// is the base's: it would replace the known file and leave the question.
bool _onlyBaseAsks(ModOrigin? origin) =>
    origin?.base?.versionConfidence == OriginConfidence.unknown &&
    !origin!.patches.any(
      (patch) => patch.hasIdentity && patch.versionConfidence == OriginConfidence.unknown,
    );

/// One mod a marking wrote: its base download as it was, and the baseline the marking gave it.
class MarkedAsCurrent {
  const MarkedAsCurrent({required this.modId, required this.before, required this.baseline});

  final String modId;
  final ModDownload before;
  final DateTime? baseline;
}

/// [bulkAssumeCurrent], also handing [onMarked] the base it replaced and the baseline it wrote. Called only when the
/// transform writes; the caller keeps the record once the write is known to have landed.
ModOrigin? bulkAssumeCurrentRecorded(
  ModOrigin? current,
  void Function(ModDownload before, DateTime? baseline) onMarked,
) {
  final next = bulkAssumeCurrent(current);
  if (next != null) onMarked(current!.base!, next.base?.baselineRemoteDate);
  return next;
}

/// The transform that takes [marked] back: the base's file confidence and baseline as they were before the marking.
///
/// Declines (null) when the base no longer holds what the marking wrote, since the user has answered it another way
/// since, and undoing the marking must not undo that.
ModOrigin? undoAssumeCurrent(ModOrigin? current, MarkedAsCurrent marked) {
  final base = current?.base;
  if (base == null ||
      base.modId != marked.before.modId ||
      base.versionConfidence != OriginConfidence.assumedLatest ||
      base.baselineRemoteDate != marked.baseline) {
    return null;
  }
  return current!.withBase(
    (download) => download.withVersionBaseline(marked.before.versionConfidence, marked.before.baselineRemoteDate),
  );
}
