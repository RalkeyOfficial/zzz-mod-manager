import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'character_tile.dart';
import 'zenith_controls.dart';
import 'zenith_switch.dart';

/// The row above a character's mods: the grid's filter chips, the character's One at a time switch and the sort.
/// The library-wide actions are on the All mods page.
///
/// Its state lives in providers, so it rebuilds only on the slices it watches.
class ModsToolbar extends ConsumerStatefulWidget {
  const ModsToolbar({super.key, this.oneAtATimeWriter});

  /// Injected only by tests. Defaults to `ApiService.setOneAtATime`, which writes the developer's own config.
  final Future<bool> Function(String groupId, bool on)? oneAtATimeWriter;

  @override
  ConsumerState<ModsToolbar> createState() => _ModsToolbarState();
}

class _ModsToolbarState extends ConsumerState<ModsToolbar> {
  AppLocalizations get loc => context.loc;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final filter = ref.watch(modGridFilterProvider);
    final mods = ref.watch(currentCharacterSkinsProvider);
    final updates = ref.watch(modsWithUpdatesCountProvider);
    final checked = ref.watch(modUpdateChecksProvider).isNotEmpty;
    final needsAttention = ref.watch(modsNeedingAttentionCountProvider);
    final group = ref.watch(currentCharacterIdProvider);

    Widget chip(ModGridFilter value, String key, int? count) => ZenithChip(
      label: loc.t(key),
      count: count,
      selected: filter == value,
      onTap: () => ref.read(modGridFilterProvider.notifier).state = value,
    );

    return Container(
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
            ],
          ),
        ],
      ),
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
