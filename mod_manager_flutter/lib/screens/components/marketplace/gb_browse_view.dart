import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import '../settings/marketplace_section.dart' show ContentFilterWriter;
import '../zenith_controls.dart';
import '../zenith_switch.dart';
import 'gb_character_picker.dart';
import 'gb_mod_card.dart';
import 'gb_state_view.dart';
import 'gb_top_subs_carousel.dart';

/// Persists the browse sort. Defaults to [ApiService.setMarketplaceSort].
typedef MarketplaceSortWriter = Future<void> Function(GbModSort sort);

/// Persists the Hide installed switch. Defaults to [ApiService.setMarketplaceHideInstalled].
typedef HideInstalledWriter = Future<void> Function(bool hide);

/// The Browse page: the title and search, the "best of" carousel, the filter bar pinned at the top as the page
/// scrolls, and the grid of mod cards, which loads the next page as the scroll nears its end.
class GbBrowseView extends ConsumerStatefulWidget {
  const GbBrowseView({
    super.key,
    required this.onOpenMod,
    this.onInstallFile,
    this.contentFilterWriter,
    this.sortWriter,
    this.hideInstalledWriter,
    this.carouselAutoAdvance = GbTopSubsCarousel.defaultAutoAdvanceInterval,
  });

  final void Function(int modId) onOpenMod;

  /// Queues one file of a mod as an install: a card's or the carousel's Install, for a mod with one current file.
  final void Function(int modId, GbFile file)? onInstallFile;

  /// Persists the content filter, from the Mature content menu and from the "everything here is hidden" empty
  /// state. Defaults to [ApiService.setContentFilter].
  ///
  /// The three writers are seams because `ApiService` lazily builds a `ConfigService` against the developer's
  /// **real** `<appData>/config.json` — a widget test that pressed one without a seam would rewrite their own
  /// settings.
  final ContentFilterWriter? contentFilterWriter;

  final MarketplaceSortWriter? sortWriter;
  final HideInstalledWriter? hideInstalledWriter;

  /// The carousel's dwell, or null to hold it still; a test passes null.
  final Duration? carouselAutoAdvance;

  @override
  ConsumerState<GbBrowseView> createState() => _GbBrowseViewState();
}

class _GbBrowseViewState extends ConsumerState<GbBrowseView> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Asks for the next page once the scroll is within one viewport of the end. Also run after every frame that
  /// built the grid, since a page whose cards Hide installed or the content filter dropped may leave nothing to
  /// scroll, and then no scroll would ever ask. A failed page waits for its Try again, and so does a failed first
  /// page, whose error state stands in for the grid while the feed still holds the previous query's pages.
  void _maybeLoadMore() {
    if (!mounted || !_scroll.hasClients) return;
    final listing = ref.read(marketplaceFeedProvider);
    final feed = listing.valueOrNull;
    if (listing.hasError || feed == null || feed.isComplete || feed.loadingMore || feed.loadMoreError != null) return;
    final position = _scroll.position;
    if (position.extentAfter <= position.viewportDimension) {
      ref.read(marketplaceFeedProvider.notifier).loadMore();
    }
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _setHideInstalled(bool hide) {
    ref.read(marketplaceHideInstalledProvider.notifier).state = hide;
    (widget.hideInstalledWriter ?? ApiService.setMarketplaceHideInstalled)(hide);
  }

  void _setContentFilter(ContentFilterMode mode) {
    // Both, in this order: the provider so the grid re-filters this frame without refetching, and config so the
    // choice survives a restart.
    ref.read(contentFilterProvider.notifier).state = mode;
    (widget.contentFilterWriter ?? ApiService.setContentFilter)(mode);
  }

  @override
  Widget build(BuildContext context) {
    // A new query is a new listing, read from the top.
    ref.listen(marketplaceQueryProvider, (_, _) => _toTop());

    final query = ref.watch(marketplaceQueryProvider);
    final feed = ref.watch(marketplaceFeedProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        const SliverToBoxAdapter(child: _Header()),
        // Whenever no search is typed, whatever the chips say: a search names what the user is after, and a
        // game-wide best-of list above it would only push the answer down.
        if (!query.hasText)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
              child: GbTopSubsCarousel(
                onOpenMod: widget.onOpenMod,
                onInstallFile: widget.onInstallFile,
                autoAdvanceInterval: widget.carouselAutoAdvance,
              ),
            ),
          ),
        // Pinned and sized to its content, which wraps to a second line in a narrow window.
        PinnedHeaderSliver(
          child: _FilterBar(
            onHideInstalled: _setHideInstalled,
            onContentFilter: _setContentFilter,
            sortWriter: widget.sortWriter ?? ApiService.setMarketplaceSort,
            onRefreshed: _toTop,
          ),
        ),
        ...feed.when(
          loading: () => const [
            SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())),
          ],
          error: (error, _) => [
            SliverFillRemaining(
              hasScrollBody: false,
              child: GbFailureState(error: error, onRetry: () => ref.invalidate(marketplaceFeedProvider)),
            ),
          ],
          data: (feed) => _results(context, feed),
        ),
      ],
    );
  }

  /// The grid and what is under it, or the empty state that replaces them, as slivers.
  List<Widget> _results(BuildContext context, MarketplaceFeed feed) {
    final filter = ref.watch(contentFilterProvider);
    final hideInstalled = ref.watch(marketplaceHideInstalledProvider);
    // While the library snapshot loads, `empty` means "nothing is known to be installed" — no badge, rather than a
    // badge that might be wrong.
    final installed = ref.watch(installedModsIndexProvider).valueOrNull ?? InstalledModsIndex.empty;
    final enrichment = <int, GbMod>{
      for (final page in feed.pages)
        ...?ref.watch(modEnrichmentProvider(ModIdList([for (final mod in page) mod.idRow]))).valueOrNull,
    };

    // Both filters drop records on the client, so switching either is instant and re-uses the loaded pages.
    final records = feed.records;
    final filtered = <(GbMod, ContentTreatment)>[
      for (final mod in records)
        if (contentTreatment(mod.effectiveVisibility, filter) case final treatment
            when treatment != ContentTreatment.omit)
          (mod, treatment),
    ];
    final visible = hideInstalled
        ? [
            for (final entry in filtered)
              if (!installed.hasMod(entry.$1.idRow)) entry,
          ]
        : filtered;

    if (visible.isEmpty && feed.isComplete) {
      // Three different claims, and showing the wrong one sends the user hunting for a mod that was never in the
      // results. "Every one installed" holds only when Hide installed dropped every record; one the content filter
      // dropped is not installed as far as anyone knows, so then it is the content filter's state.
      final Widget state;
      if (records.isEmpty) {
        state = _noResults(context);
      } else if (filtered.length < records.length) {
        state = _allFiltered(context, alsoInstalled: filtered.isNotEmpty);
      } else {
        state = _allInstalled(context);
      }
      return [SliverFillRemaining(hasScrollBody: false, child: state)];
    }

    final extentFor = GbModCard.extentFor;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
        sliver: SliverGrid(
          gridDelegate: GbCardGridDelegate(
            tileExtent: (width) => extentFor(context, width),
            textBlockHeight: GbModCard.textBlockHeight(context),
            itemCount: visible.length,
          ),
          delegate: SliverChildBuilderDelegate(childCount: visible.length, (context, index) {
            final (mod, treatment) = visible[index];
            return GbModCard(
              mod: mod,
              treatment: treatment,
              enrichment: enrichment[mod.idRow],
              installedAs: installed.installsOfMod(mod.idRow),
              onOpen: () => widget.onOpenMod(mod.idRow),
              onInstallFile: widget.onInstallFile == null ? null : (file) => widget.onInstallFile!(mod.idRow, file),
            );
          }),
        ),
      ),
      SliverToBoxAdapter(child: _Footer(feed: feed)),
    ];
  }

  /// Nothing came back. A search offers to clear itself; an ordinary browse has nothing to offer, and an empty
  /// state with a button that cannot help is worse than one that simply says so.
  Widget _noResults(BuildContext context) {
    final loc = context.loc;
    final query = ref.watch(marketplaceQueryProvider);
    return GbStateView(
      icon: Icons.search_off,
      title: loc.t('marketplace.empty_results'),
      action: query.hasText
          ? FilledButton.icon(
              // Exactly what submitting an empty box does, so the search field empties itself: the header listens
              // for the text going away.
              onPressed: () => ref.read(marketplaceQueryProvider.notifier).state = query.withText(''),
              icon: const Icon(Icons.close, size: 16),
              label: Text(loc.t('marketplace.empty_search_action')),
            )
          : null,
    );
  }

  /// Nothing is left to show and the content filter dropped at least one record. With [alsoInstalled], Hide
  /// installed dropped the rest, and the title names both.
  Widget _allFiltered(BuildContext context, {required bool alsoInstalled}) =>
      GbAllFilteredState(alsoInstalled: alsoInstalled, onBlur: () => _setContentFilter(ContentFilterMode.blur));

  /// Hide installed dropped every record the listing has.
  Widget _allInstalled(BuildContext context) => GbAllInstalledState(onShowInstalled: () => _setHideInstalled(false));
}

/// The Hide installed switch and its label, on Browse's filter bar and a creator's page.
class GbHideInstalledToggle extends StatelessWidget {
  const GbHideInstalledToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        ZenithSwitch(value: value, semanticLabel: loc.t('marketplace.hide_installed'), onChanged: onChanged),
        Text(
          loc.t('marketplace.hide_installed'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).text2),
        ),
      ],
    );
  }
}

/// Auto-fill columns at least [minCrossAxisExtent] wide, and a tile as tall as [tileExtent] says for the column
/// width: the card's 4:3 cover plus its fixed text block.
///
/// A fixed extent, never `childAspectRatio`: with a ratio the tile gets shorter as it gets narrower while the text
/// block needs the same height, so the card would overflow its bottom at the narrow end.
class GbCardGridDelegate extends SliverGridDelegate {
  const GbCardGridDelegate({
    required this.tileExtent,
    required this.textBlockHeight,
    required this.itemCount,
    this.minCrossAxisExtent = 230,
    this.spacing = 18,
  });

  final double Function(double width) tileExtent;

  /// The card's text block height, which [tileExtent] depends on; a change relays the grid out.
  final double textBlockHeight;

  /// How many cards the grid holds. A change relays it out: a page appended past the built cards changes no child,
  /// so without this the grid keeps its old scroll extent, and the scroll check reads the end as near and asks for
  /// page after page.
  final int itemCount;

  final double minCrossAxisExtent;
  final double spacing;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    final columns = math.max(1, ((width + spacing) / (minCrossAxisExtent + spacing)).floor());
    final columnWidth = (width - spacing * (columns - 1)) / columns;
    final extent = tileExtent(columnWidth);
    return SliverGridRegularTileLayout(
      crossAxisCount: columns,
      mainAxisStride: extent + spacing,
      crossAxisStride: columnWidth + spacing,
      childMainAxisExtent: extent,
      childCrossAxisExtent: columnWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(GbCardGridDelegate oldDelegate) =>
      oldDelegate.textBlockHeight != textBlockHeight ||
      oldDelegate.itemCount != itemCount ||
      oldDelegate.minCrossAxisExtent != minCrossAxisExtent ||
      oldDelegate.spacing != spacing;
}

/// Under the grid: the ring while the next page loads, Try again when it failed, and nothing once the last page
/// is in.
class _Footer extends ConsumerWidget {
  const _Footer({required this.feed});

  final MarketplaceFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(color: palette.text3);

    final Widget? content;
    if (feed.loadingMore) {
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 10,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent, backgroundColor: palette.line),
          ),
          Text(loc.t('marketplace.loading_more'), style: style),
        ],
      );
    } else if (feed.loadMoreError != null) {
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 10,
        children: [
          Text(loc.t('marketplace.load_more_failed'), style: style),
          OutlinedButton(
            style: smallButtonStyle(context),
            onPressed: () => ref.read(marketplaceFeedProvider.notifier).loadMore(),
            child: Text(loc.t('marketplace.retry')),
          ),
        ],
      );
    } else {
      content = null;
    }

    return Padding(padding: EdgeInsets.fromLTRB(32, content == null ? 0 : 26, 32, 32), child: content);
  }
}

/// "Browse" and its subtitle, and the search field on the right.
class _Header extends ConsumerStatefulWidget {
  const _Header();

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The trimmed text becomes the name filter; empty text lifts it. Either way the chips and the sort stay as they
  /// are.
  void _submit(String raw) {
    final notifier = ref.read(marketplaceQueryProvider.notifier);
    notifier.state = notifier.state.withText(raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final searching = ref.watch(marketplaceQueryProvider.select((q) => q.hasText));

    // The empty state's "Clear search" lifts the filter from outside this widget, so the box has to stop showing a
    // term that is no longer being applied.
    //
    // Through `ref.listen`, never inline in build. `_search.clear()` notifies the controller's listeners, one of
    // which is the TextField built right below it — so clearing during build scheduled another build, every frame,
    // forever. `ref.listen`'s callback runs after the provider changes, outside the build phase.
    ref.listen(marketplaceQueryProvider, (previous, next) {
      if (!next.hasText && _search.text.isNotEmpty) _search.clear();
    });

    const fieldHeight = 40.0;
    final line = text.bodyLarge!.fontSize! * text.bodyLarge!.height!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              spacing: 12,
              children: [
                Text(loc.t('marketplace.title'), style: text.headlineLarge!.copyWith(color: palette.text)),
                Flexible(
                  child: Text(
                    loc.t('marketplace.subtitle'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium!.copyWith(color: palette.text3),
                  ),
                ),
              ],
            ),
            SizedBox(
              width: math.min(420, constraints.maxWidth),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: _submit,
                style: text.bodyLarge!.copyWith(color: palette.text),
                decoration: InputDecoration(
                  constraints: const BoxConstraints.tightFor(height: fieldHeight),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: (fieldHeight - line) / 2),
                  prefixIconConstraints: const BoxConstraints(minWidth: fieldHeight, minHeight: fieldHeight),
                  suffixIconConstraints: const BoxConstraints(minWidth: fieldHeight, minHeight: fieldHeight),
                  prefixIcon: const Icon(Icons.search_rounded, size: 16),
                  hintText: loc.t('marketplace.search_hint'),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: loc.t('marketplace.clear_search'),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () {
                            _search.clear();
                            _submit('');
                          },
                        )
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chips on the left — the character, then one per type — and Hide installed, Mature content, Sort and Refresh
/// on the right, on the page ground with a divider under it.
class _FilterBar extends ConsumerWidget {
  const _FilterBar({
    required this.onHideInstalled,
    required this.onContentFilter,
    required this.sortWriter,
    required this.onRefreshed,
  });

  final ValueChanged<bool> onHideInstalled;
  final ValueChanged<ContentFilterMode> onContentFilter;
  final MarketplaceSortWriter sortWriter;
  final VoidCallback onRefreshed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final query = ref.watch(marketplaceQueryProvider);
    final roots = ref.watch(rootCategoriesProvider).valueOrNull ?? const <GbCategoryNode>[];
    final hideInstalled = ref.watch(marketplaceHideInstalledProvider);

    void setQuery(MarketplaceQuery next) => ref.read(marketplaceQueryProvider.notifier).state = next;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      decoration: BoxDecoration(
        color: palette.ground,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: _EndWrap(
        spacing: 14,
        runSpacing: 10,
        start: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GbCharacterPicker(query: query, onChanged: setQuery),
            if (roots.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(width: 1, height: 20, child: ColoredBox(color: palette.line)),
              ),
            // The live roots decide which types exist; the order and the short labels are the map's.
            for (final root in _inChipOrder(roots))
              ZenithChip(
                label: switch (kTypeChipLabelKeys[root.idRow]) {
                  final key? => loc.t(key),
                  null => root.name ?? '#${root.idRow}',
                },
                selected: query.typeId == root.idRow,
                // Single-select: the chip that is on turns off, back to every mod.
                onTap: () => setQuery(query.withType(query.typeId == root.idRow ? null : root.idRow)),
              ),
          ],
        ),
        end: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 14,
          children: [
            GbHideInstalledToggle(value: hideInstalled, onChanged: onHideInstalled),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                _MatureMenu(onChanged: onContentFilter),
                GbSortMenu(
                  sort: query.sort,
                  onChanged: (sort) {
                    // Both, in this order: the query so the grid refetches now, and config so the choice is still
                    // there next launch.
                    setQuery(query.withSort(sort));
                    sortWriter(sort);
                  },
                ),
                _RefreshButton(onRefreshed: onRefreshed),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The filter bar's two groups: side by side, the first at the start and the second at the end, or the second on a
/// line of its own under the first when they don't fit, still at the end. A `Wrap` aligns every run alike, so it
/// can't keep the first group at the start and the second at the end once they wrap.
class _EndWrap extends MultiChildRenderObjectWidget {
  _EndWrap({required Widget start, required Widget end, required this.spacing, required this.runSpacing})
    : super(children: [start, end]);

  /// The least room between the groups on one line.
  final double spacing;

  /// The room between the lines once they wrap.
  final double runSpacing;

  @override
  _RenderEndWrap createRenderObject(BuildContext context) => _RenderEndWrap(spacing: spacing, runSpacing: runSpacing);

  @override
  void updateRenderObject(BuildContext context, _RenderEndWrap renderObject) => renderObject
    ..spacing = spacing
    ..runSpacing = runSpacing;
}

class _EndWrapParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderEndWrap extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EndWrapParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EndWrapParentData> {
  _RenderEndWrap({required double spacing, required double runSpacing}) : _spacing = spacing, _runSpacing = runSpacing;

  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  double _runSpacing;
  set runSpacing(double value) {
    if (value == _runSpacing) return;
    _runSpacing = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EndWrapParentData) child.parentData = _EndWrapParentData();
  }

  @override
  void performLayout() {
    final start = firstChild!;
    final end = lastChild!;
    start.layout(constraints.loosen(), parentUsesSize: true);
    end.layout(constraints.loosen(), parentUsesSize: true);
    final width = constraints.maxWidth;
    final startData = start.parentData! as _EndWrapParentData;
    final endData = end.parentData! as _EndWrapParentData;
    if (start.size.width + _spacing + end.size.width <= width) {
      final height = math.max(start.size.height, end.size.height);
      startData.offset = Offset(0, (height - start.size.height) / 2);
      endData.offset = Offset(width - end.size.width, (height - end.size.height) / 2);
      size = constraints.constrain(Size(width, height));
    } else {
      startData.offset = Offset.zero;
      endData.offset = Offset(width - end.size.width, start.size.height + _runSpacing);
      size = constraints.constrain(Size(width, start.size.height + _runSpacing + end.size.height));
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}

/// A menu's caps header, such as SORT BY.
class _MenuHeader extends StatelessWidget {
  const _MenuHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Text(
      label.toUpperCase(),
      style: ZenithType.of(context).caps.copyWith(color: ZenithPalette.of(context).text3),
    ),
  );
}

/// The ✓ before the current choice in a menu, or the room for one.
Widget _menuCheck(BuildContext context, bool on) =>
    Icon(on ? Icons.check_rounded : null, size: 14, color: ZenithPalette.of(context).accent);

/// The width of the Mature content and Sort menus, as drawn.
const double _menuWidth = 236;

/// A [MenuAnchor] whose open menu takes Escape, however it was opened.
///
/// A click focuses nothing, so a menu opened by one would leave Escape to whatever is under it: on a creator's page,
/// going back a page with the menu still open. Opened by a click, it moves focus to a node around the button, under
/// the anchor's own dismiss action, rather than to the button itself, which would draw its focus ring. Opened from
/// the keyboard, focus is on the button already, under the same action, and stays there.
class _EscapableMenuAnchor extends StatefulWidget {
  const _EscapableMenuAnchor({
    required this.style,
    required this.alignmentOffset,
    required this.menuChildren,
    required this.builder,
  });

  final MenuStyle style;
  final Offset alignmentOffset;
  final List<Widget> menuChildren;
  final MenuAnchorChildBuilder builder;

  @override
  State<_EscapableMenuAnchor> createState() => _EscapableMenuAnchorState();
}

class _EscapableMenuAnchorState extends State<_EscapableMenuAnchor> {
  final FocusNode _anchorFocus = FocusNode(debugLabel: 'menu anchor', skipTraversal: true);

  @override
  void dispose() {
    _anchorFocus.dispose();
    super.dispose();
  }

  /// A click-open: a keyboard open finds focus on the button already, and keeps it there with its ring.
  void _onOpen() {
    if (!_anchorFocus.hasFocus) _anchorFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    onOpen: _onOpen,
    style: widget.style,
    alignmentOffset: widget.alignmentOffset,
    menuChildren: widget.menuChildren,
    builder: (context, controller, child) =>
        Focus(focusNode: _anchorFocus, child: widget.builder(context, controller, child)),
  );
}

/// The Mature content and Sort buttons' style, with the hover fill and a stronger border while their menu is open.
ButtonStyle _menuButtonStyle(BuildContext context, {required bool open}) {
  final style = smallButtonStyle(context);
  if (!open) return style;
  final palette = ZenithPalette.of(context);
  return style.copyWith(
    backgroundColor: WidgetStatePropertyAll(palette.hover),
    side: WidgetStatePropertyAll(BorderSide(color: palette.check)),
  );
}

/// The design's menu item: at least 34px tall with 10px sides, where Material's is 48.
const ButtonStyle _menuItemStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 34)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
);

/// The Mature content menu: the current mode's icon, and the three modes with what each does. It writes the
/// setting Settings shows.
class _MatureMenu extends ConsumerWidget {
  const _MatureMenu({required this.onChanged});

  final ValueChanged<ContentFilterMode> onChanged;

  static IconData _icon(ContentFilterMode mode) => switch (mode) {
    ContentFilterMode.blur => Icons.water_drop_outlined,
    ContentFilterMode.show => Icons.visibility_outlined,
    ContentFilterMode.hide => Icons.visibility_off_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mode = ref.watch(contentFilterProvider);

    String label(ContentFilterMode m) => loc.t(switch (m) {
      ContentFilterMode.blur => 'marketplace.content_filter_blur',
      ContentFilterMode.show => 'marketplace.content_filter_show',
      ContentFilterMode.hide => 'marketplace.content_filter_hide',
    });
    String description(ContentFilterMode m) => loc.t(switch (m) {
      ContentFilterMode.blur => 'marketplace.mature_blur_hint',
      ContentFilterMode.show => 'marketplace.mature_show_hint',
      ContentFilterMode.hide => 'marketplace.mature_hide_hint',
    });

    return _EscapableMenuAnchor(
      // Opens leftwards from the button's right edge, so it stays inside the window at the bar's right end.
      style: const MenuStyle(alignment: AlignmentDirectional.bottomEnd),
      alignmentOffset: const Offset(-_menuWidth, 4),
      menuChildren: [
        _MenuHeader(loc.t('marketplace.mature_content')),
        for (final m in ContentFilterMode.values)
          SizedBox(
            width: _menuWidth,
            child: MenuItemButton(
              style: _menuItemStyle,
              leadingIcon: _menuCheck(context, m == mode),
              onPressed: () => onChanged(m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label(m)),
                  Text(
                    description(m),
                    style: text.labelSmall!.copyWith(color: palette.text3, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ),
        Container(
          width: _menuWidth,
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.line)),
          ),
          child: Text(
            loc.t('marketplace.mature_settings_note'),
            style: text.labelSmall!.copyWith(color: palette.text3, fontWeight: FontWeight.w400),
          ),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: loc.t('marketplace.mature_tooltip', params: {'mode': label(mode)}),
        child: OutlinedButton(
          style: _menuButtonStyle(context, open: controller.isOpen),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Icon(_icon(mode), size: 16),
              Icon(Icons.expand_more_rounded, size: 12, color: palette.text3),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Sort menu: the current sort's label, and the six sorts. Browse's filter bar and a creator's page.
class GbSortMenu extends StatelessWidget {
  const GbSortMenu({super.key, required this.sort, required this.onChanged});

  final GbModSort sort;
  final ValueChanged<GbModSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    String label(GbModSort s) => loc.t('marketplace.sort_${s.name}');

    return _EscapableMenuAnchor(
      style: const MenuStyle(alignment: AlignmentDirectional.bottomEnd),
      alignmentOffset: const Offset(-_menuWidth, 4),
      menuChildren: [
        _MenuHeader(loc.t('marketplace.sort_by')),
        for (final s in kMarketplaceSorts)
          SizedBox(
            width: _menuWidth,
            child: MenuItemButton(
              style: _menuItemStyle,
              leadingIcon: _menuCheck(context, s == sort),
              onPressed: () => onChanged(s),
              child: Text(label(s)),
            ),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: loc.t('marketplace.sort_tooltip', params: {'sort': label(sort)}),
        child: OutlinedButton(
          style: _menuButtonStyle(context, open: controller.isOpen),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              const Icon(Icons.swap_vert_rounded, size: 16),
              Text(label(sort)),
              Icon(Icons.expand_more_rounded, size: 12, color: palette.text3),
            ],
          ),
        ),
      ),
    );
  }
}

/// The refresh button, which spins while the request is in flight.
///
/// The spin is not decoration: it is the only thing that tells the user the click
/// landed, since a listing that has not changed upstream looks identical
/// afterwards. The refresh bypasses the client's 10-minute cache so the press has
/// a result at all, and starts the grid again from page 1 at the top.
class _RefreshButton extends ConsumerStatefulWidget {
  const _RefreshButton({required this.onRefreshed});

  final VoidCallback onRefreshed;

  @override
  ConsumerState<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends ConsumerState<_RefreshButton> with SingleTickerProviderStateMixin {
  /// One full turn per revolution.
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  /// Keep spinning at least this long, even when the response beats it.
  ///
  /// A warm CDN answers in tens of milliseconds, so without a floor the icon would
  /// turn for a frame or two and the click would look ignored.
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
    var refreshed = false;
    try {
      await ref.read(marketplaceFeedProvider.notifier).refresh();
      refreshed = true;
    } catch (_) {
      // Swallowed on purpose: the grid already shows the cards it had, and the
      // listing's own error state is where a failure of the next read lands.
    } finally {
      final remaining = _minimumSpin - stopwatch.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      if (mounted) {
        _spin.stop();
        _spin.value = 0;
        setState(() => _busy = false);
        if (refreshed) widget.onRefreshed();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Tooltip(
      message: loc.t(_busy ? 'marketplace.refreshing' : 'marketplace.reload'),
      child: OutlinedButton(
        style: smallButtonStyle(context, iconOnly: true),
        // Disabled while running, so a second press can't stack another request.
        onPressed: _busy ? null : _refresh,
        child: RotationTransition(turns: _spin, child: const Icon(Icons.refresh_rounded, size: 16)),
      ),
    );
  }
}

/// [roots] in [kTypeChipLabelKeys]' order, with any root the map doesn't know after them in GameBanana's order.
List<GbCategoryNode> _inChipOrder(List<GbCategoryNode> roots) {
  final order = kTypeChipLabelKeys.keys.toList();
  int rank(int i) {
    final known = order.indexOf(roots[i].idRow);
    return known < 0 ? order.length + i : known;
  }

  final indices = [for (var i = 0; i < roots.length; i++) i]..sort((a, b) => rank(a).compareTo(rank(b)));
  return [for (final i in indices) roots[i]];
}
