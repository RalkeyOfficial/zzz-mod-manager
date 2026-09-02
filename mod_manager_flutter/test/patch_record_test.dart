import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/patch_record.dart';

/// **The writes that record what a folder holds.**
///
/// A patch folder can be recognised exactly once — before the user drags the
/// base mod's files in around it. Afterwards every reference resolves and the
/// folder is indistinguishable from an ordinary one, so a scan can never recover
/// the fact. Recognising it and not writing it down is therefore the same
/// outcome as never looking: no mark on the card, no row offering to name what
/// it patches, and an update check that goes on asking the patch's own page and
/// calling the answer "up to date".
///
/// Each of these is a **stack operation**, and that is what changed: they used to
/// be two mirror-image writes over a primary-plus-companions record, where
/// getting the role wrong claimed the opposite of the truth. Now
/// [withPatchShape] inserts at the bottom, [withAppliedPatch] adds on top, and
/// the role follows the position with nothing to get backwards.
void main() {
  /// A folder holding one download, which is what an ingest produces.
  ModOrigin tracked({
    int? modId = 4001,
    int? fileId = 9001,
    ModIngest? ingest,
    List<ModDownload> patches = const [],
  }) =>
      ModOrigin(
        provenance: OriginProvenance.importedFolder,
        source: 'gamebanana',
        ingest: ingest,
        downloads: [
          ModDownload(
            modId: modId,
            modIdConfidence: OriginConfidence.exact,
            fileId: fileId,
            versionConfidence: OriginConfidence.exact,
          ),
          ...patches,
        ],
      );

  group('withPatchShape', () {
    test('it flags the bottom of the stack as missing', () {
      final amended = withPatchShape(tracked())!;
      expect(amended.ingest!.patchShaped, isTrue);
      expect(amended.needsBase, isTrue,
          reason: 'the flag with nothing under it is exactly the state the '
              'resolve row exists to clear');
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
      final ingest = withPatchShape(tracked(
        ingest: const ModIngest(
          mode: IngestMode.combined,
          folders: ['Body', 'Wings'],
          siblingGroup: 'group-7',
        ),
      ))!
          .ingest!;

      expect(ingest.mode, IngestMode.combined);
      expect(ingest.folders, ['Body', 'Wings']);
      expect(ingest.siblingGroup, 'group-7');
      expect(ingest.patchShaped, isTrue);
    });

    test('it starts a record when the folder has none', () {
      final ingest = withPatchShape(tracked())!.ingest!;
      expect(ingest.patchShaped, isTrue);
      expect(ingest.mode, IngestMode.separate);
      expect(ingest.folders, isEmpty);
    });

    test('the download\'s own record is untouched', () {
      // It describes the patch, which is the whole reason the flag is needed.
      // Rewriting it here would be answering a question nobody asked.
      final amended = withPatchShape(tracked())!;
      expect(amended.base!.modId, 4001);
      expect(amended.base!.modIdConfidence, OriginConfidence.exact);
      expect(amended.base!.fileId, 9001);
      expect(amended.provenance, OriginProvenance.importedFolder);
    });

    test('applying it twice says the same thing as applying it once', () {
      final once = withPatchShape(tracked());
      expect(withPatchShape(once), once,
          reason: 'a re-import over an existing folder must not accumulate');
    });

    group('the base mod, when the user has named one', () {
      const base = ModDownload(
        modId: 7100,
        modIdConfidence: OriginConfidence.user,
      );

      test('it is inserted underneath, and the patch becomes a patch', () {
        // **The insert is the whole operation.** What was the only layer is now
        // written over the base — with no role field to rewrite, because the
        // role follows the position.
        final amended = withPatchShape(tracked(), base: base)!;

        expect(amended.downloads.map((d) => d.modId), [7100, 4001]);
        expect(amended.downloads.map((d) => d.role),
            [DownloadRole.base, DownloadRole.patch]);
        expect(amended.needsBase, isFalse,
            reason: 'the question has been answered');
        expect(amended.ingest!.patchShaped, isTrue,
            reason: 'and the flag still records what the ingest was, so the '
                'answer stays undoable');
      });

      test('a re-import never inserts a second base under the first', () {
        // This runs again on every re-import of the same folder. Answering the
        // prompt with a *different* mod replaces the bottom layer — a folder
        // patches one mod, so two would be a contradiction rather than more
        // information — and the depth stays at two either way.
        final already = withPatchShape(tracked(), base: base)!;
        final again = withPatchShape(
          already,
          base: const ModDownload(
            modId: 6000,
            modIdConfidence: OriginConfidence.user,
          ),
        )!;

        expect(again.downloads.map((d) => d.modId), [6000, 4001]);
      });

      test('answering with the mod already on file changes nothing', () {
        final already = withPatchShape(tracked(), base: base)!;
        final again = withPatchShape(already, base: base)!;

        expect(again.downloads.map((d) => d.modId), [7100, 4001]);
        expect(again.needsBase, isFalse,
            reason: 'and the question stays answered');
      });

      test('saying nothing never clears what is already recorded', () {
        // **Only ever added.** An unanswered prompt is the user not saying,
        // which is not the same as them saying there is nothing there.
        final already = withPatchShape(tracked(), base: base)!;
        expect(withPatchShape(already)!.downloads.map((d) => d.modId),
            [7100, 4001]);
      });

      test('the flat patch-file list is rebuilt from the new order', () {
        // The layer that just became a patch is what `patch_files` now names,
        // and an older build reads that key to set it aside.
        final amended = withPatchShape(
          ModOrigin(
            provenance: OriginProvenance.importedFolder,
            downloads: const [
              ModDownload(
                modId: 4001,
                files: [InstalledFile(path: 'Body.dds')],
              ),
            ],
          ),
          base: base,
        )!;

        expect(amended.ingest!.patchFiles, ['Body.dds']);
      });
    });
  });

  /// The other direction: this folder is the mod, and a patch was written into
  /// it by an "install into…" the user asked for.
  group('withAppliedPatch', () {
    const patch = ModDownload(
      role: DownloadRole.patch,
      modId: 5100,
      modIdConfidence: OriginConfidence.exact,
      version: '1.2',
    );

    test('the folder keeps saying what it is', () {
      final amended = withAppliedPatch(tracked(), patch);

      expect(amended.base!.modId, 4001,
          reason: 'still the base mod — that is what it mostly is');
      expect(amended.ingest?.patchShaped ?? false, isFalse,
          reason: 'that flag says the bottom of the stack is missing, which is '
              'the opposite claim');
      expect(amended.patches.single.modId, 5100);
    });

    test('an untracked folder gets a block rather than being refused', () {
      // Unlike `withPatchShape`: the target is an existing library mod, and most
      // of a library that predates origin tracking has no block at all. Those
      // are the folders most likely to be hand-assembled, so refusing them
      // would make the feature quietly unavailable exactly where it is wanted.
      final amended = withAppliedPatch(null, patch);

      expect(amended.provenance, OriginProvenance.importedFolder);
      expect(amended.downloads.single.modId, 5100);
      expect(amended.hasIdentity, isTrue,
          reason: 'the only layer there is sits at the bottom, and it is the '
              'patch — which is what `patch_shaped` would say if the install '
              'had reason to');
    });

    test('a patch with no page of its own is still recorded', () {
      // The old shape required an identity and therefore wrote **nothing** for
      // a patch dragged off a disk. The install knows which files it laid down
      // even when it cannot say which mod they are, and that is enough to set
      // the layer aside and to take it back out.
      final amended = withAppliedPatch(
        tracked(),
        const ModDownload(
          role: DownloadRole.patch,
          files: [InstalledFile(path: 'Body.dds')],
        ),
      );

      expect(amended.downloads, hasLength(2));
      expect(amended.patches.single.hasIdentity, isFalse);
      expect(amended.ingest!.patchFiles, ['Body.dds'],
          reason: 'so a base update still sets it aside');
    });

    test('applying the same patch again does not list it twice', () {
      const newer = ModDownload(
        role: DownloadRole.patch,
        modId: 5100,
        modIdConfidence: OriginConfidence.exact,
        version: '1.3',
      );

      final amended =
          withAppliedPatch(withAppliedPatch(tracked(), patch), newer);

      expect(amended.patches.map((d) => d.version), ['1.3'],
          reason: 'the same mod, at whatever version arrived last');
    });

    test('a second, different patch goes on top of the first', () {
      // **Deduplicated by mod id, not by role.** One folder can legitimately
      // hold two patches from two authors, and the order is the order they
      // went on.
      const other = ModDownload(
        role: DownloadRole.patch,
        modId: 6200,
        modIdConfidence: OriginConfidence.exact,
      );

      final amended =
          withAppliedPatch(withAppliedPatch(tracked(), patch), other);

      expect(amended.downloads.map((d) => d.modId), [4001, 5100, 6200]);
    });

    test('two unnamed patches are both kept', () {
      // Nothing to match them against, so each is additive. Two hand-dragged
      // patches in one folder is a real shape and neither can be deduplicated
      // away.
      const unnamed = ModDownload(
        role: DownloadRole.patch,
        files: [InstalledFile(path: 'Body.dds')],
      );

      final amended =
          withAppliedPatch(withAppliedPatch(tracked(), unnamed), unnamed);

      expect(amended.downloads, hasLength(3));
    });
  });

  /// One layer, after the app fetched and wrote a newer file of it.
  ///
  /// A separate write from the one that records what the folder is, and for one
  /// reason: a layer's place in the stack does not change because we learned
  /// something about it.
  group('withDownloadUpdatedTo', () {
    ModOrigin folder({ModDownload? extra}) => tracked(patches: [
          const ModDownload(
            role: DownloadRole.patch,
            modId: 7100,
            modIdConfidence: OriginConfidence.user,
            fileId: 500,
            version: '1.0',
            versionConfidence: OriginConfidence.user,
          ),
          if (extra != null) extra,
        ]);

    ModOrigin? updated(ModOrigin? origin) => withDownloadUpdatedTo(
          origin,
          modId: 7100,
          fileId: 900,
          version: '2.0',
          versionLabel: 'NSFW',
          archiveMd5: 'deadbeef',
        );

    test('the file we installed is recorded at exact', () {
      // **The one route to `exact` on a layer the user did not identify by
      // hand**: every other is somebody telling us about bytes they moved in
      // themselves, and these are bytes we fetched.
      final layer = updated(folder())!.downloadOf(7100)!;

      expect(layer.fileId, 900);
      expect(layer.version, '2.0');
      expect(layer.versionLabel, 'NSFW');
      expect(layer.versionConfidence, OriginConfidence.exact);
      expect(layer.modIdConfidence, OriginConfidence.exact,
          reason: 'we fetched it off that page');
      expect(layer.archiveMd5, 'deadbeef');
      expect(layer.role, DownloadRole.patch,
          reason: 'where its files sit did not change');
    });

    test('its position in the stack does not move', () {
      expect(updated(folder())!.downloads.map((d) => d.modId), [4001, 7100]);
    });

    test('the folder still says what it is', () {
      final amended = updated(folder())!;
      expect(amended.base!.modId, 4001);
      expect(amended.base!.fileId, 9001);
      expect(amended.base!.versionConfidence, OriginConfidence.exact);
    });

    test('a baseline date goes, because the file is now known', () {
      // "I don't know which file, I got it around then" is a weaker answer, and
      // leaving it beside a known file means two comparisons disagreeing.
      final start = folder().withDownload(
        7100,
        (d) => d.copyWith(baselineRemoteDate: DateTime.utc(2025, 1, 1)),
      );
      expect(updated(start)!.downloadOf(7100)!.baselineRemoteDate, isNull);
    });

    test('a dismissal goes, because they have taken the update', () {
      // Stored as a date at or after this file's, so keeping it would silence
      // the *next* release too.
      final start = folder().withDownload(
        7100,
        (d) => d.copyWith(updatesDismissedUntil: DateTime.utc(2025, 1, 1)),
      );
      expect(updated(start)!.downloadOf(7100)!.updatesDismissedUntil, isNull);
    });

    test('a page recorded as gone is not gone — we just read it', () {
      final start =
          folder().withDownload(7100, (d) => d.copyWith(remoteMissing: true));
      expect(updated(start)!.downloadOf(7100)!.remoteMissing, isFalse);
    });

    test('the file list survives when the caller cannot report one', () {
      // Null is "I do not know", and an empty list would claim this layer put
      // nothing in the folder.
      final start = folder().withDownload(
        7100,
        (d) => d.copyWith(files: const [InstalledFile(path: 'Body.dds')]),
      );
      expect(updated(start)!.downloadOf(7100)!.files.single.path, 'Body.dds');
    });

    test('the other layers are untouched', () {
      const other = ModDownload(
        role: DownloadRole.patch,
        modId: 5100,
        modIdConfidence: OriginConfidence.exact,
      );
      expect(updated(folder(extra: other))!.downloads.last, other);
    });

    test('a folder with no such layer is left exactly as it was', () {
      // Nothing to amend. Inventing the layer would record a download nobody
      // named.
      final origin = tracked();
      expect(updated(origin), origin);
    });

    test('nothing is invented for a folder with no block', () {
      expect(updated(null), isNull);
    });
  });

  group('withRebuiltPatchFiles', () {
    test('it derives the flat list from the layers', () {
      final origin = tracked(patches: [
        const ModDownload(
          role: DownloadRole.patch,
          modId: 5100,
          files: [InstalledFile(path: 'Body.dds')],
        ),
      ]);

      expect(withRebuiltPatchFiles(origin).ingest!.patchFiles, ['Body.dds']);
    });

    test('a folder with no registries keeps whatever it had', () {
      // Everything installed before the registries existed has a hand-written
      // `patch_files` and no `files` to derive one from. Rebuilding would
      // replace the only record it has with an empty list — and that record is
      // what makes such a folder rebuildable.
      final legacy = tracked(
        ingest: const ModIngest(patchFiles: ['Textures/Body.dds']),
      );

      expect(withRebuiltPatchFiles(legacy).ingest!.patchFiles,
          ['Textures/Body.dds']);
    });
  });
}
