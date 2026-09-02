import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_resolution.dart';
import 'package:mod_manager_flutter/services/origin_resolution.dart';

import 'support/fixtures.dart';
import 'support/origin_shorthand.dart';

/// The bulk resolution pass: who gets asked what, what a pre-ticked row is
/// allowed to claim, and — the half that is easy to get wrong — what happens
/// when the answer is applied to a sidecar that changed underneath it.
///
/// Ranked against a **real captured `Mod/Multi` response** (`531649`, fourteen
/// files: six current, eight archived, real md5s and real upload dates), for
/// the reason this project keeps relearning: a hand-written fixture would have
/// tidy versions and agreeing dates, and every rule below would look obviously
/// correct.
void main() {
  final rabbitFx = parseBareList(
    loadGbFixture('mod_multi_files'),
    GbMod.fromJson,
  ).firstWhere((m) => m.idRow == 531649);

  /// `v7.4`, archived. Its published md5 is what a banked hash would match.
  const mainV74 = 1696178;
  const v74Md5 = '16ff653df6a6d2a994b2dd5c4ef470b3';
  final v74Added = DateTime.fromMillisecondsSinceEpoch(1778243355 * 1000,
      isUtc: true);

  ModOrigin origin({
    int? modId = 531649,
    OriginConfidence modIdConfidence = OriginConfidence.user,
    int? fileId,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    DateTime? installedAt,
    String? archiveMd5,
    OriginTracking tracking = OriginTracking.auto,
    bool remoteMissing = false,
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: modIdConfidence,
        fileId: fileId,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        installedAt: installedAt,
        archiveMd5: archiveMd5,
        tracking: tracking,
        remoteMissing: remoteMissing,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  /// A mod publishing exactly one file, so the single-file inference can fire.
  GbMod single({
    int modId = 42,
    int fileId = 900,
    required DateTime added,
    String? md5,
  }) =>
      GbMod(
        idRow: modId,
        name: 'One File Mod',
        files: [
          GbFile(
            idRow: fileId,
            file: 'onefile.zip',
            dateAdded: added,
            md5Checksum: md5,
          ),
        ],
      );

  GbMod gone(int modId) => GbMod(idRow: modId, name: 'Gone', isTrashed: true);

  group('who gets a row', () {
    test('a mod with no remote id gets none, and is counted instead', () {
      // Bulk acts only on precise handles. Identifying an untracked mod means
      // fuzzy-matching a folder name against a search, and a rubber-stamped
      // wrong match would later let an "update" overwrite it with an unrelated
      // mod's files.
      final plan = planBulkResolution(
        mods: [mod('bare'), mod('no id', origin: origin(modId: null))],
        records: {531649: rabbitFx},
      );
      expect(plan.rows, isEmpty);
      expect(plan.untracked.map((m) => m.name), ['bare', 'no id']);
      expect(plan.hasWork, isFalse);
    });

    test('"not from GameBanana" is not revisited here', () {
      final plan = planBulkResolution(
        mods: [
          mod('mine', origin: origin(tracking: OriginTracking.off)),
        ],
        records: {531649: rabbitFx},
      );
      expect(plan.rows, isEmpty);
      expect(plan.settled, 1);
    });

    test('a mod the pass never reached is unreachable, not settled', () {
      // "No questions" and "no questions among the mods we could reach" are
      // different statements, and a row cannot be confirmed against a record
      // that never arrived.
      final plan = planBulkResolution(
        mods: [mod('a', origin: origin(modId: 777))],
        records: const {},
      );
      expect(plan.rows, isEmpty);
      expect(plan.unreachable, 1);
      expect(plan.settled, 0);
    });

    test('a fully resolved mod is a number, not a row', () {
      final plan = planBulkResolution(
        mods: [
          mod('done',
              origin: origin(
                fileId: mainV74,
                versionConfidence: OriginConfidence.user,
              )),
        ],
        records: {531649: rabbitFx},
      );
      expect(plan.rows, isEmpty);
      expect(plan.settled, 1);
    });
  });

  group('what a row is asked', () {
    test('an inferred identity is asked to be confirmed', () {
      final plan = planBulkResolution(
        mods: [
          mod('legacy',
              origin: origin(
                modIdConfidence: OriginConfidence.inferred,
                fileId: mainV74,
                versionConfidence: OriginConfidence.user,
              )),
        ],
        records: {531649: rabbitFx},
      );
      final row = plan.rows.single;
      expect(row.needsIdentity, isTrue);
      expect(row.needsVersion, isFalse, reason: 'the file is already on record');
      expect(row.remoteName, 'ZZMI RabbitFX - Glow FX + Censor Remover');
    });

    test('one row can carry both questions', () {
      // The commonest shape in a legacy library: an id parsed out of a pasted
      // url and no version at all. One row, one write.
      final plan = planBulkResolution(
        mods: [
          mod('legacy',
              origin: origin(modIdConfidence: OriginConfidence.inferred)),
        ],
        records: {531649: rabbitFx},
      );
      final row = plan.rows.single;
      expect(row.needsIdentity, isTrue);
      expect(row.needsVersion, isTrue);
      expect(row.candidates, hasLength(14),
          reason: 'current and archived both rank — an old install usually '
              'matches a superseded file');
    });

    test('a gone page is asked one question and only that one', () {
      // Nothing else has an answer: a file list read off a private page is
      // empty, and an identity confirmed against a blank confirms nothing.
      final plan = planBulkResolution(
        mods: [
          mod('vanished',
              origin: origin(
                modId: 42,
                modIdConfidence: OriginConfidence.inferred,
              )),
        ],
        records: {42: gone(42)},
      );
      final row = plan.rows.single;
      expect(row.sourceGone, isTrue);
      expect(row.needsIdentity, isFalse);
      expect(row.needsVersion, isFalse);
    });

    test('a page that came back offers to clear the flag', () {
      final plan = planBulkResolution(
        mods: [
          mod('back',
              origin: origin(
                fileId: mainV74,
                versionConfidence: OriginConfidence.user,
                remoteMissing: true,
              )),
        ],
        records: {531649: rabbitFx},
      );
      expect(plan.rows.single.sourceBack, isTrue);
    });

    test('a gone page already recorded as gone asks nothing', () {
      final plan = planBulkResolution(
        mods: [
          mod('vanished', origin: origin(modId: 42, remoteMissing: true)),
        ],
        records: {42: gone(42)},
      );
      expect(plan.rows, isEmpty);
      expect(plan.settled, 1);
    });
  });

  group('what the pass may answer by itself', () {
    test('a banked hash resolves the row outright, at exact', () {
      final plan = planBulkResolution(
        mods: [mod('hashed', origin: origin(archiveMd5: v74Md5))],
        records: {531649: rabbitFx},
      );
      final suggestion = plan.rows.single.suggestion!;
      expect(suggestion.file.idRow, mainV74);
      expect(suggestion.reason, FileMatchReason.archiveHash);
      expect(suggestion.isExact, isTrue);
    });

    test('a folder-name match is offered but never pre-ticked', () {
      // A suggestion informs; it does not drive. The row still lists it with
      // its reason, so the user can take it in one tap.
      final plan = planBulkResolution(
        mods: [mod('v74', origin: origin())],
        records: {531649: rabbitFx},
      );
      final row = plan.rows.single;
      expect(row.suggestion, isNull);
      expect(
        row.candidates.first.reason,
        FileMatchReason.folderName,
        reason: 'ranked first, and shown with its reason',
      );
    });

    test('a mod with fourteen files never pre-ticks anything', () {
      final plan = planBulkResolution(
        mods: [mod('ambiguous', origin: origin(installedAt: v74Added))],
        records: {531649: rabbitFx},
      );
      expect(plan.rows.single.suggestion, isNull);
      expect(plan.autoResolvable, isEmpty);
    });

    test('one file uploaded before the install is inferred', () {
      final added = DateTime.utc(2026, 1, 1);
      final plan = planBulkResolution(
        mods: [
          mod('lone',
              origin: origin(modId: 42, installedAt: DateTime.utc(2026, 2, 1))),
        ],
        records: {42: single(added: added)},
      );
      final suggestion = plan.rows.single.suggestion!;
      expect(suggestion.file.idRow, 900);
      // The *reason* shown is whatever evidence ranked highest — here the file
      // also happens to predate the install, so it reads `installDate` rather
      // than `onlyFile`. What decides the pre-tick is the list having one entry,
      // which is a property of the list rather than a reason on a row.
      expect(suggestion.reason, FileMatchReason.installDate);
      expect(suggestion.isExact, isFalse, reason: 'inferred, not exact');
    });

    test('one file uploaded after the install is not', () {
      // The one thing on the page provably is *not* what the user has: their
      // file was deleted outright. Recording it would invent a version and then
      // report the mod as up to date.
      final plan = planBulkResolution(
        mods: [
          mod('lone',
              origin: origin(modId: 42, installedAt: DateTime.utc(2026, 1, 1))),
        ],
        records: {42: single(added: DateTime.utc(2026, 2, 1))},
      );
      final row = plan.rows.single;
      expect(row.suggestion, isNull);
      expect(row.needsVersion, isTrue, reason: 'still pickable by hand');
    });

    test('one file and no install date at all is not inferred either', () {
      final plan = planBulkResolution(
        mods: [mod('lone', origin: origin(modId: 42))],
        records: {42: single(added: DateTime.utc(2026))},
      );
      expect(plan.rows.single.suggestion, isNull);
    });
  });

  group('applying an answer', () {
    BulkResolutionAnswer answer({
      int modId = 531649,
      bool confirmIdentity = false,
      GbFile? file,
      OriginConfidence tier = OriginConfidence.inferred,
      bool? remoteMissing,
    }) =>
        BulkResolutionAnswer(
          modId: modId,
          confirmIdentity: confirmIdentity,
          file: file,
          fileConfidence: tier,
          remoteMissing: remoteMissing,
        );

    GbFile fileV74() =>
        rabbitFx.allFiles!.firstWhere((f) => f.idRow == mainV74);

    test('confirming raises an inferred identity to user', () {
      final next = applyBulkResolution(
        origin(modIdConfidence: OriginConfidence.inferred),
        answer(confirmIdentity: true),
      );
      expect(next!.modIdConfidence, OriginConfidence.user);
    });

    test('an inferred file is written at inferred, never at user', () {
      final next = applyBulkResolution(origin(), answer(file: fileV74()));
      expect(next!.fileId, mainV74);
      expect(next.version, '7.4');
      expect(next.versionLabel, 'Main file');
      expect(next.versionConfidence, OriginConfidence.inferred);
    });

    test('picking a row off the list is the user saying so', () {
      final next = applyBulkResolution(
        origin(),
        answer(file: fileV74(), tier: OriginConfidence.user),
      );
      expect(next!.versionConfidence, OriginConfidence.user);
    });

    test('picking a file confirms the identity too', () {
      // Choosing a file off a mod's own file list is a stronger statement that
      // this is your mod than ticking a box beside its name — the same rule the
      // per-mod dialog follows when it binds before it writes.
      final next = applyBulkResolution(
        origin(modIdConfidence: OriginConfidence.inferred),
        answer(file: fileV74(), tier: OriginConfidence.user),
      );
      expect(next!.modIdConfidence, OriginConfidence.user);
    });

    test('a hash match confirms it as well — that one is proof', () {
      final next = applyBulkResolution(
        origin(modIdConfidence: OriginConfidence.inferred),
        answer(file: fileV74(), tier: OriginConfidence.exact),
      );
      expect(next!.modIdConfidence, OriginConfidence.user);
      expect(next.versionConfidence, OriginConfidence.exact);
    });

    test('the pass\'s own inference does NOT confirm the identity', () {
      // The bug this pins. The single-file inference arrives *pre-ticked*, so
      // pressing Save on a row whose "yes, this is the right mod page" was
      // deliberately left unticked would otherwise raise the identity to `user`
      // anyway — laundering a guess from a pasted url into the tier that lets an
      // update overwrite files, on the one screen where the user visibly
      // declined to confirm it.
      final next = applyBulkResolution(
        origin(modIdConfidence: OriginConfidence.inferred),
        answer(file: fileV74()),
      );
      expect(next!.versionConfidence, OriginConfidence.inferred);
      expect(next.modIdConfidence, OriginConfidence.inferred,
          reason: 'still a guess on both axes, which caps the verdict');
    });

    test('an untouched row writes nothing at all', () {
      // What Save does for a row where nothing was ticked: it is not in the map
      // the dialog hands over, and even if it were the transform declines.
      expect(
        applyBulkResolution(
          origin(modIdConfidence: OriginConfidence.inferred),
          answer(),
        ),
        isNull,
      );
      expect(answer().isEmpty, isTrue);
    });

    test('an inference never displaces a version already on record', () {
      // The guard that matters. A mod resolved *exactly* while the batch ran
      // must not be downgraded to a guess by a plan built before it was.
      final current = origin(
        fileId: 1732269,
        versionConfidence: OriginConfidence.exact,
      );
      final next = applyBulkResolution(current, answer(file: fileV74()));
      expect(next, isNull, reason: 'nothing left to write, so nothing written');
    });

    test('a declined file does not throw away a confirmed identity', () {
      final current = origin(
        modIdConfidence: OriginConfidence.inferred,
        fileId: 1732269,
        versionConfidence: OriginConfidence.exact,
      );
      final next = applyBulkResolution(
        current,
        answer(confirmIdentity: true, file: fileV74()),
      );
      expect(next!.modIdConfidence, OriginConfidence.user);
      expect(next.fileId, 1732269, reason: 'the better answer stands');
      expect(next.versionConfidence, OriginConfidence.exact);
    });

    test('a folder rebound while the screen was open is abandoned', () {
      final next = applyBulkResolution(
        origin(modId: 999),
        answer(confirmIdentity: true, file: fileV74()),
      );
      expect(next, isNull);
    });

    test('an untracked folder is abandoned rather than created', () {
      expect(applyBulkResolution(null, answer(confirmIdentity: true)), isNull);
    });

    test('remote_missing is written and cleared by the same answer', () {
      final marked = applyBulkResolution(origin(), answer(remoteMissing: true));
      expect(marked!.remoteMissing, isTrue);
      final cleared = applyBulkResolution(
        origin(remoteMissing: true),
        answer(remoteMissing: false),
      );
      expect(cleared!.remoteMissing, isFalse);
    });

    test('an answer that changes nothing writes nothing', () {
      expect(
        applyBulkResolution(
          origin(modIdConfidence: OriginConfidence.user),
          answer(confirmIdentity: true),
        ),
        isNull,
      );
    });
  });
}
