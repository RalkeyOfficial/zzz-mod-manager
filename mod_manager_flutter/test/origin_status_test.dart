import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_status.dart';

ModOrigin origin({
  int? modId,
  OriginConfidence versionConfidence = OriginConfidence.unknown,
  OriginTracking tracking = OriginTracking.auto,
  bool remoteMissing = false,
}) =>
    ModOrigin(
      source: modId == null ? null : 'gamebanana',
      modId: modId,
      modIdConfidence:
          modId == null ? OriginConfidence.unknown : OriginConfidence.inferred,
      versionConfidence: versionConfidence,
      provenance: OriginProvenance.importedFolder,
      tracking: tracking,
      remoteMissing: remoteMissing,
    );

void main() {
  group('modOriginStatus', () {
    test('no sidecar block at all is untracked', () {
      expect(modOriginStatus(null), ModOriginStatus.untracked);
    });

    test('a block with no mod id is untracked', () {
      expect(modOriginStatus(origin()), ModOriginStatus.untracked);
    });

    test('identity without a version is the actionable state', () {
      expect(modOriginStatus(origin(modId: 123)),
          ModOriginStatus.versionUnknown);
    });

    test('a known version renders nothing', () {
      for (final tier in [
        OriginConfidence.exact,
        OriginConfidence.user,
        OriginConfidence.inferred,
      ]) {
        expect(
          modOriginStatus(origin(modId: 123, versionConfidence: tier)),
          ModOriginStatus.none,
          reason: '$tier is a recorded answer, not a missing one',
        );
      }
    });

    test('assumed_latest is an answer, not an outstanding question', () {
      // The user pressed "I don't know which, I got it around then". Re-ambering
      // it would make the dialog impossible to finish.
      expect(
        modOriginStatus(
          origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
        ),
        ModOriginStatus.none,
      );
    });

    test('tracking off silences the slot even with a mod id on record', () {
      // The declaration is permanent until the user reverses it, and a stale
      // source_url is exactly why they might have made it.
      expect(
        modOriginStatus(origin(modId: 123, tracking: OriginTracking.off)),
        ModOriginStatus.none,
      );
    });

    test('tracking off silences an untracked mod too', () {
      expect(
        modOriginStatus(origin(tracking: OriginTracking.off)),
        ModOriginStatus.none,
      );
    });

    test('remote_missing silences the amber offer it cannot honour', () {
      // Amber promises "click to set the version", which means reading a mod
      // page that is private, trashed or withheld.
      expect(
        modOriginStatus(origin(modId: 123, remoteMissing: true)),
        ModOriginStatus.none,
      );
    });

    test('identity is checked before version', () {
      // Both are unknown here; only one of them is actionable, and claiming the
      // version is the missing piece would promise a check we cannot run.
      expect(
        modOriginStatus(
          origin(versionConfidence: OriginConfidence.unknown),
        ),
        ModOriginStatus.untracked,
      );
    });
  });

  group('modNeedsAttention', () {
    test('keeps both the amber and the muted state', () {
      expect(modNeedsAttention(null), isTrue);
      expect(modNeedsAttention(origin(modId: 7)), isTrue);
    });

    test('drops resolved mods and opted-out ones', () {
      expect(
        modNeedsAttention(
          origin(modId: 7, versionConfidence: OriginConfidence.exact),
        ),
        isFalse,
      );
      expect(
        modNeedsAttention(origin(modId: 7, tracking: OriginTracking.off)),
        isFalse,
      );
    });

    test('agrees with the badge for every state, by construction', () {
      // The filter and the slot must never disagree about which mods are which;
      // this pins that they are one decision rather than two.
      for (final candidate in [
        null,
        origin(),
        origin(modId: 1),
        origin(modId: 1, versionConfidence: OriginConfidence.user),
        origin(modId: 1, tracking: OriginTracking.off),
        origin(modId: 1, remoteMissing: true),
      ]) {
        expect(
          modNeedsAttention(candidate),
          modOriginStatus(candidate) != ModOriginStatus.none,
        );
      }
    });
  });
}
