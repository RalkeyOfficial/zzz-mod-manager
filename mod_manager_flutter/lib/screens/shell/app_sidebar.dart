import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import '../components/downloads_button.dart';
import '../components/sidebar_nav_item.dart';
import 'keycap.dart';
import 'launch_game.dart';

/// The app's main navigation, down the left of every page.
///
/// Updates is a view of the Characters page with every mod shown and only those with an update kept, so it is
/// the current row only while that filter is on.
class AppSidebar extends ConsumerWidget {
  const AppSidebar({super.key});

  static const double width = 216;

  /// Between the sidebar's edges and its rows.
  static const double inset = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final destination = ref.watch(destinationProvider);
    final updatesOnly = ref.watch(modUpdatesOnlyProvider);
    final mods = ref.watch(modsProvider);
    final updates = ref.watch(libraryUpdateCountProvider);
    // Agents only, as on the Characters page: the built-in categories and `unknown` are not characters.
    final characters = mods.map((m) => m.characterId).where((id) => characterById(id) != null).toSet().length;

    void go(AppDestination to) => ref.read(destinationProvider.notifier).state = to;
    final onCharacters = destination == AppDestination.characters;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(right: BorderSide(color: palette.divider)),
      ),
      // Storage and Settings sit at the bottom when there is room, and the whole column scrolls when the window is
      // shorter than it.
      child: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(inset, 14, inset, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 2,
                children: [
                  _SectionLabel(loc.t('navigation.library'), top: 6),
                  SidebarNavItem(
                    icon: Icons.grid_view_rounded,
                    label: loc.t('navigation.characters'),
                    count: characters > 0 ? characters : null,
                    selected: onCharacters && !updatesOnly,
                    onTap: () {
                      ref.read(modUpdatesOnlyProvider.notifier).state = false;
                      go(AppDestination.characters);
                    },
                  ),
                  SidebarNavItem(
                    icon: Icons.arrow_circle_up_rounded,
                    label: loc.t('navigation.updates'),
                    count: updates > 0 ? updates : null,
                    hot: true,
                    selected: onCharacters && updatesOnly,
                    onTap: () {
                      // Index 0 is the ALL group, every mod across characters.
                      ref.read(selectedCharacterIndexProvider.notifier).state = 0;
                      ref.read(modUpdatesOnlyProvider.notifier).state = true;
                      go(AppDestination.characters);
                    },
                  ),
                  _SectionLabel(loc.t('navigation.gamebanana'), top: 18),
                  SidebarNavItem(
                    icon: Icons.explore_outlined,
                    label: loc.t('navigation.browse'),
                    selected: destination == AppDestination.browse,
                    onTap: () => go(AppDestination.browse),
                  ),
                  const DownloadsNavItem(),
                  const Spacer(),
                  const _ZzmiCard(),
                  const SizedBox(height: 8),
                  SidebarNavItem(
                    icon: Icons.pie_chart_outline_rounded,
                    label: loc.t('navigation.storage'),
                    selected: destination == AppDestination.storage,
                    onTap: () => go(AppDestination.storage),
                  ),
                  SidebarNavItem(
                    icon: Icons.tune_rounded,
                    label: loc.t('navigation.settings'),
                    selected: destination == AppDestination.settings,
                    onTap: () => go(AppDestination.settings),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.top});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(12, top, 12, 8),
    child: Text(
      text.toUpperCase(),
      style: ZenithType.of(context).caps.copyWith(color: ZenithPalette.of(context).text3),
    ),
  );
}

/// Whether ZZMI is where Settings says, how many mods are on, the F10 reminder, and Launch game.
class _ZzmiCard extends ConsumerWidget {
  const _ZzmiCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final loc = context.loc;
    final found = ref.watch(zzmiFoundProvider).valueOrNull ?? false;
    final active = ref.watch(modsProvider).where((m) => m.isActive).length;
    final dot = found ? palette.accent : palette.red;
    final secondary = text.bodySmall?.copyWith(color: palette.text2);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            spacing: 8,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: dot.withValues(alpha: 0.25), spreadRadius: 3)],
                ),
              ),
              Expanded(
                child: Text(
                  loc.t(found ? 'shell.zzmi.connected' : 'shell.zzmi.missing'),
                  style: text.labelMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (found)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${loc.plural('shell.zzmi.active', active, params: {'count': '$active'})} · '),
                  ...keycapSentence(context, loc.t('shell.zzmi.press_key'), 'F10'),
                ],
              ),
              style: secondary,
            )
          else
            Text(loc.t('shell.zzmi.missing_hint'), style: secondary),
          SizedBox(
            height: 40,
            child: FilledButton.icon(
              onPressed: () => launchGame(context, ref),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(loc.t('shell.launch.button')),
            ),
          ),
        ],
      ),
    );
  }
}
