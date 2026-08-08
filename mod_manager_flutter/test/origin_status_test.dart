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

    test('a version we actually know renders nothing', () {
      for (final tier in [OriginConfidence.exact, OriginConfidence.user]) {
        expect(
          modOriginStatus(origin(modId: 123, versionConfidence: tier)),
          ModOriginStatus.none,
          reason: '$tier names a specific file; there is nothing to report',
        );
      }
    });

    test('a recorded guess is its own state, neither amber nor silent', () {
      // The gap this closes: `assumed_latest` and `user` both used to render
      // nothing, so a mod waved through by the bulk action was indistinguishable
      // from one whose file the user had actually picked — across a whole
      // library, with no way to tell but opening every dialog in turn.
      //
      // Quiet rather than amber, though. The user pressed "I don't know which,
      // I got it around then" and that is a legitimate answer; re-ambering it
      // would make the dialog impossible to finish.
      for (final tier in [
        OriginConfidence.assumedLatest,
        // Nothing writes `inferred` yet — the bulk resolution pass will — and it
        // is covered here so a guess can never arrive rendering as fact.
        OriginConfidence.inferred,
      ]) {
        expect(
          modOriginStatus(origin(modId: 1, versionConfidence: tier)),
          ModOriginStatus.versionGuessed,
          reason: '$tier is recorded, but it is still a guess',
        );
      }
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
    test('keeps the untracked and the amber state', () {
      expect(modNeedsAttention(null), isTrue);
      expect(modNeedsAttention(origin(modId: 7)), isTrue);
    });

    test('a recorded guess is visible but not outstanding', () {
      // The one place the badge and the filter deliberately disagree. The bulk
      // "assume current" action turns amber mods into guessed ones, and the
      // count dropping to zero is the entire visible proof that it worked —
      // were these still counted, the number would sit unchanged while the
      // marks merely changed shape.
      final guessed =
          origin(modId: 7, versionConfidence: OriginConfidence.assumedLatest);
      expect(modOriginStatus(guessed), ModOriginStatus.versionGuessed);
      expect(modNeedsAttention(guessed), isFalse);
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

    test('is derived from the badge, so the two cannot drift apart', () {
      // They are one decision, read two ways: the filter asks "what have I not
      // dealt with", the badge asks "how loudly should this card speak". Every
      // state maps the same way every time, and the single exception —
      // `versionGuessed`, which is shown but not counted — is deliberate and is
      // pinned above rather than hidden in this loop.
      const outstanding = {
        ModOriginStatus.untracked,
        ModOriginStatus.versionUnknown,
      };
      for (final candidate in [
        null,
        origin(),
        origin(modId: 1),
        origin(modId: 1, versionConfidence: OriginConfidence.user),
        origin(modId: 1, versionConfidence: OriginConfidence.exact),
        origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
        origin(modId: 1, versionConfidence: OriginConfidence.inferred),
        origin(modId: 1, tracking: OriginTracking.off),
        origin(modId: 1, remoteMissing: true),
      ]) {
        expect(
          modNeedsAttention(candidate),
          outstanding.contains(modOriginStatus(candidate)),
        );
      }
    });
  });
}
