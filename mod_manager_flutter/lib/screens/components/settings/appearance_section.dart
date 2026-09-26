import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../utils/state_providers.dart';
import 'settings_row.dart';

/// Persists the theme choice. Production is [ApiService].
///
/// A seam for the same reason [UpdatesSettingsSection]'s is — see
/// `updates_section.dart`.
typedef ThemeModeWriter = Future<void> Function(ThemeMode mode);

/// The Settings tab's **Appearance** section: light, system, or dark.
///
/// Three states rather than a switch, because the third one is the default and
/// a switch cannot express it. *System* is not "dark off" — it is the app
/// deferring to the desktop, which is the only setting that stays right when
/// the desktop changes on a schedule.
///
/// Laid out in the order the brightness runs, light on the left and dark on the
/// right, so *system* sits between the two things it chooses from.
class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key, this.writer});

  final ThemeModeWriter? writer;

  static const _order = [ThemeMode.light, ThemeMode.system, ThemeMode.dark];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final mode = ref.watch(themeModeProvider);

    return SettingsRow(
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
    );
  }
}
