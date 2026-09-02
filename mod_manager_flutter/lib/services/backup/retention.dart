/// How long a pre-update snapshot is kept.
///
/// Pure: it takes a list of snapshots and returns which of them to delete. The
/// filesystem work is `snapshot_service.dart`'s.
///
/// ## Retention has to outlive *discovery*, which is the stronger constraint
///
/// The update path deliberately accepts some losses — a reverted keybind, an
/// overwritten patch, a hand edit — on the grounds that the snapshot is the
/// recourse. None of those announce themselves while the update runs. They
/// surface the next time the user launches the game and finds a hotkey dead or a
/// texture back to default, which is plausibly days and several further updates
/// later.
///
/// So "keep the newest snapshot per mod" throws away exactly the one they come
/// looking for. **The age floor beats the count cap, and where they conflict,
/// age wins.**
///
/// ## Why the cap is size-aware and not just a count
///
/// The median mod archive is ~22 MB, so a generous count cap costs almost every
/// library nothing — but the tail reaches 1.24 GB, and a handful of those turn
/// "keep three per mod" into several gigabytes of invisible disk. A pure count
/// cap therefore cannot bound this; a size budget can, and it is applied *after*
/// the age and count rules rather than instead of them.
///
/// ## The tiers
///
/// Deletion walks these in order and stops as soon as the budget is met:
///
/// 0. **The newest snapshot of each mod is never pruned.** It is the entire
///    rollback story for that mod; a policy that can delete it makes the update
///    path's accepted losses undefendable.
/// 1. Beyond [RetentionPolicy.keepPerMod] **and** older than
///    [RetentionPolicy.minAge] — pruned unconditionally. Both conditions, so
///    neither rule can act alone.
/// 2. Beyond the count cap but still inside the age floor — pruned **only**
///    under size pressure, oldest first. This is where age wins over count.
/// 3. Inside the count cap — pruned only once tier 2 is exhausted and the budget
///    is still not met.
///
/// If the budget is still exceeded after tier 3, the plan says so
/// ([RetentionPlan.overBudgetBytes]) rather than reaching into tier 0. A user
/// with one 1.2 GB mod is over any sane budget by keeping a single snapshot of
/// it, and the honest answer is to report it, not to quietly leave them with no
/// rollback.
library;

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

/// The three numbers, in one place so they can be stated in the docs and
/// changed in one edit.
class RetentionPolicy {
  const RetentionPolicy({
    this.minAge = const Duration(days: 30),
    this.keepPerMod = 3,
    this.maxTotalBytes = 5 * 1024 * 1024 * 1024,
  });

  static const RetentionPolicy standard = RetentionPolicy();

  /// Nothing younger than this is deleted to satisfy the count cap.
  final Duration minAge;

  /// How many snapshots a mod keeps once they are older than [minAge].
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
///
/// [now] is injected rather than read, so the age floor is testable without
/// waiting a month.
RetentionPlan planRetention(
  List<SnapshotRef> snapshots, {
  RetentionPolicy policy = RetentionPolicy.standard,
  required DateTime now,
}) {
  if (snapshots.isEmpty) {
    return const RetentionPlan(prune: [], keptBytes: 0, overBudgetBytes: 0);
  }

  final byMod = <String, List<SnapshotRef>>{};
  for (final snapshot in snapshots) {
    byMod.putIfAbsent(snapshot.modUid, () => []).add(snapshot);
  }

  final protected = <SnapshotRef>{};
  final tier1 = <SnapshotRef>[];
  final tier2 = <SnapshotRef>[];
  final tier3 = <SnapshotRef>[];

  for (final group in byMod.values) {
    // Newest first, ties broken by id so the "newest" is stable when two
    // snapshots share a timestamp.
    group.sort((a, b) {
      final byDate = b.takenAt.compareTo(a.takenAt);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    for (var i = 0; i < group.length; i++) {
      final snapshot = group[i];
      if (i == 0) {
        protected.add(snapshot);
        continue;
      }
      final old = now.difference(snapshot.takenAt) >= policy.minAge;
      final beyondCount = i >= policy.keepPerMod;
      if (beyondCount && old) {
        tier1.add(snapshot);
      } else if (beyondCount) {
        tier2.add(snapshot);
      } else {
        tier3.add(snapshot);
      }
    }
  }

  final prune = <SnapshotRef>{...tier1};
  var kept = 0;
  for (final snapshot in snapshots) {
    if (!prune.contains(snapshot)) kept += snapshot.sizeBytes;
  }

  // Oldest first inside each tier — the age floor already decided *which* tier a
  // snapshot is in, so within a tier there is nothing to prefer but age.
  int oldestFirst(SnapshotRef a, SnapshotRef b) {
    final byDate = a.takenAt.compareTo(b.takenAt);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  }

  for (final tier in [tier2..sort(oldestFirst), tier3..sort(oldestFirst)]) {
    for (final snapshot in tier) {
      if (kept <= policy.maxTotalBytes) break;
      prune.add(snapshot);
      kept -= snapshot.sizeBytes;
    }
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
