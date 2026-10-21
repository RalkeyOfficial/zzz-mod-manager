import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/services/update_check_run.dart';

import 'support/origin_shorthand.dart';

/// A check's results land only on folders nothing else changed while it ran.
void main() {
  ModInfo mod(String id, {int fileId = 10}) => ModInfo(
        id: id,
        name: id,
        characterId: 'ellen',
        isActive: false,
        origin: originFixture(modId: 1, modIdConfidence: OriginConfidence.user, fileId: fileId),
      );
  const before = UpdateCheck(outcome: UpdateOutcome.updateAvailable, subjectModId: 1);
  const found = UpdateCheck(outcome: UpdateOutcome.upToDate, subjectModId: 1);

  Set<String> changed(
    UpdateCheckStart start, {
    Map<String, UpdateCheck> checks = const {},
    required List<ModInfo> mods,
    Set<String> writing = const {},
    Map<String, int> writesStarted = const {},
  }) =>
      start.changedSince(checks: checks, mods: mods, writing: writing, writesStarted: writesStarted);

  test('a folder left alone takes the result', () {
    final start = UpdateCheckStart(checks: {'a': before}, mods: [mod('a')], writesStarted: {'a': 2}, writing: const {});
    expect(changed(start, checks: {'a': before}, mods: [mod('a')], writesStarted: {'a': 2}), isEmpty);
  });

  test('a write started since, ended and not yet rescanned, keeps the folder out', () {
    // As the tracking screen or a marking: the write is over, the verdict untouched, and the scan still shows the
    // block from before.
    final start = UpdateCheckStart(checks: const {}, mods: [mod('a'), mod('b')], writesStarted: {'a': 1}, writing: const {});
    expect(changed(start, mods: [mod('a'), mod('b')], writesStarted: {'a': 2, 'b': 1}), {'a', 'b'});
  });

  test('a write already running when the check started keeps the folder out, though it ended since', () {
    // As one folder of an update into several: it started before the check, and its rescan comes after the results.
    final start = UpdateCheckStart(checks: const {}, mods: [mod('a'), mod('b')], writesStarted: {'a': 1}, writing: {'a'});
    expect(changed(start, mods: [mod('a'), mod('b')], writesStarted: {'a': 1}), {'a'});
  });

  test("a verdict set or dropped since the start, as the update dialog's own check does, keeps the folder's", () {
    final start = UpdateCheckStart(checks: {'a': before, 'b': before}, mods: [mod('a'), mod('b')], writesStarted: const {}, writing: const {});
    expect(changed(start, checks: {'a': before.asDismissed(true)}, mods: [mod('a'), mod('b')]), {'a', 'b'});
  });

  test('tracking that differs on the last scan keeps the folder out', () {
    final start = UpdateCheckStart(checks: const {}, mods: [mod('a'), mod('b')], writesStarted: const {}, writing: const {});
    expect(changed(start, mods: [mod('a', fileId: 11), mod('b')]), {'a'});
  });

  test('a folder being written, or gone, keeps out too', () {
    final start = UpdateCheckStart(checks: const {}, mods: [mod('a'), mod('b'), mod('c')], writesStarted: const {}, writing: const {});
    expect(changed(start, mods: [mod('a'), mod('b')], writing: {'a'}), {'a', 'c'});
  });

  test('the merge leaves the kept folders as they are and takes the rest', () {
    const outcome = BulkUpdateCheckOutcome(checks: {'a': found, 'b': found}, failed: {}, requests: 1);
    final merged = mergedChecks({'a': before, 'c': before}, outcome, keep: {'a'});
    expect(merged, {'a': before, 'b': found, 'c': before});
  });
}
