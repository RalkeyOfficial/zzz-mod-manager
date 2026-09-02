import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_assume_current.dart';

import 'support/origin_shorthand.dart';

/// The zero-network "assume current" bulk action.
///
/// Two things here are worth more than the rest. The **planner** decides how
/// many mods the confirmation claims it will touch, and a plan that disagrees
/// with what the writes actually do is a lie told to the user right before a
/// batch rewrite. The **transform** is the guard that stops that batch
/// downgrading a mod someone resolved exactly while it was running.
void main() {
  final installedAt = DateTime.utc(2026, 5, 8, 15);

  ModOrigin origin({
    int? modId = 1,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    OriginTracking tracking = OriginTracking.auto,
    bool remoteMissing = false,
    DateTime? at,
    bool undated = false,
    bool proxy = true,
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence:
            modId == null ? OriginConfidence.unknown : OriginConfidence.inferred,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        tracking: tracking,
        remoteMissing: remoteMissing,
        installedAt: undated ? null : (at ?? installedAt),
        installedAtIsProxy: proxy,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  group('planning', () {
    test('splits a mixed library into the three groups the dialog names', () {
      final plan = planBulkAssumeCurrent([
        mod('no sidecar'),
        mod('no identity', origin: origin(modId: null)),
        mod('tracked, versionless', origin: origin()),
        mod('no install date', origin: origin(undated: true)),
        mod('already exact',
            origin: origin(versionConfidence: OriginConfidence.exact)),
        mod('already assumed',
            origin: origin(versionConfidence: OriginConfidence.assumedLatest)),
        mod('my own', origin: origin(tracking: OriginTracking.off)),
        mod('gone upstream', origin: origin(remoteMissing: true)),
      ]);

      expect(plan.eligible.map((m) => m.name), ['tracked, versionless']);
      expect(plan.untracked.map((m) => m.name), ['no sidecar', 'no identity']);
      expect(plan.undatable.map((m) => m.name), ['no install date']);
    });

    test('an already-assumed mod is not swept up again', () {
      // Re-running the action must be a no-op rather than rewriting the same
      // baseline: `assumed_latest` is a resolved state, and re-flagging it would
      // make the count grow back every time the user looks at it.
      final plan = planBulkAssumeCurrent([
        mod('assumed',
            origin: origin(versionConfidence: OriginConfidence.assumedLatest)),
      ]);
      expect(plan.hasWork, isFalse);
    });

    test('the proxy caveat is shown only when a derived date is being used', () {
      expect(
        planBulkAssumeCurrent([mod('a', origin: origin(proxy: true))])
            .anyBaselineIsProxy,
        isTrue,
      );
      expect(
        planBulkAssumeCurrent([mod('a', origin: origin(proxy: false))])
            .anyBaselineIsProxy,
        isFalse,
      );
    });

    test('an empty library plans no work', () {
      expect(planBulkAssumeCurrent(const <ModInfo>[]).hasWork, isFalse);
    });
  });

  group('the transform', () {
    test('records the baseline and nothing else', () {
      final next = bulkAssumeCurrent(origin())!;

      expect(next.versionConfidence, OriginConfidence.assumedLatest);
      expect(next.baselineRemoteDate, installedAt);
      // The honest half: no version is invented, and identity is untouched.
      expect(next.fileId, isNull);
      expect(next.version, isNull);
      expect(next.versionLabel, isNull);
      expect(next.modId, 1);
      expect(next.modIdConfidence, OriginConfidence.inferred);
    });

    test('abandons a mod resolved out from under it', () {
      // The plan is built from a scan; the write re-reads. Between the two, the
      // user can resolve a mod exactly through the per-mod dialog — and
      // applying `assumed_latest` on top would turn a known version back into a
      // guess, silently, inside a batch.
      for (final resolved in [
        OriginConfidence.exact,
        OriginConfidence.user,
        OriginConfidence.inferred,
        OriginConfidence.assumedLatest,
      ]) {
        expect(
          bulkAssumeCurrent(origin(versionConfidence: resolved)),
          isNull,
          reason: 'must not downgrade a $resolved version',
        );
      }
    });

    test('abandons a mod that lost its identity or its date', () {
      expect(bulkAssumeCurrent(origin(modId: null)), isNull);
      expect(bulkAssumeCurrent(origin(undated: true)), isNull);
      expect(bulkAssumeCurrent(null), isNull);
    });

    test('abandons a mod the user declared their own, or one gone upstream', () {
      expect(bulkAssumeCurrent(origin(tracking: OriginTracking.off)), isNull);
      expect(bulkAssumeCurrent(origin(remoteMissing: true)), isNull);
    });

    test('reads its baseline from the block it is given, not from the plan', () {
      // `updateOrigin` hands over the sidecar as it is on disk now. A mod whose
      // install date was corrected in the meantime must use the corrected one.
      final corrected = DateTime.utc(2026, 7, 1);
      expect(
        bulkAssumeCurrent(origin(at: corrected))!.baselineRemoteDate,
        corrected,
      );
    });

    test('leaves everything the action is not about alone', () {
      final before = origin().copyBase(archiveMd5: 'a' * 32);
      final after = bulkAssumeCurrent(before)!;
      expect(after.archiveMd5, before.archiveMd5);
      expect(after.provenance, before.provenance);
      expect(after.installedAt, before.installedAt);
      expect(after.installedAtIsProxy, before.installedAtIsProxy);
    });
  });
}
