import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/services/http/image_fetcher.dart';
import 'package:mod_manager_flutter/services/mod_metadata_repository.dart';
import 'package:mod_manager_flutter/services/origin_backfill.dart';
import 'package:mod_manager_flutter/services/origin_resolution.dart';

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

/// In-memory stand-in for the preview-image fetcher.
///
/// Counts calls **per url**, because "one archive that became five mods must not
/// download the same screenshot five times" is a property of the repository, not
/// of the planner, and a count is the only way to see it.
class _FakeImageFetcher implements ImageFetcher {
  _FakeImageFetcher({this.failing = const {}});

  /// Urls that answer with null, as an unreachable CDN node would.
  final Set<String> failing;

  final Map<String, int> calls = {};

  int callsFor(String url) => calls[url] ?? 0;
  int get totalCalls => calls.values.fold(0, (sum, n) => sum + n);

  @override
  Future<Uint8List?> fetch(Uri url) async {
    calls['$url'] = callsFor('$url') + 1;
    if (failing.contains('$url')) return null;
    return Uint8List.fromList(utf8.encode('bytes of $url'));
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
  late _FakeImageFetcher images;
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
    images = _FakeImageFetcher();

    repo = ModMetadataRepository(
      config,
      modsPath: () => modsDir.path,
      legacyImagesPath: () => legacyImages.path,
      imageFetcher: images,
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
          'vendor_x': {'id': 42},
          'origin': {'provenance': 'downloaded', 'mod_id': 42},
        }));
      // A stale config tag must not override what's on disk.
      await config.setModCharacterTag('Tracked Mod', 'ellen');

      final meta = await repo.loadOrMigrate('Tracked Mod', dir.path);

      expect(meta.characterId, 'miyabi');
      expect(meta.extra['vendor_x'], {'id': 42});
      expect(meta.origin?.modId, 42, reason: 'typed origin parsed off disk');
      expect(meta.origin?.provenance, OriginProvenance.downloaded);
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

  group('loadOrMigrate — offline origin backfill', () {
    /// A mod that already has a sidecar. That is the *only* branch the backfill
    /// can run on: `source_url` lives in the sidecar, so a mod without one has
    /// nothing to parse and falls through to the legacy migration instead.
    Directory sidecarMod(String name, Map<String, dynamic> json) {
      final dir = makeMod(name);
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(json));
      // A file of the mod's own, so the install-date proxy has something to
      // find that isn't our own bookkeeping.
      File(path.join(dir.path, 'mod.ini'))
        ..writeAsStringSync('[Constants]')
        ..setLastModifiedSync(DateTime(2024, 5, 6));
      return dir;
    }

    test('recovers identity from source_url and stamps schema v2', () async {
      final dir = sidecarMod('Legacy Mod', {
        'schema_version': 1,
        'source_url': 'https://gamebanana.com/mods/531649',
        'tags': ['4k'],
      });

      final meta = await repo.loadOrMigrate('Legacy Mod', dir.path);

      expect(meta.origin?.modId, 531649);
      expect(meta.origin?.modIdConfidence, OriginConfidence.inferred);

      final written = sidecarOf('Legacy Mod')!;
      final origin = written['origin'] as Map;
      expect(origin['mod_id'], 531649);
      expect(origin['mod_id_confidence'], 'inferred');
      expect(origin['source'], 'gamebanana');
      expect(origin['installed_at_is_proxy'], isTrue,
          reason: 'a derived date must never look observed');
      expect(DateTime.parse(origin['installed_at'] as String),
          DateTime(2024, 5, 6).toUtc());
      expect(written['schema_version'], 2,
          reason: 'a v1 stamp on a file holding an origin block would lie');
      expect(written['tags'], ['4k'], reason: 'user data untouched');
    });

    test('version stays unknown — only identity is recoverable offline', () async {
      final dir = sidecarMod('Legacy Mod', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });

      await repo.loadOrMigrate('Legacy Mod', dir.path);

      final origin = sidecarOf('Legacy Mod')!['origin'] as Map;
      expect(origin.containsKey('file_id'), isFalse);
      expect(origin.containsKey('version'), isFalse);
      expect(origin.containsKey('version_confidence'), isFalse,
          reason: 'unknown is the read-side default and is not written out');
      expect(ModOrigin.fromJson(origin)!.allowsUnattendedUpdate, isFalse);
    });

    test('is idempotent — a second scan rewrites nothing', () async {
      final dir = sidecarMod('Legacy Mod', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });

      await repo.loadOrMigrate('Legacy Mod', dir.path);
      final file = File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'));
      final first = file.readAsStringSync();
      final firstWrite = file.lastModifiedSync();

      await repo.loadOrMigrate('Legacy Mod', dir.path);

      expect(file.readAsStringSync(), first);
      expect(file.lastModifiedSync(), firstWrite,
          reason: 'a backfilled mod must not be re-walked or re-written on '
              'every scan — this is what keeps it off the hot path');
    });

    test('writes nothing at all when no id is derivable', () async {
      // The don't-litter rule, and the reason there is no "already swept"
      // marker: re-sniffing costs one string parse, and a marker would need a
      // file we have decided not to create.
      final dir = sidecarMod('Local Mod', {
        'source_url': 'https://drive.google.com/file/d/abc',
        'tags': ['mine'],
      });
      final before = File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
          .readAsStringSync();

      final meta = await repo.loadOrMigrate('Local Mod', dir.path);

      expect(meta.origin, isNull);
      expect(
        File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
            .readAsStringSync(),
        before,
      );
    });

    test('never rebinds a mod that already has an identity', () async {
      // A downloaded mod whose source_url points somewhere else entirely — a
      // wrong paste, or a collection link. Re-parsing it would bind the folder
      // to an unrelated remote mod, after which an "update" overwrites it with
      // another mod's files.
      final dir = sidecarMod('Downloaded Mod', {
        'source_url': 'https://gamebanana.com/mods/999',
        'origin': {
          'source': 'gamebanana',
          'provenance': 'downloaded',
          'mod_id': 111,
          'mod_id_confidence': 'exact',
          'installed_at': '2026-01-01T00:00:00.000Z',
        },
      });

      final meta = await repo.loadOrMigrate('Downloaded Mod', dir.path);

      expect(meta.origin?.modId, 111);
      expect(meta.origin?.modIdConfidence, OriginConfidence.exact);
      expect(meta.origin?.installedAt, DateTime.utc(2026, 1, 1));
    });

    test('respects tracking: off', () async {
      final dir = sidecarMod('My Own Mod', {
        'source_url': 'https://gamebanana.com/mods/531649',
        'origin': {'provenance': 'imported_folder', 'tracking': 'off'},
      });

      final meta = await repo.loadOrMigrate('My Own Mod', dir.path);

      expect(meta.origin?.modId, isNull,
          reason: '"it\'s my own" is the user\'s decision, not a gap to fill');
      expect((sidecarOf('My Own Mod')!['origin'] as Map)['tracking'], 'off');
    });

    test('a read-only mod folder still yields the identity in memory', () async {
      final dir = sidecarMod('Locked Legacy', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });
      // The sidecar itself, not its directory: a read-only *directory* still
      // permits rewriting a file that already exists inside it, so chmod'ing
      // the folder would let the write succeed and prove nothing.
      final sidecar = path.join(dir.path, '.zzz-mod-manager', 'metadata.json');
      Process.runSync('chmod', ['a-w', sidecar]);
      addTearDown(() => Process.runSync('chmod', ['u+w', sidecar]));

      final meta = await repo.loadOrMigrate('Locked Legacy', dir.path);

      expect(meta.origin?.modId, 531649);
      expect(sidecarOf('Locked Legacy')!.containsKey('origin'), isFalse);
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);

    test('a corrected source_url re-points the mod', () async {
      // A wrong paste bound the folder to mod 111 at `inferred`; the user has
      // now fixed the url. Without this the folder stays bound to the wrong mod
      // forever, since editing the url is the only remedy that exists today.
      final dir = sidecarMod('Mistyped Mod', {
        'source_url': 'https://gamebanana.com/mods/222',
        'origin': {
          'source': 'gamebanana',
          'provenance': 'imported_folder',
          'mod_id': 111,
          'mod_id_confidence': 'inferred',
          'file_id': 555,
          'version': '1.2',
          'version_confidence': 'inferred',
        },
      });

      final meta = await repo.loadOrMigrate('Mistyped Mod', dir.path);

      expect(meta.origin?.modId, 222);
      final written = sidecarOf('Mistyped Mod')!['origin'] as Map;
      expect(written['mod_id'], 222);
      expect(written.containsKey('file_id'), isFalse,
          reason: 'file 555 belonged to the mod we are no longer pointing at');
      expect(written.containsKey('version'), isFalse);
    });

    test('does no filesystem walk for a mod it cannot place', () async {
      var probes = 0;
      final counted = ModMetadataRepository(
        config,
        modsPath: () => modsDir.path,
        legacyImagesPath: () => legacyImages.path,
        backfill: OriginBackfill(installDateProbe: (_) async {
          probes++;
          return DateTime(2024, 5, 6);
        }),
      );

      final untracked = sidecarMod('No Url Mod', {'tags': ['mine']});
      await counted.loadOrMigrate('No Url Mod', untracked.path);
      expect(probes, 0,
          reason: 'the untracked majority of a library must cost no I/O');

      final tracked = sidecarMod('Url Mod', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });
      await counted.loadOrMigrate('Url Mod', tracked.path);
      expect(probes, 1);

      // ...and never again, because the mod no longer qualifies.
      await counted.loadOrMigrate('Url Mod', tracked.path);
      expect(probes, 1);
    });

    test('a concurrent edit is not reverted by the backfill write', () async {
      // The window this closes: the folder walk is an await, and a scan runs
      // after every toggle and rename, so the user confirming the edit dialog
      // can land a save() mid-walk. Writing back the copy read *before* the
      // walk would quietly revert their description and tags.
      final dir = sidecarMod('Raced Mod', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });

      late ModMetadataRepository racing;
      racing = ModMetadataRepository(
        config,
        modsPath: () => modsDir.path,
        legacyImagesPath: () => legacyImages.path,
        backfill: OriginBackfill(installDateProbe: (_) async {
          await racing.save(ModInfo(
            id: 'Raced Mod',
            name: 'Raced Mod',
            characterId: 'ellen',
            isActive: false,
            description: 'notes the user just typed',
            sourceUrl: 'https://gamebanana.com/mods/531649',
          ));
          return DateTime(2024, 5, 6);
        }),
      );

      await racing.loadOrMigrate('Raced Mod', dir.path);

      final raw = sidecarOf('Raced Mod')!;
      expect(raw['description'], 'notes the user just typed');
      expect(raw['character_id'], 'ellen');
      expect((raw['origin'] as Map)['mod_id'], 531649,
          reason: 'and the backfill still contributes its own key');
    });

    test('keeps re-attempting a folder whose write cannot succeed', () async {
      var probes = 0;
      final counted = ModMetadataRepository(
        config,
        modsPath: () => modsDir.path,
        legacyImagesPath: () => legacyImages.path,
        backfill: OriginBackfill(installDateProbe: (_) async {
          probes++;
          return DateTime(2024, 5, 6);
        }),
      );

      final dir = sidecarMod('Locked Repeat', {
        'source_url': 'https://gamebanana.com/mods/531649',
      });
      final sidecar = path.join(dir.path, '.zzz-mod-manager', 'metadata.json');
      Process.runSync('chmod', ['a-w', sidecar]);
      addTearDown(() => Process.runSync('chmod', ['u+w', sidecar]));

      await counted.loadOrMigrate('Locked Repeat', dir.path);
      await counted.loadOrMigrate('Locked Repeat', dir.path);
      await counted.loadOrMigrate('Locked Repeat', dir.path);

      expect(probes, 3,
          reason: 'a scan has to re-attempt, or it cannot tell a fixed folder '
              'from a still-broken one');
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);

    group('reporting a write it could not make', () {
      /// A repository whose backfill probe is counted, over a mod whose sidecar
      /// has been made read-only.
      (ModMetadataRepository, int Function()) lockedMod(String name) {
        var probes = 0;
        final repo = ModMetadataRepository(
          config,
          modsPath: () => modsDir.path,
          legacyImagesPath: () => legacyImages.path,
          backfill: OriginBackfill(installDateProbe: (_) async {
            probes++;
            return DateTime(2024, 5, 6);
          }),
        );
        final dir = sidecarMod(name, {
          'source_url': 'https://gamebanana.com/mods/531649',
        });
        final sidecar = path.join(dir.path, '.zzz-mod-manager', 'metadata.json');
        Process.runSync('chmod', ['a-w', sidecar]);
        addTearDown(() => Process.runSync('chmod', ['u+w', sidecar]));
        return (repo, () => probes);
      }

      test('names the mod it could not record, by name and not by path',
          () async {
        final (repo, _) = lockedMod('Locked Report');

        expect(repo.takeBackfillWriteFailures(), isEmpty,
            reason: 'nothing has been scanned yet');

        await repo.loadOrMigrate(
            'Locked Report', path.join(modsDir.path, 'Locked Report'));

        expect(repo.takeBackfillWriteFailures(), ['Locked Report']);
      });

      test('names it again on every scan that still cannot write', () async {
        // The mod is unusable for update checking until this is fixed, so the
        // warning is not a once-per-session notice.
        final (repo, _) = lockedMod('Locked Repeatedly');
        final dir = path.join(modsDir.path, 'Locked Repeatedly');

        for (var scan = 1; scan <= 3; scan++) {
          await repo.loadOrMigrate('Locked Repeatedly', dir);
          expect(repo.takeBackfillWriteFailures(), ['Locked Repeatedly'],
              reason: 'scan $scan');
        }
      });

      test('stops naming it once the folder is writable again', () async {
        // What retrying buys: no restart needed to notice the fix.
        final (repo, _) = lockedMod('Locked Then Fixed');
        final dir = path.join(modsDir.path, 'Locked Then Fixed');
        final sidecar = path.join(dir, '.zzz-mod-manager', 'metadata.json');

        await repo.loadOrMigrate('Locked Then Fixed', dir);
        expect(repo.takeBackfillWriteFailures(), ['Locked Then Fixed']);

        Process.runSync('chmod', ['u+w', sidecar]);

        await repo.loadOrMigrate('Locked Then Fixed', dir);
        expect(repo.takeBackfillWriteFailures(), isEmpty);
        expect((sidecarOf('Locked Then Fixed')!['origin'] as Map)['mod_id'],
            531649);
      });

      test('a folder that writes fine is never named', () async {
        final dir = sidecarMod('Writable Mod', {
          'source_url': 'https://gamebanana.com/mods/531649',
        });
        await repo.loadOrMigrate('Writable Mod', dir.path);

        expect(repo.takeBackfillWriteFailures(), isEmpty);
      });
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);

    test('a mod with no sidecar is left to the legacy migration', () async {
      // The branch that makes the sibling framing concrete: no sidecar means no
      // source_url to parse, so there is nothing for the backfill to do and no
      // empty file gets created on its behalf.
      makeMod('Untouched Mod');

      final meta = await repo.loadOrMigrate(
          'Untouched Mod', path.join(modsDir.path, 'Untouched Mod'));

      expect(meta.origin, isNull);
      expect(sidecarOf('Untouched Mod'), isNull);
    });
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
          'vendor_x': {'id': 7},
          'origin': {'provenance': 'downloaded', 'mod_id': 7},
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
      expect(raw['vendor_x'], {'id': 7}, reason: 'unknown key survives a user edit');
      expect(
        (raw['origin'] as Map)['mod_id'],
        7,
        reason: 'the typed origin block survives a user edit too — this is the '
            'exact regression that would silently untrack an installed mod',
      );
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
          'vendor_x': {'id': 99},
          'origin': {'provenance': 'imported_archive', 'mod_id': 99},
        }));

      await repo.setCharacter('Origin Mod', 'ellen');

      final raw = sidecarOf('Origin Mod')!;
      expect(raw['character_id'], 'ellen');
      expect(raw['vendor_x'], {'id': 99});
      expect((raw['origin'] as Map)['mod_id'], 99);
    });
  });

  group('recordOrigin', () {
    ModOrigin origin({
      OriginProvenance provenance = OriginProvenance.importedArchive,
      String? md5 = 'aaaa',
    }) =>
        ModOrigin(
          provenance: provenance,
          archiveMd5: md5,
          ingest: const ModIngest(folders: ['Mod']),
          installedAt: DateTime.utc(2026, 8, 1),
        );

    test('writes an origin block into a folder with no sidecar', () async {
      makeMod('Fresh Mod');

      expect(await repo.recordOrigin('Fresh Mod', origin()), isTrue);

      final raw = sidecarOf('Fresh Mod')!;
      expect((raw['origin'] as Map)['provenance'], 'imported_archive');
      expect((raw['origin'] as Map)['archive_md5'], 'aaaa');
    });

    test("drops a stranger's origin block but keeps their user data", () async {
      // The rule this method exists for. `_copyDirectory` copies a source
      // folder's `.zzz-mod-manager/` wholesale, so a mod passed around on
      // Discord arrives carrying someone else's origin — a claim of `exact`
      // confidence about a remote file that we never made, on the one field
      // that gates unattended updates.
      final dir = makeMod('Shared Mod');
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'schema_version': 1,
          'description': 'notes from the author',
          'tags': ['4k', 'swimsuit'],
          'images': ['Preview.png'],
          'origin': {
            'source': 'gamebanana',
            'mod_id': 999,
            'mod_id_confidence': 'exact',
            'file_id': 555,
            'version_confidence': 'exact',
            'provenance': 'downloaded',
          },
        }));

      expect(
        await repo.recordOrigin(
          'Shared Mod',
          origin(provenance: OriginProvenance.importedFolder, md5: null),
        ),
        isTrue,
      );

      final raw = sidecarOf('Shared Mod')!;
      final written = raw['origin'] as Map;

      // The foreign identity is gone entirely...
      expect(written.containsKey('mod_id'), isFalse);
      expect(written.containsKey('file_id'), isFalse);
      expect(written.containsKey('source'), isFalse);
      expect(written['provenance'], 'imported_folder');
      // ...and with it every claim of exactness.
      expect(written.containsKey('mod_id_confidence'), isFalse);
      expect(written.containsKey('version_confidence'), isFalse);

      final parsed = ModOrigin.fromJson(written)!;
      expect(parsed.allowsUnattendedUpdate, isFalse);

      // But the user-facing fields survive — those travelling with a shared
      // folder is the whole point of a sidecar.
      expect(raw['description'], 'notes from the author');
      expect(raw['tags'], ['4k', 'swimsuit']);
      expect(raw['images'], ['Preview.png']);
    });

    test('a later user edit does not erase the origin block', () async {
      makeMod('Tracked');
      await repo.recordOrigin('Tracked', origin());

      await repo.save(ModInfo(
        id: 'Tracked',
        name: 'Tracked',
        characterId: 'ellen',
        isActive: false,
        description: 'my notes',
      ));

      final raw = sidecarOf('Tracked')!;
      expect(raw['description'], 'my notes');
      expect((raw['origin'] as Map)['archive_md5'], 'aaaa');
    });

    test('an origin forged on ModInfo in memory can never reach disk', () async {
      // `ModInfo` now carries the origin block, so the library UI can draw status
      // badges from the scan it already did instead of re-reading every sidecar.
      // This is precisely the hazard the old "origin must not go on ModInfo" ban
      // was written for, so it gets a test rather than a promise: the save path
      // rebuilds the sidecar from the copy on **disk** via replaceUserFields,
      // which takes no origin parameter — so there is no route in.
      makeMod('Tracked');
      await repo.recordOrigin('Tracked', origin());

      await repo.save(ModInfo(
        id: 'Tracked',
        name: 'Tracked',
        characterId: 'ellen',
        isActive: false,
        description: 'my notes',
        origin: const ModOrigin(
          provenance: OriginProvenance.downloaded,
          source: 'gamebanana',
          modId: 424242,
          modIdConfidence: OriginConfidence.exact,
          fileId: 1,
          versionConfidence: OriginConfidence.exact,
        ),
      ));

      final written = sidecarOf('Tracked')!['origin'] as Map;
      expect(written['provenance'], 'imported_archive');
      expect(written['archive_md5'], 'aaaa');
      expect(written.containsKey('mod_id'), isFalse);
      expect(written.containsKey('mod_id_confidence'), isFalse);
      expect(ModOrigin.fromJson(written)!.allowsUnattendedUpdate, isFalse);
    });

    test('the stored origin block is readable back in memory', () async {
      // The other half of that trade: the block has to come *out* of a normal
      // scan, because `_buildModInfo` reads it from here and nothing else does.
      makeMod('Tracked');
      await repo.recordOrigin('Tracked', origin());

      final loaded = await repo.loadOrMigrate(
        'Tracked',
        path.join(modsDir.path, 'Tracked'),
      );
      expect(loaded.origin?.archiveMd5, 'aaaa');
      expect(loaded.origin?.provenance, OriginProvenance.importedArchive);
    });

    test('returns false when no library is configured', () async {
      final orphan = ModMetadataRepository(config, modsPath: () => null);
      expect(await orphan.recordOrigin('Any', origin()), isFalse);
    });

    test('never recreates a mod folder that no longer exists', () async {
      // The ghost-folder guard: a mod renamed out from under us must not
      // rematerialize as a directory holding only our sidecar.
      expect(await repo.recordOrigin('Vanished', origin()), isFalse);
      expect(Directory(path.join(modsDir.path, 'Vanished')).existsSync(), isFalse);
    });

    test('returns false for a read-only mod folder', () async {
      final dir = makeMod('Locked');
      Process.runSync('chmod', ['a-w', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['u+w', dir.path]));

      expect(await repo.recordOrigin('Locked', origin()), isFalse);
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);
  });

  group('updateOrigin', () {
    test('amends the block instead of replacing it', () async {
      // The whole difference from recordOrigin: the resolve dialog decides about
      // identity and version, and everything else — the archive hash, the ingest
      // shape, the provenance — has to survive its decision.
      makeMod('Legacy Mod');
      await repo.recordOrigin(
        'Legacy Mod',
        const ModOrigin(
          provenance: OriginProvenance.importedArchive,
          archiveMd5: 'bbbb',
          ingest: ModIngest(folders: ['Legacy Mod']),
        ),
      );

      final ok = await repo.updateOrigin(
        'Legacy Mod',
        (current) => current!.copyWith(
          modId: 555,
          modIdConfidence: OriginConfidence.user,
        ),
      );

      expect(ok, isTrue);
      final block = sidecarOf('Legacy Mod')!['origin'] as Map;
      expect(block['mod_id'], 555);
      expect(block['mod_id_confidence'], 'user');
      expect(block['archive_md5'], 'bbbb');
      expect(block['provenance'], 'imported_archive');
      expect((block['ingest'] as Map)['folders'], ['Legacy Mod']);
    });

    test('hands the update the block on disk, not the one held in memory',
        () async {
      // A dialog stays open across a network fetch and a human, and a scan is
      // kicked off after every toggle and rename — so the sidecar genuinely can
      // be rewritten inside that window.
      makeMod('Raced Mod');
      await repo.recordOrigin(
        'Raced Mod',
        const ModOrigin(provenance: OriginProvenance.importedFolder, modId: 1),
      );

      ModOrigin? seen;
      await repo.updateOrigin('Raced Mod', (current) {
        seen = current;
        return current;
      });

      expect(seen!.modId, 1);
    });

    test('returning null abandons the write', () async {
      // How a decision declines to clobber a block that was rebound underneath
      // it: pickFile returns null when the mod id it was decided against is gone.
      makeMod('Rebound Mod');
      await repo.recordOrigin(
        'Rebound Mod',
        const ModOrigin(provenance: OriginProvenance.importedFolder, modId: 7),
      );

      expect(await repo.updateOrigin('Rebound Mod', (_) => null), isFalse);
      expect((sidecarOf('Rebound Mod')!['origin'] as Map)['mod_id'], 7);
    });

    test('preserves user data and unknown keys around the amendment', () async {
      makeMod('Shared Mod');
      File(path.join(modsDir.path, 'Shared Mod', '.zzz-mod-manager', 'metadata.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'description': 'from the author',
          'tags': ['ellen'],
          'future_key': {'kept': true},
        }));

      await repo.updateOrigin(
        'Shared Mod',
        (current) => OriginResolution.bind(current, 900),
      );

      final raw = sidecarOf('Shared Mod')!;
      expect(raw['description'], 'from the author');
      expect(raw['tags'], ['ellen']);
      expect(raw['future_key'], {'kept': true});
      expect((raw['origin'] as Map)['mod_id'], 900);
    });

    test('writes a block for a mod that had no sidecar at all', () async {
      // "Not from GameBanana / it's my own" is the one decision that must litter:
      // absence means "not looked at yet", which is exactly what it switches off.
      makeMod('My Own Mod');

      final ok = await repo.updateOrigin(
        'My Own Mod',
        (current) => OriginResolution.stopTracking(current),
      );

      expect(ok, isTrue);
      expect((sidecarOf('My Own Mod')!['origin'] as Map)['tracking'], 'off');
    });

    test('never recreates a mod folder that no longer exists', () async {
      expect(
        await repo.updateOrigin('Vanished', (c) => OriginResolution.bind(c, 1)),
        isFalse,
      );
      expect(Directory(path.join(modsDir.path, 'Vanished')).existsSync(), isFalse);
    });

    test('returns false when no library is configured', () async {
      final orphan = ModMetadataRepository(config, modsPath: () => null);
      expect(
        await orphan.updateOrigin('Any', (c) => OriginResolution.bind(c, 1)),
        isFalse,
      );
    });
  });

  group('installDateProxy', () {
    test('reports the oldest file in the folder', () async {
      final dir = makeMod('Dated Mod');
      final old = File(path.join(dir.path, 'mod.ini'))..writeAsStringSync('x');
      final recent = File(path.join(dir.path, 'notes.txt'))..writeAsStringSync('y');
      old.setLastModifiedSync(DateTime.utc(2024, 1, 2));
      recent.setLastModifiedSync(DateTime.utc(2026, 5, 5));

      expect(await repo.installDateProxy('Dated Mod'), DateTime.utc(2024, 1, 2));
    });

    test('is null for a folder that is not there', () async {
      expect(await repo.installDateProxy('Vanished'), isNull);
    });
  });

  group('applyRemoteMetadata', () {
    // Deliberately *not* named 01/02: `addImageBytes` numbers stored files
    // sequentially, so urls that already matched its output would make the
    // assertions below read as though remote filenames are preserved.
    const coverUrl = 'https://images.gamebanana.com/img/ss/mods/cover.jpg';
    const secondUrl = 'https://images.gamebanana.com/img/ss/mods/shot.jpg';

    RemoteModMetadata remote({
      String? description = 'Remote description',
      String? sourceUrl = 'https://gamebanana.com/mods/700727',
      List<String> tags = const ['Ellen: Chained school uniforms'],
      String? characterId = 'ellen',
      List<String> imageUrls = const [coverUrl, secondUrl],
    }) =>
        RemoteModMetadata(
          description: description,
          sourceUrl: sourceUrl,
          tags: tags,
          characterId: characterId,
          imageUrls: imageUrls.map(Uri.parse).toList(),
        );

    test('fills a bare mod\'s sidecar and stores the gallery', () async {
      makeMod('Ellen Swimsuit');

      final fill = await repo.applyRemoteMetadata(['Ellen Swimsuit'], remote());

      final sidecar = sidecarOf('Ellen Swimsuit')!;
      expect(sidecar['description'], 'Remote description');
      expect(sidecar['source_url'], 'https://gamebanana.com/mods/700727');
      expect(sidecar['tags'], ['Ellen: Chained school uniforms']);
      expect(sidecar['character_id'], 'ellen');
      expect(sidecar['images'], [
        '.zzz-mod-manager/images/01.jpg',
        '.zzz-mod-manager/images/02.jpg',
      ]);
      // The extension follows the url, because it is what decides how the file
      // is decoded later.
      expect(
        File(path.join(modsDir.path, 'Ellen Swimsuit', '.zzz-mod-manager',
                'images', '01.jpg'))
            .existsSync(),
        isTrue,
      );

      expect(fill.descriptions, 1);
      expect(fill.tagSets, 1);
      expect(fill.images, 2);
      expect(fill.characterTags, {'Ellen Swimsuit': 'ellen'});
      expect(fill.unwritable, isEmpty);
    });

    test('mirrors the character into config.json, like setCharacter does',
        () async {
      makeMod('Ellen Swimsuit');
      await repo.applyRemoteMetadata(['Ellen Swimsuit'], remote());

      // Otherwise this one path leaves the sidecar and the legacy mirror
      // disagreeing about the same mod.
      expect(config.tags['Ellen Swimsuit'], 'ellen');
    });

    test('fetches each image once, however many mods the archive became',
        () async {
      // The reason the fetch is a separate pass: five sibling folders from one
      // archive all want the same page's gallery.
      makeMod('Ellen A');
      makeMod('Ellen B');
      makeMod('Ellen C');

      final fill =
          await repo.applyRemoteMetadata(['Ellen A', 'Ellen B', 'Ellen C'], remote());

      expect(images.callsFor(coverUrl), 1);
      expect(images.callsFor(secondUrl), 1);
      expect(images.totalCalls, 2);
      // ...and every folder still got its own copy on disk.
      expect(fill.images, 6);
      for (final mod in ['Ellen A', 'Ellen B', 'Ellen C']) {
        expect(sidecarOf(mod)!['images'], hasLength(2));
      }
    });

    test('never displaces what the mod folder already carried', () async {
      // A folder shared on Discord arrives with the author's own sidecar. Its
      // user-facing fields are deliberately kept (only `origin` is dropped), so
      // "already set" means "somebody wrote this" and it wins.
      final dir = makeMod('Shared Mod');
      Directory(path.join(dir.path, '.zzz-mod-manager')).createSync();
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
          .writeAsStringSync(jsonEncode({
        'schema_version': 2,
        'description': 'The author wrote this',
        'source_url': 'https://example.com/author-page',
        'tags': ['4k'],
        'character_id': 'jane',
        'images': ['Preview.png'],
      }));

      final fill = await repo.applyRemoteMetadata(['Shared Mod'], remote());

      final sidecar = sidecarOf('Shared Mod')!;
      expect(sidecar['description'], 'The author wrote this');
      expect(sidecar['source_url'], 'https://example.com/author-page',
          reason: 'a url somebody chose may be a mirror or a collection, and '
              'the canonical link is no substitute for it');
      expect(sidecar['tags'], ['4k']);
      expect(sidecar['character_id'], 'jane');
      expect(sidecar['images'], ['Preview.png']);
      expect(fill.isEmpty, isTrue);
      expect(images.totalCalls, 0,
          reason: 'nothing to store means nothing to download');
    });

    test('fills only the source url when that is all that is missing', () async {
      // The narrow case the `remote.isEmpty` early-out used to swallow: nothing
      // to fetch, nothing to describe, and still a write worth making — without
      // it the mod has no "open mod page" link anywhere in the library.
      final dir = makeMod('Linkless Mod');
      Directory(path.join(dir.path, '.zzz-mod-manager')).createSync();
      File(path.join(dir.path, '.zzz-mod-manager', 'metadata.json'))
          .writeAsStringSync(jsonEncode({
        'schema_version': 2,
        'description': 'The author wrote this',
        'tags': ['4k'],
        'character_id': 'jane',
        'images': ['Preview.png'],
      }));

      await repo.applyRemoteMetadata(['Linkless Mod'], remote());

      expect(sidecarOf('Linkless Mod')!['source_url'],
          'https://gamebanana.com/mods/700727');
      expect(images.totalCalls, 0);
    });

    test('keeps a shipped Preview.png as the cover', () async {
      final dir = makeMod('Shipped Preview');
      File(path.join(dir.path, 'Preview.png')).writeAsBytesSync([1, 2, 3]);

      await repo.applyRemoteMetadata(['Shipped Preview'], remote());

      expect(sidecarOf('Shipped Preview')!['images'], [
        'Preview.png',
        '.zzz-mod-manager/images/01.jpg',
        '.zzz-mod-manager/images/02.jpg',
      ]);
    });

    test('preserves the origin block written moments earlier at ingest',
        () async {
      // The whole install sequence is: import -> recordOrigin -> autofill. If
      // this rebuilt the sidecar from anything but the copy on disk, the block
      // that makes the mod updatable would be gone before the user saw it.
      makeMod('Ellen Swimsuit');
      await repo.recordOrigin(
        'Ellen Swimsuit',
        const ModOrigin(
          source: 'gamebanana',
          modId: 531275,
          modIdConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
        ),
      );

      await repo.applyRemoteMetadata(['Ellen Swimsuit'], remote());

      final origin = sidecarOf('Ellen Swimsuit')!['origin'] as Map;
      expect(origin['mod_id'], 531275);
      expect(origin['mod_id_confidence'], 'exact');
    });

    test('the stored extension follows the url, and falls back to png', () async {
      // The extension decides how the file is decoded later, so it is read off
      // the url rather than assumed — but a url can carry a query string, no
      // extension at all, or a suffix that is plainly not one.
      makeMod('Odd Urls');

      await repo.applyRemoteMetadata(
        ['Odd Urls'],
        remote(
          description: null,
          tags: const [],
          characterId: null,
          imageUrls: const [
            'https://images.gamebanana.com/x/a.JPG?v=2',
            'https://images.gamebanana.com/x/b',
            'https://images.gamebanana.com/x/c.notanextension',
          ],
        ),
      );

      // The first must not read `png`, or the assertion would pass on the
      // fallback alone and prove nothing about the query or the case.
      expect(sidecarOf('Odd Urls')!['images'], [
        '.zzz-mod-manager/images/01.jpg', // query stripped, lower-cased
        '.zzz-mod-manager/images/02.png', // no extension at all
        '.zzz-mod-manager/images/03.png', // too long to be one
      ]);
    });

    test('an unreachable image is skipped, not fatal', () async {
      images = _FakeImageFetcher(failing: {coverUrl});
      repo = ModMetadataRepository(
        config,
        modsPath: () => modsDir.path,
        legacyImagesPath: () => legacyImages.path,
        imageFetcher: images,
      );
      makeMod('Ellen Swimsuit');

      final fill = await repo.applyRemoteMetadata(['Ellen Swimsuit'], remote());

      expect(fill.images, 1);
      expect(sidecarOf('Ellen Swimsuit')!['images'],
          ['.zzz-mod-manager/images/01.jpg']);
      // The free fields still landed — they never needed the network.
      expect(fill.descriptions, 1);
    });

    test('writes nothing at all when every image fails and only images were missing',
        () async {
      images = _FakeImageFetcher(failing: {coverUrl});
      repo = ModMetadataRepository(
        config,
        modsPath: () => modsDir.path,
        legacyImagesPath: () => legacyImages.path,
        imageFetcher: images,
      );
      final dir = makeMod('Shipped Preview');
      File(path.join(dir.path, 'Preview.png')).writeAsBytesSync([1, 2, 3]);

      final fill = await repo.applyRemoteMetadata(
        ['Shipped Preview'],
        // `sourceUrl: null` too, so this isolates the images-only case. A page
        // that offered a link would rightly be written even here — that is a
        // fact worth recording, unlike a lone `Preview.png` entry.
        remote(description: null, sourceUrl: null, tags: const [],
            characterId: null, imageUrls: const [coverUrl]),
      );

      // A lone `Preview.png` entry would be a pointless write, and it would
      // freeze the gallery at one image — the scan already resolves it.
      expect(fill.images, 0);
      expect(sidecarOf('Shipped Preview'), isNull);
    });

    test('does nothing, and fetches nothing, for an empty remote', () async {
      makeMod('Ellen Swimsuit');

      final fill = await repo.applyRemoteMetadata(
        ['Ellen Swimsuit'],
        const RemoteModMetadata(),
      );

      expect(fill.isEmpty, isTrue);
      expect(images.totalCalls, 0);
      expect(sidecarOf('Ellen Swimsuit'), isNull,
          reason: 'the don\'t-litter rule still holds');
    });

    test('skips a mod folder that does not exist, before downloading anything',
        () async {
      final fill = await repo.applyRemoteMetadata(['Vanished'], remote());

      expect(fill.isEmpty, isTrue);
      expect(Directory(path.join(modsDir.path, 'Vanished')).existsSync(), isFalse,
          reason: 'the ghost-folder guard');
      expect(images.totalCalls, 0,
          reason: 'a whole gallery downloaded for a folder that is gone');
    });
  });
}
