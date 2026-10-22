import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
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

  Uri browseUrl(MarketplaceQuery query, {int page = 1}) => client.endpoints.modIndex(
        categoryId: query.categoryId,
        sort: query.sort,
        page: page,
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

    test('a search term goes to Index as a name filter', () async {
      const query = MarketplaceQuery(
        text: 'ellen',
        typeId: kCharacterSkinsCategoryId,
        character: MarketplaceCharacter(30341, 'Ellen Joe'),
      );
      final url = client.endpoints.modIndex(name: 'ellen', categoryId: 30341);
      transport.stub(url, body: page1);

      await fetchMarketplaceResults(client, query);
      await fetchMarketplaceResults(client, query, refresh: true);

      expect(transport.callCount, 2);
      expect(transport.requests.every((r) => r.path.endsWith('Mod/Index')),
          isTrue);
      expect(transport.requests.first.toString(),
          contains('Generic_Name%5D=contains%2Cellen'));
    });

    group('a pasted mod link or id', () {
      const profile = '{"_idRow":531649,"_sName":"Only Mod",'
          '"_aGame":{"_idRow":19567}}';
      const otherGame = '{"_idRow":7,"_sName":"Elsewhere",'
          '"_aGame":{"_idRow":8552}}';

      setUp(() {
        client = GameBananaClient(transport: transport, gameId: 19567);
      });

      test('shows that one mod, whatever the category and sort', () async {
        transport.stub(client.endpoints.modProfile(531649), body: profile);
        const query = MarketplaceQuery(
          text: 'https://gamebanana.com/mods/531649',
          typeId: 30395,
          sort: GbModSort.mostLiked,
        );

        final page = await fetchMarketplaceResults(client, query);

        expect(page.records.single.name, 'Only Mod');
        expect(page.isComplete, isTrue);
        expect(page.pageCount, 1);
        expect(transport.requests.single.path, endsWith('/Mod/531649/ProfilePage'));
      });

      test('a bare id does the same', () async {
        transport.stub(client.endpoints.modProfile(531649), body: profile);

        final page =
            await fetchMarketplaceResults(client, const MarketplaceQuery(text: '531649'));

        expect(page.records.single.idRow, 531649);
      });

      test('an id nobody has is an empty page, not an error', () async {
        transport.stub(client.endpoints.modProfile(1),
            statusCode: 404,
            body: '{"_sErrorCode":"NO_SUCH_RECORD"}');

        final page =
            await fetchMarketplaceResults(client, const MarketplaceQuery(text: '1'));

        expect(page.records, isEmpty);
        expect(page.isComplete, isTrue);
      });

      test("another game's mod is an empty page", () async {
        transport.stub(client.endpoints.modProfile(7), body: otherGame);

        final page =
            await fetchMarketplaceResults(client, const MarketplaceQuery(text: '7'));

        expect(page.records, isEmpty);
      });

      test('refresh: true asks again', () async {
        transport.stub(client.endpoints.modProfile(531649), body: profile);
        const query = MarketplaceQuery(text: '531649');

        await fetchMarketplaceResults(client, query);
        await fetchMarketplaceResults(client, query, refresh: true);

        expect(transport.callCount, 2);
      });
    });

    test('honours the query it is given rather than a default', () async {
      const query = MarketplaceQuery(
        typeId: 30305,
        sort: GbModSort.mostLiked,
      );
      transport.stub(browseUrl(query, page: 3), body: page1);

      await fetchMarketplaceResults(client, query, page: 3, refresh: true);

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

    await container.read(marketplaceFeedProvider.future);
    container.invalidate(marketplaceFeedProvider);
    await container.read(marketplaceFeedProvider.future);

    expect(transport.callCount, 1,
        reason: 'invalidate alone re-reads the cache — which was the bug');
  });

  test("the feed's refresh asks the network again and starts at page 1", () async {
    const query = MarketplaceQuery();
    transport
      ..stub(browseUrl(query), body: _page(ids: [1, 2], total: 4))
      ..stub(browseUrl(query, page: 2), body: _page(ids: [3, 4], total: 4));

    final container = ProviderContainer(overrides: [
      gameBananaClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(marketplaceFeedProvider, (_, _) {});
    addTearDown(sub.close);

    await container.read(marketplaceFeedProvider.future);
    await container.read(marketplaceFeedProvider.notifier).loadMore();
    expect(container.read(marketplaceFeedProvider).requireValue.pages, hasLength(2));
    final before = transport.callCount;

    await container.read(marketplaceFeedProvider.notifier).refresh();

    expect(transport.callCount, before + 1, reason: 'one request, past the cache');
    expect(container.read(marketplaceFeedProvider).requireValue.pages, hasLength(1));
  });

  test('a page past the first goes past the cache in every run, after a Refresh too', () async {
    const query = MarketplaceQuery();
    transport
      ..stub(browseUrl(query), body: _page(ids: [1, 2], total: 6))
      ..stub(browseUrl(query, page: 2), body: _page(ids: [3, 4], total: 6));

    final container = ProviderContainer(overrides: [
      gameBananaClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(marketplaceFeedProvider, (_, _) {});
    addTearDown(sub.close);
    final notifier = container.read(marketplaceFeedProvider.notifier);

    await container.read(marketplaceFeedProvider.future);
    await notifier.loadMore();
    expect(transport.callCount, 2);

    // The same listing again from page 1: page 1 may come from the cache, page 2 may not.
    container.invalidate(marketplaceFeedProvider);
    await container.read(marketplaceFeedProvider.future);
    expect(transport.callCount, 2, reason: 'page 1 is answered from the cache');
    await container.read(marketplaceFeedProvider.notifier).loadMore();
    expect(transport.callCount, 3, reason: 'page 2 asks the network again');

    await container.read(marketplaceFeedProvider.notifier).refresh();
    await container.read(marketplaceFeedProvider.notifier).loadMore();
    expect(transport.callCount, 5, reason: 'a Refresh is fresh past its first page');
    expect(container.read(marketplaceFeedProvider).requireValue.records.map((m) => m.idRow), [1, 2, 3, 4]);
  });

  group('the feed pages through the listing', () {
    ProviderContainer feedOver(Map<int, Object> pages, {List<int>? asked}) {
      final container = ProviderContainer(overrides: [
        marketplacePageFetcherProvider.overrideWithValue((query, page, {refresh = false}) async {
          asked?.add(page);
          final result = pages[page];
          if (result is GbPage<GbMod>) return result;
          throw result ?? StateError('no page $page');
        }),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(marketplaceFeedProvider, (_, _) {});
      addTearDown(sub.close);
      return container;
    }

    GbPage<GbMod> page(List<int> ids, {int total = 6, bool complete = false}) => GbPage(
          records: [for (final id in ids) GbMod(idRow: id)],
          recordCount: total,
          isComplete: complete,
        );

    test('appends the next page', () async {
      final asked = <int>[];
      final container = feedOver({1: page([1, 2]), 2: page([3, 4])}, asked: asked);
      await container.read(marketplaceFeedProvider.future);
      await container.read(marketplaceFeedProvider.notifier).loadMore();

      final feed = container.read(marketplaceFeedProvider).requireValue;
      expect(feed.records.map((m) => m.idRow), [1, 2, 3, 4]);
      expect(feed.isComplete, isFalse);
      expect(asked, [1, 2]);
    });

    test('a mod the listing shifted onto the next page is not shown twice', () async {
      final container = feedOver({1: page([1, 2]), 2: page([2, 3])});
      await container.read(marketplaceFeedProvider.future);
      await container.read(marketplaceFeedProvider.notifier).loadMore();
      expect(container.read(marketplaceFeedProvider).requireValue.records.map((m) => m.idRow), [1, 2, 3]);
    });

    test('is complete on _bIsComplete, on the record count, and on an empty page', () async {
      expect(MarketplaceFeed.first(page([1], complete: true)).isComplete, isTrue);
      expect(MarketplaceFeed.first(page([1, 2], total: 2)).isComplete, isTrue);
      expect(MarketplaceFeed.first(page([])).isComplete, isTrue);
      expect(MarketplaceFeed.first(page([1, 2], total: 3)).append(page([3], total: 3)).isComplete, isTrue);
    });

    test('asks nothing once complete', () async {
      final asked = <int>[];
      final container = feedOver({1: page([1], complete: true)}, asked: asked);
      await container.read(marketplaceFeedProvider.future);
      await container.read(marketplaceFeedProvider.notifier).loadMore();
      expect(asked, [1]);
    });

    test('a failed next page keeps the loaded ones and holds the error until asked again', () async {
      final container = feedOver({1: page([1, 2]), 2: StateError('offline')});
      await container.read(marketplaceFeedProvider.future);
      await container.read(marketplaceFeedProvider.notifier).loadMore();

      final feed = container.read(marketplaceFeedProvider).requireValue;
      expect(feed.records, hasLength(2));
      expect(feed.loadMoreError, isA<StateError>());
      expect(feed.loadingMore, isFalse);
    });

    test('a next page that lands after the query changed is dropped', () async {
      final late = Completer<GbPage<GbMod>>();
      final container = ProviderContainer(overrides: [
        marketplacePageFetcherProvider.overrideWithValue((query, page, {refresh = false}) {
          if (page == 2) return late.future;
          return Future.value(GbPage(records: [GbMod(idRow: query.hasText ? 10 : 1)], recordCount: 9));
        }),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(marketplaceFeedProvider, (_, _) {});
      addTearDown(sub.close);

      await container.read(marketplaceFeedProvider.future);
      final loading = container.read(marketplaceFeedProvider.notifier).loadMore();
      container.read(marketplaceQueryProvider.notifier).state = const MarketplaceQuery(text: 'maid');
      await container.read(marketplaceFeedProvider.future);
      late.complete(GbPage(records: [const GbMod(idRow: 2)], recordCount: 9));
      await loading;

      expect(container.read(marketplaceFeedProvider).requireValue.records.map((m) => m.idRow), [10]);
    });

    test("a failed first page of a new query never asks for its page 2 onto the old query's cards", () async {
      final asked = <(int?, int)>[];
      final container = ProviderContainer(overrides: [
        marketplacePageFetcherProvider.overrideWithValue((query, page, {refresh = false}) async {
          asked.add((query.typeId, page));
          if (query.typeId == null) {
            return GbPage(records: [for (var i = 1; i <= 3; i++) GbMod(idRow: i)], recordCount: 100);
          }
          if (page == 1) throw const GbNetworkException('offline');
          return GbPage(records: const [GbMod(idRow: 500)], recordCount: 100);
        }),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(marketplaceFeedProvider, (_, _) {});
      addTearDown(sub.close);

      await container.read(marketplaceFeedProvider.future);
      container.read(marketplaceQueryProvider.notifier).state = const MarketplaceQuery(typeId: 30702);
      await expectLater(container.read(marketplaceFeedProvider.future), throwsA(isA<GbNetworkException>()));

      await container.read(marketplaceFeedProvider.notifier).loadMore();

      final state = container.read(marketplaceFeedProvider);
      expect(state.hasError, isTrue, reason: 'the failure stays, with its Try again');
      expect(asked, [(null, 1), (30702, 1)]);
    });
  });

  group('the query', () {
    test('an equal query changes nothing: no page 1 again, no listener told', () async {
      final asked = <int>[];
      final container = ProviderContainer(overrides: [
        marketplacePageFetcherProvider.overrideWithValue((query, page, {refresh = false}) async {
          asked.add(page);
          return GbPage(records: const [GbMod(idRow: 1)], recordCount: 1);
        }),
      ]);
      addTearDown(container.dispose);
      var told = 0;
      final querySub = container.listen(marketplaceQueryProvider, (_, _) => told++);
      addTearDown(querySub.close);
      final feedSub = container.listen(marketplaceFeedProvider, (_, _) {});
      addTearDown(feedSub.close);
      await container.read(marketplaceFeedProvider.future);

      final notifier = container.read(marketplaceQueryProvider.notifier);
      final start = notifier.state;
      // A fresh instance, as re-picking the current sort, chip or search builds one.
      notifier.state = start.withSort(start.sort);
      notifier.state = start.withType(start.typeId);
      notifier.state = start.withText(start.text);
      await container.read(marketplaceFeedProvider.future);

      expect(told, 0);
      expect(asked, [1]);

      notifier.state = start.withText('maid');
      await container.read(marketplaceFeedProvider.future);
      expect(told, 1);
      expect(asked, [1, 1]);
    });
  });
}

String _page({required List<int> ids, required int total}) =>
    '{"_aMetadata":{"_nRecordCount":$total,"_nPerpage":2},'
    '"_aRecords":[${ids.map((id) => '{"_idRow":$id}').join(',')}]}';
