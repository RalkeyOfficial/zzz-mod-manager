import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_status.dart';

ModOrigin origin({
  int? modId,
  OriginConfidence versionConfidence = OriginConfidence.unknown,
  OriginTracking tracking = OriginTracking.auto,
  bool remoteMissing = false,
  bool patchShaped = false,
  List<ModCompanion> companions = const [],
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
      ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
      companions: companions,
    );

/// A companion the user has **fully** answered for: which mod, and which file
/// of it. Anything less is still outstanding work — see the half-answered case
/// below.
const ModCompanion namedBase = ModCompanion(
  role: CompanionRole.base,
  modId: 111,
  modIdConfidence: OriginConfidence.user,
  fileId: 9,
  versionConfidence: OriginConfidence.user,
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

    test('remote_missing gets its own state, not amber and not silence', () {
      // Amber promises "click to set the version", which means reading a mod
      // page that is private, trashed or withheld — so it must not be amber.
      // It must not be silence either: the bulk resolution pass writes this
      // flag now, and a mod that quietly stops being watched with no wording
      // anywhere is the hole that would open.
      expect(
        modOriginStatus(origin(modId: 123, remoteMissing: true)),
        ModOriginStatus.sourceGone,
      );
    });

    test('a gone source is not counted as needing attention', () {
      // The filter's promise is that everything in it can be dealt with, and a
      // private, trashed or withheld page cannot. Counting it would leave a
      // number that never reaches zero however much work the user does.
      expect(modNeedsAttention(origin(modId: 123, remoteMissing: true)), isFalse);
    });

    test('tracking off still beats a gone source', () {
      // "Not from GameBanana / it's my own" promises permanent silence, and a
      // stale remote id must not talk the user out of a decision they made.
      expect(
        modOriginStatus(origin(
          modId: 123,
          remoteMissing: true,
          tracking: OriginTracking.off,
        )),
        ModOriginStatus.none,
      );
    });

    test('a patch-shaped folder with no base named is its own state', () {
      // The version here is as known as it gets — we downloaded the patch and
      // recorded its file id — so nothing else on the card would say a word.
      // What is unknown is the *other* mod in the folder.
      expect(
        modOriginStatus(origin(
          modId: 222,
          versionConfidence: OriginConfidence.exact,
          patchShaped: true,
        )),
        ModOriginStatus.secondIdentityUnknown,
      );
    });

    test('naming the base mod clears it', () {
      // The property the "needs attention" filter depends on: this state can be
      // reached zero by doing work, which is what disqualifies `sourceGone`.
      expect(
        modOriginStatus(origin(
          modId: 222,
          versionConfidence: OriginConfidence.exact,
          patchShaped: true,
          companions: const [namedBase],
        )),
        ModOriginStatus.none,
      );
    });

    test('it is not returned for a folder that was never patch-shaped', () {
      expect(
        modOriginStatus(
            origin(modId: 222, versionConfidence: OriginConfidence.exact)),
        ModOriginStatus.none,
      );
    });

    test('tracking off and a gone source still win over it', () {
      // Both are promises about the slot going quiet, and a folder being two
      // things is not a reason to break either one.
      for (final quiet in [
        origin(modId: 222, patchShaped: true, tracking: OriginTracking.off),
        origin(modId: 222, patchShaped: true, remoteMissing: true),
      ]) {
        expect(modOriginStatus(quiet),
            isNot(ModOriginStatus.secondIdentityUnknown));
      }
    });

    test('an untracked folder is untracked before it is anything else', () {
      // Without a primary identity there is no folder-is-two-things claim to
      // make: `patch_shaped` says the download brought no content, and with no
      // mod id we cannot ask about either half.
      expect(
        modOriginStatus(origin(patchShaped: true)),
        ModOriginStatus.untracked,
      );
    });

    test('a companion whose file is unknown still asks for something', () {
      // The hole this closes: naming the base mod clears `needsCompanion`, and
      // the slot then reads only the *primary's* version confidence — which for
      // a downloaded patch is `exact`. So a folder we cannot judge rendered
      // nothing at all: no amber, and no blue either, because the check answers
      // `versionUnknown` rather than finding an update.
      expect(
        modOriginStatus(origin(
          modId: 222,
          versionConfidence: OriginConfidence.exact,
          patchShaped: true,
          companions: const [
            ModCompanion(
              role: CompanionRole.base,
              modId: 111,
              modIdConfidence: OriginConfidence.user,
            ),
          ],
        )),
        ModOriginStatus.versionUnknown,
        reason: 'one pass through the resolve dialog fixes it, which is exactly '
            'what the amber state is for',
      );
      expect(
        modOriginStatus(origin(
          modId: 222,
          versionConfidence: OriginConfidence.exact,
          patchShaped: true,
          companions: const [
            ModCompanion(
              role: CompanionRole.base,
              modId: 111,
              modIdConfidence: OriginConfidence.user,
              fileId: 9,
              versionConfidence: OriginConfidence.user,
            ),
          ],
        )),
        ModOriginStatus.none,
        reason: 'picking a file for it is what finishes the job',
      );
    });

    test('it outranks an unknown version', () {
      // Both are true and one dialog answers both, so the ordering is
      // low-stakes — but it is pinned rather than left to chance. "Which file
      // of the patch is installed" is an ambiguous question while the folder is
      // known to be two things and only one is named.
      expect(
        modOriginStatus(origin(modId: 222, patchShaped: true)),
        ModOriginStatus.secondIdentityUnknown,
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

    test('an unnamed second identity is outstanding work', () {
      // It belongs in the filter for the reason `sourceGone` does not: the user
      // can finish it, and finishing it moves the count.
      final unnamed = origin(
        modId: 222,
        versionConfidence: OriginConfidence.exact,
        patchShaped: true,
      );
      expect(modNeedsAttention(unnamed), isTrue);
      expect(
        modNeedsAttention(origin(
          modId: 222,
          versionConfidence: OriginConfidence.exact,
          patchShaped: true,
          companions: const [namedBase],
        )),
        isFalse,
        reason: 'naming the base is what takes it off the list',
      );
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
        ModOriginStatus.secondIdentityUnknown,
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
        origin(modId: 1, patchShaped: true),
        origin(modId: 1, patchShaped: true, companions: const [namedBase]),
      ]) {
        expect(
          modNeedsAttention(candidate),
          outstanding.contains(modOriginStatus(candidate)),
        );
      }
    });
  });
}
