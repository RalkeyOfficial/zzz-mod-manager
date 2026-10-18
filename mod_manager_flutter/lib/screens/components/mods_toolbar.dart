import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/origin_write.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../dialogs/assume_current_dialog.dart';
import 'character_tile.dart';
import 'library_actions_host.dart';
import 'tracking_nudge.dart';
import 'zenith_controls.dart';
import 'zenith_switch.dart';

/// The row above a character's mods: the grid's filter chips, the character's One at a time switch, the sort, and
/// the library menu, with the tracking reminder under it.
///
/// Its state lives in providers, so it rebuilds only on the slices it watches. The update check and the tracking
/// screen run in [LibraryActionsHost], above the page, since they outlive it.
class ModsToolbar extends ConsumerStatefulWidget {
  const ModsToolbar({
    super.key,
    this.onLibraryChanged,
    this.onRescan,
    this.originWriter,
    this.nudgeWriter,
    this.oneAtATimeWriter,
  });

  /// Called after "mark all as current" ran, so the screen can rescan — the status badge is drawn from
  /// `ModInfo.origin`, which only a scan refreshes.
  final VoidCallback? onLibraryChanged;

  /// The library menu's "read the library again". Absent hides the entry.
  final VoidCallback? onRescan;

  /// Injected only by tests — see [OriginWriter].
  final OriginWriter? originWriter;

  /// Injected only by tests — see [NudgeDismissWriter].
  final NudgeDismissWriter? nudgeWriter;

  /// Injected only by tests. Defaults to `ApiService.setOneAtATime`, which writes the developer's own config.
  final Future<bool> Function(String groupId, bool on)? oneAtATimeWriter;

  @override
  ConsumerState<ModsToolbar> createState() => _ModsToolbarState();
}

class _ModsToolbarState extends ConsumerState<ModsToolbar> {
  /// Set while "mark all as current" is in flight, so the menu can't start it twice over the same folders.
  bool _assuming = false;

  AppLocalizations get loc => context.loc;

  @override
  Widget build(BuildContext context) {
    // The Updates filters switch themselves off once the library has none left,
    // rather than leaving the grid filtered to nothing with a control the user
    // has to work out they need to press.
    //
    // Keyed on the **library**, not on the view-scoped count: on that this would
    // fire merely because the user picked a character with no updates of its
    // own, and the filter would evaporate whenever they looked somewhere else.
    //
    // Deferred a frame because a listener can fire *during* the rebuild its own
    // change triggered, and Riverpod refuses a provider write in that window.
    ref.listen(libraryHasUpdatesProvider, (_, hasUpdates) {
      if (hasUpdates) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final grid = ref.read(modGridFilterProvider.notifier);
        if (grid.state == ModGridFilter.updates) grid.state = ModGridFilter.all;
        final list = ref.read(characterListFilterProvider.notifier);
        if (list.state == CharacterListFilter.updates) list.state = CharacterListFilter.all;
      });
    });

    final palette = ZenithPalette.of(context);
    final filter = ref.watch(modGridFilterProvider);
    final mods = ref.watch(currentCharacterSkinsProvider);
    final updates = ref.watch(modsWithUpdatesCountProvider);
    final checked = ref.watch(modUpdateChecksProvider).isNotEmpty;
    final needsAttention = ref.watch(modsNeedingAttentionCountProvider);
    final untrackedCount = ref.watch(untrackedModsCountProvider);
    final nudgeDismissed = ref.watch(trackingNudgeDismissedProvider);
    final checking = ref.watch(libraryCheckRunningProvider);
    final group = ref.watch(currentCharacterIdProvider);

    Widget chip(ModGridFilter value, String key, int? count) => ZenithChip(
      label: loc.t(key),
      count: count,
      selected: filter == value,
      onTap: () => ref.read(modGridFilterProvider.notifier).state = value,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.divider))),
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  chip(ModGridFilter.all, 'library.grid.all', mods.length),
                  chip(ModGridFilter.active, 'library.grid.active', mods.where((m) => m.isActive).length),
                  // No number before a check: "0 updates" and "not checked" are different claims.
                  chip(ModGridFilter.updates, 'library.grid.updates', checked ? updates : null),
                  chip(ModGridFilter.favorites, 'library.grid.favorites', mods.where((m) => m.isFavorite).length),
                  // Hidden at zero, unless it is on: the answer is usually nothing or most of the library, and a
                  // chip that is on must stay to be switched off.
                  if (needsAttention > 0 || filter == ModGridFilter.needsAttention)
                    chip(ModGridFilter.needsAttention, 'library.grid.needs_attention', needsAttention),
                ],
              ),
              // A Wrap as well: at the minimum window the toolbar has about 300px.
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (hasOneAtATime(group)) _OneAtATime(groupId: group, writer: widget.oneAtATimeWriter),
                  const SizedBox(width: 4),
                  _buildSortButton(),
                  _buildLibraryMenu(checking),
                ],
              ),
            ],
          ),
        ),
        if (untrackedCount > 0 && !nudgeDismissed)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 14, 28, 0),
            child: TrackingNudge(
              count: untrackedCount,
              onSortOut: checking ? null : () => unawaited(LibraryActionsHost.of(context).sortOutTracking()),
              onDismiss: _dismissNudge,
            ),
          ),
      ],
    );
  }

  Widget _buildSortButton() {
    final sortMode = ref.watch(modSortProvider);
    return MenuAnchor(
      menuChildren: [
        for (final m in ModSort.values)
          MenuItemButton(
            leadingIcon: Icon(sortMode == m ? Icons.check_rounded : null),
            onPressed: () {
              // Update the UI immediately and persist the choice for next launch.
              ref.read(modSortProvider.notifier).state = m;
              ApiService.saveSortMode(m);
            },
            child: Text(_sortLabel(m)),
          ),
      ],
      builder: (context, controller, _) => TextButton.icon(
        style: smallButtonStyle(context),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.swap_vert_rounded),
        label: Text(_sortLabel(sortMode)),
      ),
    );
  }

  String _sortLabel(ModSort mode) => switch (mode) {
    ModSort.added => loc.t('mods.sort.added'),
    ModSort.nameAsc => loc.t('mods.sort.name_asc'),
    ModSort.nameDesc => loc.t('mods.sort.name_desc'),
  };

  /// The things you can *do* to the library, in one menu. Grouping them is
  /// what gives the resolution screen a door to be re-opened from.
  ///
  /// Each entry shows the count of mods it would act on, even at zero, so a
  /// disabled entry says why.
  Widget _buildLibraryMenu(bool checking) {
    final checkPlan = ref.watch(bulkUpdateCheckPlanProvider);
    final resolution = ref.watch(bulkResolutionPlanProvider);
    final assumable = ref.watch(characterAssumeCurrentCountProvider);
    final pending = resolution.rows.length;
    final enabled = !checking && !_assuming;
    final actions = LibraryActionsHost.of(context);

    return MenuAnchor(
      menuChildren: [
        _menuItem(
          icon: Icons.sync_rounded,
          label: loc.t('mods.toolbar.check_updates'),
          count: checkPlan.checkableCount,
          onPressed: checkPlan.hasWork ? () => unawaited(actions.checkForUpdates()) : null,
        ),
        _menuItem(
          icon: Icons.rule_rounded,
          label: loc.t('mods.toolbar.sort_out_tracking'),
          count: pending,
          // Enabled with nothing in hand as well: the entry runs the check
          // itself in that case, which is the request it would have taken
          // anyway. An untracked mod is enough on its own, since its row needs no mod page.
          onPressed: pending > 0 || checkPlan.hasWork || resolution.untracked.isNotEmpty
              ? () => unawaited(actions.sortOutTracking())
              : null,
        ),
        _menuItem(
          icon: Icons.event_available_rounded,
          label: loc.t('mods.toolbar.assume_current'),
          count: assumable,
          onPressed: assumable > 0 ? () => unawaited(_runAssumeCurrent()) : null,
        ),
        if (widget.onRescan != null) ...[
          const Divider(),
          MenuItemButton(
            leadingIcon: const Icon(Icons.refresh_rounded),
            onPressed: widget.onRescan,
            child: Text(loc.t('library.grid.rescan')),
          ),
        ],
      ],
      builder: (context, controller, _) => IconButton(
        style: smallButtonStyle(context, iconOnly: true),
        tooltip: loc.t('mods.toolbar.library'),
        onPressed: enabled ? () => controller.isOpen ? controller.close() : controller.open() : null,
        // Only for the check, which is a request. `_assuming` merely disables the menu: its work is
        // milliseconds behind a modal, and a spinner turning behind a dialog says the app is still busy.
        icon: checking
            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.more_horiz_rounded),
      ),
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required int count,
    required VoidCallback? onPressed,
  }) {
    final palette = ZenithPalette.of(context);
    return MenuItemButton(
      leadingIcon: Icon(icon),
      trailingIcon: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Text('$count', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }

  /// The provider first so the reminder leaves this frame, then the write so it stays away after a restart.
  void _dismissNudge() {
    ref.read(trackingNudgeDismissedProvider.notifier).state = true;
    unawaited((widget.nudgeWriter ?? ApiService.setTrackingNudgeDismissed)(true));
  }

  /// The zero-network "assume current" bulk action, over the character on screen.
  ///
  /// **Turns the needs-attention filter on before confirming**, so the grid
  /// behind the confirmation shows exactly the mods about to be rewritten — the
  /// user must have *seen* the set. The menu's count is taken over that same set
  /// ([characterAssumeCurrentCountProvider]), whichever filter was on at the press.
  Future<void> _runAssumeCurrent() async {
    setState(() => _assuming = true);
    // Restored if the action does not go through: cancelling, the one thing a
    // confirmation exists to allow, must not leave the grid filtered behind the
    // user's back with nothing on screen saying why.
    final filter = ref.read(modGridFilterProvider.notifier);
    final previous = filter.state;
    void restoreFilter() {
      if (mounted) filter.state = previous;
    }

    try {
      filter.state = ModGridFilter.needsAttention;
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
        writer: widget.originWriter ??
            originWriterFor(ref.read(modManagerServiceProvider.future)),
      );
      if (!mounted || outcome == null) {
        restoreFilter();
        return;
      }
      showAssumeCurrentOutcome(context, outcome);
      // Unconditional, even when nothing was written. A run that only *declined*
      // means the plan on screen was stale, and skipping the rescan there would
      // leave the same stale plan behind a menu that keeps offering the same work.
      widget.onLibraryChanged?.call();
      // Everything this view had to offer is now resolved, so leaving the
      // filter on would hand the user an empty grid as the reward for pressing.
      if (plan.untracked.isEmpty &&
          plan.undatable.isEmpty &&
          outcome.written > 0 &&
          outcome.failed == 0) {
        filter.state = ModGridFilter.all;
      }
    } finally {
      if (mounted) setState(() => _assuming = false);
    }
  }
}

/// The One at a time switch for the character on screen (`docs/library-screen.md` §10).
class _OneAtATime extends ConsumerWidget {
  const _OneAtATime({required this.groupId, this.writer});

  final String groupId;
  final Future<bool> Function(String groupId, bool on)? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final on = isOneAtATime(ref.watch(oneAtATimeProvider), groupId);
    final label = loc.t('library.grid.one_at_a_time');

    return Tooltip(
      message: loc.t(on ? 'library.grid.one_at_a_time_on' : 'library.grid.one_at_a_time_off'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [
          ZenithSwitch(
            value: on,
            semanticLabel: label,
            onChanged: (value) async {
              final notify = context.notify;
              final failedTitle = loc.t('library.grid.one_at_a_time_failed_title');
              final name = libraryGroupName(groupId, loc);
              final writer = this.writer;
              // The real path publishes the choice once it is saved; a test's writer has no provider to publish to,
              // so the switch publishes it the same way, after a successful write.
              final saved = writer == null
                  ? await ApiService.setOneAtATime(groupId, value)
                  : await writer(groupId, value);
              if (saved && writer != null) {
                ref.read(oneAtATimeProvider.notifier).state = {...ref.read(oneAtATimeProvider), groupId: value};
              }
              if (!saved) notify.error(failedTitle, body: name);
            },
          ),
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2)),
        ],
      ),
    );
  }
}
