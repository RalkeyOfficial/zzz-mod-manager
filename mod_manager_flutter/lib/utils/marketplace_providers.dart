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
    this.sort = GbModSort.newest,
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
final marketplaceQueryProvider =
    StateProvider<MarketplaceQuery>((ref) => const MarketplaceQuery());

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

/// The mod categories offered in the filter bar: the game's root categories
/// followed by the children of Character Skins (the live character roster).
///
/// One provider rather than two because the filter bar needs them together, and
/// there is no useful intermediate state where roots have loaded but characters
/// have not.
///
/// **No offline fallback to the local roster, deliberately.** The doc's earlier
/// plan was to fall back to `utils/zzz_characters.dart`, but that roster carries
/// no GameBanana category ids, and an id is the only thing `Generic_Category`
/// accepts — a name is not a filter value here. A local list could therefore
/// only render chips that cannot filter. It would also never help: this request
/// fails exactly when the listing request beside it fails, so the screen already
/// has one honest error state covering both.
final marketplaceCategoriesProvider =
    FutureProvider<MarketplaceCategories>((ref) async {
  final client = ref.watch(gameBananaClientProvider);
  final roots = await client.categories();
  final characters = await client.categories(
    categoryId: AppConstants.gameBananaCharacterSkinsCategoryId,
  );
  return MarketplaceCategories(roots: roots, characters: characters);
});

/// The filter bar's two category groups.
class MarketplaceCategories {
  const MarketplaceCategories({required this.roots, required this.characters});

  /// Character Skins, Bangboo Skins, Other/Misc, UI.
  final List<GbCategoryNode> roots;

  /// The children of Character Skins — in practice the character roster.
  final List<GbCategoryNode> characters;
}

/// The mod whose detail view is open, or null while browsing.
///
/// The marketplace tab lives inside the app's own tab switcher rather than a
/// `Navigator`, so "which screen" is state rather than a route.
final marketplaceOpenModProvider = StateProvider<int?>((ref) => null);
