import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dual-storage pattern, tested end to end against a temp directory.
///
/// `ConfigService` writes every setting **twice** — through SharedPreferences and
/// into `config.json` — and adding one means touching three places: the
/// getter/setter, the `_saveToFile()` map, and the `loadFromFile()` parse. Miss the
/// map and the setting works for the whole session and then silently vanishes on
/// restart. That is the failure these tests exist for, and it is invisible to
/// `flutter analyze`.
///
/// "Next session" is simulated the only way that proves anything: build a *fresh*
/// service over the same file with empty preferences, and load.
void main() {
  late Directory temp;
  File configFile() => File('${temp.path}/config.json');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zzz_config_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<ConfigService> build() async {
    // A fresh SharedPreferences instance each time, so nothing carries over in
    // memory and the file is genuinely the only channel.
    final prefs = await SharedPreferences.getInstance();
    return ConfigService(prefs, configFile: configFile());
  }

  Future<Map<String, dynamic>> readFile() async =>
      jsonDecode(await configFile().readAsString()) as Map<String, dynamic>;

  group('marketplace sort', () {
    test('is empty until chosen, so the caller applies its own default',
        () async {
      expect((await build()).marketplaceSort, '');
    });

    test('reaches config.json, not just SharedPreferences', () async {
      await (await build()).setMarketplaceSort('mostLiked');
      expect((await readFile())['marketplace_sort'], 'mostLiked');
    });

    test('survives into a fresh session', () async {
      await (await build()).setMarketplaceSort('mostViewed');

      // The restart: new prefs (empty), new service, same file.
      SharedPreferences.setMockInitialValues({});
      final next = await build();
      expect(next.marketplaceSort, '',
          reason: 'nothing in prefs yet — the file has not been loaded');

      await next.loadFromFile();
      expect(next.marketplaceSort, 'mostViewed');
    });
  });

  group('content filter', () {
    test('defaults to blur with nothing stored', () async {
      expect((await build()).contentFilter, 'blur');
    });

    test('survives into a fresh session', () async {
      await (await build()).setContentFilter('show');

      SharedPreferences.setMockInitialValues({});
      final next = await build();
      await next.loadFromFile();
      expect(next.contentFilter, 'show');
    });

    test('a fresh session with no file keeps the safe default', () async {
      // Failing *open* here would un-blur adult content on a missing config.
      final next = await build();
      expect(await next.loadFromFile(), isFalse, reason: 'no file to load');
      expect(next.contentFilter, 'blur');
    });
  });

  test('both marketplace preferences persist together', () async {
    final service = await build();
    await service.setMarketplaceSort('latestModified');
    await service.setContentFilter('hide');

    SharedPreferences.setMockInitialValues({});
    final next = await build();
    await next.loadFromFile();

    expect(next.marketplaceSort, 'latestModified');
    expect(next.contentFilter, 'hide');
  });

  test('writing one setting does not drop the others', () async {
    // `_saveToFile` rewrites the whole document every time, so a partial map would
    // silently erase unrelated settings.
    final service = await build();
    await service.setPaths('/mods', '/game/Mods');
    await service.setTheme('dark-blue');
    await service.setContentFilter('show');
    await service.setMarketplaceSort('oldest');

    final json = await readFile();
    expect(json['mods_path'], '/mods');
    expect(json['save_mods_path'], '/game/Mods');
    expect(json['theme'], 'dark-blue');
    expect(json['content_filter'], 'show');
    expect(json['marketplace_sort'], 'oldest');
  });

  test('every key written to the file is read back by loadFromFile', () async {
    // The three-place rule, enforced rather than remembered: anything `_saveToFile`
    // emits must have a matching branch in `loadFromFile`, or it works all session
    // and vanishes on restart.
    final service = await build();
    await service.setPaths('/mods', '/game/Mods');
    await service.setTheme('light');
    await service.setLanguage('uk');
    await service.setSortMode('nameAsc');
    await service.setContentFilter('hide');
    await service.setMarketplaceSort('mostDownloaded');
    await service.addActiveMod('SomeMod');
    await service.addFavoriteMod('SomeMod');
    await service.setModCharacterTag('SomeMod', 'ellen');

    final written = (await readFile()).keys.toSet();

    SharedPreferences.setMockInitialValues({});
    final next = await build();
    await next.loadFromFile();
    final restored = <String, Object?>{
      'mods_path': next.modsPath,
      'save_mods_path': next.saveModsPath,
      'theme': next.theme,
      'language': next.language,
      'sort_mode': next.sortMode,
      'content_filter': next.contentFilter,
      'marketplace_sort': next.marketplaceSort,
      'active_mods': next.activeMods,
      'favorite_mods': next.favoriteMods,
      'mod_character_tags': next.modCharacterTags,
      // `first_run` is always serialised as false and has no round-trip value.
      'first_run': false,
    };

    expect(written.difference(restored.keys.toSet()), isEmpty,
        reason: 'a key is written to config.json but never read back');
    for (final entry in restored.entries) {
      if (entry.key == 'first_run') continue;
      expect(entry.value, isNot(anyOf(isNull, '', isEmpty)),
          reason: '${entry.key} did not survive the restart');
    }
  });
}
