import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/gamebanana_url.dart';

/// `source_url` -> `mod_id` parsing. Pure, offline, and the highest-yield step
/// of the metadata backfill — which also makes it the place where a quiet bug
/// does the most damage: a wrong id binds a local folder to an unrelated remote
/// mod, and a later "update" then overwrites it with a different mod's files.
void main() {
  group('accepts mod page urls', () {
    test('the canonical form', () {
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/531649'), 531649);
    });

    test('trailing slash, query and fragment', () {
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/531649/'), 531649);
      expect(
          gameBananaModIdFromUrl('https://gamebanana.com/mods/531649?tab=files'),
          531649);
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/531649#comments'),
          531649);
      expect(
          gameBananaModIdFromUrl(
              'https://gamebanana.com/mods/531649/?utm_source=x#posts'),
          531649);
    });

    test('http, www and a mixed-case host', () {
      expect(gameBananaModIdFromUrl('http://gamebanana.com/mods/531649'), 531649);
      expect(
          gameBananaModIdFromUrl('https://www.gamebanana.com/mods/531649'), 531649);
      expect(
          gameBananaModIdFromUrl('https://GameBanana.com/mods/531649'), 531649);
    });

    test('a missing scheme, as a user would paste it', () {
      expect(gameBananaModIdFromUrl('gamebanana.com/mods/531649'), 531649);
      expect(gameBananaModIdFromUrl('www.gamebanana.com/mods/531649'), 531649);
    });

    test('surrounding whitespace', () {
      expect(gameBananaModIdFromUrl('  https://gamebanana.com/mods/531649  '),
          531649);
    });

    test('the download-page form', () {
      expect(
          gameBananaModIdFromUrl('https://gamebanana.com/mods/download/531649'),
          531649);
    });
  });

  group('rejects things that are not a mod page', () {
    test('a /dl/ link is a FILE id, not a mod id', () {
      // The most important negative in this file. The two are separate id
      // spaces; treating a file id as a mod id would resolve to whatever
      // unrelated mod happens to hold that number.
      expect(gameBananaModIdFromUrl('https://gamebanana.com/dl/1770600'), isNull);
      expect(gameBananaModIdFromUrl('gamebanana.com/dl/1491924'), isNull);
    });

    test('a category url', () {
      expect(
          gameBananaModIdFromUrl('https://gamebanana.com/mods/cats/30305'), isNull);
    });

    test('game, member and section pages', () {
      expect(gameBananaModIdFromUrl('https://gamebanana.com/games/19567'), isNull);
      expect(
          gameBananaModIdFromUrl('https://gamebanana.com/members/2987570'), isNull);
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods'), isNull);
    });

    test('another host, even with a convincing path', () {
      expect(gameBananaModIdFromUrl('https://example.com/mods/531649'), isNull);
      expect(
          gameBananaModIdFromUrl('https://notgamebanana.com/mods/531649'), isNull);
      expect(gameBananaModIdFromUrl('https://drive.google.com/file/d/abc'), isNull);
    });

    test('a non-numeric or non-positive id', () {
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/abc'), isNull);
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/0'), isNull);
      expect(gameBananaModIdFromUrl('https://gamebanana.com/mods/-5'), isNull);
    });

    test('empty, null and junk', () {
      expect(gameBananaModIdFromUrl(null), isNull);
      expect(gameBananaModIdFromUrl(''), isNull);
      expect(gameBananaModIdFromUrl('   '), isNull);
      expect(gameBananaModIdFromUrl('not a url at all'), isNull);
      expect(gameBananaModIdFromUrl('ellen swimsuit mod'), isNull);
    });
  });

  group('gameBananaFileIdFromUrl', () {
    test('reads a download link', () {
      expect(gameBananaFileIdFromUrl('https://gamebanana.com/dl/1701141'),
          1701141);
      expect(gameBananaFileIdFromUrl('gamebanana.com/mmdl/1701141'), 1701141);
      expect(
        gameBananaFileIdFromUrl('http://www.gamebanana.com/dl/1701141?x=1'),
        1701141,
      );
    });

    test('a mod page is not a file link, and vice versa', () {
      // The two id spaces must never be read as each other: a file id used as a
      // mod id binds a folder to an unrelated mod.
      expect(gameBananaFileIdFromUrl('https://gamebanana.com/mods/531649'),
          isNull);
      expect(gameBananaModIdFromUrl('https://gamebanana.com/dl/1701141'),
          isNull);
    });

    test('rejects other hosts and junk', () {
      expect(gameBananaFileIdFromUrl('https://example.com/dl/1'), isNull);
      expect(gameBananaFileIdFromUrl('https://gamebanana.com/dl/'), isNull);
      expect(gameBananaFileIdFromUrl('https://gamebanana.com/dl/abc'), isNull);
      expect(gameBananaFileIdFromUrl('https://gamebanana.com/dl/1/2'), isNull);
      expect(gameBananaFileIdFromUrl(null), isNull);
      expect(gameBananaFileIdFromUrl(''), isNull);
    });
  });

  group('isGameBananaUrl', () {
    test('is about the host only, not about identifying a mod', () {
      expect(isGameBananaUrl('https://gamebanana.com/dl/1770600'), isTrue);
      expect(isGameBananaUrl('https://gamebanana.com/games/19567'), isTrue);
      expect(isGameBananaUrl('gamebanana.com/mods/531649'), isTrue);
      expect(isGameBananaUrl('https://example.com/mods/1'), isFalse);
      expect(isGameBananaUrl(null), isFalse);
      expect(isGameBananaUrl(''), isFalse);
    });
  });

  group('gameBananaModUrl', () {
    test('builds the canonical mod-page url', () {
      expect(gameBananaModUrl(531649), 'https://gamebanana.com/mods/531649');
    });

    test('round-trips with the parser', () {
      expect(gameBananaModIdFromUrl(gameBananaModUrl(531649)), 531649);
    });
  });
}
