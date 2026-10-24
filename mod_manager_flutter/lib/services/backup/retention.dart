/// How many pre-update snapshots a mod keeps.
///
/// Pure: it takes a list of snapshots and returns which of them to delete. The
/// filesystem work is `snapshot_service.dart`'s.
///
/// ## The user picks the count; the size budget is a backstop
///
/// Each mod keeps its newest [RetentionPolicy.keepPerMod] snapshots, a number the
/// user sets in Settings. The median mod archive is ~22 MB, so a handful per mod
/// costs almost every library nothing, but the tail reaches 1.24 GB and a few of
/// those turn any count into several gigabytes of invisible disk. A count cannot
/// bound that; a size budget can, so it is applied *after* the count rather than
/// instead of it.
///
/// ## The tiers
///
/// Deletion walks these in order and stops as soon as the budget is met:
///
/// 0. **The newest snapshot of each mod is never pruned.** It is the entire
///    rollback story for that mod; a policy that can delete it makes the update
///    path's accepted losses undefendable.
/// 1. Beyond [RetentionPolicy.keepPerMod] — pruned unconditionally.
/// 2. Inside the count but not the newest — pruned only under size pressure,
///    oldest first.
///
/// If the budget is still exceeded after tier 2, the plan says so
/// ([RetentionPlan.overBudgetBytes]) rather than reaching into tier 0. A user
/// with one 1.2 GB mod is over any sane budget by keeping a single snapshot of
/// it, and the honest answer is to report it, not to quietly leave them with no
/// rollback.
library;

/// How many snapshots a mod keeps until the user says otherwise.
const int defaultSnapshotsToKeep = 3;

/// The fewest and most snapshots a mod can be set to keep. One is the floor
/// because the newest is never pruned anyway; ten keeps the stepper short and the
/// budget meaningful.
const int minSnapshotsToKeep = 1;
const int maxSnapshotsToKeep = 10;

int clampSnapshotsToKeep(int count) => count.clamp(minSnapshotsToKeep, maxSnapshotsToKeep);

/// One snapshot on disk, as far as retention is concerned.
class SnapshotRef {
  const SnapshotRef({
    required this.modUid,
    required this.id,
    required this.takenAt,
    required this.sizeBytes,
  });

  /// Which mod this belongs to — **its uid, never its folder name.**
  ///
  /// Grouping is what the tiers below are computed per, so this decides what
  /// "each mod's newest" means. A name would make one mod look like two the
  /// moment it was renamed, and each half would then keep a newest of its own
  /// forever.
  final String modUid;

  /// The snapshot directory's name — unique within the mod.
  final String id;

  final DateTime takenAt;
  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is SnapshotRef && other.modUid == modUid && other.id == id;

  @override
  int get hashCode => Object.hash(modUid, id);

  @override
  String toString() => '$modUid/$id';
}

/// The two numbers, in one place so they can be stated in the docs and changed
/// in one edit.
class RetentionPolicy {
  const RetentionPolicy({
    this.keepPerMod = defaultSnapshotsToKeep,
    this.maxTotalBytes = 5 * 1024 * 1024 * 1024,
  });

  static const RetentionPolicy standard = RetentionPolicy();

  /// How many snapshots a mod keeps, the newest included.
  final int keepPerMod;

  /// Budget across every mod. Five gigabytes: enough that a normal library never
  /// meets it, small enough that a few tail-sized mods cannot quietly eat a
  /// disk.
  final int maxTotalBytes;
}

/// What to delete, and what is left.
class RetentionPlan {
  const RetentionPlan({
    required this.prune,
    required this.keptBytes,
    required this.overBudgetBytes,
  });

  final List<SnapshotRef> prune;

  /// Total size of everything that survives.
  final int keptBytes;

  /// How far over [RetentionPolicy.maxTotalBytes] the survivors still are, or
  /// zero. Non-zero only when the remainder is entirely tier 0 — one
  /// irreducible snapshot per mod.
  final int overBudgetBytes;

  bool get isEmpty => prune.isEmpty;
}

/// Decides which snapshots to delete.
RetentionPlan planRetention(
  List<SnapshotRef> snapshots, {
  RetentionPolicy policy = RetentionPolicy.standard,
}) {
  if (snapshots.isEmpty) {
    return const RetentionPlan(prune: [], keptBytes: 0, overBudgetBytes: 0);
  }

  final byMod = <String, List<SnapshotRef>>{};
  for (final snapshot in snapshots) {
    byMod.putIfAbsent(snapshot.modUid, () => []).add(snapshot);
  }

  final tier1 = <SnapshotRef>[];
  final tier2 = <SnapshotRef>[];

  for (final group in byMod.values) {
    // Newest first, ties broken by id so the "newest" is stable when two
    // snapshots share a timestamp.
    group.sort((a, b) {
      final byDate = b.takenAt.compareTo(a.takenAt);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    // Index 0 is tier 0 and goes nowhere.
    for (var i = 1; i < group.length; i++) {
      (i >= policy.keepPerMod ? tier1 : tier2).add(group[i]);
    }
  }

  final prune = <SnapshotRef>{...tier1};
  var kept = 0;
  for (final snapshot in snapshots) {
    if (!prune.contains(snapshot)) kept += snapshot.sizeBytes;
  }

  // Oldest first inside the tier: the count already decided which tier a
  // snapshot is in, so there is nothing to prefer but age.
  tier2.sort((a, b) {
    final byDate = a.takenAt.compareTo(b.takenAt);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  for (final snapshot in tier2) {
    if (kept <= policy.maxTotalBytes) break;
    prune.add(snapshot);
    kept -= snapshot.sizeBytes;
  }

  return RetentionPlan(
    prune: prune.toList()
      ..sort((a, b) {
        final byMod = a.modUid.compareTo(b.modUid);
        return byMod != 0 ? byMod : a.id.compareTo(b.id);
      }),
    keptBytes: kept,
    overBudgetBytes:
        kept > policy.maxTotalBytes ? kept - policy.maxTotalBytes : 0,
  );
}
