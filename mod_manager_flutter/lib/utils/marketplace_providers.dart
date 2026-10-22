/// Riverpod state for the native GameBanana browser.
///
/// Kept out of `state_providers.dart` on purpose. That file is the registry for
/// **app-wide** state (tab, theme, locale, the mod library); everything here is
/// one screen's browsing session, and folding a dozen more providers into the
/// central registry would make the thing nobody can skim. The settings that *are*
/// app-wide — the content filter, the sort, Hide installed — stay over there,
/// hydrated from config at startup like the others.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/gamebanana/gamebanana.dart';
import '../services/gamebanana/gamebanana_client.dart';
import 'gamebanana_url.dart';
import 'state_providers.dart';

/// GameBanana's Character Skins root. Its children are the live character roster, which the character chip lists.
const int kCharacterSkinsCategoryId = 30305;

/// The type chips' short labels, by root category id, in the chips' order. A root this map doesn't know shows its live name, after these.
const Map<int, String> kTypeChipLabelKeys = {
  kCharacterSkinsCategoryId: 'marketplace.type_character',
  30702: 'marketplace.type_bangboo',
  30395: 'marketplace.type_ui',
  29874: 'marketplace.type_misc',
};

/// The sorts the Sort menu offers, in its order. `latestComment` is a valid `_sSort` the menu leaves out.
const List<GbModSort> kMarketplaceSorts = [
  GbModSort.newest,
  GbModSort.oldest,
  GbModSort.mostLiked,
  GbModSort.mostDownloaded,
  GbModSort.mostViewed,
  GbModSort.latestModified,
];

/// A character picked in the character chip: a Character Skins child, by id, with the name the chip shows.
@immutable
class MarketplaceCharacter {
  const MarketplaceCharacter(this.id, this.name);

  final int id;
  final String name;

  @override
  bool operator ==(Object other) => other is MarketplaceCharacter && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Everything that identifies the listing the grid shows.
///
/// One `Mod/Index` request, whatever is set: the search text is a filter on the
/// title beside the category and sort, not a different listing. The site-wide
/// search endpoint matches any one word in any field, so a full title returned
/// hundreds of unrelated mods where the site's own name filter returns one.
///
/// The chips are two fields, the type and the character, so the filter bar can draw both, while the request takes
/// one category: the character's when one is picked, else the type's ([categoryId]).
///
/// Immutable and value-equal, which [MarketplaceQueryController] compares on: setting a query equal to the current
/// one, such as re-picking the current sort or re-submitting the same search, changes nothing.
@immutable
class MarketplaceQuery {
  const MarketplaceQuery({this.text = '', this.typeId, this.character, this.sort = kDefaultMarketplaceSort});

  /// The submitted search text, matched anywhere in a mod's title. Empty means
  /// no name filter.
  final String text;

  /// The type chip that is on: a root category id, or null for every mod.
  final int? typeId;

  /// The character picked in the character chip. Set only with [typeId] on Character Skins.
  final MarketplaceCharacter? character;

  final GbModSort sort;

  bool get hasText => text.isNotEmpty;

  /// The `Generic_Category` the request sends.
  int? get categoryId => character?.id ?? typeId;

  MarketplaceQuery withText(String text) =>
      MarketplaceQuery(text: text, typeId: typeId, character: character, sort: sort);

  MarketplaceQuery withSort(GbModSort sort) =>
      MarketplaceQuery(text: text, typeId: typeId, character: character, sort: sort);

  /// Turns [typeId] on, or every type off with null. Any type but Character Skins clears the character.
  MarketplaceQuery withType(int? typeId) => MarketplaceQuery(
    text: text,
    typeId: typeId,
    character: typeId == kCharacterSkinsCategoryId ? character : null,
    sort: sort,
  );

  /// Picks [character], which turns Character Skins on, or clears it with null and leaves the type as it is.
  MarketplaceQuery withCharacter(MarketplaceCharacter? character) => MarketplaceQuery(
    text: text,
    typeId: character == null ? typeId : kCharacterSkinsCategoryId,
    character: character,
    sort: sort,
  );

  /// The grid filtered by a mod page's category link: a Character Skins child picks that character, a root turns
  /// its type on, and a child of another root, which no chip names, turns its root on. Anything but a character
  /// clears the character, Character Skins itself included, since the link names the whole category.
  MarketplaceQuery showingCategory({required int id, String? name, int? parentId}) {
    if (parentId == kCharacterSkinsCategoryId && id != parentId) {
      return withCharacter(MarketplaceCharacter(id, name ?? '#$id'));
    }
    return MarketplaceQuery(text: text, typeId: parentId != null && parentId != id ? parentId : id, sort: sort);
  }

  @override
  bool operator ==(Object other) =>
      other is MarketplaceQuery &&
      other.text == text &&
      other.typeId == typeId &&
      other.character == character &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(text, typeId, character, sort);
}

/// What the results grid is currently asking for.
///
/// Starts on the user's saved sort (`marketplaceSortProvider`, hydrated from
/// config at startup) rather than a hardcoded one, which is what makes the choice
/// survive a restart. Read, not watched: this is a starting value, and re-creating
/// the whole query — losing the chips and the search — because a preference
/// changed would be wrong.
final marketplaceQueryProvider = StateNotifierProvider<MarketplaceQueryController, MarketplaceQuery>((ref) {
  return MarketplaceQueryController(MarketplaceQuery(sort: ref.read(marketplaceSortProvider)));
});

/// Holds the query and tells its listeners only when it changes by value, so an equal query neither restarts the
/// listing at page 1 nor scrolls the grid to the top.
class MarketplaceQueryController extends StateController<MarketplaceQuery> {
  MarketplaceQueryController(super.state);

  @override
  bool updateShouldNotify(MarketplaceQuery old, MarketplaceQuery current) => old != current;
}

/// Runs one page of a query against the client.
///
/// [refresh] issues the identical request with the cache bypassed. Without that, refresh is a no-op: invalidating
/// the listing re-runs this, the client's 10-minute response cache answers from memory, and the byte-identical page
/// comes back, so for up to ten minutes the button would do nothing at all.
Future<GbPage<GbMod>> fetchMarketplaceResults(
  GameBananaClient client,
  MarketplaceQuery query, {
  int page = 1,
  bool refresh = false,
}) {
  if (gameBananaModIdFromText(query.text) case final modId?) {
    return _lookUpMod(client, modId, refresh: refresh);
  }
  return client.browseMods(
    categoryId: query.categoryId,
    name: query.text,
    sort: query.sort,
    page: page,
    refresh: refresh,
  );
}

/// A pasted mod link or id shows that one mod as the whole result set.
///
/// The category and sort are ignored for it: an id names a mod outright, and
/// hiding it because a filter happens to be set would read as "not found".
/// A mod that does not exist any more, or belongs to another game, comes back
/// as an empty page rather than an error, so the grid shows "no mods found"
/// with the same clear-search action a fruitless name search gets.
Future<GbPage<GbMod>> _lookUpMod(GameBananaClient client, int modId, {required bool refresh}) async {
  const nothing = GbPage<GbMod>(records: [], recordCount: 0, isComplete: true);
  final GbMod mod;
  try {
    mod = await client.modProfile(modId, refresh: refresh);
  } on GbApiException catch (e) {
    if (e.isNotFound) return nothing;
    rethrow;
  }
  final ours = client.endpoints.gameId;
  if (ours != null && mod.gameId != null && mod.gameId != ours) return nothing;
  return GbPage(records: [mod], recordCount: 1, perPage: 1, isComplete: true);
}

/// Fetches page [page] (1-based) of [query], bypassing the client's cache with [refresh].
typedef MarketplacePageFetcher = Future<GbPage<GbMod>> Function(MarketplaceQuery query, int page, {bool refresh});

/// How the listing reaches GameBanana: [fetchMarketplaceResults] on the app's client. A test overrides it to hand
/// back pages without a network.
final marketplacePageFetcherProvider = Provider<MarketplacePageFetcher>((ref) {
  final client = ref.watch(gameBananaClientProvider);
  return (query, page, {refresh = false}) => fetchMarketplaceResults(client, query, page: page, refresh: refresh);
});

/// The pages of the listing loaded so far, for the grid's infinite scroll.
@immutable
class MarketplaceFeed {
  const MarketplaceFeed({required this.pages, required this.isComplete, this.loadingMore = false, this.loadMoreError});

  /// The first page of a listing.
  factory MarketplaceFeed.first(GbPage<GbMod> page) =>
      MarketplaceFeed(pages: [page.records], isComplete: _lastPage(page, page.records.length));

  /// Each loaded page's records, in order. Kept per page, since each page's enrichment is one request keyed by its
  /// ids.
  final List<List<GbMod>> pages;

  /// Whether the last page is in: `_bIsComplete`, the record count reached, or a page that came back empty.
  final bool isComplete;

  /// Whether the next page is in flight.
  final bool loadingMore;

  /// Why the last next-page request failed, until the next one is asked for.
  final Object? loadMoreError;

  List<GbMod> get records => [for (final page in pages) ...page];

  /// [page] appended as the next page. A mod already loaded is left out: a listing shifts while it is paged, as new
  /// mods arrive at the top of Newest, and the same mod would otherwise show twice.
  MarketplaceFeed append(GbPage<GbMod> page) {
    final seen = {for (final mod in records) mod.idRow};
    final fresh = [
      for (final mod in page.records)
        if (seen.add(mod.idRow)) mod,
    ];
    final loaded = seen.length;
    return MarketplaceFeed(pages: [...pages, fresh], isComplete: _lastPage(page, loaded));
  }

  MarketplaceFeed copyWith({bool? loadingMore, Object? loadMoreError, bool clearError = false}) => MarketplaceFeed(
    pages: pages,
    isComplete: isComplete,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
  );

  static bool _lastPage(GbPage<GbMod> page, int loaded) =>
      page.isComplete || page.records.isEmpty || (page.recordCount != null && loaded >= page.recordCount!);
}

/// The listing for the current query, page by page. A query change starts again at page 1.
final marketplaceFeedProvider = AsyncNotifierProvider<MarketplaceFeedNotifier, MarketplaceFeed>(
  MarketplaceFeedNotifier.new,
);

class MarketplaceFeedNotifier extends AsyncNotifier<MarketplaceFeed> {
  /// Bumped by every build, so a next page that lands after the query changed is dropped rather than appended to
  /// the new listing.
  int _generation = 0;

  @override
  Future<MarketplaceFeed> build() async {
    final query = ref.watch(marketplaceQueryProvider);
    final fetch = ref.watch(marketplacePageFetcherProvider);
    _generation++;
    return MarketplaceFeed.first(await fetch(query, 1));
  }

  /// Fetches and appends the next page. Does nothing while a page is in flight, once the last page is in, while the
  /// first page loads, or while it has failed: Riverpod keeps the previous listing's feed beside the error, and a
  /// page appended to that would mix the old query's cards with the new one's.
  ///
  /// Always past the client's cache. Page 1 may be answered from it, which keeps flipping back to a chip instant,
  /// but a later page from the cache can be minutes older than the page above it, and a Refresh would then be fresh
  /// only for its first page.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || state.isLoading || state.hasError || current.isComplete || current.loadingMore) return;
    final generation = _generation;
    final query = ref.read(marketplaceQueryProvider);
    final fetch = ref.read(marketplacePageFetcherProvider);
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await fetch(query, current.pages.length + 1, refresh: true);
      if (generation == _generation) state = AsyncData(current.append(page));
    } on Object catch (error) {
      if (generation == _generation) state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: error));
    }
  }

  /// Forces a network re-fetch of page 1 and starts the listing again from it.
  ///
  /// Two steps, one request: the first call goes to the network and repopulates the
  /// client's cache, then invalidating makes the build re-read that now-fresh
  /// entry (an instant cache hit). In this order the grid keeps showing the old
  /// cards while the request is in flight, rather than flashing a spinner over
  /// content that is about to be replaced by something nearly identical.
  ///
  /// Scoped to the listing. The category tree is structural and rarely changes,
  /// and the carousel's windows turn over daily — neither is what someone pressing
  /// refresh above the grid is asking about.
  Future<void> refresh() async {
    final query = ref.read(marketplaceQueryProvider);
    await ref.read(marketplacePageFetcherProvider)(query, 1, refresh: true);
    ref.invalidateSelf();
    await future;
  }
}

/// The ids of one batch of mods, value-equal so it can key a provider family.
@immutable
class ModIdList {
  const ModIdList(this.ids);

  final List<int> ids;

  @override
  bool operator ==(Object other) => other is ModIdList && listEquals(other.ids, ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

/// What `Mod/Multi` is asked for to fill out a card: listings carry no download count and no files, and TopSubs
/// no character.
const List<String> modEnrichmentProperties = ['_idRow', '_nDownloadCount', '_aCategory', '_aFiles'];

/// The records of an enrichment response by mod id.
///
/// A withheld mod comes back blank — its count, category and files all null — and is left out, so its card reads
/// as one with no enrichment rather than as a mod with no files. Every published mod has a download count, zero
/// for a new one, so a record without one is the blank.
Map<int, GbMod> enrichmentByMod(Iterable<GbMod> records) => {
  for (final record in records)
    if (record.downloadCount != null || record.category != null) record.idRow: record,
};

/// One `Mod/Multi` for a batch of ids: a page of the listing, or the carousel's entries.
///
/// Keyed by the id list so a rebuild doesn't fetch again. A failed request is an empty map, so the cards stay as they
/// are, without download counts and with Install opening the mod page; nothing retries and nothing is said, since
/// the client has already logged the failure and the cards work without it.
final modEnrichmentProvider = FutureProvider.autoDispose.family<Map<int, GbMod>, ModIdList>((ref, key) async {
  if (key.ids.isEmpty) return const {};
  try {
    final records = await ref.watch(gameBananaClientProvider).modsMulti(key.ids, properties: modEnrichmentProperties);
    return enrichmentByMod(records);
  } on GbException {
    return const {};
  }
});

/// Mods whose card Install is fetching the mod page before the download is queued, shown as Queued meanwhile.
final marketplacePendingInstallsProvider = StateProvider<Set<int>>((ref) => const {});

/// Full detail for one mod, by id.
///
/// `.family` keyed by mod id so opening a detail view twice reuses the response
/// (and the client's cache) instead of refetching.
final modProfileProvider = FutureProvider.family<GbMod, int>((ref, modId) {
  return ref.watch(gameBananaClientProvider).modProfile(modId);
});

/// The author's update posts for one mod: the first page of `Mod/<id>/Updates`, which the mod page's Updates section
/// lists. Disposed with the page, so reopening the mod asks again, through the client's cache.
final modUpdatesProvider = FutureProvider.autoDispose.family<List<GbUpdate>, int>((ref, modId) {
  return ref.watch(gameBananaClientProvider).modUpdates(modId);
});

/// The game's root mod categories — Character Skins, Bangboo Skins, Other/Misc,
/// UI — which the type chips are built from.
///
/// Fetched, never hardcoded. GameBanana is the authority on what categories exist,
/// so a local copy is exactly the thing that goes stale.
final rootCategoriesProvider = FutureProvider<List<GbCategoryNode>>((ref) {
  return ref.watch(gameBananaClientProvider).categories();
});

/// The children of one category. The character chip's menu is Character Skins' children, the live roster.
///
/// **No offline fallback to the local roster, deliberately.**
/// `utils/zzz_characters.dart` carries no GameBanana category ids, and an id is
/// the only thing `Generic_Category` accepts — a name is not a filter value here,
/// so a local list could only render entries that cannot filter.
final categoryChildrenProvider = FutureProvider.family<List<GbCategoryNode>, int>((ref, categoryId) {
  return ref.watch(gameBananaClientProvider).categories(categoryId: categoryId);
});

/// The game's "best of period" submissions, behind the featured carousel.
///
/// Its own provider rather than part of the listing: it does not depend on
/// the query at all (no filters, no sort, no paging — the endpoint takes no
/// parameters), so tying it to `marketplaceQueryProvider` would refetch it on
/// every filter change for no reason.
final topSubsProvider = FutureProvider<List<GbTopSub>>((ref) {
  return ref.watch(gameBananaClientProvider).topSubs();
});

/// One page over Browse's grid: a mod's page or a creator's page.
///
/// Value-equal on what the page shows, the mod id or the member id, which is what the stack finds a page by.
@immutable
sealed class MarketplaceRoute {
  const MarketplaceRoute();
}

/// A mod's page.
final class MarketplaceModRoute extends MarketplaceRoute {
  const MarketplaceModRoute(this.modId);

  final int modId;

  @override
  bool operator ==(Object other) => other is MarketplaceModRoute && other.modId == modId;

  @override
  int get hashCode => Object.hash(MarketplaceModRoute, modId);
}

/// A creator's page: every Zenless Zone Zero mod [member] published. The member comes from the mod page that
/// linked here, so the page has a name and an avatar before its listing loads.
final class MarketplaceCreatorRoute extends MarketplaceRoute {
  const MarketplaceCreatorRoute(this.member);

  final GbSubmitter member;

  @override
  bool operator ==(Object other) => other is MarketplaceCreatorRoute && other.member.idRow == member.idRow;

  @override
  int get hashCode => Object.hash(MarketplaceCreatorRoute, member.idRow);
}

/// The pages open over Browse's grid, bottom first; empty while the grid is shown.
///
/// The marketplace lives inside the app's own page switcher rather than a `Navigator`, so which page is shown is
/// state rather than a route. Every page in the stack stays mounted under the top one (`docs/marketplace.md` §3).
final marketplaceRoutesProvider = StateNotifierProvider<MarketplaceRoutesController, List<MarketplaceRoute>>(
  (ref) => MarketplaceRoutesController(),
);

class MarketplaceRoutesController extends StateController<List<MarketplaceRoute>> {
  MarketplaceRoutesController([super.state = const []]);

  /// Shows [route] on top. A page already in the stack is gone back to rather than opened twice, which keeps the
  /// stack as deep as the pages it holds, and each page's state in one place.
  void open(MarketplaceRoute route) {
    final at = state.indexOf(route);
    state = at < 0 ? [...state, route] : state.sublist(0, at + 1);
  }

  /// A mod's page as the only page over the grid: a card or the carousel on the grid, or a caller outside Browse.
  void openFromGrid(int modId) => state = [MarketplaceModRoute(modId)];

  /// Goes back one page.
  void back() {
    if (state.isNotEmpty) state = state.sublist(0, state.length - 1);
  }

  /// Goes back to the grid.
  void toGrid() => state = const [];

  @override
  bool updateShouldNotify(List<MarketplaceRoute> old, List<MarketplaceRoute> current) => !listEquals(old, current);
}

/// The mod whose page is on top, for a caller outside Browse: the Library's update dialog opens a mod's page by
/// writing its id here.
///
/// Writing an id makes that mod's page the only page over the grid, and null goes back to the grid. Reading gives
/// the mod on top of [marketplaceRoutesProvider], or null while the grid or a creator's page is shown.
final marketplaceOpenModProvider = StateNotifierProvider<MarketplaceOpenModController, int?>((ref) {
  final controller = MarketplaceOpenModController(ref.read(marketplaceRoutesProvider.notifier));
  ref.listen(marketplaceRoutesProvider, (_, routes) => controller._follow(routes));
  return controller;
});

class MarketplaceOpenModController extends StateController<int?> {
  MarketplaceOpenModController(this._routes) : super(_topMod(_routes.state));

  final MarketplaceRoutesController _routes;

  @override
  set state(int? modId) => modId == null ? _routes.toGrid() : _routes.openFromGrid(modId);

  void _follow(List<MarketplaceRoute> routes) => super.state = _topMod(routes);

  static int? _topMod(List<MarketplaceRoute> routes) => switch (routes.lastOrNull) {
    MarketplaceModRoute(:final modId) => modId,
    _ => null,
  };
}

/// A creator's page fetches at most this many records a request: `_nPerpage`'s cap on `Mod/Index`.
const int kCreatorPageSize = 50;

/// And at most this many pages, so 1000 mods; past that the page says it shows the first 1000.
const int kCreatorMaxPages = 20;

/// One member's Zenless Zone Zero mods at one sort: what a creator's page lists.
@immutable
class CreatorListing {
  const CreatorListing(this.memberId, this.sort);

  final int memberId;
  final GbModSort sort;

  @override
  bool operator ==(Object other) => other is CreatorListing && other.memberId == memberId && other.sort == sort;

  @override
  int get hashCode => Object.hash(memberId, sort);
}

/// Fetches page [page] (1-based) of [listing], [kCreatorPageSize] records long.
typedef CreatorPageFetcher = Future<GbPage<GbMod>> Function(CreatorListing listing, int page);

/// How a creator's page reaches GameBanana: `Mod/Index` filtered by `Generic_Submitter`. A test overrides it.
final creatorPageFetcherProvider = Provider<CreatorPageFetcher>((ref) {
  final client = ref.watch(gameBananaClientProvider);
  return (listing, page) =>
      client.browseMods(submitterId: listing.memberId, sort: listing.sort, page: page, perPage: kCreatorPageSize);
});

/// Whether [feed] stopped at [kCreatorMaxPages] with more of the member's mods left on GameBanana.
bool isCreatorFeedCapped(MarketplaceFeed feed) => !feed.isComplete && feed.pages.length >= kCreatorMaxPages;

/// Every page of a member's mods, up to [kCreatorMaxPages]: the character tiles and both counts are about the whole
/// set, so the page loads all of it rather than scrolling into it.
///
/// The build answers with page 1, and the later pages are then fetched one at a time and appended as each lands, so
/// the header and the tiles show from the first page and fill as the rest come in. A later page that fails stops
/// the loading with the pages already in kept, until [retry]. Every page goes through the client's cache.
final creatorFeedProvider = AsyncNotifierProvider.autoDispose
    .family<CreatorFeedNotifier, MarketplaceFeed, CreatorListing>(CreatorFeedNotifier.new);

class CreatorFeedNotifier extends AutoDisposeFamilyAsyncNotifier<MarketplaceFeed, CreatorListing> {
  /// Bumped by every build and by disposal, so the loop of a feed that was rebuilt or closed stops at its next page.
  int _generation = 0;

  @override
  Future<MarketplaceFeed> build(CreatorListing arg) async {
    ref.onDispose(() => _generation++);
    final generation = ++_generation;
    // Each page that lands is a new state, which asks for the next: page 2 follows page 1 becoming the state.
    listenSelf((_, next) {
      if (generation == _generation && next.hasValue && !next.isLoading) _loadNext(generation);
    });
    return MarketplaceFeed.first(await ref.watch(creatorPageFetcherProvider)(arg, 1));
  }

  /// Fetches the next page again after one failed, and the rest after it.
  void retry() {
    final current = state.valueOrNull;
    if (current?.loadMoreError == null) return;
    state = AsyncData(current!.copyWith(clearError: true));
  }

  /// Fetches the next page, unless one is in flight, the last is in, the cap is reached or the last one failed.
  Future<void> _loadNext(int generation) async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isComplete ||
        current.loadingMore ||
        current.loadMoreError != null ||
        isCreatorFeedCapped(current)) {
      return;
    }
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await ref.read(creatorPageFetcherProvider)(arg, current.pages.length + 1);
      if (generation == _generation) state = AsyncData(current.append(page));
    } on Object catch (error) {
      if (generation == _generation) state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: error));
    }
  }
}
