import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../utils/state_providers.dart';
import 'settings_row.dart';

/// Persists the theme choice. Production is [ApiService].
///
/// A seam for the same reason [UpdatesSettingsSection]'s is — see
/// `updates_section.dart`.
typedef ThemeModeWriter = Future<void> Function(ThemeMode mode);

/// Persists the accent choice. Production is [ApiService.setAccent].
typedef AccentWriter = Future<void> Function(AccentChoice accent);

/// The Settings tab's **Appearance** section: light, system, or dark, and the accent.
///
/// Three states rather than a switch, because the third one is the default and
/// a switch cannot express it. *System* is not "dark off" — it is the app
/// deferring to the desktop, which is the only setting that stays right when
/// the desktop changes on a schedule.
///
/// Laid out in the order the brightness runs, light on the left and dark on the
/// right, so *system* sits between the two things it chooses from.
class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key, this.writer, this.accentWriter});

  final ThemeModeWriter? writer;
  final AccentWriter? accentWriter;

  static const _order = [ThemeMode.light, ThemeMode.system, ThemeMode.dark];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final mode = ref.watch(themeModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: loc.t('settings.appearance.theme'),
          description: loc.t('settings.appearance.theme_hint'),
          // Words rather than sun/moon icons: nothing else on this tab is
          // iconographic, and each icon costs the description beside it 30px of
          // width at the narrowest window for a label that is already one word.
          trailing: SegmentedButton<ThemeMode>(
            segments: [
              for (final value in _order)
                ButtonSegment(
                  value: value,
                  label: Text(loc.t('settings.appearance.theme_${value.name}')),
                ),
            ],
            selected: {mode},
            // The tick says what the fill already says, and it is only ever on one
            // segment — so it widens whichever one is selected and the labels
            // shuffle sideways on every press.
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              final value = selection.first;
              // The provider first so the app repaints this frame, then the write
              // so the choice survives a restart — the same order and the same
              // reason as the marketplace's content filter.
              ref.read(themeModeProvider.notifier).state = value;
              (writer ?? ApiService.setThemeMode)(value);
            },
          ),
        ),
        const SizedBox(height: 12),
        SettingsRow(
          label: loc.t('settings.appearance.accent'),
          description: loc.t('settings.appearance.accent_hint'),
          trailing: _AccentPicker(
            selected: ref.watch(accentProvider),
            onPicked: (accent) {
              ref.read(accentProvider.notifier).state = accent;
              (accentWriter ?? ApiService.setAccent)(accent);
            },
          ),
        ),
      ],
    );
  }
}

/// One swatch per accent, each painted in the colour it gives the current theme.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onPicked});

  final AccentChoice selected;
  final ValueChanged<AccentChoice> onPicked;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        for (final accent in AccentChoice.values)
          _Swatch(
            label: context.loc.t('settings.appearance.accent_${accent.name}'),
            color: ZenithPalette.forBrightness(palette.brightness, accent).accent,
            ring: palette.text,
            gap: palette.card,
            outline: palette.control,
            selected: accent == selected,
            onTap: () => onPicked(accent),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.color,
    required this.ring,
    required this.gap,
    required this.outline,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color ring;
  final Color gap;
  final Color outline;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? ring : Colors.transparent, width: 2),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                // Keeps the paper swatch visible on a light card.
                border: Border.all(color: selected ? gap : outline),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
