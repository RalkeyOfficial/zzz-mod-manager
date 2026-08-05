import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';

/// Refresh has to reach the network.
///
/// The bug these exist for: the button called `ref.invalidate`, the provider re-ran,
/// and the client's 10-minute response cache answered from memory with the identical
/// page. So for up to ten minutes pressing refresh could not change anything —
/// which read as "no feedback" but was actually "no effect".
///
/// The assertion that matters is a **request count**, not a returned value: the old
/// behaviour returned perfectly good data, it just never asked anyone for it.
void main() {
  const page1 = '{"_aMetadata":{"_nRecordCount":2,"_nPerpage":30},'
      '"_aRecords":[{"_idRow":1,"_sName":"One"}]}';
  const page2 = '{"_aMetadata":{"_nRecordCount":2,"_nPerpage":30},'
      '"_aRecords":[{"_idRow":2,"_sName":"Two"}]}';

  late FakeHttpTransport transport;
  late GameBananaClient client;

  setUp(() {
    transport = FakeHttpTransport();
    client = GameBananaClient(transport: transport);
  });

  Uri browseUrl(MarketplaceQuery query) => client.endpoints.modIndex(
        categoryId: query.categoryId,
        sort: query.sort,
        page: query.page,
      );

  group('fetchMarketplaceResults', () {
    test('a plain fetch is served from cache the second time', () async {
      const query = MarketplaceQuery();
      transport.stub(browseUrl(query), body: page1);

      await fetchMarketplaceResults(client, query);
      await fetchMarketplaceResults(client, query);

      expect(transport.callCount, 1,
          reason: 'the response cache is the point — normal paging reuses it');
    });

    test('refresh: true bypasses the cache and asks again', () async {
      const query = MarketplaceQuery();
      transport.stub(browseUrl(query), body: page1);

      await fetchMarketplaceResults(client, query);
      expect(transport.callCount, 1);

      await fetchMarketplaceResults(client, query, refresh: true);
      expect(transport.callCount, 2,
          reason: 'this is the whole fix: refresh must hit the network');
    });

    test('and it returns the new data, not the cached page', () async {
      const query = MarketplaceQuery();
      // Two `enqueue`s, not `stub` + `enqueue`: a stubbed response repeats
      // indefinitely and is taken from the front of the queue, so it would shadow
      // anything queued behind it and this test would assert nothing.
      transport
        ..enqueue(browseUrl(query), body: page1)
        ..enqueue(browseUrl(query), body: page2);

      final first = await fetchMarketplaceResults(client, query);
      expect(first.records.single.name, 'One');

      final second = await fetchMarketplaceResults(client, query, refresh: true);
      expect(second.records.single.name, 'Two',
          reason: 'a refresh that returned the old page would be the old bug');
    });

    test('a search refresh bypasses the cache too', () async {
      // Two endpoints behind one button; only exercising browse would leave half
      // the button broken.
      const query =
          MarketplaceQuery(mode: MarketplaceMode.search, text: 'ellen');
      final url = client.endpoints.search('ellen', page: 1);
      transport.stub(url, body: page1);

      await fetchMarketplaceResults(client, query);
      await fetchMarketplaceResults(client, query, refresh: true);

      expect(transport.callCount, 2);
      expect(transport.requests.every((r) => r.path.contains('Search')), isTrue);
    });

    test('honours the query it is given rather than a default', () async {
      const query = MarketplaceQuery(
        categoryId: 30305,
        sort: GbModSort.mostLiked,
        page: 3,
      );
      transport.stub(browseUrl(query), body: page1);

      await fetchMarketplaceResults(client, query, refresh: true);

      final sent = transport.requests.single.toString();
      expect(sent, contains('30305'));
      expect(sent, contains('Generic_MostLiked'));
      expect(sent, contains('_nPage=3'));
    });
  });

  test('the provider itself does not bypass the cache', () async {
    // Normal use must keep using the cache — the fix is scoped to the refresh
    // action, not a blanket "always re-fetch" that would undo the caching the
    // client exists to do.
    const query = MarketplaceQuery();
    transport.stub(browseUrl(query), body: page1);

    final container = ProviderContainer(overrides: [
      gameBananaClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);

    await container.read(marketplaceResultsProvider.future);
    container.invalidate(marketplaceResultsProvider);
    await container.read(marketplaceResultsProvider.future);

    expect(transport.callCount, 1,
        reason: 'invalidate alone re-reads the cache — which was the bug');
  });
}
