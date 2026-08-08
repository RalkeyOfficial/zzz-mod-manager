import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

/// The whole-library pass: what it asks about, how it batches, and — the part
/// that is genuinely easy to get wrong — what it does when the batch endpoint
/// refuses the whole request because one id is bad.
///
/// That is not a hypothetical: most ids in a legacy library are `inferred`,
/// parsed out of a `source_url` somebody typed. A wrong paste, a mod since
/// deleted, and `Mod/Multi` answers `400` for the other forty-nine.
void main() {
  ModOrigin origin({
    int? modId,
    int? fileId,
    OriginTracking tracking = OriginTracking.auto,
  }) =>
      ModOrigin(
        source: modId == null ? null : 'gamebanana',
        modId: modId,
        modIdConfidence:
            modId == null ? OriginConfidence.unknown : OriginConfidence.user,
        fileId: fileId,
        versionConfidence:
            fileId == null ? OriginConfidence.unknown : OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
        tracking: tracking,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  /// A remote mod publishing one current file, [fileId], added in 2026.
  GbMod record(int modId, {int fileId = 10}) => GbMod(
        idRow: modId,
        files: [GbFile(idRow: fileId, dateAdded: DateTime.utc(2026))],
      );

  GbApiException noSuchRecord() => const GbApiException(
        "Record Mod.999 doesn't exist",
        code: 'INPUT_ERRORS',
        statusCode: 400,
        fieldErrors: {
          '_csvRowIds': GbFieldError(code: 'NO_SUCH_RECORD'),
        },
      );

  group('planning', () {
    test('splits by what can be asked about at all', () {
      final plan = planBulkUpdateCheck([
        mod('tracked', origin: origin(modId: 1, fileId: 10)),
        mod('bare'),
        mod('no id', origin: origin()),
        mod('mine', origin: origin(modId: 2, tracking: OriginTracking.off)),
      ]);

      expect(plan.modIds, [1]);
      expect(plan.checkableCount, 1);
      expect(plan.skipped['bare']?.outcome, UpdateOutcome.untracked);
      expect(plan.skipped['no id']?.outcome, UpdateOutcome.untracked);
      expect(plan.skipped['mine']?.outcome, UpdateOutcome.trackingOff);
    });

    test('one mod page can be several folders', () {
      // Two variants of one mod installed side by side is common, not an edge
      // case — measured twice in a real 23-mod library. They share a request
      // and each gets its own verdict, because each has its own file id.
      final plan = planBulkUpdateCheck([
        mod('a', origin: origin(modId: 7, fileId: 10)),
        mod('b', origin: origin(modId: 7, fileId: 11)),
      ]);
      expect(plan.modIds, [7]);
      expect(plan.checkableCount, 2);
    });
  });

  group('running', () {
    test('batches, and folds a record onto every folder that shares its id',
        () async {
      final asked = <List<int>>[];
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mod('a', origin: origin(modId: 1, fileId: 10)),
          mod('b', origin: origin(modId: 1, fileId: 99)),
          mod('c', origin: origin(modId: 2, fileId: 10)),
          mod('d', origin: origin(modId: 3, fileId: 10)),
        ]),
        fetch: (ids) async {
          asked.add(ids);
          return [for (final id in ids) record(id)];
        },
        batchSize: 2,
      );

      expect(asked, [
        [1, 2],
        [3],
      ]);
      expect(outcome.requests, 2);
      expect(outcome.checks['a']?.outcome, UpdateOutcome.upToDate);
      // Same remote record, different recorded file — and file 99 is not among
      // what the mod offers now.
      expect(outcome.checks['b']?.outcome, UpdateOutcome.updateAvailable);
      expect(outcome.updatesFound, 1);
      expect(outcome.failed, isEmpty);
    });

    test('halves the batch around an id the server refuses', () async {
      final asked = <List<int>>[];
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          for (final id in [1, 2, 3, 999])
            mod('mod$id', origin: origin(modId: id, fileId: 10)),
        ]),
        fetch: (ids) async {
          asked.add(ids);
          if (ids.contains(999)) throw noSuchRecord();
          return [for (final id in ids) record(id)];
        },
      );

      // The good mods still get real answers…
      expect(outcome.checks['mod1']?.outcome, UpdateOutcome.upToDate);
      expect(outcome.checks['mod2']?.outcome, UpdateOutcome.upToDate);
      expect(outcome.checks['mod3']?.outcome, UpdateOutcome.upToDate);
      // …and the bad id is an answer of its own, not a failure to report.
      expect(outcome.checks['mod999']?.outcome, UpdateOutcome.sourceGone);
      expect(outcome.failed, isEmpty);
      expect(outcome.abortedBy, isNull);
      // Narrowed rather than retried one at a time: [1,2,3,999] → [1,2] →
      // [3,999] → [3] → [999].
      expect(asked.last, [999]);
      expect(outcome.requests, lessThan(8));
    });

    test('an error about anything but the ids aborts instead of splitting',
        () async {
      // A malformed `_csvProperties` fails identically for every half, so
      // bisecting would issue a hundred requests to learn what the first one
      // already said.
      var calls = 0;
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          for (final id in [1, 2, 3, 4])
            mod('mod$id', origin: origin(modId: id, fileId: 10)),
        ]),
        fetch: (ids) async {
          calls++;
          throw const GbApiException(
            'bad property',
            code: 'INPUT_ERRORS',
            statusCode: 400,
            fieldErrors: {
              '_csvProperties': GbFieldError(code: 'UNKNOWN_PROPERTY'),
            },
          );
        },
      );

      expect(calls, 1);
      expect(outcome.abortedBy, isA<GbApiException>());
      // Every mod the pass never answered is reported unchecked, whichever way
      // it gave up. "No entry in the map" is indistinguishable from "not in the
      // library" to the caller, and a summary built from that would describe
      // nothing-was-checked as nothing-was-found.
      expect(outcome.failed, {'mod1', 'mod2', 'mod3', 'mod4'});
      expect(outcome.checks.values.where((c) => c.hasUpdate), isEmpty);
    });

    test('an outage is reported as unchecked, never as up to date', () async {
      var calls = 0;
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          for (final id in [1, 2, 3, 4])
            mod('mod$id', origin: origin(modId: id, fileId: 10)),
        ]),
        fetch: (ids) async {
          calls++;
          throw const GbNetworkException('offline');
        },
        batchSize: 2,
      );

      // Not split, and the remaining batch is not attempted — the answer would
      // be the same, and the honest report is "we could not look".
      expect(calls, 1);
      expect(outcome.failed, {'mod1', 'mod2', 'mod3', 'mod4'});
      expect(outcome.abortedBy, isA<GbNetworkException>());
    });

    test('an id that comes back in nothing is treated as gone', () async {
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mod('a', origin: origin(modId: 1, fileId: 10)),
          mod('b', origin: origin(modId: 2, fileId: 10)),
        ]),
        fetch: (ids) async => [record(1)],
      );
      expect(outcome.checks['a']?.outcome, UpdateOutcome.upToDate);
      expect(outcome.checks['b']?.outcome, UpdateOutcome.sourceGone);
    });

    test('mods that need no request are still in the result', () async {
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([mod('bare')]),
        fetch: (ids) async => fail('should not have asked about anything'),
      );
      expect(outcome.requests, 0);
      expect(outcome.checks['bare']?.outcome, UpdateOutcome.untracked);
    });
  });
}
