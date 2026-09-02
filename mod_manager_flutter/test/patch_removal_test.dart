import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/folder_contents.dart';
import 'package:mod_manager_flutter/services/patch_removal.dart';

/// **What taking a patch out would do**, decided before anything is touched.
///
/// The split that matters is `added` against `replaced`: only the files the
/// patch brought are the patch's to delete, and only the ones it wrote over
/// have anything to put back. Getting that backwards deletes the mod.
void main() {
  ModDownload patch({
    int modId = 605460,
    List<InstalledFile> files = const [],
  }) =>
      ModDownload(
        role: DownloadRole.patch,
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        versionConfidence: OriginConfidence.exact,
        files: files,
      );

  /// A folder whose bottom layer is the mod, with [patches] written over it.
  ModOrigin origin({List<ModDownload> patches = const []}) => ModOrigin(
        source: 'gamebanana',
        provenance: OriginProvenance.downloaded,
        downloads: [
          const ModDownload(
            modId: 585282,
            modIdConfidence: OriginConfidence.exact,
          ),
          for (final p in patches) p,
        ],
      );

  /// The comparison keys are lower-cased, as everywhere the loader's
  /// case-insensitivity is respected.
  FolderContents folder(List<String> paths) => FolderContents(
        files: {for (final p in paths) p.toLowerCase()},
        actualPaths: {for (final p in paths) p.toLowerCase(): p},
      );

  test('a file the patch added is deleted', () {
    final plan = planPatchRemoval(
      origin: origin(patches: [
        patch(files: const [
          InstalledFile(path: 'ellen_patch.ini', role: InstalledFileRole.added),
        ]),
      ]),
      patchModId: 605460,
      onDisk: folder(['ellen_patch.ini']),
      storedOriginals: const {},
    );

    expect(plan.delete, ['ellen_patch.ini']);
    expect(plan.restore, isEmpty);
    expect(plan.unrecoverable, isEmpty);
  });

  test('a file the patch wrote over is restored, not deleted', () {
    // Deleting this would take the mod's own file with the patch and leave a
    // hole where a texture used to be.
    final plan = planPatchRemoval(
      origin: origin(patches: [
        patch(files: const [
          InstalledFile(
            path: 'Textures/Body.dds',
            role: InstalledFileRole.replaced,
          ),
        ]),
      ]),
      patchModId: 605460,
      onDisk: folder(['Textures/Body.dds']),
      storedOriginals: const {'Textures/Body.dds'},
    );

    expect(plan.restore, ['Textures/Body.dds']);
    expect(plan.delete, isEmpty);
  });

  test('a displaced file with no stored original is left where it is', () {
    // A folder patched before the store existed, or one whose store could not
    // be written. Deleting it leaves a hole; leaving it keeps a patched file in
    // a folder that no longer claims to be patched — and the user is told.
    final plan = planPatchRemoval(
      origin: origin(patches: [
        patch(files: const [
          InstalledFile(
            path: 'Textures/Body.dds',
            role: InstalledFileRole.replaced,
          ),
        ]),
      ]),
      patchModId: 605460,
      onDisk: folder(['Textures/Body.dds']),
      storedOriginals: const {},
    );

    expect(plan.unrecoverable, ['Textures/Body.dds']);
    expect(plan.delete, isEmpty);
    expect(plan.restore, isEmpty);
    expect(plan.leavesPatchBehind, isTrue);
  });

  test('a recorded file the user deleted themselves is reported, not restored',
      () {
    // The record says what the app wrote, so a path that is gone is an edit
    // rather than damage — the same rule `ingest.patch_files` reads by.
    final plan = planPatchRemoval(
      origin: origin(patches: [
        patch(files: const [
          InstalledFile(path: 'Body.dds', role: InstalledFileRole.replaced),
          InstalledFile(path: 'extra.ini', role: InstalledFileRole.added),
        ]),
      ]),
      patchModId: 605460,
      onDisk: folder(const []),
      storedOriginals: const {'Body.dds'},
    );

    expect(plan.gone, ['Body.dds', 'extra.ini']);
    expect(plan.restore, isEmpty);
    expect(plan.delete, isEmpty);
    expect(plan.touchesFiles, isFalse);
  });

  test('paths are matched case-insensitively and acted on as recorded', () {
    // The loader is case-insensitive so comparison must be; the path that
    // reaches `File` has to be the real spelling or it deletes nothing.
    final plan = planPatchRemoval(
      origin: origin(patches: [
        patch(files: const [
          InstalledFile(path: 'Textures/BodyA.dds',
              role: InstalledFileRole.added),
        ]),
      ]),
      patchModId: 605460,
      onDisk: folder(['textures/bodya.dds']),
      storedOriginals: const {},
    );

    expect(plan.delete, ['Textures/BodyA.dds']);
  });

  group('what it refuses to plan', () {
    test('a patch this folder does not record', () {
      final plan = planPatchRemoval(
        origin: origin(patches: [
          patch(files: const [InstalledFile(path: 'a.ini')]),
        ]),
        patchModId: 999999,
        onDisk: folder(['a.ini']),
        storedOriginals: const {},
      );

      expect(plan.isEmpty, isTrue);
    });

    test('a patch with no file registry', () {
      // A folder merged by hand has no way to tell the patch's files from the
      // mod's, and guessing would delete the mod.
      final plan = planPatchRemoval(
        origin: origin(patches: [patch()]),
        patchModId: 605460,
        onDisk: folder(['a.ini']),
        storedOriginals: const {},
      );

      expect(plan.isEmpty, isTrue);
    });

    test('the bottom layer — what the folder is', () {
      // Taking it out would leave a patch with nothing to patch, which is the
      // broken state `patch_shaped` exists to warn about. Expressible in the
      // stack and refused on its merits, not because the model cannot say it.
      final plan = planPatchRemoval(
        origin: origin(patches: [patch()]),
        patchModId: 585282,
        onDisk: folder(['a.ini']),
        storedOriginals: const {},
      );

      expect(plan.isEmpty, isTrue);
    });

    test('a folder with no origin block', () {
      expect(
        planPatchRemoval(
          origin: null,
          patchModId: 605460,
          onDisk: folder(const []),
          storedOriginals: const {},
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('which patches offer the action at all', () {
    test('only a layer whose files are known, topmost first', () {
      // **Topmost first** is the order they have to come out in: a layer with
      // another over it has had some of its own files overwritten in turn.
      final origins = origin(patches: [
        patch(modId: 111, files: const [InstalledFile(path: 'a.ini')]),
        patch(modId: 222),
        patch(modId: 333, files: const [InstalledFile(path: 'b.ini')]),
      ]);

      expect(removablePatches(origins).map((c) => c.modId), [333, 111]);
    });

    test('never the bottom layer, however the folder was assembled', () {
      // Taking the bottom out leaves a patch with nothing to patch; what a user
      // wants there is deleting the mod, which already exists.
      // A patch-shaped folder nobody has named a base for: its only layer is
      // at the bottom, so there is nothing here to take out.
      expect(
        removablePatches(ModOrigin(
          source: 'gamebanana',
          provenance: OriginProvenance.downloaded,
          ingest: const ModIngest(patchShaped: true),
          downloads: [patch(modId: 605460, files: const [
            InstalledFile(path: 'a.ini'),
          ])],
        )),
        isEmpty,
      );
      expect(removablePatches(null), isEmpty);
    });
  });
}
