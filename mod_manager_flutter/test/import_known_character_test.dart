import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// Who decides a freshly-imported mod's character.
///
/// Detection from a folder name is a *guess*, and the marketplace does not have
/// to make it: a mod page files the mod under a character category, which is the
/// author's own statement. The two genuinely disagree — "Zhao Nicole" is a Zhao
/// skin whose name reads as Nicole, because the longest matching term wins — and
/// the autofill that runs after the import cannot fix it, since it fills absence
/// only and detection has already filled the slot.
///
/// Run against real directories rather than a fake filesystem: the thing under
/// test is an import that copies folders and writes a sidecar, and the parts
/// worth trusting are exactly the parts a fake would stub out. `ConfigService`
/// goes through its `configFile:` seam so the developer's real
/// `<appData>/config.json` is never touched.
void main() {
  late Directory temp;
  late Directory modsDir;
  late Directory sourceDir;
  late ModManagerService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_import_char_test_');
    modsDir = await Directory(path.join(temp.path, 'mods')).create();
    sourceDir = await Directory(path.join(temp.path, 'src')).create();
    final saveModsDir =
        await Directory(path.join(temp.path, 'saveMods')).create();

    SharedPreferences.setMockInitialValues({});
    final config = ConfigService(
      await SharedPreferences.getInstance(),
      configFile: File(path.join(temp.path, 'config.json')),
    );
    await config.setPaths(modsDir.path, saveModsDir.path);

    service = ModManagerService(config);
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// A mod-shaped source folder, ready to import.
  Future<String> sourceFolder(String name) async {
    final folder = await Directory(path.join(sourceDir.path, name)).create();
    await File(path.join(folder.path, 'mod.ini')).writeAsString('[Constants]\n');
    return folder.path;
  }

  /// The character in the mod's own sidecar — the copy that travels with the
  /// folder, and therefore the one that has to be right.
  Future<String?> sidecarCharacter(String modName) async {
    final file = File(path.join(
      modsDir.path,
      modName,
      '.zzz-mod-manager',
      'metadata.json',
    ));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return json['character_id'] as String?;
  }

  /// The mod's own identity, which is what its saved versions get filed under.
  Future<String?> sidecarUid(String modName) async {
    final file = File(path.join(
      modsDir.path,
      modName,
      '.zzz-mod-manager',
      'metadata.json',
    ));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return json['uid'] as String?;
  }

  group('an installed mod gets an identity', () {
    test('at install, without waiting for a scan or a snapshot', () async {
      // A mod installed and updated in one session must be identifiable before
      // anything rescans, or its first snapshot has nowhere to go.
      final folder = await sourceFolder('Ellen Swimsuit');

      await service.importMods([folder]);

      expect(await sidecarUid('Ellen Swimsuit'), isNotNull);
    });

    test('a fresh one, never the one the folder came with', () async {
      // The ingest copies `.zzz-mod-manager/` wholesale on purpose, so a shared
      // folder arrives with its author's sidecar — uid included. Inheriting it
      // would hand two mods one snapshot group.
      final folder = await sourceFolder('Shared Ellen');
      final sidecar =
          Directory(path.join(folder, '.zzz-mod-manager'))..createSync();
      File(path.join(sidecar.path, 'metadata.json')).writeAsStringSync(
        '{"schema_version": 2, "uid": "somebody-elses", '
        '"description": "from whoever shared this"}',
      );

      await service.importMods([folder]);

      expect(await sidecarUid('Shared Ellen'), isNot('somebody-elses'));
      expect(await sidecarUid('Shared Ellen'), isNotNull);
    });

    test('and two mods out of one shared folder do not share it', () async {
      final first = await sourceFolder('Ellen A');
      final second = await sourceFolder('Ellen B');

      await service.importMods([first, second]);

      expect(await sidecarUid('Ellen A'), isNot(await sidecarUid('Ellen B')));
    });
  });

  group('importMods', () {
    test('a told character beats what the name reads as', () async {
      final folder = await sourceFolder('Zhao Nicole');

      final (imported, autoTags) = await service.importMods(
        [folder],
        detectionHints: {folder: 'Zhao Nicole v2.zip'},
        knownCharacters: {folder: 'zhao'},
      );

      expect(imported, ['Zhao Nicole']);
      expect(autoTags, {'Zhao Nicole': 'zhao'});
      expect(await sidecarCharacter('Zhao Nicole'), 'zhao',
          reason: 'the sidecar is what survives a rename and a re-scan');
    });

    test('without one, the name is still read — and reads it wrong', () async {
      // The bug this change exists for, pinned so the difference between the
      // two paths is visible rather than asserted about in a comment.
      final folder = await sourceFolder('Zhao Nicole');

      final (_, autoTags) = await service.importMods([folder]);

      expect(autoTags, {'Zhao Nicole': 'nicole'});
    });

    test('an unassigned value falls back to detection', () async {
      // A mod filed under "Other/Misc" upstream yields no character at all, and
      // must not lose the one its name would have given it.
      final folder = await sourceFolder('Ellen Swimsuit');

      final (_, autoTags) = await service.importMods(
        [folder],
        knownCharacters: {folder: ''},
      );

      expect(autoTags, {'Ellen Swimsuit': 'ellen'});
    });

    test('is per folder, like the hints and the seeds beside it', () async {
      // One call can mix folders from different sources, so a character told
      // about one of them must not reach the others.
      final told = await sourceFolder('Zhao Nicole');
      final guessed = await sourceFolder('Ellen Swimsuit');

      final (_, autoTags) = await service.importMods(
        [told, guessed],
        knownCharacters: {told: 'zhao'},
      );

      expect(autoTags, {'Zhao Nicole': 'zhao', 'Ellen Swimsuit': 'ellen'});
    });
  });

  group('importCombinedMod', () {
    test('a told character beats what the name reads as', () async {
      final folder = await sourceFolder('Zhao Nicole');

      final (imported, autoTags) = await service.importCombinedMod(
        [folder],
        'Zhao Nicole',
        detectionHint: 'Zhao Nicole v2.zip',
        knownCharacter: 'zhao',
      );

      expect(imported, ['Zhao Nicole']);
      expect(autoTags, {'Zhao Nicole': 'zhao'});
      expect(await sidecarCharacter('Zhao Nicole'), 'zhao');
    });

    test('an unassigned value falls back to detection', () async {
      final folder = await sourceFolder('Ellen Swimsuit');

      final (_, autoTags) = await service.importCombinedMod(
        [folder],
        'Ellen Swimsuit',
        knownCharacter: null,
      );

      expect(autoTags, {'Ellen Swimsuit': 'ellen'});
    });
  });
}
