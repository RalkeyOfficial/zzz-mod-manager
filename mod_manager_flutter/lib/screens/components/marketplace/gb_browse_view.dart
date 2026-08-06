import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import 'gb_category_panel.dart';
import 'gb_mod_card.dart';
import 'gb_top_subs_carousel.dart';

/// The results grid: search box + sort + category/character filters over a grid
/// of mod cards, with paging.
class GbBrowseView extends ConsumerWidget {
  const GbBrowseView({super.key, required this.onOpenMod});

  final void Function(int modId) onOpenMod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(marketplaceResultsProvider);
    final filter = ref.watch(contentFilterProvider);
    final query = ref.watch(marketplaceQueryProvider);
    // While the library snapshot loads, `empty` means "nothing is known to be
    // installed" — no badge, rather than a badge that might be wrong.
    final installed = ref.watch(installedModsIndexProvider).valueOrNull ??
        InstalledModsIndex.empty;

    // "All" means browsing with no category — not merely page 1, so the carousel
    // doesn't vanish and re-appear as the user pages through the grid.
    final isAllView =
        query.mode == MarketplaceMode.browse && query.categoryId == null;

    final scheme = Theme.of(context).colorScheme;

    // Categories live in a column on the right, the way GameBanana's own site
    // presents them, rather than as a horizontal chip strip across the top.
    //
    // Laid out as two bands rather than two columns: the top band holds the filter
    // controls *and* the categories header side by side, so they share one height
    // and one continuous bottom border no matter what either contains. Nesting the
    // header inside the right-hand column instead would mean matching its padding
    // to the filter bar's by hand — which is how they came to disagree, and would
    // break again the moment the filter bar gained its second line while searching.
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
          // IntrinsicHeight is required, not decorative. `stretch` makes the Row
          // pass a *tight* cross-axis constraint to its children — and this Row
          // sits directly in a Column, so its incoming maxHeight is unbounded.
          // Without IntrinsicHeight the two cells are handed an infinite height.
          // IntrinsicHeight resolves the band to the tallest child's natural
          // height (the filter bar) first, which is exactly the height wanted.
          child: const IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _FilterBar()),
                GbCategoryPanelHeader(),
              ],
            ),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      // One scroll view holding the carousel *and* the grid, so
                      // the carousel scrolls away with the content instead of
                      // being pinned above it. That is the reason the grid is a
                      // `SliverGrid` here rather than a `GridView`: two nested
                      // scrollables would either fight or need a fixed-height
                      // carousel, and neither scrolls naturally.
                      child: CustomScrollView(
                        slivers: [
                          // Only on the unfiltered "All" view: a fixed game-wide
                          // "best of" list stops being about what the user is
                          // looking at the moment they filter or search.
                          //
                          // Outside the `results.when` below on purpose — the
                          // carousel loads independently of the listing, so it
                          // stays put while the grid is loading, erroring or
                          // empty rather than flickering in and out with it.
                          if (isAllView)
                            SliverToBoxAdapter(
                              child: GbTopSubsCarousel(onOpenMod: onOpenMod),
                            ),
                          ...results.when(
                            loading: () => const [
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                    child: CircularProgressIndicator()),
                              ),
                            ],
                            error: (error, _) => [
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: _ErrorState(error: error),
                              ),
                            ],
                            data: (page) => _resultSlivers(
                              context,
                              page: page,
                              filter: filter,
                              onOpenMod: onOpenMod,
                              installed: installed,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Stays put below the scroll view: paging is navigation, and
                    // having to scroll to the bottom to reach it would be worse
                    // the longer the page is.
                    if (results.valueOrNull case final page?)
                      _Pager(page: page),
                  ],
                ),
              ),
              const GbCategoryList(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The grid (or an empty state) as **slivers**, so they share one scroll view with
/// the carousel above them.
///
/// A function rather than a widget: its whole job is to contribute slivers to a
/// caller's `CustomScrollView`, and a widget returning a sliver cannot be dropped
/// into a box context by mistake — whereas a `List<Widget>` of slivers spread with
/// `...` reads exactly as what it is at the call site.
List<Widget> _resultSlivers(
  BuildContext context, {
  required GbPage<GbMod> page,
  required ContentFilterMode filter,
  required void Function(int modId) onOpenMod,
  required InstalledModsIndex installed,
}) {
  final loc = context.loc;

  // The filter is applied here rather than in the provider so that switching it is
  // instant and re-uses the fetched page instead of issuing a request.
  final visible = <(GbMod, ContentTreatment)>[
    for (final mod in page.records)
      if (contentTreatment(mod.effectiveVisibility, filter)
          case final treatment when treatment != ContentTreatment.omit)
        (mod, treatment),
  ];

  if (visible.isEmpty) {
    // Two genuinely different empty states. "Your filter hid all of these" is
    // actionable; "there is nothing here" is not, and showing the wrong one sends
    // the user hunting for a mod that was never in the results.
    final hiddenByFilter = page.records.isNotEmpty;
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: _EmptyState(
          message: loc.t(hiddenByFilter
              ? 'marketplace.empty_filtered'
              : 'marketplace.empty_results'),
          icon:
              hiddenByFilter ? Icons.visibility_off_outlined : Icons.search_off,
        ),
      ),
    ];
  }

  return [
    SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 300,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          // A fixed height rather than `childAspectRatio`, deliberately. With an
          // aspect ratio the tile gets *shorter as it gets narrower*, while the
          // text block below the cover needs a constant height — so the card
          // overflowed its bottom below ~179px wide. Tile width here ranges over
          // roughly 150–300px depending on window and sidebar state, which left
          // only ~20px of margin.
          //
          // Fixing the height decouples the two: the text block always has the
          // same room and the cover (an Expanded in GbModCard) takes whatever is
          // left, so its aspect varies with width instead of the layout breaking.
          // 240 gives a 16:9-ish cover at a typical ~245px tile.
          mainAxisExtent: 240,
        ),
        delegate: SliverChildBuilderDelegate(
          childCount: visible.length,
          (context, index) {
            final (mod, treatment) = visible[index];
            return GbModCard(
              mod: mod,
              treatment: treatment,
              onOpen: () => onOpenMod(mod.idRow),
              installedAs: installed.installsOfMod(mod.idRow),
            );
          },
        ),
      ),
    ),
  ];
}

class _Pager extends ConsumerWidget {
  const _Pager({required this.page});

  final GbPage<GbMod> page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final query = ref.watch(marketplaceQueryProvider);
    final total = page.pageCount;
    final canGoBack = query.page > 1;
    // `_bIsComplete` is the server's own "this page exhausts the set", which is
    // more reliable than comparing a computed page count — search reports a
    // per-page it silently capped.
    final canGoForward = !page.isComplete &&
        (total == null || query.page < total);

    void go(int page) => ref.read(marketplaceQueryProvider.notifier).state =
        query.copyWith(page: page);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: canGoBack ? () => go(query.page - 1) : null,
            icon: const Icon(Icons.chevron_left),
            tooltip: loc.t('marketplace.prev_page'),
          ),
          Text(
            total == null
                ? loc.t('marketplace.page_of_unknown',
                    params: {'page': '${query.page}'})
                : loc.t('marketplace.page_of',
                    params: {'page': '${query.page}', 'total': '$total'}),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          IconButton(
            onPressed: canGoForward ? () => go(query.page + 1) : null,
            icon: const Icon(Icons.chevron_right),
            tooltip: loc.t('marketplace.next_page'),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends ConsumerStatefulWidget {
  const _FilterBar();

  @override
  ConsumerState<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends ConsumerState<_FilterBar> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Submitting empty text returns to browsing rather than searching for "",
  /// which would be an endpoint call with nothing to find.
  void _submitSearch(String raw) {
    final text = raw.trim();
    final notifier = ref.read(marketplaceQueryProvider.notifier);
    notifier.state = text.isEmpty
        ? notifier.state.refine(mode: MarketplaceMode.browse, text: '')
        : notifier.state.refine(mode: MarketplaceMode.search, text: text);
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;
    final query = ref.watch(marketplaceQueryProvider);
    final isSearching = query.mode == MarketplaceMode.search;

    // Picking a category exits search mode (search cannot take a category filter),
    // so the box has to stop showing a term that is no longer being applied.
    //
    // Through `ref.listen`, never inline in build. `_search.clear()` notifies the
    // controller's listeners, one of which is the TextField built right below it —
    // so clearing during build scheduled another build, every frame, forever. That
    // showed up as an endless `!semantics.parentDataDirty` assertion rather than as
    // anything mentioning the controller. `ref.listen`'s callback runs *after* the
    // provider changes, outside the build phase, which is where a mutation like
    // this belongs.
    ref.listen(marketplaceQueryProvider, (previous, next) {
      final leftSearch = next.mode == MarketplaceMode.browse && next.text.isEmpty;
      if (leftSearch && _search.text.isNotEmpty) _search.clear();
    });

    // Padding only — the background and the bottom border belong to the shared
    // band in GbBrowseView, so this cell and the categories header beside it can't
    // end up with different heights or a broken divider line.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _submitSearch,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: loc.t('marketplace.search_hint'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    suffixIcon: isSearching
                        ? IconButton(
                            tooltip: loc.t('marketplace.clear_search'),
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              _submitSearch('');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Search supports no sort at all, so the control is disabled
              // rather than silently ignored while searching.
              _SortMenu(enabled: !isSearching),
              const SizedBox(width: 6),
              const _ContentFilterMenu(),
              const SizedBox(width: 6),
              const _RefreshButton(),
            ],
          ),
          if (isSearching)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      loc.t('marketplace.search_scope_note'),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The refresh button, which spins while the request is in flight.
///
/// The spin is not decoration. Refresh previously gave no signal whatsoever — and
/// worse, no *result*, because it re-read the client's 10-minute cache and got the
/// identical page back (see `refreshMarketplaceResults`). Now that it genuinely
/// re-fetches, the animation is what tells the user the click landed, since a
/// listing that has not changed upstream looks exactly the same afterwards.
class _RefreshButton extends ConsumerStatefulWidget {
  const _RefreshButton();

  @override
  ConsumerState<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends ConsumerState<_RefreshButton>
    with SingleTickerProviderStateMixin {
  /// One full turn per revolution.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Keep spinning at least this long, even when the response beats it.
  ///
  /// The point of the whole change: a warm CDN answers in tens of milliseconds, so
  /// without a floor the icon would turn for a frame or two and the click would look
  /// ignored again — the exact complaint, just faster.
  static const Duration _minimumSpin = Duration(milliseconds: 650);

  bool _busy = false;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    _spin.repeat();

    final stopwatch = Stopwatch()..start();
    try {
      await refreshMarketplaceResults(ref);
    } catch (_) {
      // Swallowed here on purpose: invalidating the provider surfaces the failure
      // through the grid's own error state, which is where the user is looking.
      // Re-throwing would only produce an unhandled async error.
    } finally {
      final remaining = _minimumSpin - stopwatch.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      if (mounted) {
        _spin.stop();
        _spin.value = 0;
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return IconButton(
      // Disabled while running, so a second press can't stack another request —
      // and the greyed-out state is itself a signal that something is happening.
      onPressed: _busy ? null : _refresh,
      tooltip: loc.t(_busy ? 'marketplace.refreshing' : 'marketplace.reload'),
      icon: RotationTransition(
        turns: _spin,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final query = ref.watch(marketplaceQueryProvider);

    return PopupMenuButton<GbModSort>(
      enabled: enabled,
      tooltip: loc.t('marketplace.sort'),
      icon: Icon(Icons.sort, color: enabled ? null : Theme.of(context).disabledColor),
      initialValue: query.sort,
      // Both, in this order: the query so the grid refetches now, and config so the
      // choice is still there next launch.
      onSelected: (sort) {
        ref.read(marketplaceQueryProvider.notifier).state =
            query.refine(sort: sort);
        ApiService.setMarketplaceSort(sort);
      },
      itemBuilder: (context) => [
        for (final sort in GbModSort.values)
          PopupMenuItem(
            value: sort,
            child: Text(loc.t('marketplace.sort_${sort.name}')),
          ),
      ],
    );
  }
}

class _ContentFilterMenu extends ConsumerWidget {
  const _ContentFilterMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final mode = ref.watch(contentFilterProvider);

    return PopupMenuButton<ContentFilterMode>(
      tooltip: loc.t('marketplace.content_filter'),
      icon: Icon(switch (mode) {
        ContentFilterMode.blur => Icons.blur_on,
        ContentFilterMode.show => Icons.visibility_outlined,
        ContentFilterMode.hide => Icons.visibility_off_outlined,
      }),
      initialValue: mode,
      // Both, in this order: the provider so the grid re-filters this frame
      // without refetching, and config so the choice survives a restart.
      onSelected: (value) {
        ref.read(contentFilterProvider.notifier).state = value;
        ApiService.setContentFilter(value);
      },
      itemBuilder: (context) => [
        for (final value in ContentFilterMode.values)
          PopupMenuItem(
            value: value,
            child: Text(loc.t('marketplace.content_filter_${value.wire}')),
          ),
      ],
    );
  }
}


class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final scheme = Theme.of(context).colorScheme;

    // Offline is by far the most common failure and is not a bug, so it gets
    // its own wording instead of a stack-trace-shaped message.
    final isNetwork = error is GbNetworkException;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNetwork ? Icons.wifi_off : Icons.error_outline,
              size: 44,
              color: scheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              loc.t(isNetwork
                  ? 'marketplace.error_offline'
                  : 'marketplace.error_generic'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              error is GbException ? (error as GbException).message : '$error',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => ref.invalidate(marketplaceResultsProvider),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(loc.t('marketplace.retry')),
            ),
          ],
        ),
      ),
    );
  }
}
