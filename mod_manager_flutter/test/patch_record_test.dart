import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/patch_record.dart';

/// **The two writes that record a folder holding more than one download.**
///
/// A patch folder can be recognised exactly once — before the user drags the
/// base mod's files in around it. Afterwards every reference resolves and the
/// folder is indistinguishable from an ordinary one, so a scan can never recover
/// the fact. Recognising it and not writing it down is therefore the same
/// outcome as never looking: no mark on the card, no row offering to name what
/// it patches, and an update check that goes on asking the patch's own page and
/// calling the answer "up to date".
///
/// The two are mirror images and must not be confused. [withPatchShape] is for a
/// folder that **is** a patch and is missing its base; [withAppliedPatch] is for
/// a folder that **is** the mod, with a patch written into it. Whether the flag
/// is set is the difference, and setting it on the wrong one claims the opposite
/// of the truth.
void main() {
  const tracked = ModOrigin(
    provenance: OriginProvenance.importedFolder,
    source: 'gamebanana',
    modId: 4001,
    modIdConfidence: OriginConfidence.exact,
    fileId: 9001,
    versionConfidence: OriginConfidence.exact,
  );

  group('withPatchShape', () {
    test('it flags the folder as holding a patch', () {
      final amended = withPatchShape(tracked)!;
      expect(amended.ingest!.patchShaped, isTrue);
      expect(amended.needsCompanion, isTrue,
          reason: 'the flag with nobody named is exactly the state the resolve '
              'row exists to clear');
    });

    test('nothing is invented for a folder that has no block', () {
      // This is an amendment, not the write that creates an origin. Both import
      // paths seed one for every folder they create, so a null here means the
      // seed write itself failed — and inventing a block would replace a
      // reported failure with a sidecar claiming a provenance nobody observed.
      expect(withPatchShape(null), isNull);
    });

    test('it does not erase how the folder was assembled', () {
      // The seam this write sits on: `ingest` is one object holding both what
      // the import did and what the scan concluded, so the flag has to be
      // added to the record rather than written as one.
      final combined = tracked.copyWith(
        ingest: const ModIngest(
          mode: IngestMode.combined,
          folders: ['Body', 'Wings'],
          siblingGroup: 'group-7',
        ),
      );

      final ingest = withPatchShape(combined)!.ingest!;
      expect(ingest.mode, IngestMode.combined);
      expect(ingest.folders, ['Body', 'Wings']);
      expect(ingest.siblingGroup, 'group-7');
      expect(ingest.patchShaped, isTrue);
    });

    test('it starts a record when the folder has none', () {
      final ingest = withPatchShape(tracked)!.ingest!;
      expect(ingest.patchShaped, isTrue);
      expect(ingest.mode, IngestMode.separate);
      expect(ingest.folders, isEmpty);
    });

    test('the remote identity is untouched', () {
      // It describes the patch, which is the whole reason the flag is needed.
      // Rewriting it here would be answering a question nobody asked.
      final amended = withPatchShape(tracked)!;
      expect(amended.modId, 4001);
      expect(amended.modIdConfidence, OriginConfidence.exact);
      expect(amended.fileId, 9001);
      expect(amended.provenance, OriginProvenance.importedFolder);
    });

    test('applying it twice says the same thing as applying it once', () {
      final once = withPatchShape(tracked);
      expect(withPatchShape(once), once,
          reason: 'a re-import over an existing folder must not accumulate');
    });

    group('the base mod, when the user has named one', () {
      const base = ModCompanion(
        role: CompanionRole.base,
        modId: 7100,
        modIdConfidence: OriginConfidence.user,
      );

      test('it is recorded beside the flag', () {
        final amended = withPatchShape(tracked, base: base)!;
        expect(amended.ingest!.patchShaped, isTrue,
            reason: 'the folder is still two downloads — being told which does '
                'not make it one');
        expect(amended.companionOfRole(CompanionRole.base), base);
        expect(amended.needsCompanion, isFalse);
      });

      test('naming a different one replaces it rather than adding a second',
          () {
        final amended = withPatchShape(
          tracked.copyWith(companions: const [
            ModCompanion(
              role: CompanionRole.base,
              modId: 6000,
              modIdConfidence: OriginConfidence.user,
            ),
          ]),
          base: base,
        )!;

        expect(amended.companions, [base],
            reason: 'a folder patches one mod, so two base companions is a '
                'contradiction rather than more information');
      });

      test('a patch companion is left where it is', () {
        // The other ordering — a folder whose primary is the mod itself, with a
        // patch written into it. Nothing about naming a base speaks to that.
        const patch = ModCompanion(
          role: CompanionRole.patch,
          modId: 8200,
          modIdConfidence: OriginConfidence.exact,
        );
        final amended = withPatchShape(
          tracked.copyWith(companions: const [patch]),
          base: base,
        )!;

        expect(amended.companions, [patch, base]);
      });

      test('saying nothing never clears what is already recorded', () {
        // **Only ever added.** An unanswered prompt is the user not saying,
        // which is not the same as them saying there is nothing there — and
        // this write runs again on every re-import of the same folder.
        final amended = withPatchShape(
          tracked.copyWith(companions: const [base]),
        )!;
        expect(amended.companions, [base]);
      });
    });
  });

  /// The reverse ordering: this folder is the mod, and a patch was written into
  /// it by an "install into…" the user asked for.
  group('withAppliedPatch', () {
    const patch = ModCompanion(
      role: CompanionRole.patch,
      modId: 5100,
      modIdConfidence: OriginConfidence.exact,
      version: '1.2',
    );

    test('the folder keeps saying what it is', () {
      final amended = withAppliedPatch(tracked, patch);

      expect(amended.modId, 4001,
          reason: 'still the base mod — that is what it mostly is');
      expect(amended.ingest?.patchShaped ?? false, isFalse,
          reason: 'that flag says the folder *is* a patch missing its base, '
              'which is the opposite claim');
      expect(amended.companionOfRole(CompanionRole.patch), patch);
    });

    test('an untracked folder gets a block rather than being refused', () {
      // Unlike `withPatchShape`: the target is an existing library mod, and most
      // of a library that predates origin tracking has no block at all. Those
      // are the folders most likely to be hand-assembled, so refusing them
      // would make the feature quietly unavailable exactly where it is wanted.
      final amended = withAppliedPatch(null, patch);

      expect(amended.provenance, OriginProvenance.importedFolder);
      expect(amended.companionOfRole(CompanionRole.patch), patch);
      expect(amended.hasIdentity, isFalse,
          reason: 'no identity is invented for the folder itself');
    });

    test('applying the same patch again does not list it twice', () {
      const newer = ModCompanion(
        role: CompanionRole.patch,
        modId: 5100,
        modIdConfidence: OriginConfidence.exact,
        version: '1.3',
      );

      final amended = withAppliedPatch(withAppliedPatch(tracked, patch), newer);

      expect(amended.companions, [newer],
          reason: 'the same mod, at whatever version arrived last');
    });

    test('a second, different patch is kept alongside the first', () {
      // **Deduplicated by mod id, not by role.** One folder can legitimately
      // hold two patches from two authors.
      const other = ModCompanion(
        role: CompanionRole.patch,
        modId: 6200,
        modIdConfidence: OriginConfidence.exact,
      );

      final amended = withAppliedPatch(withAppliedPatch(tracked, patch), other);

      expect(amended.companions, [patch, other]);
    });

    test('a base companion is left where it is', () {
      // A folder can be a patch that was told what it patches *and* have had a
      // further patch written into it. Neither statement erases the other.
      const base = ModCompanion(
        role: CompanionRole.base,
        modId: 7100,
        modIdConfidence: OriginConfidence.user,
      );

      final amended =
          withAppliedPatch(tracked.copyWith(companions: const [base]), patch);

      expect(amended.companions, [base, patch]);
    });
  });
}
