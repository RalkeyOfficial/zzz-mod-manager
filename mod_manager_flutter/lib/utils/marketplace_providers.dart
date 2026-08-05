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

import '../core/constants.dart';
import '../models/gamebanana/gamebanana.dart';
import 'state_providers.dart';

/// Which listing the results grid is showing.
///
/// Browse and search are genuinely different endpoints, not one endpoint with an
/// optional parameter: `Mod/Index` filters and sorts but cannot take text, while
/// `Util/Search/Results` takes text but supports neither a category filter nor a
/// sort, and silently caps at 15 per page. Modelling them as one "query with an
/// optional string" would quietly promise filters that search cannot honour.
enum MarketplaceMode { browse, search }

/// Everything that identifies one page of results.
///
/// Immutable and value-equal so the results provider re-fetches exactly when
/// something meaningful changed — typing in the search box without submitting
/// must not fire a request per keystroke.
class MarketplaceQuery {
  const MarketplaceQuery({
    this.mode = MarketplaceMode.browse,
    this.text = '',
    this.categoryId,
    this.sort = kDefaultMarketplaceSort,
    this.page = 1,
  });

  final MarketplaceMode mode;

  /// The submitted search text. Only meaningful in [MarketplaceMode.search].
  final String text;

  /// A `Generic_Category` id — a root category or a character. Browse only.
  final int? categoryId;

  /// Browse only; search has no sort control.
  final GbModSort sort;

  /// 1-based.
  final int page;

  MarketplaceQuery copyWith({
    MarketplaceMode? mode,
    String? text,
    int? categoryId,
    bool clearCategory = false,
    GbModSort? sort,
    int? page,
  }) {
    return MarketplaceQuery(
      mode: mode ?? this.mode,
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
    MarketplaceMode? mode,
    String? text,
    int? categoryId,
    bool clearCategory = false,
    GbModSort? sort,
  }) =>
      copyWith(
        mode: mode,
        text: text,
        categoryId: categoryId,
        clearCategory: clearCategory,
        sort: sort,
        page: 1,
      );

  @override
  bool operator ==(Object other) =>
      other is MarketplaceQuery &&
      other.mode == mode &&
      other.text == text &&
      other.categoryId == categoryId &&
      other.sort == sort &&
      other.page == page;

  @override
  int get hashCode => Object.hash(mode, text, categoryId, sort, page);
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

  if (query.mode == MarketplaceMode.search) {
    return client.searchMods(query.text, page: query.page);
  }
  return client.browseMods(
    categoryId: query.categoryId,
    sort: query.sort,
    page: query.page,
  );
});

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
