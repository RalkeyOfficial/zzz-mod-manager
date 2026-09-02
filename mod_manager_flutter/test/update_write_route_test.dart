import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_apply/update_write_route.dart';

/// **Which write installs an update into a folder that holds two downloads.**
///
/// A layer's **position** decides it:
///
/// ```
///   the bottom layer updated → write it by layout, then the layers above back on top
///   any layer above it      → place it over what is below, by basename
/// ```
///
/// Layout belongs to the bottom — it decides where files live. Replaying the
/// folder's layout for a *patch* archive writes its files beside the ones they
/// should replace, where the `.ini` goes on loading the base's, nothing errors,
/// and the update appears to have done nothing at all.
///
/// This used to read a **relative** role off a companion record, because the two
/// shapes a mixed folder came in put the same download in different records
/// depending on install order. **That ambiguity is gone**: both orderings are
/// the same stack, so the two groups below — which were the two shapes — now
/// assert the same answers, and `indexOf` is the whole decision.
void main() {
  /// A folder holding the mod with a patch over it. Both install orders produce
  /// this, which is the point.
  ModOrigin mixed({ModIngest? ingest}) => ModOrigin(
        provenance: OriginProvenance.downloaded,
        source: 'gamebanana',
        ingest: ingest ?? const ModIngest(patchFiles: ['Textures/Body.dds']),
        downloads: const [
          ModDownload(modId: 7100, modIdConfidence: OriginConfidence.user),
          ModDownload(
            role: DownloadRole.patch,
            modId: 5100,
            modIdConfidence: OriginConfidence.exact,
          ),
        ],
      );

  group('a folder that holds a mod and a patch', () {
    test('the bottom layer writes by layout, with the patch set aside', () {
      final route = updateWriteRoute(origin: mixed(), subjectModId: 7100);

      expect(route.kind, UpdateWriteKind.base);
      expect(route.asCompanion, isFalse);
      expect(route.patchFiles, ['Textures/Body.dds']);
      expect(route.patchModId, 5100,
          reason: 'whose displaced originals get rebuilt as it goes back');
    });

    test('the layer above is placed over what is below it', () {
      final route = updateWriteRoute(origin: mixed(), subjectModId: 5100);

      expect(route.kind, UpdateWriteKind.patch);
      expect(route.asCompanion, isTrue);
    });

    test('install order cannot change either answer', () {
      // The property the stack exists for. Whichever download the user
      // installed first, the record is the same list — so there is no second
      // shape for this function to have an opinion about.
      final byPatchFirst = ModOrigin(
        provenance: OriginProvenance.downloaded,
        source: 'gamebanana',
        ingest: const ModIngest(patchFiles: ['Textures/Body.dds']),
        // Written by "install the patch, then name what it patches": the base
        // is fetched and placed *underneath*, exactly as above.
        downloads: const [
          ModDownload(modId: 7100, modIdConfidence: OriginConfidence.user),
          ModDownload(
            role: DownloadRole.patch,
            modId: 5100,
            modIdConfidence: OriginConfidence.exact,
          ),
        ],
      );

      expect(
        updateWriteRoute(origin: byPatchFirst, subjectModId: 7100).kind,
        updateWriteRoute(origin: mixed(), subjectModId: 7100).kind,
      );
      expect(
        updateWriteRoute(origin: byPatchFirst, subjectModId: 5100).kind,
        updateWriteRoute(origin: mixed(), subjectModId: 5100).kind,
      );
    });

    test('the topmost layer is the one whose store is rebuilt', () {
      // Three deep: one store, and it is the layer sitting on top of everything.
      final deep = mixed().withLayerOnTop(const ModDownload(
        modId: 9000,
        modIdConfidence: OriginConfidence.exact,
      ));

      expect(
        updateWriteRoute(origin: deep, subjectModId: 7100).patchModId,
        9000,
      );
    });
  });

  group('a folder that is one download', () {
    final alone = ModOrigin(
      provenance: OriginProvenance.downloaded,
      source: 'gamebanana',
      downloads: const [
        ModDownload(modId: 4001, modIdConfidence: OriginConfidence.exact),
      ],
    );

    test('it is an ordinary update', () {
      final route = updateWriteRoute(origin: alone, subjectModId: 4001);

      expect(route.kind, UpdateWriteKind.base);
      expect(route.asCompanion, isFalse);
      expect(route.patchFiles, isEmpty,
          reason: 'nothing in it is recorded as a patch, so there is nothing '
              'to set aside — and this is the ordinary overwrite');
      expect(route.flattensPatch, isFalse);
      expect(route.patchModId, isNull);
    });

    test('a patch with no identity of its own is still set aside', () {
      // A patch written in from a local archive is a layer with no mod page.
      // It is recorded now — the old shape required an identity and therefore
      // recorded nothing at all — and its *files* are what the write needs.
      final route = updateWriteRoute(
        origin: alone.copyWith(
          ingest: const ModIngest(patchFiles: ['Textures/Body.dds']),
          downloads: [
            alone.base!,
            const ModDownload(
              role: DownloadRole.patch,
              files: [InstalledFile(path: 'Textures/Body.dds')],
            ),
          ],
        ),
        subjectModId: 4001,
      );

      expect(route.kind, UpdateWriteKind.base);
      expect(route.patchFiles, ['Textures/Body.dds']);
      expect(route.patchModId, isNull,
          reason: 'no page means no store to key by, and no removal either');
      expect(route.flattensPatch, isFalse,
          reason: 'the files are on record, so it can be put back');
    });
  });

  group('what it refuses to guess', () {
    test('a subject that is not in the folder is not written', () {
      // A verdict about a mod this folder does not claim to hold. Writing it
      // would overwrite one mod with another.
      expect(
        updateWriteRoute(origin: mixed(), subjectModId: 999).kind,
        UpdateWriteKind.none,
      );
    });

    test('a folder with no origin block at all', () {
      expect(
        updateWriteRoute(origin: null, subjectModId: 4001).kind,
        UpdateWriteKind.none,
      );
    });

    test('no subject at all', () {
      // Every layer is addressed by its own id now. Null used to mean "the
      // folder's own", which was the spelling that made one download special.
      expect(
        updateWriteRoute(origin: mixed(), subjectModId: null).kind,
        UpdateWriteKind.none,
      );
    });

    test('a base update with a patch whose files are unrecorded', () {
      // A folder from before the record existed, or one merged by hand. The
      // base update is what the user wants and the snapshot makes it
      // reversible — but nothing can be put back on top, so the caller has to
      // say so.
      final route = updateWriteRoute(
        origin: mixed(ingest: const ModIngest()),
        subjectModId: 7100,
      );

      expect(route.kind, UpdateWriteKind.base);
      expect(route.patchFiles, isEmpty);
      expect(route.flattensPatch, isTrue,
          reason: 'which is the sentence that has to be on screen first');
    });

    test('a folder with the record intact claims nothing of the kind', () {
      expect(
        updateWriteRoute(origin: mixed(), subjectModId: 7100).flattensPatch,
        isFalse,
      );
    });
  });
}
