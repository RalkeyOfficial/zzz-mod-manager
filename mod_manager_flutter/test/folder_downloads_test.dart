import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/folder_downloads.dart';
import 'package:mod_manager_flutter/services/origin_summary.dart';

/// Flattening a folder's origin block into peers.
///
/// **The property under test is symmetry.** Install a patch and then name the
/// mod it patches, or install the mod and then patch it, and the sidecar comes
/// out mirrored: the same two mods, with whichever was installed first in
/// `origin`'s own fields and the other in `companions`. The block is identical
/// in substance, so what this produces has to be identical too — same roles,
/// same order — or the same folder reads differently for two users who did the
/// same thing in a different sequence.
void main() {
  ModCompanion companion({
    required CompanionRole role,
    int modId = 605460,
    int? fileId = 1473174,
    OriginConfidence versionConfidence = OriginConfidence.exact,
    bool remoteMissing = false,
  }) =>
      ModCompanion(
        role: role,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
        versionConfidence: versionConfidence,
        remoteMissing: remoteMissing,
      );

  ModOrigin origin({
    int? modId = 585282,
    List<ModCompanion> companions = const [],
    bool patchShaped = false,
    bool remoteMissing = false,
  }) =>
      ModOrigin(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: 1433843,
        versionConfidence: OriginConfidence.exact,
        provenance: OriginProvenance.downloaded,
        ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
        companions: companions,
        remoteMissing: remoteMissing,
      );

  group('roles', () {
    test('a folder that is the mod, with a patch in it', () {
      final downloads = folderDownloads(
        origin(companions: [companion(role: CompanionRole.patch)]),
      );

      expect(downloads.map((d) => d.role), [
        FolderDownloadRole.mod,
        FolderDownloadRole.patch,
      ]);
      expect(downloads.first.modId, 585282);
      expect(downloads.first.isFolderOwn, isTrue);
      expect(downloads.last.modId, 605460);
    });

    test('a folder that is the patch, with the mod named', () {
      // The mirror image. The mod comes first *even though it is the companion*,
      // which is the whole point: the list is ordered by what each download is,
      // never by where the sidecar keeps it.
      final downloads = folderDownloads(
        origin(companions: [companion(role: CompanionRole.base)]),
      );

      expect(downloads.map((d) => d.role), [
        FolderDownloadRole.mod,
        FolderDownloadRole.patch,
      ]);
      expect(downloads.first.modId, 605460, reason: 'the mod, a companion');
      expect(downloads.first.isFolderOwn, isFalse);
      expect(downloads.last.modId, 585282, reason: 'the patch, the own block');
      expect(downloads.last.isFolderOwn, isTrue);
    });

    test('the two orderings differ only in which entry is the folder\'s own',
        () {
      // Stated as one assertion because it is the invariant, not a coincidence
      // of the two tests above.
      final asMod =
          folderDownloads(origin(companions: [companion(role: CompanionRole.patch)]));
      final asPatch = folderDownloads(
        origin(modId: 605460, companions: [companion(role: CompanionRole.base, modId: 585282)]),
      );

      expect(asMod.map((d) => d.role), asPatch.map((d) => d.role));
      expect(asMod.map((d) => d.modId), asPatch.map((d) => d.modId));
      // And the flag that does differ points at opposite entries, which is what
      // makes it useless for ranking and fine for naming.
      expect(asMod.map((d) => d.isFolderOwn), [true, false]);
      expect(asPatch.map((d) => d.isFolderOwn), [false, true]);
    });

    test('a patch-shaped folder is a patch before anything is named', () {
      // `ingest.patch_shaped` is captured at install because that is the only
      // moment a patch folder is legible. It has to be enough on its own: the
      // base is not named yet, so no companion can say which way round this is.
      final downloads = folderDownloads(origin(patchShaped: true));

      expect(downloads, hasLength(1));
      expect(downloads.single.role, FolderDownloadRole.patch);
    });

    test('a base companion makes it a patch with no ingest block at all', () {
      // The other route, and it has to work alone: a sidecar written before
      // `ingest` existed carries no `patch_shaped`, and the user answering
      // "what does this patch?" is then the only evidence.
      final downloads = folderDownloads(
        origin(companions: [companion(role: CompanionRole.base)]),
      );

      expect(
        downloads.firstWhere((d) => d.isFolderOwn).role,
        FolderDownloadRole.patch,
      );
    });

    test('an ordinary mod is one entry, not none', () {
      // The caller decides whether one entry is worth a section. Returning
      // nothing here would make "this folder holds one mod" and "this folder
      // has no origin block" the same answer, and they are not.
      final downloads = folderDownloads(origin());

      expect(downloads, hasLength(1));
      expect(downloads.single.role, FolderDownloadRole.mod);
    });

    test('no origin block is no entries', () {
      expect(folderDownloads(null), isEmpty);
    });
  });

  group('what each entry carries', () {
    test('the folder\'s own entry is summarised as an origin', () {
      final downloads = folderDownloads(
        origin(companions: [companion(role: CompanionRole.patch)]),
      );
      final own = downloads.firstWhere((d) => d.isFolderOwn);

      // `downloaded`, which is a claim only the folder's own ingest can make.
      expect(own.summary.version, VersionSummary.downloaded);
      expect(own.summary.identity, IdentitySummary.downloaded);
    });

    test('a companion is summarised as a companion', () {
      final downloads = folderDownloads(
        origin(companions: [companion(role: CompanionRole.patch)]),
      );
      final other = downloads.firstWhere((d) => !d.isFolderOwn);

      // Never `downloaded`: that phrasing is about this folder's ingest, and a
      // companion is a different download. See `summarizeCompanion`.
      expect(other.summary.version, VersionSummary.chosen);
    });

    test('an unresolved companion carries no file', () {
      final downloads = folderDownloads(
        origin(
          companions: [
            companion(
              role: CompanionRole.patch,
              fileId: null,
              versionConfidence: OriginConfidence.unknown,
            ),
          ],
        ),
      );

      expect(
        downloads.firstWhere((d) => !d.isFolderOwn).summary.version,
        VersionSummary.none,
      );
    });

    test('a gone page is carried per entry, from whichever field holds it', () {
      final ownGone = folderDownloads(
        origin(
          remoteMissing: true,
          companions: [companion(role: CompanionRole.patch)],
        ),
      );
      expect(ownGone.firstWhere((d) => d.isFolderOwn).remoteMissing, isTrue);
      expect(ownGone.firstWhere((d) => !d.isFolderOwn).remoteMissing, isFalse);

      final otherGone = folderDownloads(
        origin(
          companions: [companion(role: CompanionRole.patch, remoteMissing: true)],
        ),
      );
      expect(otherGone.firstWhere((d) => d.isFolderOwn).remoteMissing, isFalse);
      expect(otherGone.firstWhere((d) => !d.isFolderOwn).remoteMissing, isTrue);
    });
  });

  test('several patches keep the order the block lists them in', () {
    // Not sorted — `List.sort` is not stable in Dart, and peers that reshuffled
    // on a rewrite would make a sidecar edit look like a change to the folder.
    final downloads = folderDownloads(
      origin(
        companions: [
          companion(role: CompanionRole.patch, modId: 111),
          companion(role: CompanionRole.patch, modId: 222),
          companion(role: CompanionRole.patch, modId: 333),
        ],
      ),
    );

    expect(downloads.map((d) => d.modId), [585282, 111, 222, 333]);
  });
}
