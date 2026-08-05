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
      // query when the preference changed would throw away the current page and
      // category selection. The sort menu updates both explicitly instead.
      final container = ProviderContainer(
        overrides: [
          marketplaceSortProvider.overrideWith((ref) => GbModSort.newest),
        ],
      );
      addTearDown(container.dispose);

      container.read(marketplaceQueryProvider.notifier).state = container
          .read(marketplaceQueryProvider)
          .copyWith(page: 4, categoryId: 30305);

      container.read(marketplaceSortProvider.notifier).state =
          GbModSort.mostViewed;

      final query = container.read(marketplaceQueryProvider);
      expect(query.page, 4, reason: 'paging survives a preference change');
      expect(query.categoryId, 30305);
    });
  });
}
