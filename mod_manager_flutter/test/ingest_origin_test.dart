import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_origin_seed.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/ingest_origin_builder.dart';

import 'support/origin_shorthand.dart';

void main() {
  late DateTime clock;
  var idCounter = 0;

  IngestOriginBuilder build() => IngestOriginBuilder(
        now: () => clock,
        newId: () => 'group${++idCounter}',
      );

  setUp(() {
    clock = DateTime.utc(2026, 8, 1, 12);
    idCounter = 0;
  });

  final archiveSeed =
      ModOriginSeed.importedArchive(archiveMd5: '9e107d9d372bb6826bd81d3542a419d6');

  group('sibling groups', () {
    test('a single mod gets no group', () {
      // A "group" of one is noise, and it invites code to read "has a group"
      // as "is part of a group".
      expect(build().siblingGroupFor(1), isNull);
      expect(build().siblingGroupFor(0), isNull);
    });

    test('several mods from one archive share a group', () {
      final builder = build();
      final group = builder.siblingGroupFor(3);
      expect(group, isNotNull);

      final origins = [
        for (final folder in ['/tmp/x/A', '/tmp/x/B', '/tmp/x/C'])
          builder.separate(
            seed: archiveSeed,
            sourceFolder: folder,
            siblingGroup: group,
          ),
      ];

      expect(origins.map((o) => o.ingest!.siblingGroup).toSet(), {group});
      expect(
        origins.map((o) => o.ingest!.folders).toList(),
        [
          ['A'],
          ['B'],
          ['C'],
        ],
        reason: 'each sidecar names only its own folder, never its siblings',
      );
    });

    test('the real generator produces distinct 12-hex ids', () {
      final ids = {
        for (var i = 0; i < 200; i++) IngestOriginBuilder.defaultIdGenerator(),
      };
      expect(ids.length, greaterThan(190), reason: 'collisions should be rare');
      expect(ids.every((id) => RegExp(r'^[0-9a-f]{12}$').hasMatch(id)), isTrue);
    });
  });

  group('separate mode', () {
    test('records the archive-relative basename, not a path', () {
      // The source lived in a temp dir that no longer exists, so an absolute
      // path would be meaningless later and would leak the filesystem layout
      // into a file meant to be shareable.
      final origin = build().separate(
        seed: archiveSeed,
        sourceFolder: '/tmp/zzz_archive_extract_abc/Ellen Swimsuit',
      );

      expect(origin.ingest!.mode, IngestMode.separate);
      expect(origin.ingest!.folders, ['Ellen Swimsuit']);
      expect(origin.ingest!.folders.single, isNot(contains('/')));
    });

    test('carries the seed through', () {
      final origin = build().separate(seed: archiveSeed, sourceFolder: '/x/Mod');

      expect(origin.provenance, OriginProvenance.importedArchive);
      expect(origin.archiveMd5, '9e107d9d372bb6826bd81d3542a419d6');
      expect(origin.installedAt, clock);
      expect(origin.installedAtIsProxy, isFalse,
          reason: 'this install was observed, not inferred from mtimes');
    });

    test('a dropped folder has no archive hash', () {
      final origin = build()
          .separate(seed: ModOriginSeed.importedFolder, sourceFolder: '/x/Mod');

      expect(origin.provenance, OriginProvenance.importedFolder);
      expect(origin.archiveMd5, isNull);
      expect(origin.toJson().containsKey('archive_md5'), isFalse);
    });

    test('identity is unknown until the marketplace can supply it', () {
      final origin = build().separate(seed: archiveSeed, sourceFolder: '/x/Mod');

      expect(origin.modId, isNull);
      expect(origin.modIdConfidence, OriginConfidence.unknown);
      expect(origin.versionConfidence, OriginConfidence.unknown);
      expect(origin.allowsUnattendedUpdate, isFalse);
    });
  });

  group('combined mode', () {
    test('names every source folder and takes no group', () {
      final origin = build().combined(
        seed: archiveSeed,
        sourceFolders: ['/tmp/x/Mod', '/tmp/x/Dependency'],
      );

      expect(origin.ingest!.mode, IngestMode.combined);
      expect(origin.ingest!.folders, ['Mod', 'Dependency']);
      expect(origin.ingest!.siblingGroup, isNull,
          reason: 'combined is exactly the case of one archive -> one mod');
    });
  });

  group('combineSeeds', () {
    test('keeps the hash when every folder came from the same archive', () {
      final seed = IngestOriginBuilder.combineSeeds([archiveSeed, archiveSeed]);
      expect(seed.provenance, OriginProvenance.importedArchive);
      expect(seed.archiveMd5, archiveSeed.archiveMd5);
    });

    test('drops to imported_folder when the sources are mixed', () {
      // Merging a folder unpacked from a zip with one the user dragged in
      // yields a mod only partly from that archive — claiming the hash would
      // imply the whole folder matches a published file.
      final seed = IngestOriginBuilder.combineSeeds(
          [archiveSeed, ModOriginSeed.importedFolder]);

      expect(seed.provenance, OriginProvenance.importedFolder);
      expect(seed.archiveMd5, isNull);
    });

    test('drops the hash when two different archives are merged', () {
      final other = ModOriginSeed.importedArchive(archiveMd5: 'ffff');
      final seed = IngestOriginBuilder.combineSeeds([archiveSeed, other]);

      expect(seed.archiveMd5, isNull);
    });

    test('an empty or all-null list is a plain folder import', () {
      expect(IngestOriginBuilder.combineSeeds([]).provenance,
          OriginProvenance.importedFolder);
      expect(IngestOriginBuilder.combineSeeds([null, null]).provenance,
          OriginProvenance.importedFolder);
    });
  });
}
