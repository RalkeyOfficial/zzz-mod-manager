import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/utils/gamebanana_url.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

import '../support/fixtures.dart';

/// What a mod page is worth to a freshly-installed mod's sidecar.
///
/// Driven by real captured profiles rather than hand-written maps, because every
/// judgement in this unit is a judgement about what GameBanana actually sends —
/// and two of those fields do not send what a reader would assume: tags are
/// `{_sTitle, _sValue}` objects on a profile, and only the *cover* publishes a
/// small variant.
void main() {
  GbMod profile(String name) => GbMod.fromJson(parseObject(loadGbFixture(name)))!;

  group('description', () {
    test('is converted out of HTML into the markdown we store', () {
      final remote = RemoteModMetadata.fromMod(profile('mod_profile_tagged'));

      expect(remote.description, isNotNull);
      // The source really is HTML — pinning that keeps this test honest if the
      // fixture is ever re-captured against a changed API.
      expect(profile('mod_profile_tagged').text, contains('<'));
      expect(remote.description, isNot(contains('<br>')));
      expect(remote.description, isNot(contains('<h1')));
    });

    test('is null rather than empty when the page has no text', () {
      final remote = RemoteModMetadata.fromMod(const GbMod(idRow: 1));
      expect(remote.description, isNull);
      expect(remote.tags, isEmpty);
      expect(remote.characterId, isNull);
      expect(remote.imageUrls, isEmpty);
      // Not `isEmpty`, and deliberately so: a page with nothing else on it
      // still has an id, and a link back to it is worth writing on its own.
      expect(remote.isEmpty, isFalse);
    });
  });

  group('tags', () {
    test('keeps an author tag, flattened to "title: value"', () {
      // The live profile shape, probed directly. Authors fill both halves
      // freely: "Ellen" / "Chained school uniforms".
      final mod = GbMod.fromJson({
        '_idRow': 531275,
        '_aTags': [
          {'_sTitle': 'Ellen', '_sValue': 'Chained school uniforms'},
        ],
      })!;

      expect(RemoteModMetadata.fromMod(mod).tags,
          ['Ellen: Chained school uniforms']);
    });

    test('drops the "Software Used" credit family', () {
      // Every tag this real profile carries is that family, so the whole list
      // goes — which is the point: they name the author's toolchain, and the
      // tag list drives the library's filter chips.
      final mod = profile('mod_profile_tagged');
      expect(mod.tags, hasLength(3));
      expect(mod.tags.first, startsWith('Software Used'));

      expect(RemoteModMetadata.fromMod(mod).tags, isEmpty);
    });

    test('drops a credit tag that arrived with no value', () {
      // `gbTags` emits a bare title when `_sValue` is missing, so this reaches the
      // filter with no colon to split on — and a rule keyed on the colon lets it
      // straight through into the toolbar's filter chips.
      final mod = GbMod.fromJson({
        '_idRow': 1,
        '_aTags': [
          {'_sTitle': 'Software Used'},
        ],
      })!;
      expect(mod.tags, ['Software Used']);

      expect(RemoteModMetadata.fromMod(mod).tags, isEmpty);
    });

    test('a colon inside a kept tag is not mistaken for the credit prefix', () {
      final mod = GbMod.fromJson({
        '_idRow': 1,
        '_aTags': ['ratio 16:9', 'software used: Blender'],
      })!;

      // Case-insensitive on the *title* only, so "ratio 16:9" survives.
      expect(RemoteModMetadata.fromMod(mod).tags, ['ratio 16:9']);
    });
  });

  group('source url', () {
    test('is built from the mod id, in the form the backfill parses back', () {
      final remote = RemoteModMetadata.fromMod(const GbMod(idRow: 700727));
      expect(remote.sourceUrl, 'https://gamebanana.com/mods/700727');
      // The round trip is the point: the offline backfill reads `source_url`
      // for a mod id, and it must arrive at the one the origin block already
      // records rather than at a second opinion.
      expect(gameBananaModIdFromUrl(remote.sourceUrl), 700727);
    });

    test('is the canonical url even when the page publishes its own', () {
      final mod = GbMod.fromJson({
        '_idRow': 531275,
        '_sProfileUrl': 'https://gamebanana.com/mods/531275?utm=whatever',
      })!;
      expect(RemoteModMetadata.fromMod(mod).sourceUrl,
          'https://gamebanana.com/mods/531275');
    });
  });

  group('character', () {
    test('comes from the category, which is where the author filed it', () {
      expect(RemoteModMetadata.fromMod(profile('mod_profile_rated')).characterId,
          'ellen');
      expect(RemoteModMetadata.fromMod(profile('mod_profile_tagged')).characterId,
          'jane');
    });

    test('is null for a mod filed under a non-character category', () {
      // "Other/Misc" — a real profile, and the case that must not guess.
      expect(RemoteModMetadata.fromMod(profile('mod_profile_531649')).characterId,
          isNull);
    });

    test('every live character category maps to a roster id', () {
      // The canary for this whole approach. If GameBanana adds a character whose
      // category name our roster doesn't know, this fails and says which — far
      // better than silently tagging nothing.
      final categories = parseBareList(
          loadGbFixture('categories_30305'), GbCategoryNode.fromJson);
      expect(categories, hasLength(60));

      final unmapped = <String>[];
      for (final category in categories) {
        final id = detectCharacterId(category.name ?? '');
        if (id == null || characterById(id) == null) {
          unmapped.add(category.name ?? '<unnamed>');
        }
      }
      expect(unmapped, isEmpty);
    });

    test('no root category is mistaken for a character', () {
      // The other half of the canary: a false positive here would tag every UI
      // or Bangboo mod as somebody's skin.
      final roots =
          parseBareList(loadGbFixture('categories_root'), GbCategoryNode.fromJson);
      for (final root in roots) {
        expect(detectCharacterId(root.name ?? ''), isNull,
            reason: 'root category "${root.name}" matched a character');
      }
    });
  });

  group('images', () {
    test('takes the gallery in order, capped, at full size', () {
      final mod = profile('mod_profile_rated');
      expect(mod.images.length, greaterThan(RemoteModMetadata.maxImages));

      final urls = RemoteModMetadata.fromMod(mod).imageUrls;
      expect(urls, hasLength(RemoteModMetadata.maxImages));
      expect(urls.first.toString(), mod.images.first.fullUrl);
      // Full size, not a ladder rung: measured, 112 of 132 captured gallery
      // images publish nothing between `_sFile100` and the original, so asking
      // for a mid-size variant would shrink only the cover.
      expect(urls.first.toString(), isNot(contains('530-')));
    });

    test('every url is absolute http(s)', () {
      for (final url in RemoteModMetadata.fromMod(profile('mod_profile_tagged'))
          .imageUrls) {
        expect(url.isAbsolute, isTrue);
        expect(url.scheme, anyOf('http', 'https'));
      }
    });

    test('an image with no base url is dropped rather than fetched', () {
      // `_sBaseUrl` missing leaves a bare filename, which parses fine as a
      // relative Uri and would be requested as garbage.
      final mod = GbMod.fromJson({
        '_idRow': 1,
        '_aPreviewContent': {
          'screenshots': [
            {'_sFile': 'orphan.jpg'},
            {'_sBaseUrl': 'https://images.gamebanana.com/x', '_sFile': 'ok.jpg'},
          ],
        },
      })!;

      expect(RemoteModMetadata.fromMod(mod).imageUrls.map((u) => '$u'),
          ['https://images.gamebanana.com/x/ok.jpg']);
    });
  });
}
