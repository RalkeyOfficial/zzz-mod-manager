import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../utils/state_providers.dart';

/// Search + sort + tag-filter + favorites toolbar shown above the mods grid.
///
/// All of its state lives in providers (see `state_providers.dart`), so this
/// widget only reads/writes those; the search field's controller is the one
/// piece of local state, kept in sync with [modSearchQueryProvider] so clearing
/// the query from elsewhere (e.g. the "no results" screen) also clears the box.
class ModsToolbar extends ConsumerStatefulWidget {
  const ModsToolbar({super.key});

  @override
  ConsumerState<ModsToolbar> createState() => _ModsToolbarState();
}

class _ModsToolbarState extends ConsumerState<ModsToolbar> {
  final TextEditingController _searchController = TextEditingController();

  // Anchored dropdown for the tag filter.
  final OverlayPortalController _tagMenuController = OverlayPortalController();
  final LayerLink _tagMenuLink = LayerLink();

  @override
  void initState() {
    super.initState();
    _searchController.text = ref.read(modSearchQueryProvider);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  AppLocalizations get loc => context.loc;

  @override
  Widget build(BuildContext context) {
    // Mirror the query provider into the field, so clearing it elsewhere also
    // empties the box. When the user types, the text already matches, so this
    // is a no-op and never moves the cursor.
    ref.listen(modSearchQueryProvider, (_, next) {
      if (_searchController.text != next) _searchController.text = next;
    });

    final tags = ref.watch(availableModTagsProvider);
    final searchQuery = ref.watch(modSearchQueryProvider);
    final isFiltering = ref.watch(modFiltersActiveProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppConstants.defaultPadding,
        AppConstants.smallPadding,
        AppConstants.defaultPadding,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) =>
                      ref.read(modSearchQueryProvider.notifier).state = v,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: loc.t('mods.toolbar.search'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            tooltip: loc.t('mods.toolbar.clear'),
                            onPressed: () => ref
                                .read(modSearchQueryProvider.notifier)
                                .state = '',
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildSortButton(),
              if (tags.isNotEmpty) ...[
                const SizedBox(width: 8),
                _buildTagFilterButton(tags),
              ],
              const SizedBox(width: 8),
              _buildFavoritesToggle(),
            ],
          ),
          if (isFiltering)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => clearModFilters(ref),
                icon: const Icon(Icons.clear, size: 16),
                label: Text(loc.t('mods.toolbar.clear_filters')),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbarButton({required Widget child, bool active = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF0EA5E9).withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active
              ? const Color(0xFF0EA5E9).withValues(alpha: 0.6)
              : Colors.grey.withValues(alpha: 0.4),
        ),
      ),
      child: child,
    );
  }

  Widget _buildSortButton() {
    final sortMode = ref.watch(modSortProvider);
    return PopupMenuButton<ModSort>(
      tooltip: loc.t('mods.toolbar.sort'),
      initialValue: sortMode,
      onSelected: (m) {
        // Update the UI immediately and persist the choice for next launch.
        ref.read(modSortProvider.notifier).state = m;
        ApiService.saveSortMode(m);
      },
      itemBuilder: (_) => [
        for (final m in ModSort.values)
          CheckedPopupMenuItem(
            value: m,
            checked: sortMode == m,
            child: Text(_sortLabel(m)),
          ),
      ],
      child: _toolbarButton(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 18),
            const SizedBox(width: 6),
            Text(_sortLabel(sortMode), style: const TextStyle(fontSize: 13)),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  String _sortLabel(ModSort mode) {
    switch (mode) {
      case ModSort.added:
        return loc.t('mods.sort.added');
      case ModSort.nameAsc:
        return loc.t('mods.sort.name_asc');
      case ModSort.nameDesc:
        return loc.t('mods.sort.name_desc');
    }
  }

  /// Tag filter as an anchored dropdown panel (scales to many tags) with an
  /// Any/All match-mode toggle. Built with OverlayPortal so it's a normal part
  /// of the tree — toggles update state directly and re-filter live.
  Widget _buildTagFilterButton(List<String> tags) {
    // Count only tags present in this view — matches what visibleModsProvider
    // actually applies, so the badge can't claim a filter that does nothing.
    final count = ref.watch(modTagFiltersProvider).where(tags.contains).length;
    return OverlayPortal(
      controller: _tagMenuController,
      overlayChildBuilder: (context) {
        return Stack(
          children: [
            // Tap-outside barrier to dismiss.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tagMenuController.hide,
              ),
            ),
            // Anchor the panel's right edge to the button's right edge so it
            // grows leftward into the window instead of clipping off the right.
            CompositedTransformFollower(
              link: _tagMenuLink,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 6),
              child: _buildTagMenuPanel(tags),
            ),
          ],
        );
      },
      child: CompositedTransformTarget(
        link: _tagMenuLink,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _tagMenuController.toggle,
          child: _toolbarButton(
            active: count > 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.filter_list, size: 18),
                const SizedBox(width: 6),
                Text(loc.t('mods.toolbar.tags'), style: const TextStyle(fontSize: 13)),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagMenuPanel(List<String> tags) {
    // The panel lives in the app Overlay (via OverlayPortal), so it watches the
    // filter providers through its own Consumer to rebuild on toggle.
    return Consumer(
      builder: (context, ref, _) {
        final activeTags = ref.watch(modTagFiltersProvider);
        final matchAll = ref.watch(modTagMatchAllProvider);
        return Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        loc.t('mods.toolbar.match'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          ChoiceChip(
                            label: Text(loc.t('mods.toolbar.match_any')),
                            selected: !matchAll,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => ref
                                .read(modTagMatchAllProvider.notifier)
                                .state = false,
                          ),
                          ChoiceChip(
                            label: Text(loc.t('mods.toolbar.match_all')),
                            selected: matchAll,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => ref
                                .read(modTagMatchAllProvider.notifier)
                                .state = true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final tag in tags)
                        CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          visualDensity: VisualDensity.compact,
                          value: activeTags.contains(tag),
                          title: Text(tag, style: const TextStyle(fontSize: 13)),
                          onChanged: (sel) {
                            final next = Set<String>.from(activeTags);
                            if (sel == true) {
                              next.add(tag);
                            } else {
                              next.remove(tag);
                            }
                            ref.read(modTagFiltersProvider.notifier).state =
                                next;
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFavoritesToggle() {
    final favoritesOnly = ref.watch(modFavoritesOnlyProvider);
    return Tooltip(
      message: loc.t('mods.toolbar.favorites_only'),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () =>
            ref.read(modFavoritesOnlyProvider.notifier).state = !favoritesOnly,
        child: _toolbarButton(
          active: favoritesOnly,
          child: Icon(
            favoritesOnly ? Icons.star : Icons.star_border,
            size: 18,
            color: favoritesOnly ? const Color(0xFFFACC15) : null,
          ),
        ),
      ),
    );
  }
}
