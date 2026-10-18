import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../utils/categories.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'zenith_controls.dart';

/// The Library's left column: the built-in categories and unassigned mods, then every agent, each with how many mods
/// it holds. An agent with none is listed too, dimmed, so the list is the roster rather than a summary of the
/// library.
///
/// A mod card dropped on a row files the mod under that row.
class CharacterList extends ConsumerStatefulWidget {
  const CharacterList({super.key, required this.onRetag});

  static const double width = 280;

  /// Files a dragged mod under a row: a roster id, a category id, or [unknownCharacterId] to unassign it.
  final void Function(ModInfo mod, String groupId) onRetag;

  @override
  ConsumerState<CharacterList> createState() => _CharacterListState();
}

class _CharacterListState extends ConsumerState<CharacterList> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(String groupId, String name) {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    if (name.toLowerCase().contains(query)) return true;
    return characterById(groupId)?.detectionTerms.any((t) => t.contains(query)) ?? false;
  }

  bool _passes(CharacterListFilter filter, LibraryGroupCounts counts) => switch (filter) {
    CharacterListFilter.all => true,
    CharacterListFilter.hasMods => counts.mods > 0,
    CharacterListFilter.active => counts.active > 0,
    CharacterListFilter.updates => counts.updates > 0,
  };

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final allCounts = ref.watch(libraryGroupCountsProvider);
    final filter = ref.watch(characterListFilterProvider);
    final current = ref.watch(currentCharacterIdProvider);
    final withUpdates = allCounts.values.where((c) => c.updates > 0).length;

    List<String> visible(Iterable<String> ids) => [
      for (final id in ids)
        if (_matches(id, libraryGroupName(id, loc)) && _passes(filter, allCounts[id] ?? LibraryGroupCounts.empty))
          id,
    ];
    final agents = visible(zzzCharacterIds);
    final others = visible([for (final c in builtInCategories) c.id, unknownCharacterId]);

    Widget chip(CharacterListFilter value, String key, {int? count}) => ZenithChip(
      label: loc.t(key),
      count: count,
      selected: filter == value,
      onTap: () => ref.read(characterListFilterProvider.notifier).state = value,
    );

    Widget row(String id) => _CharacterRow(
      key: ValueKey('character_$id'),
      groupId: id,
      name: libraryGroupName(id, loc),
      counts: allCounts[id] ?? LibraryGroupCounts.empty,
      selected: id == current,
      onTap: () {
        ref.read(selectedCharacterIdProvider.notifier).state = id;
        ref.read(characterPickedByUserProvider.notifier).state = true;
      },
      onRetag: (mod) => widget.onRetag(mod, id),
    );

    return Container(
      width: CharacterList.width,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: palette.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text),
                  decoration: InputDecoration(
                    hintText: loc.t('library.list.filter_hint'),
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    chip(CharacterListFilter.all, 'library.list.all'),
                    chip(CharacterListFilter.hasMods, 'library.list.has_mods'),
                    chip(CharacterListFilter.active, 'library.list.active'),
                    // No number before a check: "0 updates" and "not checked" are different claims.
                    chip(
                      CharacterListFilter.updates,
                      'library.list.updates',
                      count: ref.watch(modUpdateChecksProvider).isEmpty ? null : withUpdates,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: agents.isEmpty && others.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      loc.t('library.list.no_match'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    // The five other types first: a short block above the long roster, rather than at the end of it.
                    children: [
                      if (others.isNotEmpty) ...[
                        _Label(loc.t('library.list.other_types'), top: 6),
                        for (final id in others) row(id),
                      ],
                      if (agents.isNotEmpty) ...[
                        _Label(loc.t('library.list.agents'), top: others.isEmpty ? 6 : 14),
                        for (final id in agents) row(id),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.top});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(10, top, 10, 6),
    child: Text(
      text.toUpperCase(),
      style: ZenithType.of(context).caps.copyWith(color: ZenithPalette.of(context).text3),
    ),
  );
}

class _CharacterRow extends StatelessWidget {
  const _CharacterRow({
    super.key,
    required this.groupId,
    required this.name,
    required this.counts,
    required this.selected,
    required this.onTap,
    required this.onRetag,
  });

  final String groupId;
  final String name;
  final LibraryGroupCounts counts;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<ModInfo> onRetag;

  String _meta(AppLocalizations loc) {
    if (counts.mods == 0) return loc.t('library.list.no_mods');
    final mods = loc.plural('library.list.mods', counts.mods, params: {'count': '${counts.mods}'});
    if (counts.active == 0) return mods;
    return '$mods · ${loc.t('library.list.active_count', params: {'count': '${counts.active}'})}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;

    return DragTarget<ModInfo>(
      onWillAcceptWithDetails: (details) => libraryGroupOf(details.data.characterId) != groupId,
      onAcceptWithDetails: (details) => onRetag(details.data),
      builder: (context, candidates, _) {
        final dropping = candidates.isNotEmpty;
        final row = Material(
          color: selected ? palette.rowSelected : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: dropping ? palette.accent : (selected ? palette.line : Colors.transparent)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            hoverColor: palette.rowHover,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                spacing: 12,
                children: [
                  CharacterTile(groupId: groupId),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                        ),
                        Text(_meta(loc), style: text.bodySmall?.copyWith(color: palette.text3)),
                      ],
                    ),
                  ),
                  if (counts.updates > 0)
                    Tooltip(
                      message: loc.t('library.list.update_dot'),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: palette.amber, shape: BoxShape.circle),
                      ),
                    ),
                  if (counts.active > 0)
                    Tooltip(
                      message: loc.t('library.list.active_dot'),
                      child: Transform.rotate(
                        angle: math.pi / 4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: palette.accent, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Semantics(
            selected: selected,
            child: Opacity(opacity: counts.mods == 0 && !selected && !dropping ? 0.5 : 1, child: row),
          ),
        );
      },
    );
  }
}
