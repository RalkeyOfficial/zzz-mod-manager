import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/backup/retention.dart';

void main() {
  final now = DateTime.utc(2026, 8, 9, 12);
  const mb = 1024 * 1024;

  SnapshotRef snap(
    String mod,
    int daysAgo, {
    int sizeMb = 20,
    String? id,
  }) =>
      SnapshotRef(
        // The grouping key, which is a mod's uid rather than its folder name —
        // spelled here as a readable stand-in.
        modUid: mod,
        id: id ?? 'd$daysAgo',
        takenAt: now.subtract(Duration(days: daysAgo)),
        sizeBytes: sizeMb * mb,
      );

  test('the newest snapshot of a mod is never pruned', () {
    // It is the entire rollback story for that mod. A policy that can delete it
    // makes the update path's accepted losses undefendable.
    final plan = planRetention(
      [snap('ellen', 900, sizeMb: 4000)],
      now: now,
      policy: const RetentionPolicy(
        minAge: Duration(days: 1),
        keepPerMod: 1,
        maxTotalBytes: mb,
      ),
    );
    expect(plan.prune, isEmpty);
    expect(plan.overBudgetBytes, greaterThan(0));
  });

  test('age beats the count cap', () {
    // Six snapshots taken this afternoon: the count cap says keep three, the age
    // floor says keep them all, and age wins because none of them is old.
    final plan = planRetention(
      [for (var i = 0; i < 6; i++) snap('ellen', 0, id: 'a$i')],
      now: now,
    );
    expect(plan.prune, isEmpty);
  });

  test('beyond the count cap AND older than the floor is pruned', () {
    final plan = planRetention(
      [
        snap('ellen', 1),
        snap('ellen', 2),
        snap('ellen', 3),
        snap('ellen', 100),
        snap('ellen', 200),
      ],
      now: now,
    );
    expect(plan.prune.map((s) => s.id), ['d100', 'd200']);
  });

  test('size pressure reaches the young over-cap snapshots first', () {
    // Tier 2 before tier 3: a snapshot the count cap already wanted gone is a
    // better casualty than one inside it.
    final plan = planRetention(
      [
        snap('ellen', 0, sizeMb: 600),
        snap('ellen', 1, sizeMb: 600),
        snap('ellen', 2, sizeMb: 600),
        snap('ellen', 3, sizeMb: 600),
        snap('ellen', 4, sizeMb: 600),
      ],
      now: now,
      policy: const RetentionPolicy(maxTotalBytes: 2000 * mb),
    );
    expect(plan.prune.map((s) => s.id), ['d3', 'd4']);
    expect(plan.overBudgetBytes, 0);
  });

  test('size pressure then eats into the count cap, oldest first', () {
    final plan = planRetention(
      [
        snap('ellen', 0, sizeMb: 600),
        snap('ellen', 1, sizeMb: 600),
        snap('ellen', 2, sizeMb: 600),
      ],
      now: now,
      policy: const RetentionPolicy(maxTotalBytes: 700 * mb),
    );
    expect(plan.prune.map((s) => s.id), ['d1', 'd2']);
    expect(plan.keptBytes, 600 * mb);
  });

  test('the budget spans mods, and each keeps its newest', () {
    final plan = planRetention(
      [
        snap('ellen', 0, sizeMb: 900),
        snap('ellen', 5, sizeMb: 900),
        snap('lycaon', 0, sizeMb: 900),
        snap('lycaon', 6, sizeMb: 900),
      ],
      now: now,
      policy: const RetentionPolicy(maxTotalBytes: 2000 * mb),
    );
    expect(plan.prune.map((s) => '${s.modUid}/${s.id}'), [
      'ellen/d5',
      'lycaon/d6',
    ]);
    expect(plan.keptBytes, 1800 * mb);
    expect(plan.overBudgetBytes, 0);
  });

  test('an irreducible remainder is reported, not forced', () {
    // Two mods with one snapshot each, both over budget on their own. The
    // honest answer is to say so, not to leave someone with no rollback.
    final plan = planRetention(
      [snap('ellen', 0, sizeMb: 1200), snap('lycaon', 0, sizeMb: 1200)],
      now: now,
      policy: const RetentionPolicy(maxTotalBytes: 2000 * mb),
    );
    expect(plan.prune, isEmpty);
    expect(plan.overBudgetBytes, 400 * mb);
  });

  test('an empty library plans nothing', () {
    expect(planRetention(const [], now: now).isEmpty, isTrue);
  });
}
