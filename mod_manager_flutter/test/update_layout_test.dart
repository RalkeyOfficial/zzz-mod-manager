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
}
