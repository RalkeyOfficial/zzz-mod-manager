import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/mod_metadata_repository.dart';

/// In-memory stand-in for the `config.json` character-tag mirror.
///
/// Deliberately *not* the real `ConfigService`: that writes to the developer's
/// actual `<appData>/config.json`, so a test using it would clobber their
/// library paths, active mods and favourites.
class _FakeTagStore implements ModCharacterTagStore {
  final Map<String, String> tags = {};

  @override
  Map<String, String> get modCharacterTags => Map.of(tags);

  @override
  Future<bool> setModCharacterTag(String modId, String characterId) async {
    tags[modId] = characterId;
    return true;
  }

  @override
  Future<bool> removeModCharacterTag(String modId) async {
    tags.remove(modId);
    return true;
  }
}

/// Exercises the metadata *rules* — legacy migration, the "don't litter empty
/// sidecars" guard, character normalisation on both storage surfaces.
///
/// These were untestable while they lived inside `ModManagerService`, which
/// needs a configured library, a `ProviderContainer` and the platform service.
/// Here everything is injected, so a temp dir is the whole fixture.
void main() {
  late Directory tmp;
  late Directory modsDir;
  late Directory legacyImages;
  late _FakeTagStore config;
  late ModMetadataRepository repo;

  /// `<mod>/.zzz-mod-manager/metadata.json` as a raw map, or null if absent.
  Map<String, dynamic>? sidecarOf(String modName) {
    final f = File(path.join(modsDir.path, modName, '.zzz-mod-manager', 'metadata.json'));
    if (!f.existsSync()) return null;
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }

  Directory makeMod(String name) =>
      Directory(path.join(modsDir.path, name))..createSync(recursive: true);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('modrepo_test_');
    modsDir = Directory(path.join(tmp.path, 'mods'))..createSync();
    legacyImages = Directory(path.join(tmp.path, 'mod_images'))..createSync();

    config = _FakeTagStore();

    repo = ModMetadataRepository(
      config,
      modsPath: () => modsDir.path,
      legacyImagesPath: () => legacyImages.path,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('loadOrMigrate', () {
    test('writes no sidecar when there is nothing to migrate', () async {
      makeMod('Bare Mod');
      final meta = await repo.loadOrMigrate('Bare Mod', path.join(modsDir.path, 'Bare Mod'));

      expect(meta.isEmpty, isTrue);
      expect(sidecarOf('Bare Mod'), isNull,
          reason: 'a user who never touches metadata should see no new files');
    });

    test('migrates a legacy character tag out of config.json', () async {
      makeMod('Ellen Swimsuit');
      await config.setModCharacterTag('Ellen Swimsuit', 'ellen');

      final meta = await repo.loadOrMigrate(
          'Ellen Swimsuit', path.join(modsDir.path, 'Ellen Swimsuit'));

      expect(meta.characterId, 'ellen');
      expect(sidecarOf('Ellen Swimsuit')?['character_id'], 'ellen');
    });

    test('treats a legacy "unknown" tag as untagged, not as a character', () async {
      // Older builds wrote the runtime placeholder into config.json. Copying it
      // into a sidecar would both violate the never-persist rule and litter a
      // sidecar with nothing meaningful in it.
      makeMod('Mystery Mod');
      await config.setModCharacterTag('Mystery Mod', 'unknown');

      final meta = await repo.loadOrMigrate(
          'Mystery Mod', path.join(modsDir.path, 'Mystery Mod'));

      expect(meta.characterId, isNull);
      expect(sidecarOf('Mystery Mod'), isNull);
    });

    test('migrates a legacy app-data image into the mod folder', () async {
      makeMod('Anby Mod');
      File(path.join(legacyImages.path, 'Anby Mod.png')).writeAsBytesSync([1, 2, 3]);

      final meta = await repo.loadOrMigrate('Anby Mod', path.join(modsDir.path, 'Anby Mod'));

      expect(meta.images, [path.join('.zzz-mod-manager', 'images', '01.png')]);
      expect(
        File(path.join(modsDir.path, 'Anby Mod', meta.images.first)).readAsBytesSync(),
        [1, 2, 3],
      );
    });

    test('an existing sidecar wins outright and is not re-migrated', () async {
      final dir = makeMod('Tracked Mod');
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'schema_version': 1,
          'character_id': 'miyabi',
          'origin': {'mod_id': 42},
        }));
      // A stale config tag must not override what's on disk.
      await config.setModCharacterTag('Tracked Mod', 'ellen');

      final meta = await repo.loadOrMigrate('Tracked Mod', dir.path);

      expect(meta.characterId, 'miyabi');
      expect(meta.extra['origin'], {'mod_id': 42});
    });

    test('is idempotent — a second pass changes nothing', () async {
      makeMod('Repeat Mod');
      await config.setModCharacterTag('Repeat Mod', 'ellen');
      final folder = path.join(modsDir.path, 'Repeat Mod');

      await repo.loadOrMigrate('Repeat Mod', folder);
      final first = sidecarOf('Repeat Mod');
      await repo.loadOrMigrate('Repeat Mod', folder);

      expect(sidecarOf('Repeat Mod'), first);
    });

    test('a read-only mod folder still yields usable values in memory', () async {
      // Migration is best-effort: an unwritable folder must not break the app.
      final dir = makeMod('Locked Mod');
      await config.setModCharacterTag('Locked Mod', 'ellen');
      Process.runSync('chmod', ['a-w', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['u+w', dir.path]));

      final meta = await repo.loadOrMigrate('Locked Mod', dir.path);

      expect(meta.characterId, 'ellen', reason: 'resolved in memory even if unwritable');
      expect(sidecarOf('Locked Mod'), isNull);
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);
  });

  group('save', () {
    test('clears emptied fields instead of keeping the old value', () async {
      final dir = makeMod('Edited Mod');
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'schema_version': 1,
          'description': 'old text',
          'source_url': 'https://gamebanana.com/mods/1',
          'origin': {'mod_id': 7},
        }));

      final ok = await repo.save(ModInfo(
        id: 'Edited Mod',
        name: 'Edited Mod',
        characterId: 'unknown',
        isActive: false,
      ));

      expect(ok, isTrue);
      final raw = sidecarOf('Edited Mod')!;
      expect(raw.containsKey('description'), isFalse);
      expect(raw.containsKey('source_url'), isFalse);
      expect(raw.containsKey('character_id'), isFalse, reason: 'placeholder must not persist');
      expect(raw['origin'], {'mod_id': 7}, reason: 'machine-owned survives a user edit');
    });

    test('stores gallery paths relative and drops ones outside the mod folder', () async {
      final dir = makeMod('Gallery Mod');
      final inside = File(path.join(dir.path, 'Preview.png'))..writeAsBytesSync([1]);
      final outside = File(path.join(tmp.path, 'elsewhere.png'))..writeAsBytesSync([1]);

      await repo.save(ModInfo(
        id: 'Gallery Mod',
        name: 'Gallery Mod',
        characterId: 'ellen',
        isActive: false,
        images: [inside.path, outside.path],
      ));

      expect(sidecarOf('Gallery Mod')!['images'], ['Preview.png']);
    });

    test('returns false when no library is configured', () async {
      final unconfigured = ModMetadataRepository(config, modsPath: () => null);
      final ok = await unconfigured.save(ModInfo(
        id: 'x', name: 'x', characterId: 'ellen', isActive: false,
      ));
      expect(ok, isFalse);
    });
  });

  group('setCharacter', () {
    test('writes through to both the sidecar and the config mirror', () async {
      makeMod('Tagged Mod');

      expect(await repo.setCharacter('Tagged Mod', 'miyabi'), isTrue);

      expect(sidecarOf('Tagged Mod')!['character_id'], 'miyabi');
      expect(config.tags['Tagged Mod'], 'miyabi');
    });

    test('clearing removes the tag from both surfaces, never storing the placeholder', () async {
      // The edit-dialog bug: an untagged mod hands back "unknown" verbatim.
      makeMod('Untagged Mod');
      await repo.setCharacter('Untagged Mod', 'ellen');

      expect(await repo.setCharacter('Untagged Mod', 'unknown'), isTrue);

      expect(sidecarOf('Untagged Mod')!.containsKey('character_id'), isFalse);
      expect(config.tags.containsKey('Untagged Mod'), isFalse);
    });

    test('preserves unknown keys already in the sidecar', () async {
      final dir = makeMod('Origin Mod');
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'schema_version': 1,
          'origin': {'mod_id': 99},
        }));

      await repo.setCharacter('Origin Mod', 'ellen');

      final raw = sidecarOf('Origin Mod')!;
      expect(raw['character_id'], 'ellen');
      expect(raw['origin'], {'mod_id': 99});
    });
  });
}
