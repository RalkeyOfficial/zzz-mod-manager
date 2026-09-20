/// Riverpod state for the native GameBanana browser.
///
/// Kept out of `state_providers.dart` on purpose. That file is the registry for
/// **app-wide** state (tab, theme, locale, the mod library); everything here is
/// one screen's browsing session, and folding a dozen more providers into the
/// central registry would make the thing nobody can skim. The setting that *is*
/// app-wide — the content filter — stays over there, hydrated from config at
/// startup like the others.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/gamebanana/gamebanana.dart';
import '../services/gamebanana/gamebanana_client.dart';
import 'gamebanana_url.dart';
import 'state_providers.dart';

/// Everything that identifies one page of results.
///
/// One `Mod/Index` request, whatever is set: the search text is a filter on the
/// title beside the category and sort, not a different listing. The site-wide
/// search endpoint matches any one word in any field, so a full title returned
/// hundreds of unrelated mods where the site's own name filter returns one.
///
/// Immutable and value-equal so the results provider re-fetches exactly when
/// something meaningful changed — typing in the search box without submitting
/// must not fire a request per keystroke.
class MarketplaceQuery {
  const MarketplaceQuery({
    this.text = '',
    this.categoryId,
    this.sort = kDefaultMarketplaceSort,
    this.page = 1,
  });

  /// The submitted search text, matched anywhere in a mod's title. Empty means
  /// no name filter.
  final String text;

  /// A `Generic_Category` id — a root category or a character.
  final int? categoryId;

  final GbModSort sort;

  /// 1-based.
  final int page;

  bool get hasText => text.isNotEmpty;

  MarketplaceQuery copyWith({
    String? text,
    int? categoryId,
    bool clearCategory = false,
    GbModSort? sort,
    int? page,
  }) {
    return MarketplaceQuery(
      text: text ?? this.text,
      // copyWith can't express "back to no category" with a nullable value, and
      // an "All" filter chip has to be able to.
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      sort: sort ?? this.sort,
      page: page ?? this.page,
    );
  }

  /// Any change to what is being asked for resets to page 1. Staying on page 7
  /// while switching filters lands the user in an empty page for no reason.
  MarketplaceQuery refine({
    String? text,
    int? categoryId,
    bool clearCategory = false,
    GbModSort? sort,
  }) =>
      copyWith(
        text: text,
        categoryId: categoryId,
        clearCategory: clearCategory,
        sort: sort,
        page: 1,
      );

  @override
  bool operator ==(Object other) =>
      other is MarketplaceQuery &&
      other.text == text &&
      other.categoryId == categoryId &&
      other.sort == sort &&
      other.page == page;

  @override
  int get hashCode => Object.hash(text, categoryId, sort, page);
}

/// What the results grid is currently asking for.
///
/// Starts on the user's saved sort (`marketplaceSortProvider`, hydrated from
/// config at startup) rather than a hardcoded one, which is what makes the choice
/// survive a restart. Read, not watched: this is a starting value, and re-creating
/// the whole query — losing the current page and category — because a preference
/// changed would be wrong.
final marketplaceQueryProvider = StateProvider<MarketplaceQuery>((ref) {
  return MarketplaceQuery(sort: ref.read(marketplaceSortProvider));
});

/// One page of results for the current query.
///
/// A `FutureProvider` rather than hand-rolled loading flags: the three states
/// the grid must render (loading / error / data) are exactly what `AsyncValue`
/// already models, and the client's own response cache means re-selecting a
/// previous filter is usually instant rather than a fresh request.
final marketplaceResultsProvider = FutureProvider<GbPage<GbMod>>((ref) async {
  final query = ref.watch(marketplaceQueryProvider);
  final client = ref.watch(gameBananaClientProvider);
  return fetchMarketplaceResults(client, query);
});

/// Runs one query against the client.
///
/// Extracted from the provider so the **refresh** action can issue the identical
/// request with the cache bypassed. Without that, refresh was a no-op: invalidating
/// the provider re-ran this, the client's 10-minute response cache answered from
/// memory, and the byte-identical page came back — so for up to ten minutes the
/// button could not do anything at all, however hard it was pressed.
Future<GbPage<GbMod>> fetchMarketplaceResults(
  GameBananaClient client,
  MarketplaceQuery query, {
  bool refresh = false,
}) {
  if (gameBananaModIdFromText(query.text) case final modId?) {
    return _lookUpMod(client, modId, refresh: refresh);
  }
  return client.browseMods(
    categoryId: query.categoryId,
    name: query.text,
    sort: query.sort,
    page: query.page,
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
Future<GbPage<GbMod>> _lookUpMod(
  GameBananaClient client,
  int modId, {
  required bool refresh,
}) async {
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

/// Forces a network re-fetch of the current query and swaps the result in.
///
/// Two steps, one request: the first call goes to the network and repopulates the
/// client's cache, then invalidating the provider makes it re-read that now-fresh
/// entry (an instant cache hit). Doing it in this order means the grid keeps showing
/// the old page while the request is in flight, rather than flashing a spinner over
/// content that is about to be replaced by something nearly identical.
///
/// Deliberately scoped to the results. The category tree is structural and rarely
/// changes, and the carousel's windows turn over daily — neither is what someone
/// pressing refresh above the grid is asking about, and dropping their cached
/// responses would cost requests for no visible gain.
Future<void> refreshMarketplaceResults(WidgetRef ref) async {
  final query = ref.read(marketplaceQueryProvider);
  final client = ref.read(gameBananaClientProvider);
  await fetchMarketplaceResults(client, query, refresh: true);
  ref.invalidate(marketplaceResultsProvider);
}

/// Full detail for one mod, by id.
///
/// `.family` keyed by mod id so opening a detail view twice reuses the response
/// (and the client's cache) instead of refetching.
final modProfileProvider = FutureProvider.family<GbMod, int>((ref, modId) {
  return ref.watch(gameBananaClientProvider).modProfile(modId);
});

/// The game's root mod categories — Character Skins, Bangboo Skins, Other/Misc,
/// UI — as the top level of the filter tree.
///
/// Fetched, never hardcoded. GameBanana is the authority on what categories exist
/// and it gains new ones (notably new characters) with every game patch, so a
/// local copy is exactly the thing that goes stale.
///
/// **No offline fallback to the local roster, deliberately.**
/// `utils/zzz_characters.dart` carries no GameBanana category ids, and an id is
/// the only thing `Generic_Category` accepts — a name is not a filter value here,
/// so a local list could only render entries that cannot filter. It would also
/// never help: this request fails exactly when the listing request beside it
/// fails, so the screen already has one honest error state covering both.
final rootCategoriesProvider = FutureProvider<List<GbCategoryNode>>((ref) {
  return ref.watch(gameBananaClientProvider).categories();
});

/// The children of one category, fetched **on expand** rather than up front.
///
/// Lazy because the tree is lopsided: Character Skins has ~60 children (the live
/// character roster) and Bangboo Skins ~22, while Other/Misc and UI have one
/// each. Loading every branch eagerly would issue four requests to populate a
/// panel where the user typically opens one. `.family` keys the cache by id, so
/// collapsing and re-expanding costs nothing.
final categoryChildrenProvider =
    FutureProvider.family<List<GbCategoryNode>, int>((ref, categoryId) {
  return ref
      .watch(gameBananaClientProvider)
      .categories(categoryId: categoryId);
});

/// The game's "best of period" submissions, behind the featured carousel.
///
/// Its own provider rather than part of the results query: it does not depend on
/// the query at all (no filters, no sort, no paging — the endpoint takes no
/// parameters), so tying it to `marketplaceQueryProvider` would refetch it on
/// every page turn and filter change for no reason. The client's response cache
/// honours the endpoint's own `max-age=600`.
final topSubsProvider = FutureProvider<List<GbTopSub>>((ref) {
  return ref.watch(gameBananaClientProvider).topSubs();
});

/// Which root category is expanded in the filter panel, or null for none.
///
/// Single-open rather than a set: with ~60 children under Character Skins, two
/// open branches turn the panel back into the unusable wall of entries it
/// replaced.
final expandedCategoryProvider = StateProvider<int?>((ref) => null);

/// The mod whose detail view is open, or null while browsing.
///
/// The marketplace tab lives inside the app's own tab switcher rather than a
/// `Navigator`, so "which screen" is state rather than a route.
final marketplaceOpenModProvider = StateProvider<int?>((ref) => null);
