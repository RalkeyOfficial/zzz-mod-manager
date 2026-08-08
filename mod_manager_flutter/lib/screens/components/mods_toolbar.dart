import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/bulk_assume_current.dart';
import '../../services/bulk_update_check.dart';
import '../../utils/state_providers.dart';
import '../dialogs/assume_current_dialog.dart';
import 'mod_status_slot.dart';
import 'update_check_feedback.dart';

/// Search + sort + tag-filter + favorites toolbar shown above the mods grid.
///
/// All of its state lives in providers (see `state_providers.dart`), so this
/// widget only reads/writes those; the search field's controller is the one
/// piece of local state, kept in sync with [modSearchQueryProvider] so clearing
/// the query from elsewhere (e.g. the "no results" screen) also clears the box.
class ModsToolbar extends ConsumerStatefulWidget {
  const ModsToolbar({
    super.key,
    this.onLibraryChanged,
    this.originWriter,
    this.updateFetcher,
    this.updatesFetcher,
  });

  /// Called after the bulk "assume current" action wrote something, so the
  /// screen can rescan — the status slot is drawn from `ModInfo.origin`, which
  /// only a scan refreshes.
  final VoidCallback? onLibraryChanged;

  /// Injected only by tests — see [BulkOriginWriter].
  final BulkOriginWriter? originWriter;

  /// Injected only by tests. Defaults to the shared GameBanana client, which a
  /// widget test must not be allowed to reach — the same reason the origin
  /// writer above is injectable.
  final ModRecordFetcher? updateFetcher;

  /// Injected only by tests, for the same reason. The second phase — asking
  /// each flagged mod's release feed which files shipped together.
  final ModUpdatesFetcher? updatesFetcher;

  @override
  ConsumerState<ModsToolbar> createState() => _ModsToolbarState();
}

class _ModsToolbarState extends ConsumerState<ModsToolbar> {
  final TextEditingController _searchController = TextEditingController();

  /// Set while a bulk run is in flight, so the button can't be pressed twice
  /// into two overlapping passes over the same folders.
  bool _assuming = false;

  /// The same guard for the update check: a second press mid-pass would issue
  /// the whole batch again and race the first run's results into the map.
  bool _checkingUpdates = false;

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

    // The updates filter switches itself off once the library has none left,
    // rather than leaving the grid filtered to nothing with a control the user
    // has to work out they need to press. Same reasoning as the bulk "assume
    // current" action clearing its filter when a run leaves nothing behind.
    //
    // Keyed on the **library**, not on the view-scoped count beside it: on the
    // view count this would fire merely because the user clicked a character
    // tab with no updates of its own, and the filter would evaporate whenever
    // they looked somewhere else.
    //
    // Deferred a frame because a listener can fire *during* the rebuild its own
    // change triggered, and Riverpod refuses a provider write in that window.
    ref.listen(libraryHasUpdatesProvider, (_, hasUpdates) {
      if (hasUpdates || !ref.read(modUpdatesOnlyProvider)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(modUpdatesOnlyProvider.notifier).state = false;
      });
    });

    final tags = ref.watch(availableModTagsProvider);
    final searchQuery = ref.watch(modSearchQueryProvider);
    final isFiltering = ref.watch(modFiltersActiveProvider);
    final needsAttentionCount = ref.watch(modsNeedingAttentionCountProvider);
    final needsAttentionActive = ref.watch(modNeedsAttentionOnlyProvider);
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
              // The spacer is conditional together with the control, the same
              // way the tag filter's is. A control that hides itself by
              // returning an empty box leaves its gaps behind, and two 8px gaps
              // between the sort dropdown and the favourites star read as a
              // missing button — which is exactly what it is.
              if (needsAttentionCount > 0 || needsAttentionActive) ...[
                const SizedBox(width: 8),
                _buildNeedsAttentionToggle(
                  needsAttentionCount,
                  needsAttentionActive,
                ),
              ],
              if (_buildUpdateCheckButton() case final button?) ...[
                const SizedBox(width: 8),
                button,
              ],
              const SizedBox(width: 8),
              _buildFavoritesToggle(),
            ],
          ),
          // A Wrap rather than a Row with a Spacer: both labels are whole words
          // with nothing to ellipsise, so at the narrow end of the window (an
          // 800px minimum, less the nav rail and the character panel) a Row
          // overflows instead of degrading. The Wrap keeps them at opposite
          // ends while they fit and stacks them when they don't.
          if (isFiltering)
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () => clearModFilters(ref),
                    icon: const Icon(Icons.clear, size: 16),
                    label: Text(loc.t('mods.toolbar.clear_filters')),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  if (_buildRecheckButton() case final button?) button,
                  if (_buildAssumeCurrentButton() case final button?) button,
                ],
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

  /// Enumerates the mods whose origin isn't fully known.
  ///
  /// Carries the count because the answer is usually zero or "most of the
  /// library", and both are worth knowing *before* pressing: a legacy library
  /// says 47 and a fully-resolved one says nothing at all. Hidden entirely at
  /// zero rather than shown disabled — a control that can never do anything is
  /// noise in a toolbar that already has four.
  ///
  /// **Whether to show it is decided by the caller**, not here, so the spacer
  /// beside it disappears with it. Returning an empty box from a build method
  /// hides the control and keeps its gaps.
  Widget _buildNeedsAttentionToggle(int count, bool active) {
    return Tooltip(
      message: loc.t('mods.toolbar.needs_attention'),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () =>
            ref.read(modNeedsAttentionOnlyProvider.notifier).state = !active,
        child: _toolbarButton(
          active: active,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.priority_high,
                size: 18,
                color: active ? ModStatusSlot.amber : null,
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text('$count', style: const TextStyle(fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Updates: **one control, two jobs**, and which one it does is decided by
  /// whether there is anything to show.
  ///
  /// | state | shows | pressing it |
  /// |---|---|---|
  /// | nothing found (or not checked yet) | bare icon | runs the check |
  /// | *n* found in this view | a count | filters the grid to them |
  ///
  /// A separate filter toggle beside it was the obvious design and was
  /// rejected: this toolbar already carries six controls, and a seventh that is
  /// meaningless until a check has run is a permanent cost for an occasional
  /// state. The rule that keeps the overload legible is **the control does the
  /// only useful thing available** — with no findings, checking is all there is
  /// to do; with findings, seeing them is. The count is the visible signal for
  /// which mode it is in, so nothing about it is hidden state.
  ///
  /// The cost, stated plainly: re-checking once results exist means turning the
  /// filter on, pressing "check again" in the row below, and turning it off
  /// again. That is the trade for not adding a control, and it is bounded — the
  /// results are session state, so every launch starts in check mode.
  ///
  /// Two scopes meet here and they are deliberately different. The **check**
  /// covers the whole library ([bulkUpdateCheckPlanProvider]) because its badges
  /// are drawn on every character tab; the **filter** covers this view
  /// ([modsWithUpdatesCountProvider]) because that is all it can narrow. So on a
  /// tab whose mods are all current the button falls back to check mode, which
  /// is the same rule applied, not an exception to it.
  ///
  /// Null when there is nothing to offer, so the caller drops the spacer with
  /// it — see [_buildNeedsAttentionToggle] for what that costs otherwise. It
  /// stays rendered while the filter is *on* even at a count of zero, or
  /// ignoring the last update would take the toggle away with the grid still
  /// filtered and nothing to switch off.
  Widget? _buildUpdateCheckButton() {
    final plan = ref.watch(bulkUpdateCheckPlanProvider);
    final active = ref.watch(modUpdatesOnlyProvider);
    if (!plan.hasWork && !active) return null;
    final found = ref.watch(modsWithUpdatesCountProvider);
    final filters = found > 0 || active;

    return Tooltip(
      message: filters
          ? loc.t('mods.toolbar.show_updates', params: {'count': '$found'})
          : loc.t(
              'mods.toolbar.check_updates',
              params: {'count': '${plan.checkableCount}'},
            ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _checkingUpdates
            ? null
            : filters
                ? () => ref.read(modUpdatesOnlyProvider.notifier).state = !active
                : () => unawaited(_runUpdateCheck(plan)),
        child: _toolbarButton(
          active: active,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_checkingUpdates)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.arrow_circle_up,
                  size: 18,
                  color: filters ? ModStatusSlot.updateBlue : null,
                ),
              if (found > 0) ...[
                const SizedBox(width: 4),
                Text('$found', style: const TextStyle(fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Re-runs the check while the update filter is holding the button hostage.
  ///
  /// The whole cost of overloading that button is that pressing it no longer
  /// re-checks once there is something to filter, so the action needs somewhere
  /// to go. This row is where it goes, and the shape is not invented: the bulk
  /// "assume current" button already appears here, and only while the filter
  /// that makes it meaningful is on.
  ///
  /// Null the rest of the time, so the caller leaves it out of the row rather
  /// than laying out an empty box.
  Widget? _buildRecheckButton() {
    if (!ref.watch(modUpdatesOnlyProvider)) return null;
    final plan = ref.watch(bulkUpdateCheckPlanProvider);
    if (!plan.hasWork) return null;

    return TextButton.icon(
      onPressed:
          _checkingUpdates ? null : () => unawaited(_runUpdateCheck(plan)),
      icon: const Icon(Icons.refresh, size: 16),
      label: Text(loc.t('mods.toolbar.check_again')),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _runUpdateCheck(BulkUpdateCheckPlan plan) async {
    setState(() => _checkingUpdates = true);
    try {
      final client = ref.read(gameBananaClientProvider);
      final outcome = await runBulkUpdateCheck(
        plan: plan,
        fetchUpdates: widget.updatesFetcher ??
            (modId) => client.modUpdates(modId, refresh: true),
        fetch: widget.updateFetcher ??
            // Bypasses the response cache for the same reason the marketplace's
            // refresh button does: a "check for updates" that can be answered
            // from a ten-minute-old copy is a control that sometimes cannot
            // check for updates, and the user has no way to tell which press
            // was which.
            (ids) => client.modsMulti(
                  ids,
                  properties: updateCheckProperties,
                  refresh: true,
                ),
      );
      if (!mounted) return;
      // Merged rather than replaced: a per-mod check the user ran on a mod this
      // pass could not reach is still the best answer available for it.
      final notifier = ref.read(modUpdateChecksProvider.notifier);
      notifier.state = {...notifier.state, ...outcome.checks};
      showUpdateCheckOutcome(context, outcome);
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  /// The zero-network "assume current" bulk action.
  ///
  /// **Offered only while the needs-attention filter is on**, and that is a
  /// decision rather than a place to put a button. The filter is what turns the
  /// state from a dot on a card into a list, and this action rewrites every mod
  /// on that list at once — so requiring the enumeration first means the user
  /// has *seen* what they are about to act on. It also keeps the default
  /// toolbar, which already carries five controls, unchanged for the fully
  /// resolved library where this can do nothing.
  ///
  /// It acts on exactly the mods **the grid is rendering** — its plan comes
  /// from `visibleModsProvider`, not from the wider list the `!` toggle counts.
  /// A control that rewrites a different set than the one on screen is the
  /// quiet kind of wrong, and the two lists come apart as soon as a second
  /// filter is active: search `ellen` with needs-attention on and the toggle
  /// still says 12 while the grid shows 3. The button then says 3, and its
  /// number differing from the toggle's is correct — they answer different
  /// questions. With needs-attention as the only filter, which is what this was
  /// designed around, they agree; on the "All" view that is the whole library.
  /// Null when there is nothing to offer, so the caller leaves it out of the
  /// row entirely rather than laying out an empty box — see
  /// [_buildNeedsAttentionToggle] for the gap that costs.
  Widget? _buildAssumeCurrentButton() {
    if (!ref.watch(modNeedsAttentionOnlyProvider)) return null;
    final plan = ref.watch(bulkAssumeCurrentPlanProvider);
    if (!plan.hasWork) return null;

    return TextButton.icon(
      onPressed: _assuming ? null : () => unawaited(_runAssumeCurrent(plan)),
      icon: const Icon(Icons.event_available, size: 16),
      label: Text(
        loc.t(
          'mods.toolbar.assume_current',
          params: {'count': '${plan.eligible.length}'},
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _runAssumeCurrent(BulkAssumeCurrentPlan plan) async {
    setState(() => _assuming = true);
    try {
      final outcome = await confirmAndApplyAssumeCurrent(
        context,
        plan,
        writer: widget.originWriter ?? ApiService.updateModOrigin,
      );
      if (!mounted || outcome == null) return;
      showAssumeCurrentOutcome(context, outcome);
      // Unconditional, even when nothing was written. A run that only *declined*
      // means the plan on screen was stale, and skipping the rescan there would
      // leave the same stale plan behind a button that keeps offering the same
      // work — a state that cannot correct itself.
      widget.onLibraryChanged?.call();
      // Everything this view had to offer is now resolved, so leaving the
      // filter on would hand the user an empty grid as the reward for pressing
      // the button. Computed from the plan rather than from the rescan, which
      // is asynchronous and owned by the screen above.
      if (plan.untracked.isEmpty &&
          plan.undatable.isEmpty &&
          outcome.written > 0 &&
          outcome.failed == 0) {
        ref.read(modNeedsAttentionOnlyProvider.notifier).state = false;
      }
    } finally {
      if (mounted) setState(() => _assuming = false);
    }
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
