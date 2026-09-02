import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

import 'support/origin_shorthand.dart';

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
      originFixture(
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

  group('a folder with two identities', () {
    /// A mixed folder: the origin block names [modId] (the patch we installed)
    /// and a companion names [baseId] (the mod it patches, which the user told
    /// us about).
    ModInfo mixed(
      String name, {
      required int modId,
      int fileId = 10,
      required int baseId,
      int? baseFileId = 10,
    }) =>
        mod(
          name,
          origin: origin(modId: modId, fileId: fileId).copyWith(
            companions: [
              ModCompanion(
                role: CompanionRole.base,
                modId: baseId,
                modIdConfidence: OriginConfidence.user,
                fileId: baseFileId,
                versionConfidence: baseFileId == null
                    ? OriginConfidence.unknown
                    : OriginConfidence.user,
              ),
            ],
          ),
        );

    test('is asked about under both of its ids', () {
      final plan = planBulkUpdateCheck([
        mixed('EllenBikini', modId: 222, baseId: 111),
      ]);
      expect(plan.modIds..sort(), [111, 222]);
      expect(plan.byModId[222]?.map((m) => m.id), ['EllenBikini']);
      expect(plan.byModId[111]?.map((m) => m.id), ['EllenBikini']);
    });

    test('counts as one mod however many pages answer for it', () {
      // What the toolbar button promises. The user counts cards, and a mixed
      // folder is one card — the *request* count is the internal number and is
      // reported separately as `outcome.requests`.
      final plan = planBulkUpdateCheck([
        mixed('EllenBikini', modId: 222, baseId: 111),
      ]);
      expect(plan.modIds.length, 2, reason: 'two pages to ask');
      expect(plan.checkableCount, 1, reason: 'one mod to report on');
    });

    test('a folder the user declared their own asks about neither half', () {
      // The folder-level switch, which is exactly why a companion carries no
      // `tracking` of its own. A muted mod must not be able to speak through
      // its second identity.
      final plan = planBulkUpdateCheck([
        mod(
          'mine',
          origin: origin(modId: 222, tracking: OriginTracking.off).copyWith(
            companions: const [
              ModCompanion(role: CompanionRole.base, modId: 111),
            ],
          ),
        ),
      ]);
      expect(plan.modIds, isEmpty);
      expect(plan.skipped['mine']?.outcome, UpdateOutcome.trackingOff);
    });

    test('a finding on the other mod reaches the folder', () async {
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          // The patch is on its newest file — nothing newer there.
          mixed('EllenBikini', modId: 222, fileId: 10, baseId: 111,
              baseFileId: 99),
        ]),
        // Both mods publish only file 10, so the base's recorded file 99 is
        // gone from its page: a real finding, and one only the second identity
        // can produce.
        fetch: (ids) async => [for (final id in ids) record(id)],
        batchSize: 1,
      );

      final check = outcome.checks['EllenBikini']!;
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.subjectModId, 111,
          reason: 'the finding belongs to the base mod, and the verdict has to '
              'say so or the dialog shows one mod\'s files under another\'s name');
      expect(outcome.updatesFound, 1);
    });

    test('a verdict is not overwritten by a later batch', () async {
      // **The failure §2d names.** The pass used to fold as each record
      // arrived, so a folder under two ids was written twice and the second
      // write won — the primary's origin compared against the *companion's*
      // page, which is nonsense that happens to look like an answer.
      //
      // Catching it needs the two records to disagree about the primary's own
      // file. 222 no longer publishes file 99, so the primary is superseded;
      // 111 does publish it, so the same origin folded against 111's page
      // reads as up to date and the finding vanishes.
      //
      // `modIds` is insertion-ordered, primary before companion, so batchSize 1
      // lands 222 first and 111 last — the losing order for fold-on-arrival.
      final asked = <List<int>>[];
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mixed('EllenBikini', modId: 222, fileId: 99, baseId: 111,
              baseFileId: 10),
        ]),
        fetch: (ids) async {
          asked.add(ids);
          return [
            for (final id in ids)
              GbMod(
                idRow: id,
                files: [
                  GbFile(idRow: 10, dateAdded: DateTime.utc(2026)),
                  // Only the base mod still offers the file the *patch* was
                  // installed from. Nothing about that is odd — the two pages
                  // number their files independently.
                  if (id == 111)
                    GbFile(idRow: 99, dateAdded: DateTime.utc(2026)),
                ],
              ),
          ];
        },
        batchSize: 1,
      );

      expect(asked, [
        [222],
        [111],
      ], reason: 'the finding must land before the answer that would mask it, '
          'or this test cannot fail');

      final check = outcome.checks['EllenBikini']!;
      expect(check.outcome, UpdateOutcome.updateAvailable);
      expect(check.subjectModId, isNull, reason: 'null names the primary');
    });

    test('a companion whose page could not be reached is never clean',
        () async {
      // The pass got a real answer for the patch and nothing for the base. The
      // folder is *not* up to date — it is unanswered, and saying otherwise is
      // the false clean this whole feature exists to remove.
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mixed('EllenBikini', modId: 222, fileId: 10, baseId: 111),
        ]),
        fetch: (ids) async {
          if (ids.contains(111)) throw Exception('offline');
          return [for (final id in ids) record(id)];
        },
        batchSize: 1,
      );

      expect(outcome.checks['EllenBikini']?.outcome,
          isNot(UpdateOutcome.upToDate));
      expect(outcome.failed, contains('EllenBikini'));
    });

    test('the reported case: a patch folder whose base has a newer variant',
        () async {
      // Reproduces a real pair, with real dates. The folder is a patch
      // installed from its own page; the mod it patches published a second
      // variant six days after the one recorded here, in its own update post —
      // so no release group suppresses it.
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mod(
            'the patch',
            origin: origin(modId: 605460, fileId: 1473174).copyWith(
              companions: const [
                ModCompanion(
                  role: CompanionRole.base,
                  modId: 585282,
                  modIdConfidence: OriginConfidence.user,
                  fileId: 1430055,
                  versionLabel: 'SFW Variants Only',
                  versionConfidence: OriginConfidence.user,
                ),
              ],
            ),
          ),
        ]),
        fetch: (ids) async => [
          for (final id in ids)
            if (id == 605460)
              GbMod(idRow: id, files: [
                GbFile(
                    idRow: 1473174,
                    dateAdded: DateTime.utc(2025, 7, 7, 15, 18, 30)),
              ])
            else
              GbMod(idRow: id, files: [
                GbFile(
                  idRow: 1430055,
                  description: 'SFW Variants Only',
                  dateAdded: DateTime.utc(2025, 4, 29, 18, 6, 59),
                ),
                GbFile(
                  idRow: 1433843,
                  description: 'NSFW Variants Included',
                  dateAdded: DateTime.utc(2025, 5, 5, 13, 18, 22),
                ),
              ]),
        ],
        // Two posts, one file each — `ReleaseGroups` keeps only groups of more
        // than one, so this is empty and suppresses nothing.
        fetchUpdates: (modId) async => [
          GbUpdate(idRow: 338426, fileRowIds: const {1433843}),
          GbUpdate(idRow: 337261, fileRowIds: const {1430055}),
        ],
      );

      final check = outcome.checks['the patch']!;
      expect(check.hasUpdate, isTrue);
      expect(check.subjectModId, 585282);
      expect(check.candidate?.idRow, 1433843);
    });

    test('the release feed is pulled for the identity that flagged', () async {
      // Phase two only runs for mods that flagged, and here that is the
      // companion. Asking the patch's feed would refine the wrong verdict and
      // leave the real finding unrefined.
      final feedsAsked = <int>[];
      await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mixed('EllenBikini', modId: 222, fileId: 10, baseId: 111,
              baseFileId: 99),
        ]),
        fetch: (ids) async => [for (final id in ids) record(id)],
        fetchUpdates: (modId) async {
          feedsAsked.add(modId);
          return const [];
        },
      );

      expect(feedsAsked, [111],
          reason: 'only the identity that produced the finding — release groups '
              'refine one mod\'s verdict, and the patch\'s groups say nothing '
              'about the base mod\'s files');
    });

    test('a release group on the companion re-folds the folder', () async {
      // Phase two can turn a flag *off*, and when it turns off the one the
      // folder was reporting, the folder falls back to what its other identity
      // said rather than keeping a verdict that has just been withdrawn.
      final outcome = await runBulkUpdateCheck(
        plan: planBulkUpdateCheck([
          mixed('EllenBikini', modId: 222, fileId: 10, baseId: 111,
              baseFileId: 99),
        ]),
        fetch: (ids) async => [
          for (final id in ids)
            GbMod(
              idRow: id,
              files: [
                GbFile(idRow: 10, dateAdded: DateTime.utc(2026)),
                if (id == 111) GbFile(idRow: 99, dateAdded: DateTime.utc(2025)),
              ],
            ),
        ],
        // The author shipped 99 and 10 together, so 10 is the other variant of
        // the installed file rather than its successor.
        fetchUpdates: (modId) async => [
          GbUpdate(idRow: 1, fileRowIds: const {10, 99}),
        ],
      );

      final check = outcome.checks['EllenBikini']!;
      expect(check.hasUpdate, isFalse);
      expect(outcome.updatesFound, 0);
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
