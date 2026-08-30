import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/bulk_resolution.dart';
import '../../services/bulk_update_check.dart';
import '../../services/update_check_run.dart';
import '../../utils/state_providers.dart';
import '../dialogs/assume_current_dialog.dart';
import '../dialogs/bulk_resolution_dialog.dart';
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
          // **Row one is search plus the library menu; row two is every
          // filter.** Interleaving actions with filters puts a bulk write beside
          // a filter reset in a row that appears and disappears, which is how
          // the bulk resolution screen ended up with nowhere to be re-opened
          // from. Row two is always present: it costs a row of height on an
          // unfiltered library and buys every control a fixed place.
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
              _buildLibraryMenu(),
            ],
          ),
          const SizedBox(height: 8),
          // A Wrap rather than a Row with a Spacer: the labels are whole words
          // with nothing to ellipsise, so at the narrow end of the window (an
          // 800px minimum, less the nav rail and the character panel) a Row
          // overflows instead of degrading. The outer Wrap holds the filters at
          // one end and the reset at the other while they fit and stacks them
          // when they don't; the inner one keeps the filters together as a
          // group rather than letting `spaceBetween` scatter them.
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildSortButton(),
                    if (tags.isNotEmpty) _buildTagFilterButton(tags),
                    // Still conditional, and still hidden rather than disabled
                    // at zero: the answer is usually nothing or most of the
                    // library. The `Wrap` means it no longer has to take a
                    // spacer with it, which is what the old `Row` got wrong.
                    if (needsAttentionCount > 0 || needsAttentionActive)
                      _buildNeedsAttentionToggle(
                        needsAttentionCount,
                        needsAttentionActive,
                      ),
                    if (_buildUpdatesFilterToggle() case final button?) button,
                    _buildFavoritesToggle(),
                  ],
                ),
                if (isFiltering)
                  TextButton.icon(
                    onPressed: () => clearModFilters(ref),
                    icon: const Icon(Icons.clear, size: 16),
                    label: Text(loc.t('mods.toolbar.clear_filters')),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
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

  /// **Only ever a filter.** It used to run the check too, which left
  /// re-checking three clicks away and the results screen with nowhere to be
  /// re-opened from; checking is an action and lives in the library menu now.
  ///
  /// Null when there is nothing to show, so the `Wrap` closes over it — but it
  /// stays rendered while the filter is *on* even at zero, or ignoring the last
  /// update would leave the grid filtered with nothing to switch off.
  Widget? _buildUpdatesFilterToggle() {
    final active = ref.watch(modUpdatesOnlyProvider);
    final found = ref.watch(modsWithUpdatesCountProvider);
    if (found == 0 && !active) return null;

    return Tooltip(
      message: loc.t('mods.toolbar.show_updates', params: {'count': '$found'}),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => ref.read(modUpdatesOnlyProvider.notifier).state = !active,
        child: _toolbarButton(
          active: active,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_circle_up,
                size: 18,
                color: active ? ModStatusSlot.updateBlue : null,
              ),
              const SizedBox(width: 4),
              Text('$found', style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  /// The three things you can *do* to the library, in one menu. Grouping them
  /// is what gives the resolution screen a door to be re-opened from.
  ///
  /// The badge counts what **"sort out mod tracking" would open** — the only
  /// entry whose work is otherwise invisible. A badge summing all three would
  /// be a number matching nothing else on screen.
  Widget _buildLibraryMenu() {
    final checkPlan = ref.watch(bulkUpdateCheckPlanProvider);
    final resolution = ref.watch(bulkResolutionPlanProvider);
    final assume = ref.watch(bulkAssumeCurrentPlanProvider);
    final pending = resolution.rows.length;

    return PopupMenuButton<_LibraryAction>(
      tooltip: loc.t('mods.toolbar.library'),
      enabled: !_checkingUpdates && !_assuming,
      onSelected: (action) {
        switch (action) {
          case _LibraryAction.check:
            unawaited(_runUpdateCheck(checkPlan));
          case _LibraryAction.resolve:
            unawaited(_openResolution(checkPlan));
          case _LibraryAction.assumeCurrent:
            unawaited(_runAssumeCurrent());
        }
      },
      itemBuilder: (_) => [
        _menuItem(
          value: _LibraryAction.check,
          icon: Icons.arrow_circle_up,
          label: loc.t('mods.toolbar.check_updates'),
          count: checkPlan.checkableCount,
          enabled: checkPlan.hasWork,
        ),
        _menuItem(
          value: _LibraryAction.resolve,
          icon: Icons.rule,
          label: loc.t('mods.toolbar.sort_out_tracking'),
          count: pending,
          // Enabled with nothing in hand as well: the entry runs the check
          // itself in that case, which is the request it would have taken
          // anyway. Refusing until a check had run would make the menu's most
          // useful item the one that is greyed out on launch.
          enabled: pending > 0 || checkPlan.hasWork,
        ),
        _menuItem(
          value: _LibraryAction.assumeCurrent,
          icon: Icons.event_available,
          label: loc.t('mods.toolbar.assume_current'),
          count: assume.eligible.length,
          enabled: assume.hasWork,
        ),
      ],
      child: _toolbarButton(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Only for the check, which is a request. `_assuming` merely
            // disables the menu: its work is milliseconds behind a modal, and a
            // spinner turning behind a dialog says the app is still busy.
            if (_checkingUpdates)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.more_vert, size: 18),
            const SizedBox(width: 6),
            Text(loc.t('mods.toolbar.library'),
                style: const TextStyle(fontSize: 13)),
            if (pending > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: ModStatusSlot.amber,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$pending',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  /// One menu row. The count shows even at zero, so a disabled entry says why.
  PopupMenuItem<_LibraryAction> _menuItem({
    required _LibraryAction value,
    required IconData icon,
    required String label,
    required int count,
    required bool enabled,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_LibraryAction>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _runUpdateCheck(BulkUpdateCheckPlan plan) async {
    setState(() => _checkingUpdates = true);
    final BulkUpdateCheckOutcome outcome;
    try {
      // Shared with the opt-in startup check, so the two cannot disagree about
      // the cache or about what a pass leaves behind.
      outcome = await runLibraryUpdateCheck(
        plan: plan,
        client: ref.read(gameBananaClientProvider),
        fetch: widget.updateFetcher,
        fetchUpdates: widget.updatesFetcher,
      );
    } finally {
      // Cleared **before** the results screen opens, not after it closes. The
      // spinner reports the request, and the request is over — leaving it
      // turning behind a modal the user is reading says the app is still
      // working, and disables the control they would press next.
      if (mounted) setState(() => _checkingUpdates = false);
    }
    if (!mounted) return;
    final checks = ref.read(modUpdateChecksProvider.notifier);
    checks.state = mergedChecks(checks.state, outcome);
    final records = ref.read(modUpdateRecordsProvider.notifier);
    records.state = mergedRecords(records.state, outcome);

    // The results screen opens by itself only when it has something to ask —
    // otherwise a modal stands between the user and the badges they pressed
    // for. It states the summary itself when it does open, so a notification is
    // never raised behind it.
    final resolution = ref.read(bulkResolutionPlanProvider);
    if (!resolution.hasWork) {
      showUpdateCheckOutcome(context, outcome);
      return;
    }
    await _showResolution(
      resolution,
      // The pass's own tally of what it could not reach. More precise than the
      // plan's, which counts any tracked mod with no record in hand — including
      // one the batch *answered* as `sourceGone`, since that answer arrives
      // without a record.
      unreachable: outcome.failed.length,
    );
  }

  /// The menu's "sort out mod tracking" — the same screen, on demand.
  ///
  /// Runs a check first when there is nothing in hand, which is the request it
  /// would have taken anyway; `_runUpdateCheck` then opens the screen itself,
  /// so this returns without doing it twice.
  Future<void> _openResolution(BulkUpdateCheckPlan checkPlan) async {
    final resolution = ref.read(bulkResolutionPlanProvider);
    if (!resolution.hasWork) {
      await _runUpdateCheck(checkPlan);
      return;
    }
    // Not zero, which is what this used to pass: a mod with no record in hand
    // is one this screen cannot cover, and dropping it makes the dialog
    // under-report on the very door the rebuild exists to provide.
    await _showResolution(resolution, unreachable: resolution.unreachable);
  }

  /// The update count is read **library-wide** rather than taken from whichever
  /// door opened the screen. The check's own tally and the view-scoped toolbar
  /// count are different numbers, and one sentence in one dialog must not mean
  /// "in your library" or "on this character tab" depending on how it was
  /// reached.
  Future<void> _showResolution(
    BulkResolutionPlan plan, {
    required int unreachable,
  }) async {
    final updatesFound = ref.read(libraryUpdateCountProvider);
    final wrote = await showBulkResolutionDialog(
      context,
      plan,
      updatesFound: updatesFound,
      unreachable: unreachable,
      writer: widget.originWriter ?? ApiService.updateModOrigin,
    );
    // Only on a write: the plan is derived from the records and the library, so
    // a run that changed nothing leaves nothing stale behind.
    if (wrote) widget.onLibraryChanged?.call();
  }

  /// The zero-network "assume current" bulk action.
  ///
  /// **Turns the needs-attention filter on before confirming**, so the grid
  /// behind the confirmation shows exactly the mods about to be rewritten. That
  /// is the same rule as before — the user must have *seen* the set — enforced
  /// by the action rather than by hiding it until the filter happens to be on.
  ///
  /// Flipping the filter cannot change *which* mods are eligible, only which
  /// are on screen: `planBulkAssumeCurrent` already keeps only `versionUnknown`
  /// mods, and needs-attention drops exactly the ones it would have skipped. So
  /// the count in the menu is the count that gets written.
  Future<void> _runAssumeCurrent() async {
    setState(() => _assuming = true);
    // Restored if the action does not go through. Under the old placement the
    // filter was a precondition, so declining changed nothing; turning it on
    // *for* the confirmation means cancelling — the one thing a confirmation
    // exists to allow — would otherwise leave the grid filtered behind the
    // user's back with nothing on screen saying why.
    final wasFiltered = ref.read(modNeedsAttentionOnlyProvider);
    void restoreFilter() {
      if (mounted && !wasFiltered) {
        ref.read(modNeedsAttentionOnlyProvider.notifier).state = false;
      }
    }

    try {
      ref.read(modNeedsAttentionOnlyProvider.notifier).state = true;
      // One frame, so the grid is actually showing that set before the
      // confirmation appears over it.
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final plan = ref.read(bulkAssumeCurrentPlanProvider);
      if (!plan.hasWork) {
        restoreFilter();
        return;
      }
      final outcome = await confirmAndApplyAssumeCurrent(
        context,
        plan,
        writer: widget.originWriter ?? ApiService.updateModOrigin,
      );
      if (!mounted || outcome == null) {
        restoreFilter();
        return;
      }
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

/// The library menu's three entries. All of them act; none of them filter.
enum _LibraryAction { check, resolve, assumeCurrent }
