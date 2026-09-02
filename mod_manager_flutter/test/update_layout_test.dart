import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_apply/update_layout.dart';

void main() {
  group('nothing recorded — the whole pre-ingest library', () {
    test('one folder maps to the mod folder itself', () {
      final layout = planUpdateLayout(
        ingest: null,
        incomingFolders: ['Ellen v2'],
      );
      expect(layout.canProceed, isTrue);
      expect(layout.mappings.single.isRoot, isTrue);
      expect(layout.replayedIngest, isFalse);
    });

    test('several folders stop and ask rather than guess', () {
      final layout = planUpdateLayout(
        ingest: null,
        incomingFolders: ['Ellen', 'previews'],
      );
      expect(layout.canProceed, isFalse);
      expect(layout.problem, UpdateLayoutProblem.layoutUnknown);
      expect(layout.unused, ['Ellen', 'previews']);
    });

    test('an empty archive has nothing to install', () {
      expect(
        planUpdateLayout(ingest: null, incomingFolders: []).problem,
        UpdateLayoutProblem.nothingToInstall,
      );
    });
  });

  group('separate install', () {
    ModIngest separate(List<String> folders, {String? group}) => ModIngest(
          folders: folders,
          siblingGroup: group,
        );

    test('the recorded folder is picked out of an archive with several', () {
      final layout = planUpdateLayout(
        ingest: separate(['Ellen'], group: 'g1'),
        incomingFolders: ['Ellen', 'Lycaon', 'previews'],
      );
      expect(layout.mappings.single.source, 'Ellen');
      expect(layout.mappings.single.isRoot, isTrue);
      expect(layout.unused, ['Lycaon', 'previews']);
      expect(layout.replayedIngest, isTrue);
    });

    test('a renamed upstream folder is routine, not a mismatch', () {
      // "Ellen" one release, "Ellen v2" the next. Unambiguous while there is
      // only one folder to pick, and the mod folder keeps its own name.
      final layout = planUpdateLayout(
        ingest: separate(['Ellen']),
        incomingFolders: ['Ellen v2'],
      );
      expect(layout.canProceed, isTrue);
      expect(layout.mappings.single.source, 'Ellen v2');
    });

    test('renamed *and* ambiguous stops and asks', () {
      final layout = planUpdateLayout(
        ingest: separate(['Ellen']),
        incomingFolders: ['Ellen v2', 'Ellen NSFW'],
      );
      expect(layout.problem, UpdateLayoutProblem.layoutChanged);
    });

    test('matching ignores case', () {
      final layout = planUpdateLayout(
        ingest: separate(['ELLEN']),
        incomingFolders: ['ellen', 'previews'],
      );
      expect(layout.mappings.single.source, 'ellen');
    });
  });

  group('combined install', () {
    ModIngest combined(List<String> folders) =>
        ModIngest(mode: IngestMode.combined, folders: folders);

    test('each recorded folder keeps the subfolder the install gave it', () {
      final layout = planUpdateLayout(
        ingest: combined(['Mod', 'Dependency']),
        incomingFolders: ['Mod', 'Dependency', 'readme'],
      );
      expect(
        layout.mappings.map((m) => (m.source, m.targetSubPath)).toList(),
        [('Mod', 'Mod'), ('Dependency', 'Dependency')],
      );
      expect(layout.unused, ['readme']);
    });

    test('a missing recorded folder stops and asks', () {
      // A rename cannot be absorbed here: with several subfolders there is no
      // way to tell which became which, and guessing writes a mod's textures
      // over its buffers.
      final layout = planUpdateLayout(
        ingest: combined(['Mod', 'Dependency']),
        incomingFolders: ['Mod v2', 'Dependency v2'],
      );
      expect(layout.problem, UpdateLayoutProblem.layoutChanged);
      expect(layout.replayedIngest, isTrue);
    });
  });

  test('a separate record naming several folders is not replayable', () {
    final layout = planUpdateLayout(
      ingest: const ModIngest(folders: ['A', 'B']),
      incomingFolders: ['A', 'B'],
    );
    expect(layout.problem, UpdateLayoutProblem.layoutChanged);
  });

  /// What gets written back after an update, which is where the *next* one reads
  /// its answer from.
  group('the record an update leaves behind', () {
    UpdateLayout layoutFor(String folder) => planUpdateLayout(
          ingest: ModIngest(folders: [folder]),
          incomingFolders: [folder],
        );

    test('it adopts the folder the update actually used', () {
      final ingest = ingestAfterUpdate(
        layoutFor('Ellen v2'),
        const ModIngest(folders: ['Ellen v1']),
      )!;
      expect(ingest.folders, ['Ellen v2']);
    });

    test('it does not forget that the folder holds a patch', () {
      // **Knowable only at install.** Rebuilt from scratch here, an ordinary
      // update turns a folder the app knows is two downloads into one it thinks
      // is one — and no later scan can recover that.
      final ingest = ingestAfterUpdate(
        layoutFor('Ellen'),
        const ModIngest(
          folders: ['Ellen'],
          patchShaped: true,
          patchFiles: ['Textures/Body.dds'],
          siblingGroup: 'group-7',
        ),
      )!;

      expect(ingest.patchShaped, isTrue);
      expect(ingest.patchFiles, ['Textures/Body.dds']);
      expect(ingest.siblingGroup, 'group-7');
    });

    test('a combined record is kept verbatim, patch record and all', () {
      const current = ModIngest(
        mode: IngestMode.combined,
        folders: ['Body', 'Wings'],
        patchFiles: ['Body/Skin.dds'],
      );
      expect(ingestAfterUpdate(layoutFor('Body'), current), current);
    });

    test('the moved patch replaces the recorded paths', () {
      // The base's layout decides where the patch lives, so an update that
      // rewrote the base moved it — and a record still naming the old paths
      // sends the next rebuild looking in the wrong place.
      final ingest = ingestAfterUpdate(
        layoutFor('Ellen'),
        const ModIngest(folders: ['Ellen'], patchFiles: ['Body.dds']),
        patchFiles: ['Textures/Body.dds'],
      )!;
      expect(ingest.patchFiles, ['Textures/Body.dds']);
    });

    test('a folder that never had a record can gain one', () {
      // The real gain for the pre-`ingest` library: a mod with no layout on
      // record now has one, so its next update replays instead of asking.
      final ingest = ingestAfterUpdate(layoutFor('Ellen'), null)!;
      expect(ingest.folders, ['Ellen']);
      expect(ingest.patchShaped, isFalse);
    });

    test('the file manifest is not this function\'s to carry', () {
      // It belongs to the **layer** that wrote it (`ModDownload.files`), not to
      // the folder — `ingest` keeps only the derived `patch_files` an older
      // build can still read. Pinned so nothing puts a per-download field back
      // on a per-folder record.
      final ingest = ingestAfterUpdate(layoutFor('Ellen'), null)!;
      expect(ingest.toJson().containsKey('files'), isFalse);
    });
  });
}
