import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../services/installed_mods_index.dart';
import '../../../utils/creator_cast.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';
import '../character_avatar.dart';
import '../character_tile.dart' show elementToneOf;
import '../page_crumbs.dart';
import '../settings/marketplace_section.dart' show ContentFilterWriter;
import '../zenith_controls.dart';
import 'gb_browse_view.dart';
import 'gb_mod_card.dart';
import 'gb_state_view.dart';

/// A creator's page in Browse, as the `BrowseCreator` artboard draws it: the member's avatar and name, how many of
/// their Zenless Zone Zero mods there are and how many the library has, a row of character tiles that filters them,
/// and a bar pinned over the grid with the count, Hide installed and Sort.
///
/// Every page of the member's mods is loaded ([creatorFeedProvider]), since the tiles and both counts are about the
/// whole set; the tile filter and Hide installed run on what is loaded, and a sort change fetches again.
class GbCreatorView extends ConsumerStatefulWidget {
  const GbCreatorView({
    super.key,
    required this.member,
    required this.onBack,
    required this.onBrowse,
    required this.onOpenMod,
    required this.onOpenInBrowser,
    this.parent,
    this.onInstallFile,
    this.hideInstalledWriter,
    this.contentFilterWriter,
  });

  final GbSubmitter member;

  /// Goes back one page, to the mod this page was opened from.
  final VoidCallback onBack;

  /// Goes back to the grid.
  final VoidCallback onBrowse;

  /// The page this one was opened from, the crumb between Browse and the member's name.
  final Crumb? parent;

  final void Function(int modId) onOpenMod;

  /// Queues one file of a mod as an install: a card's Install, for a mod with one current file.
  final void Function(int modId, GbFile file)? onInstallFile;

  final void Function(String url) onOpenInBrowser;

  /// Seams for tests, defaulting to `ApiService`, which writes the real `config.json`.
  final HideInstalledWriter? hideInstalledWriter;
  final ContentFilterWriter? contentFilterWriter;

  @override
  ConsumerState<GbCreatorView> createState() => _GbCreatorViewState();
}

class _GbCreatorViewState extends ConsumerState<GbCreatorView> {
  final ScrollController _scroll = ScrollController();

  /// This page's own sort, starting from Browse's and never saved.
  late GbModSort _sort;

  /// The tile that is on, by [CreatorGroup.key]; null for All mods.
  String? _tileKey;

  /// The listing the header, the tiles and the counts are drawn from. A new sort's listing takes over once it has
  /// finished loading or holds as many mods; until then the last one stays, since both are the same set of mods in
  /// another order, and the tile that is on stays on.
  MarketplaceFeed? _countedFeed;

  @override
  void initState() {
    super.initState();
    _sort = ref.read(marketplaceQueryProvider).sort;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  CreatorListing get _listing => CreatorListing(widget.member.idRow, _sort);

  String get _name => widget.member.name ?? '#${widget.member.idRow}';

  void _setSort(GbModSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _setHideInstalled(bool hide) {
    ref.read(marketplaceHideInstalledProvider.notifier).state = hide;
    (widget.hideInstalledWriter ?? ApiService.setMarketplaceHideInstalled)(hide);
  }

  void _setContentFilter(ContentFilterMode mode) {
    ref.read(contentFilterProvider.notifier).state = mode;
    (widget.contentFilterWriter ?? ApiService.setContentFilter)(mode);
  }

  String _label(AppLocalizations loc, CreatorGroup group) => group.name ?? loc.t(group.labelKey!);

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final url = widget.member.profileUrl ?? 'https://gamebanana.com/members/${widget.member.idRow}';
    return ColoredBox(
      color: palette.ground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageCrumbs(
            backTooltip: loc.t('marketplace.back'),
            onBack: widget.onBack,
            trail: [(label: loc.t('marketplace.title'), onTap: widget.onBrowse), ?widget.parent],
            current: _name,
            trailing: TextButton.icon(
              style: smallButtonStyle(context),
              onPressed: () => widget.onOpenInBrowser(url),
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(loc.t('marketplace.open_on_gamebanana')),
            ),
          ),
          Expanded(child: _body(context, loc)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations loc) {
    final listing = _listing;
    final async = ref.watch(creatorFeedProvider(listing));
    final feed = async.valueOrNull;
    final counted = _countedFeed;
    if (feed != null && (counted == null || !feed.loadingMore || feed.records.length >= counted.records.length)) {
      _countedFeed = feed;
    }
    final shown = _countedFeed;

    if (shown == null) {
      if (async.hasError) {
        return GbFailureState(error: async.error!, onRetry: () => ref.invalidate(creatorFeedProvider(listing)));
      }
      return const Center(child: CircularProgressIndicator());
    }

    final filter = ref.watch(contentFilterProvider);
    final hideInstalled = ref.watch(marketplaceHideInstalledProvider);
    // Null while the library loads: the header leaves out what it has, and no card claims a mod is installed.
    final library = ref.watch(installedModsIndexProvider).valueOrNull;
    final installed = library ?? InstalledModsIndex.empty;

    // The content filter drops records as Browse's does, before anything is counted.
    List<(GbMod, ContentTreatment)> listedOf(MarketplaceFeed f) => [
      for (final mod in f.records)
        if (contentTreatment(mod.effectiveVisibility, filter) case final treatment
            when treatment != ContentTreatment.omit)
          (mod, treatment),
    ];
    final listed = listedOf(shown);
    final cast = creatorCast([for (final (mod, _) in listed) mod], (group) => _label(loc, group));
    final tile = cast.where((t) => t.group.key == _tileKey).firstOrNull;
    final settled = feed != null && !feed.loadingMore;

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _Header(
          member: widget.member,
          name: _name,
          line: listed.isEmpty ? null : _headerLine(loc, listed, library),
          tiles: listed.isEmpty
              ? null
              : _CastRow(
                  cast: cast,
                  total: listed.length,
                  selected: tile?.group.key,
                  label: (group) => _label(loc, group),
                  onPick: (key) => setState(() => _tileKey = key == _tileKey ? null : key),
                ),
        ),
      ),
    ];

    if (shown.records.isEmpty && shown.isComplete) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: GbStateView(
            icon: Icons.person_search_outlined,
            title: loc.t('marketplace.creator.no_mods', params: {'name': _name}),
          ),
        ),
      );
      return CustomScrollView(controller: _scroll, slivers: slivers);
    }

    bool ofTile(GbMod mod) => tile == null || creatorGroupOf(mod) == tile.group;
    bool shownAtAll(GbMod mod) => !hideInstalled || !installed.hasMod(mod.idRow);
    final gridListed = feed == null ? null : (identical(feed, shown) ? listed : listedOf(feed));
    final visible = [
      for (final entry in gridListed ?? listed)
        if (ofTile(entry.$1) && shownAtAll(entry.$1)) entry,
    ];
    final unfiltered = [
      for (final entry in listed)
        if (shownAtAll(entry.$1)) entry,
    ];

    if (listed.isNotEmpty) {
      // Counted on the same listing as the tiles, so the bar does not drop to a page while a new sort loads.
      final count = unfiltered.where((entry) => ofTile(entry.$1)).length;
      final String countLine;
      if (tile != null) {
        countLine = loc.plural(
          'marketplace.creator.mods_for',
          count,
          params: {'count': '$count', 'name': _label(loc, tile.group)},
        );
      } else if (hideInstalled) {
        countLine = loc.plural('marketplace.creator.not_installed', count, params: {'count': '$count'});
      } else {
        countLine = loc.plural('marketplace.creator.all_mods', count, params: {'count': '$count'});
      }
      slivers.add(
        PinnedHeaderSliver(
          child: _Bar(
            countLine: countLine,
            showAll: tile == null
                ? null
                : loc.plural(
                    'marketplace.creator.show_all',
                    unfiltered.length,
                    params: {'count': '${unfiltered.length}'},
                  ),
            onShowAll: () => setState(() => _tileKey = null),
            hideInstalled: hideInstalled,
            onHideInstalled: _setHideInstalled,
            sort: _sort,
            onSort: _setSort,
          ),
        ),
      );
    }

    if (feed == null || async.isLoading) {
      slivers.add(
        async.hasError
            ? SliverFillRemaining(
                hasScrollBody: false,
                child: GbFailureState(error: async.error!, onRetry: () => ref.invalidate(creatorFeedProvider(listing))),
              )
            : const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())),
      );
      return CustomScrollView(controller: _scroll, slivers: slivers);
    }

    if (visible.isEmpty) {
      // Said once nothing more is loading, since a later page may bring a mod to show.
      if (settled) {
        slivers.add(
          SliverFillRemaining(
            hasScrollBody: false,
            child: listed.isEmpty
                ? GbAllFilteredState(alsoInstalled: false, onBlur: () => _setContentFilter(ContentFilterMode.blur))
                : GbAllInstalledState(onShowInstalled: () => _setHideInstalled(false)),
          ),
        );
      }
    } else {
      final enrichment = <int, GbMod>{
        for (final page in feed.pages)
          ...?ref.watch(modEnrichmentProvider(ModIdList([for (final mod in page) mod.idRow]))).valueOrNull,
      };
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
          sliver: SliverGrid(
            gridDelegate: GbCardGridDelegate(
              tileExtent: (width) => GbModCard.extentFor(context, width),
              textBlockHeight: GbModCard.textBlockHeight(context),
              itemCount: visible.length,
            ),
            delegate: SliverChildBuilderDelegate(childCount: visible.length, (context, index) {
              final (mod, treatment) = visible[index];
              final install = widget.onInstallFile;
              return GbModCard(
                mod: mod,
                treatment: treatment,
                enrichment: enrichment[mod.idRow],
                installedAs: installed.installsOfMod(mod.idRow),
                onOpen: () => widget.onOpenMod(mod.idRow),
                onInstallFile: install == null ? null : (file) => install(mod.idRow, file),
                // Every card has the same author, so the byline names the character, and the cover leaves it out.
                bylineSubject: _label(loc, creatorGroupOf(mod)),
                showCategory: false,
              );
            }),
          ),
        ),
      );
    }
    slivers.add(
      SliverToBoxAdapter(
        child: _Footer(feed: feed, onRetry: ref.read(creatorFeedProvider(listing).notifier).retry),
      ),
    );
    return CustomScrollView(controller: _scroll, slivers: slivers);
  }

  /// "14 mods for Zenless Zone Zero. 2 of them are in your library.", the second sentence once the library is read.
  String _headerLine(AppLocalizations loc, List<(GbMod, ContentTreatment)> listed, InstalledModsIndex? library) {
    final total = listed.length;
    final mods = loc.plural('marketplace.creator.mods_for_game', total, params: {'count': '$total'});
    if (library == null) return mods;
    final have = listed.where((entry) => library.hasMod(entry.$1.idRow)).length;
    final String inLibrary;
    if (total == 1) {
      inLibrary = loc.t(have == 1 ? 'marketplace.creator.in_library_it' : 'marketplace.creator.in_library_it_not');
    } else if (have == 0) {
      inLibrary = loc.t('marketplace.creator.in_library_none');
    } else {
      inLibrary = loc.plural('marketplace.creator.in_library', have, params: {'count': '$have'});
    }
    return '$mods $inLibrary';
  }
}

/// The avatar, the name and the line under it, then the tiles.
class _Header extends StatelessWidget {
  const _Header({required this.member, required this.name, required this.line, required this.tiles});

  final GbSubmitter member;
  final String name;
  final String? line;
  final Widget? tiles;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 26, 32, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 22,
        children: [
          Row(
            spacing: 18,
            children: [
              _Avatar(member: member, name: name),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        name,
                        key: const ValueKey('creator_name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.displayMedium!.copyWith(color: palette.text, height: 1),
                      ),
                    ),
                    if (line case final line?) Text(line, style: text.bodyMedium!.copyWith(color: palette.text2)),
                  ],
                ),
              ),
            ],
          ),
          ?tiles,
        ],
      ),
    );
  }
}

/// The member's avatar, 76px, over their initials on a dark gradient, which show while it loads and where it fails.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.member, required this.name});

  final GbSubmitter member;
  final String name;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final url = member.avatarUrl;
    return Container(
      key: const ValueKey('creator_avatar'),
      width: 76,
      height: 76,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.line),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.element(ElementTone.ether).background, palette.element(ElementTone.ice).background],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Text(
              nameInitials(name),
              style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                fontWeight: FontWeight.w800,
                height: 1,
                color: palette.text.withValues(alpha: 0.85),
              ),
            ),
          ),
          if (url != null)
            Image.network(
              url,
              fit: BoxFit.cover,
              cacheWidth: 152,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}

/// The tiles, All mods first, in a row that scrolls sideways.
class _CastRow extends ConsumerWidget {
  const _CastRow({
    required this.cast,
    required this.total,
    required this.selected,
    required this.label,
    required this.onPick,
  });

  final List<CreatorTile> cast;
  final int total;

  /// The key of the tile that is on, or null for All mods.
  final String? selected;
  final String Function(CreatorGroup group) label;

  /// Picks a tile by key, null for All mods.
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    // The tiles are artwork, a portrait under a dark shade, so they are drawn in the ink theme whatever the app's.
    final ink = ZenithPalette.dark(ref.watch(accentProvider));
    String mods(int count) => loc.plural('marketplace.creator.tile_mods', count, params: {'count': '$count'});

    return Semantics(
      container: true,
      label: loc.t('marketplace.creator.filter_label'),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
        child: Row(
          spacing: 10,
          children: [
            _CastTile(
              key: const ValueKey('cast_all'),
              ink: ink,
              name: loc.t('marketplace.creator.all_tile'),
              countLabel: '$total',
              semanticLabel: loc.plural('marketplace.creator.all_mods', total, params: {'count': '$total'}),
              big: '$total',
              bar: selected == null ? palette.accent : ink.line,
              on: selected == null,
              dim: false,
              onPressed: () => onPick(null),
            ),
            for (final tile in cast) _castTile(context, ink, tile, label(tile.group), mods(tile.count)),
          ],
        ),
      ),
    );
  }

  Widget _castTile(BuildContext context, ZenithPalette ink, CreatorTile tile, String name, String count) {
    final loc = context.loc;
    final characterId = tile.group.characterId;
    final portrait = CharacterAvatar.assetPathFor(characterId);
    final bar = characterId == null || elementToneOf(characterId) == ElementTone.neutral
        ? ink.text3
        : ink.element(elementToneOf(characterId)).foreground;
    final on = tile.group.key == selected;
    return _CastTile(
      key: ValueKey('cast_${tile.group.key}'),
      ink: ink,
      name: name,
      countLabel: count,
      semanticLabel: loc.t('marketplace.creator.tile_label', params: {'name': name, 'mods': count}),
      portrait: portrait,
      big: portrait == null ? nameInitials(name) : null,
      bar: bar,
      on: on,
      dim: selected != null && !on,
      // Pressing the tile that is on turns it off, back to All mods.
      onPressed: () => onPick(tile.group.key),
    );
  }
}

/// `grayscale(.6) brightness(.7)`: the portraits of the tiles that are not on, while one is.
final ColorFilter _dimmed = () {
  const amount = 0.6;
  const brightness = 0.7;
  const s = 1 - amount;
  List<double> row(double r, double g, double b) => [r * brightness, g * brightness, b * brightness, 0, 0];
  return ColorFilter.matrix([
    ...row(0.2126 + 0.7874 * s, 0.7152 - 0.7152 * s, 0.0722 - 0.0722 * s),
    ...row(0.2126 - 0.2126 * s, 0.7152 + 0.2848 * s, 0.0722 - 0.0722 * s),
    ...row(0.2126 - 0.2126 * s, 0.7152 - 0.7152 * s, 0.0722 + 0.9278 * s),
    0,
    0,
    0,
    1,
    0,
  ]);
}();

/// One tile: 96 × 128, the portrait anchored at the top, or [big] outlined where there is none, a shade along the
/// bottom with the name and the count, and a 3px bar in [bar]. On, it carries the accent border and ring and an
/// accent name.
class _CastTile extends StatefulWidget {
  const _CastTile({
    super.key,
    required this.ink,
    required this.name,
    required this.countLabel,
    required this.semanticLabel,
    required this.bar,
    required this.on,
    required this.dim,
    required this.onPressed,
    this.portrait,
    this.big,
  });

  /// The ink palette the inside is drawn in.
  final ZenithPalette ink;
  final String name;
  final String countLabel;
  final String semanticLabel;
  final Color bar;
  final bool on;

  /// Whether the portrait is dimmed, as every tile's is while another is on.
  final bool dim;
  final VoidCallback onPressed;
  final String? portrait;
  final String? big;

  static const double width = 96;
  static const double height = 128;

  @override
  State<_CastTile> createState() => _CastTileState();
}

class _CastTileState extends State<_CastTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final ink = widget.ink;
    final text = Theme.of(context).textTheme;
    const radius = BorderRadius.all(Radius.circular(12));

    Widget? artwork;
    if (widget.portrait case final portrait?) {
      final image = Image.asset(
        portrait,
        fit: BoxFit.cover,
        // `object-position: 50% 18%`: the face, not the chest.
        alignment: const Alignment(0, -0.64),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
      artwork = widget.dim ? ColorFiltered(colorFilter: _dimmed, child: image) : image;
    } else if (widget.big case final big?) {
      artwork = Positioned(
        top: 22,
        left: 8,
        right: 8,
        child: Center(
          // Shrunk to the tile for a count of four digits or more, which overflows it at the display size.
          child: FittedBox(
            key: const ValueKey('cast_big'),
            fit: BoxFit.scaleDown,
            child: OutlinedInitials(
              big,
              style: text.displayLarge!.copyWith(height: 1),
              color: ink.text.withValues(alpha: 0.28),
            ),
          ),
        ),
      );
    }

    final tile = Container(
      width: _CastTile.width,
      height: _CastTile.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ink.chip,
        borderRadius: radius,
        boxShadow: widget.on ? [BoxShadow(color: palette.accent, spreadRadius: 1)] : null,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: widget.on ? palette.accent : (_hovered ? palette.edge : palette.outline)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?artwork,
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.4, 1],
                colors: [ink.ground.withValues(alpha: 0), ink.ground.withValues(alpha: 0.92)],
              ),
            ),
          ),
          Positioned(
            left: 9,
            right: 9,
            bottom: 9,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 1,
              children: [
                Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                    color: widget.on ? ink.accentOnInk : ink.text,
                  ),
                ),
                Text(
                  widget.countLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZenithType.of(context).monoSmall.copyWith(height: 1.45, color: ink.textProse),
                ),
              ],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, height: 3, child: ColoredBox(color: widget.bar)),
        ],
      ),
    );

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed())},
      child: Semantics(
        button: true,
        selected: widget.on,
        label: widget.semanticLabel,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              tile,
              if (_focused)
                Positioned.fill(
                  left: -4,
                  top: -4,
                  right: -4,
                  bottom: -4,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.all(Radius.circular(16)),
                        border: Border.all(color: palette.accent, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pinned over the grid: what the grid shows, Show all while a tile is on, and Hide installed and Sort at the right.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.countLine,
    required this.showAll,
    required this.onShowAll,
    required this.hideInstalled,
    required this.onHideInstalled,
    required this.sort,
    required this.onSort,
  });

  final String countLine;

  /// "Show all 14", or null while no tile is on.
  final String? showAll;
  final VoidCallback onShowAll;
  final bool hideInstalled;
  final ValueChanged<bool> onHideInstalled;
  final GbModSort sort;
  final ValueChanged<GbModSort> onSort;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      decoration: BoxDecoration(
        color: palette.ground,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        spacing: 14,
        children: [
          // The left group takes the room the right one leaves, so the switch and the menu stay at the right.
          Expanded(
            child: Row(
              spacing: 14,
              children: [
                Flexible(
                  child: Text(
                    countLine,
                    key: const ValueKey('creator_count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium!.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                  ),
                ),
                if (showAll case final label?)
                  TextButton(style: smallButtonStyle(context), onPressed: onShowAll, child: Text(label)),
              ],
            ),
          ),
          GbHideInstalledToggle(value: hideInstalled, onChanged: onHideInstalled),
          GbSortMenu(sort: sort, onChanged: onSort),
        ],
      ),
    );
  }
}

/// Under the grid: the ring while later pages load, Try again when one failed, and the note that the page stopped
/// at the first [kCreatorMaxPages] pages.
class _Footer extends StatelessWidget {
  const _Footer({required this.feed, required this.onRetry});

  final MarketplaceFeed feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
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
          OutlinedButton(style: smallButtonStyle(context), onPressed: onRetry, child: Text(loc.t('marketplace.retry'))),
        ],
      );
    } else if (isCreatorFeedCapped(feed)) {
      const shown = kCreatorPageSize * kCreatorMaxPages;
      content = Text(
        loc.plural('marketplace.creator.capped', shown, params: {'count': '$shown'}),
        key: const ValueKey('creator_capped'),
        textAlign: TextAlign.center,
        style: style,
      );
    } else {
      content = null;
    }
    return Padding(padding: EdgeInsets.fromLTRB(32, content == null ? 0 : 26, 32, 32), child: content);
  }
}
