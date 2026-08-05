import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import 'gb_mod_card.dart';

/// The results grid: search box + sort + category/character filters over a grid
/// of mod cards, with paging.
class GbBrowseView extends ConsumerWidget {
  const GbBrowseView({super.key, required this.onOpenMod});

  final void Function(int modId) onOpenMod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(marketplaceResultsProvider);
    final filter = ref.watch(contentFilterProvider);

    return Column(
      children: [
        const _FilterBar(),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorState(error: error),
            data: (page) => _Results(
              page: page,
              filter: filter,
              onOpenMod: onOpenMod,
            ),
          ),
        ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.page,
    required this.filter,
    required this.onOpenMod,
  });

  final GbPage<GbMod> page;
  final ContentFilterMode filter;
  final void Function(int modId) onOpenMod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;

    // The filter is applied here rather than in the provider so that switching
    // it is instant and re-uses the fetched page instead of issuing a request.
    final visible = <(GbMod, ContentTreatment)>[
      for (final mod in page.records)
        if (contentTreatment(mod.effectiveVisibility, filter)
            case final treatment when treatment != ContentTreatment.omit)
          (mod, treatment),
    ];

    if (visible.isEmpty) {
      // Two genuinely different empty states. "Your filter hid all of these" is
      // actionable; "there is nothing here" is not, and showing the wrong one
      // sends the user hunting for a mod that was never in the results.
      final hiddenByFilter = page.records.isNotEmpty;
      return _EmptyState(
        message: loc.t(hiddenByFilter
            ? 'marketplace.empty_filtered'
            : 'marketplace.empty_results'),
        icon: hiddenByFilter ? Icons.visibility_off_outlined : Icons.search_off,
      );
    }

    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              // Cover (16:9) plus roughly 92px of text block. Tuned to the
              // widest card so a two-line title never overflows.
              childAspectRatio: 0.86,
            ),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final (mod, treatment) = visible[index];
              return GbModCard(
                mod: mod,
                treatment: treatment,
                onOpen: () => onOpenMod(mod.idRow),
              );
            },
          ),
        ),
        _Pager(page: page),
      ],
    );
  }
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Column(
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
              IconButton(
                tooltip: loc.t('marketplace.reload'),
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ref.invalidate(marketplaceResultsProvider),
              ),
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
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _CategoryChips(),
            ),
        ],
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
      onSelected: (sort) => ref.read(marketplaceQueryProvider.notifier).state =
          query.refine(sort: sort),
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

class _CategoryChips extends ConsumerWidget {
  const _CategoryChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final query = ref.watch(marketplaceQueryProvider);
    final categories = ref.watch(marketplaceCategoriesProvider);

    void select(int? id) =>
        ref.read(marketplaceQueryProvider.notifier).state = query.refine(
          categoryId: id,
          clearCategory: id == null,
        );

    return SizedBox(
      height: 34,
      child: categories.when(
        // A thin strip, not a blocking spinner: the grid beside it is already
        // loading and two spinners read as two failures.
        loading: () => const SizedBox.shrink(),
        // Silent on error. The category list fails exactly when the listing
        // request beside it fails, and that error is already on screen; a second
        // message here would just be the same outage twice.
        error: (_, __) => const SizedBox.shrink(),
        data: (data) => ListView(
          scrollDirection: Axis.horizontal,
          children: [
            FilterChip(
              label: Text(loc.t('marketplace.filter_all')),
              selected: query.categoryId == null,
              onSelected: (_) => select(null),
            ),
            const SizedBox(width: 6),
            for (final node in data.roots) ...[
              FilterChip(
                label: Text(node.name ?? '#${node.idRow}'),
                selected: query.categoryId == node.idRow,
                onSelected: (_) => select(node.idRow),
              ),
              const SizedBox(width: 6),
            ],
            if (data.characters.isNotEmpty) ...[
              const VerticalDivider(width: 12),
              for (final node in data.characters) ...[
                FilterChip(
                  label: Text(node.name ?? '#${node.idRow}'),
                  selected: query.categoryId == node.idRow,
                  onSelected: (_) => select(node.idRow),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ],
        ),
      ),
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
