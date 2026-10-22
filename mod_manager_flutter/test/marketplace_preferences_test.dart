import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

/// The two marketplace preferences that survive a restart: the browse sort and the
/// adult-content filter.
///
/// The persistence itself is `ConfigService`'s dual-storage pattern, which needs
/// SharedPreferences and a real app-data directory — so what is covered here is the
/// part that actually rots: the parsing on the way back in, and the query picking up
/// the restored sort instead of a hardcoded one.
void main() {
  group('reading a stored sort back', () {
    test('every sort round-trips through its name', () {
      for (final sort in GbModSort.values) {
        expect(GbModSort.byName(sort.name), sort);
      }
    });

    test('matches the Dart name, not the GameBanana wire value', () {
      // The stored value is ours, in our own config. Pinning it to the protocol
      // string would mean an upstream rename invalidated everyone's saved setting.
      expect(GbModSort.byName('latestModified'), GbModSort.latestModified);
      expect(GbModSort.byName('Generic_LatestModified'), isNull);
    });

    test('anything unrecognised is null so the caller can default', () {
      for (final value in <Object?>[null, '', 'ripe', 'NEWEST', 42, true, []]) {
        expect(GbModSort.byName(value), isNull, reason: 'byName($value)');
      }
    });
  });

  group('the content filter is unchanged by this', () {
    test('still degrades to blur, never to show', () {
      // Guarding the asymmetry between the two preferences: an unknown sort can
      // safely fall back to a default, but an unknown *filter* must not fall back to
      // something more permissive than the user chose.
      expect(ContentFilterMode.parse('nonsense'), ContentFilterMode.blur);
      expect(ContentFilterMode.parse(null), ContentFilterMode.blur);
    });

    test('every mode round-trips through its wire value', () {
      for (final mode in ContentFilterMode.values) {
        expect(ContentFilterMode.parse(mode.wire), mode);
      }
    });
  });

  group('the query starts on the restored preference', () {
    test('not on a hardcoded sort', () {
      // This is the wiring that makes the setting take effect. Hydration writes
      // `marketplaceSortProvider`; the query has to read it rather than default.
      final container = ProviderContainer(
        overrides: [
          marketplaceSortProvider.overrideWith((ref) => GbModSort.mostLiked),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(marketplaceQueryProvider).sort,
          GbModSort.mostLiked);
    });

    test('falls back to the documented default with nothing stored', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(marketplaceQueryProvider).sort,
          kDefaultMarketplaceSort);
      expect(kDefaultMarketplaceSort, GbModSort.newest,
          reason: 'a fresh install starts on newest submissions');
    });

    test('a later preference change does not rebuild the whole query', () {
      // The query reads the preference rather than watching it: re-creating the
      // query when the preference changed would throw away the chips and the
      // search. The sort menu updates both explicitly instead.
      final container = ProviderContainer(
        overrides: [
          marketplaceSortProvider.overrideWith((ref) => GbModSort.newest),
        ],
      );
      addTearDown(container.dispose);

      container.read(marketplaceQueryProvider.notifier).state = container
          .read(marketplaceQueryProvider)
          .withText('ellen')
          .withType(30395);

      container.read(marketplaceSortProvider.notifier).state =
          GbModSort.mostViewed;

      final query = container.read(marketplaceQueryProvider);
      expect(query.text, 'ellen', reason: 'the search survives a preference change');
      expect(query.categoryId, 30395);
    });
  });

  group('a stored sort the menu does not offer', () {
    test('Recent discussion reads as the default', () {
      expect(kMarketplaceSorts, isNot(contains(GbModSort.latestComment)));
      expect(parseMarketplaceSort('latestComment'), kDefaultMarketplaceSort);
    });

    test('every sort the menu offers reads back as itself', () {
      for (final sort in kMarketplaceSorts) {
        expect(parseMarketplaceSort(sort.name), sort);
      }
      expect(parseMarketplaceSort(''), kDefaultMarketplaceSort);
      expect(parseMarketplaceSort('ripe'), kDefaultMarketplaceSort);
    });

    test('the menu offers the six in the design order', () {
      expect(kMarketplaceSorts, [
        GbModSort.newest,
        GbModSort.oldest,
        GbModSort.mostLiked,
        GbModSort.mostDownloaded,
        GbModSort.mostViewed,
        GbModSort.latestModified,
      ]);
    });
  });

  group('the chips', () {
    const ellen = MarketplaceCharacter(30341, 'Ellen Joe');
    const query = MarketplaceQuery();

    test('picking a character turns Character on, and the request names the character', () {
      final next = query.withType(30395).withCharacter(ellen);
      expect(next.typeId, kCharacterSkinsCategoryId);
      expect(next.character, ellen);
      expect(next.categoryId, 30341);
    });

    test('picking another type clears the character', () {
      final next = query.withCharacter(ellen).withType(30395);
      expect(next.character, isNull);
      expect(next.categoryId, 30395);
    });

    test('turning the type off clears both', () {
      final next = query.withCharacter(ellen).withType(null);
      expect(next.typeId, isNull);
      expect(next.character, isNull);
      expect(next.categoryId, isNull);
    });

    test('clearing the character keeps Character on', () {
      final next = query.withCharacter(ellen).withCharacter(null);
      expect(next.typeId, kCharacterSkinsCategoryId);
      expect(next.categoryId, kCharacterSkinsCategoryId);
    });

    test('the text and sort survive a chip', () {
      final next = const MarketplaceQuery(text: 'maid', sort: GbModSort.mostLiked).withCharacter(ellen);
      expect(next.text, 'maid');
      expect(next.sort, GbModSort.mostLiked);
    });

    group('a mod page category link', () {
      test('a Character Skins child picks the character', () {
        final next = query.showingCategory(id: 30341, name: 'Ellen Joe', parentId: kCharacterSkinsCategoryId);
        expect(next.character, ellen);
        expect(next.typeId, kCharacterSkinsCategoryId);
      });

      test('a root turns its type on', () {
        final next = query.withCharacter(ellen).showingCategory(id: 29874, name: 'Other/Misc');
        expect(next.typeId, 29874);
        expect(next.character, isNull);
      });

      test('Character Skins from a picked character clears the character, and keeps the text and sort', () {
        final start = const MarketplaceQuery(text: 'maid', sort: GbModSort.mostLiked).withCharacter(ellen);
        for (final parentId in [null, kCharacterSkinsCategoryId]) {
          final next = start.showingCategory(
            id: kCharacterSkinsCategoryId,
            name: 'Character Skins',
            parentId: parentId,
          );
          expect(next.typeId, kCharacterSkinsCategoryId, reason: 'parent $parentId');
          expect(next.character, isNull, reason: 'parent $parentId');
          expect(next.categoryId, kCharacterSkinsCategoryId, reason: 'parent $parentId');
          expect((next.text, next.sort), ('maid', GbModSort.mostLiked), reason: 'parent $parentId');
        }
      });

      test('a root named as its own parent is still a root', () {
        final next = query.showingCategory(id: 30305, name: 'Character Skins', parentId: 30305);
        expect(next.typeId, 30305);
        expect(next.character, isNull);
      });

      test('a child of another root turns that root on, since no chip names it', () {
        final next = query.showingCategory(id: 30710, name: 'Avocaboo', parentId: 30702);
        expect(next.typeId, 30702);
        expect(next.character, isNull);
      });
    });
  });
}
