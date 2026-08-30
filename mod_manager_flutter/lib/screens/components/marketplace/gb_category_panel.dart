import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gb_category.dart';
import '../../../utils/marketplace_providers.dart';

/// Width of the category column, shared by its header cell and its list so the
/// two cannot drift apart.
const double kCategoryPanelWidth = 232;

BorderSide _panelDivider(ColorScheme scheme) =>
    BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4));

/// The category column's header cell, which sits in the **same horizontal band as
/// the search bar** rather than inside the panel.
///
/// That placement is the whole point. Inside the panel the header carries its own
/// padding, so its height is tuned independently of the filter bar's and the two
/// stop lining up — reliably again whenever the filter bar grows, which it does
/// when searching adds a second line. Putting both cells in one `Row` makes them
/// the same height by construction, gives them one continuous bottom border, and
/// lets the title centre itself in whatever height the band ends up.
class GbCategoryPanelHeader extends StatelessWidget {
  const GbCategoryPanelHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: kCategoryPanelWidth,
      decoration: BoxDecoration(border: Border(left: _panelDivider(scheme))),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      // Centered rather than padded: the band's height is set by the filter bar
      // beside it, so any fixed top/bottom padding here would be a guess that is
      // wrong as soon as that changes.
      alignment: Alignment.centerLeft,
      child: Text(
        context.loc.t('marketplace.categories'),
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The category filter list: expandable root categories with their icons,
/// mirroring how GameBanana's own site presents them.
///
/// Replaces a single horizontal strip of filter chips. That strip listed the ~60
/// children of Character Skins inline, which meant the character you wanted was
/// almost always somewhere off-screen behind a horizontal scroll with no
/// indication of how far. A tree keeps the four roots visible at once and puts the
/// long list behind one click, where its length is expected.
///
/// Children load on expand (`categoryChildrenProvider`), so opening the panel
/// costs one request rather than four.
class GbCategoryList extends ConsumerWidget {
  const GbCategoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final roots = ref.watch(rootCategoriesProvider);
    final query = ref.watch(marketplaceQueryProvider);

    return Container(
      width: kCategoryPanelWidth,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(left: _panelDivider(scheme)),
      ),
      child: roots.when(
        loading: () => const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        // Silent on error: this request fails exactly when the listing request
        // fails, and that error is already on screen. Two messages for one outage
        // reads as two problems.
        error: (_, __) => const SizedBox.shrink(),
        data: (nodes) => ListView(
          // No top padding: the first row must start flush against the band's
          // bottom border, which is what lines it up with the search bar.
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            _AllRow(selected: query.categoryId == null),
            for (final root in nodes) _RootRow(root: root),
          ],
        ),
      ),
    );
  }
}

class _AllRow extends ConsumerWidget {
  const _AllRow({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CategoryTile(
      label: context.loc.t('marketplace.filter_all'),
      selected: selected,
      icon: const Icon(Icons.apps, size: 18),
      onTap: () {
        ref.read(expandedCategoryProvider.notifier).state = null;
        selectCategory(ref, null);
      },
    );
  }
}

class _RootRow extends ConsumerWidget {
  const _RootRow({required this.root});

  final GbCategoryNode root;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(marketplaceQueryProvider);
    final expandedId = ref.watch(expandedCategoryProvider);
    final expanded = expandedId == root.idRow;

    void select(int id) => selectCategory(ref, id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CategoryTile(
          label: root.name ?? '#${root.idRow}',
          count: root.itemCount,
          selected: query.categoryId == root.idRow,
          icon: _CategoryIcon(url: root.iconUrl),
          // Tapping the row filters by the whole root — a root filter includes
          // its subcategories, so "all Character Skins" is a useful selection in
          // its own right and shouldn't require expanding first.
          onTap: () => select(root.idRow),
          trailing: root.hasChildren
              ? IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  tooltip: context.loc.t(
                    expanded
                        ? 'marketplace.collapse_category'
                        : 'marketplace.expand_category',
                  ),
                  onPressed: () =>
                      ref.read(expandedCategoryProvider.notifier).state =
                          expanded ? null : root.idRow,
                )
              : null,
        ),
        if (expanded) _Children(parentId: root.idRow, onSelect: select),
      ],
    );
  }
}

class _Children extends ConsumerWidget {
  const _Children({required this.parentId, required this.onSelect});

  final int parentId;
  final void Function(int id) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = ref.watch(categoryChildrenProvider(parentId));
    final query = ref.watch(marketplaceQueryProvider);

    return children.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (nodes) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final node in nodes)
            _CategoryTile(
              label: node.name ?? '#${node.idRow}',
              count: node.itemCount,
              selected: query.categoryId == node.idRow,
              icon: _CategoryIcon(url: node.iconUrl, size: 18),
              indent: 18,
              dense: true,
              onTap: () => onSelect(node.idRow),
            ),
        ],
      ),
    );
  }
}

/// Applies a category selection, leaving search mode if it was active.
///
/// `Util/Search/Results` accepts no category filter at all, so a category picked
/// while a search is showing could not be honoured. Silently ignoring the click
/// would be the worst option; switching back to browsing is what the click
/// evidently means.
void selectCategory(WidgetRef ref, int? categoryId) {
  final query = ref.read(marketplaceQueryProvider);
  ref.read(marketplaceQueryProvider.notifier).state = query.refine(
    mode: MarketplaceMode.browse,
    text: '',
    categoryId: categoryId,
    clearCategory: categoryId == null,
  );
}

/// A category's own icon from GameBanana, falling back to a generic glyph.
///
/// The urls point at small `ModCategory` images (some are animated GIFs, which
/// `Image.network` handles), so no size variants are involved — unlike mod
/// gallery images.
class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.url, this.size = 20});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Icon(Icons.folder_outlined, size: size);
    }
    return Image.network(
      url!,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, _, __) => Icon(Icons.folder_outlined, size: size),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
    this.count,
    this.trailing,
    this.indent = 0,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final Widget icon;
  final VoidCallback onTap;
  final int? count;
  final Widget? trailing;
  final double indent;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(10 + indent, dense ? 5 : 7, 6, dense ? 5 : 7),
          child: Row(
            children: [
              SizedBox(width: 22, child: Center(child: icon)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (dense
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.primary : null,
                  ),
                ),
              ),
              if (count case final n? when n > 0) ...[
                const SizedBox(width: 6),
                Text(
                  _compactCount(n),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (trailing != null) trailing! else const SizedBox(width: 30),
            ],
          ),
        ),
      ),
    );
  }

  static String _compactCount(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}
