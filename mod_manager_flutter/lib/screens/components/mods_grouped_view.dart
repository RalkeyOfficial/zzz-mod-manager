import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../utils/categories.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import 'own_scroll_controller.dart';

/// The "ALL" tab: cards grouped by character, each group preceded by a
/// section header. Group order follows the canonical roster; mods with no
/// known character fall into a trailing "Other" group. Within-group order
/// honours the active sort, and empty groups simply don't appear (so the
/// active filter naturally hides them).
///
/// The per-mod card is built by [modCardBuilder] (the screen owns that wiring);
/// [addModCard] is the trailing "Add" card, hidden while [isFiltering].
class ModsGroupedView extends ConsumerStatefulWidget {
  const ModsGroupedView({
    super.key,
    required this.visibleSkins,
    required this.isFiltering,
    required this.addModCard,
    required this.modCardBuilder,
  });

  final List<ModInfo> visibleSkins;
  final bool isFiltering;
  final Widget addModCard;
  final Widget Function(ModInfo mod) modCardBuilder;

  @override
  ConsumerState<ModsGroupedView> createState() => _ModsGroupedViewState();
}

class _ModsGroupedViewState extends ConsumerState<ModsGroupedView> {
  // Collapsed group ids (in-memory, by character id).
  final Set<String> _collapsedGroups = {};

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final groups = <String, List<ModInfo>>{};
    for (final mod in widget.visibleSkins) {
      final id = mod.characterId.isEmpty
          ? '__other__'
          : mod.characterId.toLowerCase();
      groups.putIfAbsent(id, () => []).add(mod);
    }

    // Built-in categories first, then the character roster, then any unknown
    // ids (alpha), then "Other".
    final orderedIds = <String>[
      for (final cat in builtInCategories)
        if (groups.containsKey(cat.id)) cat.id,
      for (final id in zzzCharacterIds)
        if (groups.containsKey(id)) id,
    ];
    final leftover =
        groups.keys
            .where(
              (id) =>
                  id != '__other__' &&
                  !zzzCharacterIds.contains(id) &&
                  !isBuiltInCategory(id),
            )
            .toList()
          ..sort();
    orderedIds.addAll(leftover);
    if (groups.containsKey('__other__')) orderedIds.add('__other__');

    const gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 6,
      childAspectRatio: 0.7,
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
    );

    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
    for (final id in orderedIds) {
      final mods = groups[id]!;
      final label = id == '__other__'
          ? loc.t('mods.uncategorized')
          : categoryDisplayName(id, loc);
      final collapsed = _collapsedGroups.contains(id);
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            label,
            mods.length,
            collapsed: collapsed,
            onToggle: () => setState(() {
              if (!_collapsedGroups.remove(id)) _collapsedGroups.add(id);
            }),
          ),
        ),
      );
      if (collapsed) continue;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppConstants.smallPadding,
            0,
            AppConstants.smallPadding,
            12,
          ),
          sliver: SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildBuilderDelegate((context, index) {
              final mod = mods[index];
              return AnimationConfiguration.staggeredGrid(
                key: ValueKey('mod_${mod.id}_${mod.isActive}'),
                position: index,
                columnCount: 6,
                duration: const Duration(milliseconds: 500),
                child: ScaleAnimation(
                  scale: 0.5,
                  curve: Curves.easeOutBack,
                  child: FadeInAnimation(
                    curve: Curves.easeOut,
                    child: widget.modCardBuilder(mod),
                  ),
                ),
              );
            }, childCount: mods.length),
          ),
        ),
      );
    }

    // Trailing "Add" card, hidden while filtering to match the flat grid.
    if (!widget.isFiltering) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppConstants.smallPadding,
            0,
            AppConstants.smallPadding,
            8,
          ),
          sliver: SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildListDelegate([widget.addModCard]),
          ),
        ),
      );
    }

    return OwnScrollController(
      builder: (context, scrollController) => AnimationLimiter(
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
            physics: const BouncingScrollPhysics(),
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  /// Section separator/identifier for a group in the grouped "ALL" view —
  /// renders as `▾ ── Label (count) ─────────────`. The whole row is clickable
  /// to collapse/expand the group.
  Widget _buildSectionHeader(
    String label,
    int count, {
    required bool collapsed,
    required VoidCallback onToggle,
  }) {
    final isDarkMode = ref.read(isDarkModeProvider);
    final lineColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);
    final textColor = isDarkMode
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.72);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppConstants.smallPadding,
        vertical: 4,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 22,
                    color: textColor,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 16,
                  child: Divider(color: lineColor, thickness: 1.5),
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Divider(color: lineColor, thickness: 1.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
