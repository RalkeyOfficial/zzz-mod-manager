import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write_route.dart';

/// **Which write installs an update into a folder that holds two downloads.**
///
/// One rule decides it, and it is not "which record did the finding come from":
///
/// ```
///   the BASE  updated → write it by layout, then the patch back on top
///   the PATCH updated → place it over the base, by basename
/// ```
///
/// Layout belongs to the base — it decides where files live. Replaying the
/// folder's layout for a *patch* archive writes its files beside the ones they
/// should replace, where the `.ini` goes on loading the base's, nothing errors,
/// and the update appears to have done nothing at all.
///
/// The two shapes a mixed folder comes in put the same download in different
/// records, which is exactly why the role is what is read:
///
/// - a patch installed as its own mod, told what it patches → primary is the
///   **patch**, companion is the `base`;
/// - a patch installed *into* a mod → primary is the **base**, companion is the
///   `patch`.
void main() {
  const base = ModCompanion(
    role: CompanionRole.base,
    modId: 7100,
    modIdConfidence: OriginConfidence.user,
  );
  const patch = ModCompanion(
    role: CompanionRole.patch,
    modId: 5100,
    modIdConfidence: OriginConfidence.exact,
  );
  const primary = ModOrigin(
    provenance: OriginProvenance.downloaded,
    source: 'gamebanana',
    modId: 4001,
    modIdConfidence: OriginConfidence.exact,
    ingest: ModIngest(patchFiles: ['Textures/Body.dds']),
  );

  group('a folder whose primary is the patch', () {
    final origin = primary.copyWith(companions: const [base]);

    test('the base updating writes the base and replaces the patch', () {
      final route = updateWriteRoute(origin: origin, subjectModId: 7100);

      expect(route.kind, UpdateWriteKind.base);
      expect(route.asCompanion, isTrue, reason: 'the base is the companion here');
      expect(route.patchFiles, ['Textures/Body.dds']);
    });

    test('the patch updating is placed over what is in there', () {
      // The folder's own identity, and it is still the patch — so this is a
      // placement, not a layout replay.
      final route = updateWriteRoute(origin: origin, subjectModId: null);

      expect(route.kind, UpdateWriteKind.patch);
      expect(route.asCompanion, isFalse);
    });
  });

  group('a folder whose primary is the base', () {
    final origin = primary.copyWith(companions: const [patch]);

    test('the primary updating writes the base and replaces the patch', () {
      final route = updateWriteRoute(origin: origin, subjectModId: null);

      expect(route.kind, UpdateWriteKind.base);
      expect(route.asCompanion, isFalse);
      expect(route.patchFiles, ['Textures/Body.dds']);
    });

    test('the patch updating is placed over the base', () {
      final route = updateWriteRoute(origin: origin, subjectModId: 5100);

      expect(route.kind, UpdateWriteKind.patch);
      expect(route.asCompanion, isTrue);
    });
  });

  group('a folder that is one download', () {
    const alone = ModOrigin(
      provenance: OriginProvenance.downloaded,
      source: 'gamebanana',
      modId: 4001,
      modIdConfidence: OriginConfidence.exact,
    );

    test('it is an ordinary update', () {
      final route = updateWriteRoute(origin: alone, subjectModId: null);

      expect(route.kind, UpdateWriteKind.base);
      expect(route.asCompanion, isFalse);
      expect(route.patchFiles, isEmpty,
          reason: 'nothing in it is recorded as a patch, so there is nothing '
              'to set aside — and this is the ordinary overwrite');
      expect(route.flattensPatch, isFalse);
    });

    test('a patch with no identity of its own is still set aside', () {
      // A patch dragged off a disk and installed into a mod records no
      // companion — there is no mod page to name — but its *files* are
      // recorded, and that is what the write needs.
      final route = updateWriteRoute(
        origin: alone.copyWith(
          ingest: const ModIngest(patchFiles: ['Textures/Body.dds']),
        ),
        subjectModId: null,
      );

      expect(route.kind, UpdateWriteKind.base);
      expect(route.patchFiles, ['Textures/Body.dds']);
    });

    test('a folder with no origin block at all is an ordinary update', () {
      final route = updateWriteRoute(origin: null, subjectModId: null);
      expect(route.kind, UpdateWriteKind.base);
      expect(route.patchFiles, isEmpty);
    });
  });

  group('what it refuses to guess', () {
    test('a subject that is not in the folder is not written', () {
      // A verdict about a mod this folder does not claim to hold. Writing it
      // would overwrite one mod with another.
      final route = updateWriteRoute(
        origin: primary.copyWith(companions: const [base]),
        subjectModId: 999,
      );

      expect(route.kind, UpdateWriteKind.none);
    });

    test('a base update with no patch on record is still offered', () {
      // A folder from before the record existed, or one merged by hand. The
      // base update is what the user wants and the snapshot makes it
      // reversible — but nothing can be put back on top, so the caller has to
      // say so.
      final route = updateWriteRoute(
        origin: primary.copyWith(
          ingest: const ModIngest(),
          companions: const [base],
        ),
        subjectModId: 7100,
      );

      expect(route.kind, UpdateWriteKind.base);
      expect(route.patchFiles, isEmpty);
      expect(route.flattensPatch, isTrue,
          reason: 'which is the sentence that has to be on screen first');
    });

    test('a folder with the record intact claims nothing of the kind', () {
      expect(
        updateWriteRoute(
          origin: primary.copyWith(companions: const [patch]),
          subjectModId: null,
        ).flattensPatch,
        isFalse,
      );
    });
  });
}
