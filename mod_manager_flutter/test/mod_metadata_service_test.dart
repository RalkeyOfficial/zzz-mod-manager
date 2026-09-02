import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/models/mod_metadata.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/mod_metadata_service.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import 'support/origin_shorthand.dart';

/// A sidecar with **every** typed field set to a non-null value.
///
/// Adding a typed field to [ModMetadata] means adding it here too. The
/// `knownKeys` test below derives both of its expectations from this fixture,
/// so it can only police fields it can see — a conditionally-emitted field
/// (most of them) left out of here is invisible to it.
const _fullyPopulatedJson = <String, dynamic>{
  'schema_version': 2,
  'description': 'd',
  'source_url': 'u',
  'tags': ['t'],
  'character_id': 'ellen',
  'images': ['i'],
  'origin': {
    'source': 'gamebanana',
    'mod_id': 531649,
    'mod_id_confidence': 'exact',
    'file_id': 1491924,
    'version': '1.0',
    'version_label': 'Full Mod',
    'version_confidence': 'exact',
    'provenance': 'downloaded',
    'ingest': {
      'mode': 'separate',
      'folders': ['Ellen Swimsuit'],
      'sibling_group': 'a3f1c9d2e4b5',
    },
    'installed_at': '2026-08-01T12:00:00.000Z',
    'installed_at_is_proxy': true,
    'baseline_remote_date': '2026-07-01T00:00:00.000Z',
    'archive_md5': '9e107d9d372bb6826bd81d3542a419d6',
    'tracking': 'off',
    'remote_missing': true,
  },
};

void main() {
  late Directory tmp;
  late ModMetadataService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('modmeta_test_');
    service = ModMetadataService();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('ModMetadata model', () {
    test('toJson/fromJson round-trips', () {
      const meta = ModMetadata(
        description: 'A cool mod',
        sourceUrl: 'https://gamebanana.com/mods/123',
        tags: ['nsfw', 'recolor'],
        characterId: 'miyabi',
        images: ['.zzz-mod-manager/images/01.png'],
      );
      final restored = ModMetadata.fromJson(meta.toJson());
      expect(restored.description, meta.description);
      expect(restored.sourceUrl, meta.sourceUrl);
      expect(restored.tags, meta.tags);
      expect(restored.characterId, meta.characterId);
      expect(restored.images, meta.images);
      expect(restored.schemaVersion, ModMetadata.currentSchemaVersion);
    });

    test('isEmpty reflects content', () {
      expect(const ModMetadata().isEmpty, isTrue);
      expect(const ModMetadata(tags: ['x']).isEmpty, isFalse);
      expect(const ModMetadata(characterId: 'anby').isEmpty, isFalse);
      // Unknown keys are someone else's data — worth persisting.
      expect(const ModMetadata(extra: {'vendor_x': 1}).isEmpty, isFalse);
      // An origin-only sidecar is worth writing too. Not covered by the
      // knownKeys test below, and without it loadOrMigrate silently refuses to
      // persist a freshly-recorded origin.
      expect(
        const ModMetadata(
          origin: ModOrigin(provenance: OriginProvenance.importedFolder),
        ).isEmpty,
        isFalse,
      );
    });

    test('toJson never resurrects a known key from extra', () {
      // A null description means the user cleared it. A stale entry in `extra`
      // must not put it back — that would defeat the whole full-replacement
      // save design.
      const meta = ModMetadata(description: null, extra: {'description': 'stale'});
      expect(meta.toJson().containsKey('description'), isFalse);
    });

    test('knownKeys matches the full set of typed keys', () {
      // A typed field whose key is missing from knownKeys is read into `extra`
      // *as well*, so it shadows the typed field and gets written twice.
      //
      // Asserting set *equality* (not just "emitted keys are known") is what
      // makes this bite: most keys are emitted conditionally, so a new field
      // left null in a fixture emits nothing and a subset check stays green.
      // Both directions are checked against the same fixture, so knownKeys and
      // _fullyPopulatedJson can't drift apart silently.
      expect(ModMetadata.knownKeys, _fullyPopulatedJson.keys.toSet());

      final meta = ModMetadata.fromJson(Map.of(_fullyPopulatedJson));
      expect(meta.extra, isEmpty, reason: 'a typed key leaked into extra');
      expect(
        meta.toJson().keys.toSet(),
        ModMetadata.knownKeys,
        reason: 'a typed field that failed to parse emits nothing and silently '
            'drops out of this set — check its fromJson against the fixture',
      );
    });

    test('extra is unmodifiable on every path it arrives through', () {
      final fromRead = ModMetadata.fromJson({'vendor_x': {'id': 1}});
      expect(() => fromRead.extra['x'] = 1, throwsUnsupportedError);
      expect(() => const ModMetadata().extra['x'] = 1, throwsUnsupportedError);
      expect(
        () => const ModMetadata().copyWith(extra: {'a': 1}).extra['x'] = 1,
        throwsUnsupportedError,
      );
    });

    test('replaceUserFields clears user fields but keeps machine-owned and unknown', () {
      // The exact failure this design exists to prevent: install from the
      // marketplace, sidecar gains an origin block, user edits the description
      // a week later, save rebuilds metadata from ModInfo (which has no origin
      // field) — and the mod silently reverts to untracked.
      final onDisk = ModMetadata.fromJson({
        'schema_version': 7,
        'description': 'old',
        'character_id': 'ellen',
        'origin': {'provenance': 'downloaded', 'mod_id': 123},
        'vendor_x': {'id': 1},
      });
      final saved = onDisk.replaceUserFields(
        description: null,
        sourceUrl: null,
        tags: const [],
        characterId: null,
        images: const [],
      );
      final json = saved.toJson();
      expect(json.containsKey('description'), isFalse, reason: 'clearing must work');
      expect(json.containsKey('character_id'), isFalse);
      expect(json['schema_version'], 7, reason: 'machine-owned: carried from disk');
      expect(json['vendor_x'], {'id': 1}, reason: 'unknown: carried from disk');
      expect(
        baseJson(json['origin'])['mod_id'],
        123,
        reason: 'typed machine-owned field survives a user edit',
      );
      expect((json['origin'] as Map)['provenance'], 'downloaded');
    });

    test('replaceUserFields never lets the "unknown" placeholder reach disk', () {
      // The placeholder is a runtime/display convention. Normalising it here
      // rather than at each save site means a future one (the marketplace
      // install) can't reintroduce it by omission.
      for (final placeholder in [unknownCharacterId, '']) {
        final json = const ModMetadata().replaceUserFields(
          description: null,
          sourceUrl: null,
          tags: const [],
          characterId: placeholder,
          images: const [],
        ).toJson();
        expect(json.containsKey('character_id'), isFalse, reason: 'for "$placeholder"');
      }
    });


    group('schema_version', () {
      test('an absent version means the file predates versioning', () {
        // Not "current". The key has been written on every save since v1, so
        // its absence dates the file — defaulting to current would stamp the
        // newest format onto the oldest files and make the marker useless.
        final meta = ModMetadata.fromJson({'description': 'old file'});
        expect(meta.schemaVersion, 1);
        expect(ModMetadata.assumedSchemaVersion, 1);
      });

      test('an ordinary save does not touch the version', () {
        // A user editing a description must not silently restamp the format.
        final onDisk = ModMetadata.fromJson({'schema_version': 1, 'tags': ['a']});
        final saved = onDisk.replaceUserFields(
          description: 'new',
          sourceUrl: null,
          tags: const [],
          characterId: null,
          images: const [],
        );
        expect(saved.schemaVersion, 1);
      });

      test('writing an origin advances the version to match the content', () {
        // Leaving a v1 stamp on a file that now holds an origin block would
        // make the marker say the opposite of what is true.
        final onDisk = ModMetadata.fromJson({'schema_version': 1});
        final withOrigin = onDisk.withOrigin(
          const ModOrigin(provenance: OriginProvenance.downloaded),
        );
        expect(withOrigin.schemaVersion, ModMetadata.currentSchemaVersion);
        expect(withOrigin.toJson()['schema_version'], 2);
      });

      test('a newer build\'s version is never downgraded', () {
        final fromFuture = ModMetadata.fromJson({'schema_version': 7});
        final withOrigin = fromFuture.withOrigin(
          const ModOrigin(provenance: OriginProvenance.downloaded),
        );
        expect(withOrigin.schemaVersion, 7);
      });

      test('clearing an origin leaves the version alone', () {
        // The file has been through a v2 build; saying so stays true.
        final tracked = ModMetadata.fromJson({
          'schema_version': 2,
          'origin': {'provenance': 'downloaded'},
        });
        expect(tracked.withOrigin(null).schemaVersion, 2);
      });
    });

    test('copyWith preserves unknown keys', () {
      // The setModCharacter path: read from disk, adjust one field, write back.
      final onDisk = ModMetadata.fromJson({
        'schema_version': 1,
        'vendor_x': {'id': 456},
        'origin': {'provenance': 'imported_archive', 'mod_id': 456},
      });
      final json = onDisk.copyWith(characterId: 'miyabi').toJson();
      expect(json['character_id'], 'miyabi');
      expect(json['vendor_x'], {'id': 456});
      expect(baseJson(json['origin'])['mod_id'], 456,
          reason: 'the flat block migrated on read and the stack was written '
              'back, with the identity intact');
    });
  });

  group('ModMetadataService read/write', () {
    test('read returns null when no sidecar exists', () async {
      expect(await service.read(tmp.path), isNull);
    });

    test('write then read round-trips and creates the sidecar path', () async {
      const meta = ModMetadata(description: 'hello', characterId: 'ellen', tags: ['a']);
      final ok = await service.write(tmp.path, meta);
      expect(ok, isTrue);

      final file = File(path.join(tmp.path, '.zzz-mod-manager', 'metadata.json'));
      expect(await file.exists(), isTrue);

      final read = await service.read(tmp.path);
      expect(read, isNotNull);
      expect(read!.description, 'hello');
      expect(read.characterId, 'ellen');
      expect(read.tags, ['a']);
    });

    test('read returns null on corrupt json', () async {
      final dir = Directory(path.join(tmp.path, '.zzz-mod-manager'))..createSync(recursive: true);
      File(path.join(dir.path, 'metadata.json')).writeAsStringSync('{ not valid json');
      expect(await service.read(tmp.path), isNull);
    });

    test('unknown keys survive a read/write cycle', () async {
      // The invariant this whole design exists for: a sidecar written by a
      // newer build (or another tool) must not be stripped when an older build
      // saves an unrelated user edit.
      final file = File(path.join(tmp.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'schema_version': 1,
          'description': 'hello',
          'tags': ['a'],
          'images': <String>[],
          // A map-valued unknown key as well as a scalar one: nested structures
          // are the shape most likely to be mangled by a naive re-encode.
          'ratings': {'sc': 'Sexual Content'},
          'vendor_x': 'whatever',
        }));

      final read = await service.read(tmp.path);
      expect(read, isNotNull);
      expect(read!.description, 'hello');
      expect(read.extra, {
        'ratings': {'sc': 'Sexual Content'},
        'vendor_x': 'whatever',
      });

      expect(await service.write(tmp.path, read), isTrue);

      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['ratings'], {'sc': 'Sexual Content'});
      expect(raw['vendor_x'], 'whatever');
      expect(raw['description'], 'hello');
      expect(raw['tags'], ['a']);
    });

    test('a corrupt sidecar is replaced wholesale on the next write', () async {
      // Known gap, pinned deliberately: read() conflates "missing" and
      // "corrupt" into a single null, so unknown keys in an unparseable file
      // are lost. See docs/metadata-schema.md §2.
      final file = File(path.join(tmp.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not valid json, "vendor_x": {"id": 1}');

      expect(await service.read(tmp.path), isNull);
      expect(await service.write(tmp.path, const ModMetadata(description: 'new')), isTrue);

      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['description'], 'new');
      expect(raw.containsKey('vendor_x'), isFalse);
    });

    test('never recreates a mod folder that no longer exists', () async {
      // The "ghost folder" guard: a mod renamed out from under an open edit
      // dialog must not be re-materialized holding only our sidecar.
      final gone = path.join(tmp.path, 'vanished');

      expect(await service.write(gone, const ModMetadata(description: 'x')), isFalse);
      expect(await service.addImageBytes(gone, [1, 2, 3]), isNull);

      final src = File(path.join(tmp.path, 'external.png'))..writeAsBytesSync([1]);
      expect(await service.importImageFile(gone, src.path), isNull);

      expect(Directory(gone).existsSync(), isFalse);
    });
  });

  group('ModMetadataService images', () {
    test('addImageBytes writes into images dir and increments index', () async {
      final rel1 = await service.addImageBytes(tmp.path, [1, 2, 3], extension: 'png');
      final rel2 = await service.addImageBytes(tmp.path, [4, 5, 6], extension: 'png');

      expect(rel1, path.join('.zzz-mod-manager', 'images', '01.png'));
      expect(rel2, path.join('.zzz-mod-manager', 'images', '02.png'));
      expect(await File(path.join(tmp.path, rel1!)).exists(), isTrue);
      expect(await File(path.join(tmp.path, rel2!)).exists(), isTrue);
    });

    test('importImageFile copies an external file into the mod folder', () async {
      final src = File(path.join(tmp.path, 'external.jpg'))..writeAsBytesSync([9, 9, 9]);
      final rel = await service.importImageFile(tmp.path, src.path);
      expect(rel, path.join('.zzz-mod-manager', 'images', '01.jpg'));
      expect(await File(path.join(tmp.path, rel!)).readAsBytes(), [9, 9, 9]);
    });
  });
}
