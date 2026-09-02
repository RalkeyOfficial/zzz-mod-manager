import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/folder_downloads.dart';

/// **The flat patch-file list, derived from the stack.**
///
/// This file used to hold the whole compensation layer for a model that stored
/// one download in `origin`'s own fields and the rest in a companion list with
/// roles *relative* to it: an absolute-role enum, a per-entry wrapper, a
/// derivation from two signals, and a partition to put the mod's half first.
/// Every test here was a test of that derivation.
///
/// `ModOrigin.downloads` is ordered bottom-up, so **the symmetry it was
/// defending is now structural**: `origin.base`, `origin.patches` and the order
/// the list is already in. There is nothing left to derive except the one thing
/// that genuinely has to be — the `string[]` an already-released build reads out
/// of `ingest.patch_files`.
void main() {
  ModDownload patch(int modId, List<String> paths) => ModDownload(
        role: DownloadRole.patch,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        files: [for (final p in paths) InstalledFile(path: p)],
      );

  ModOrigin origin({
    int? modId = 585282,
    List<String> baseFiles = const [],
    List<ModDownload> patches = const [],
    bool patchShaped = false,
  }) =>
      ModOrigin(
        source: 'gamebanana',
        provenance: OriginProvenance.downloaded,
        ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
        downloads: [
          ModDownload(
            modId: modId,
            modIdConfidence: OriginConfidence.exact,
            files: [for (final p in baseFiles) InstalledFile(path: p)],
          ),
          ...patches,
        ],
      );

  test('a folder with one download has no patch files', () {
    expect(derivedPatchFiles(origin(baseFiles: ['Ellen.ini'])), isEmpty);
  });

  test('every layer above the bottom contributes, in stack order', () {
    final files = derivedPatchFiles(origin(
      baseFiles: ['Ellen.ini', 'Textures/Body.dds'],
      patches: [
        patch(111, ['Body.dds']),
        patch(222, ['Face.dds', 'Hair.dds']),
      ],
    ));

    // Stack order, which is the order the files themselves go on disk.
    expect(files, ['Body.dds', 'Face.dds', 'Hair.dds']);
  });

  test('the mod\'s own files are never in it', () {
    final files = derivedPatchFiles(origin(
      baseFiles: ['Ellen.ini'],
      patches: [patch(111, ['Body.dds'])],
    ));

    expect(files, isNot(contains('Ellen.ini')));
  });

  test('a patch-shaped folder with nothing under it derives nothing', () {
    // Its only layer is at the bottom — the bottom of what exists — and
    // `patch_shaped` is the separate claim that something is missing beneath
    // it. Nothing is *above* anything, so there is no patch half to list.
    //
    // That is a real change: the old derivation read the flag and counted the
    // folder's own files, because "which entry is the patch" was a question it
    // had to answer. `patch_files` is for setting a layer aside while the one
    // below it is rewritten, and a folder with nothing below has no such write.
    expect(
      derivedPatchFiles(origin(baseFiles: ['Body.dds'], patchShaped: true)),
      isEmpty,
    );
  });

  test('naming the base makes the folder\'s own layer the patch half', () {
    // Which is what closes the case above: the insert puts the mod underneath,
    // and the patch's files are now a layer above something.
    final named = origin(baseFiles: ['Body.dds'], patchShaped: true)
        .withBaseInserted(const ModDownload(
      modId: 585283,
      modIdConfidence: OriginConfidence.user,
    ));

    expect(derivedPatchFiles(named), ['Body.dds']);
  });

  test('a layer with no file registry contributes nothing of its own', () {
    // Everything installed before the registries existed has none. A caller
    // must read an empty result as "nothing to derive" and leave whatever
    // `patch_files` is already recorded alone — that hand-written list is the
    // only thing making such a folder rebuildable.
    expect(
      derivedPatchFiles(origin(patches: [patch(111, const [])])),
      isEmpty,
    );
  });

  test('a layer nobody can name still contributes its files', () {
    // A patch written in from a local archive has no page, and the old shape
    // therefore recorded nothing at all for it. Its files are known, so it is
    // set aside like any other.
    final files = derivedPatchFiles(origin(patches: [
      const ModDownload(
        role: DownloadRole.patch,
        files: [InstalledFile(path: 'Body.dds')],
      ),
    ]));

    expect(files, ['Body.dds']);
  });

  test('the on-disk spelling survives', () {
    // These paths open and delete files; a lower-cased one deletes nothing on
    // Linux and leaves a second copy behind.
    expect(
      derivedPatchFiles(origin(patches: [patch(111, ['Textures/BodyA.dds'])])),
      ['Textures/BodyA.dds'],
    );
  });
}
