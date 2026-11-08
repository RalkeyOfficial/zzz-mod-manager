import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../zenith_controls.dart';
import 'settings_widgets.dart';

/// Persists the theme choice. Production is [ApiService.setThemeMode].
///
/// The writers are seams: a test that pressed a choice must not write the developer's real `config.json`.
typedef ThemeModeWriter = Future<void> Function(ThemeMode mode);

/// Persists the accent choice. Production is [ApiService.setAccent].
typedef AccentWriter = Future<void> Function(AccentChoice accent);

/// Persists the language. Production is [ApiService.setLanguage].
typedef LanguageWriter = Future<void> Function(String languageCode);

/// Settings' **Appearance** section: the theme, the accent and the language.
///
/// Dark, light or system. System is not "dark off": it defers to the desktop, which is the only choice that stays
/// right when the desktop changes on a schedule. Each choice goes to its provider first so the app repaints this
/// frame, then to disk so it survives a restart.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key, this.writer, this.accentWriter, this.languageWriter});

  final ThemeModeWriter? writer;
  final AccentWriter? accentWriter;
  final LanguageWriter? languageWriter;

  static const _themes = [ThemeMode.dark, ThemeMode.light, ThemeMode.system];
  static const _languages = ['en', 'uk'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final locale = ref.watch(localeProvider).languageCode;

    return SettingsSectionBlock(
      title: loc.t('settings.nav.appearance'),
      children: [
        SettingsRow(
          label: loc.t('settings.appearance.theme'),
          description: null,
          trailing: ZenithSegments<ThemeMode>(
            value: ref.watch(themeModeProvider),
            options: [for (final mode in _themes) (mode, loc.t('settings.appearance.theme_${mode.name}'))],
            onChanged: (mode) {
              ref.read(themeModeProvider.notifier).state = mode;
              (writer ?? ApiService.setThemeMode)(mode);
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.appearance.accent'),
          description: null,
          trailing: _AccentPicker(
            selected: ref.watch(accentProvider),
            onPicked: (accent) {
              ref.read(accentProvider.notifier).state = accent;
              (accentWriter ?? ApiService.setAccent)(accent);
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.language.label'),
          description: null,
          trailing: SettingsSelect<String>(
            value: _languages.contains(locale) ? locale : 'en',
            semanticLabel: loc.t('settings.language.label'),
            options: [for (final code in _languages) (code, loc.t('language_names.$code'))],
            onChanged: (code) => _changeLanguage(context, ref, code),
          ),
        ),
      ],
    );
  }

  Future<void> _changeLanguage(BuildContext context, WidgetRef ref, String code) async {
    if (code == ref.read(localeProvider).languageCode) return;
    final notify = context.notify;
    final loc = context.loc;
    ref.read(localeProvider.notifier).state = Locale(code);
    try {
      await (languageWriter ?? ApiService.setLanguage)(code);
    } catch (e) {
      final title = loc.t('settings.language.error_title');
      notify.error(title, body: '$e', actions: [copyDetailsAction(loc, notify, title: title, body: '$e')]);
    }
  }
}

/// One swatch per accent, each painted in the colour it gives the current theme. Paper's colour is its primary
/// button, since its accent stays violet.
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
            color: _swatchColor(ZenithPalette.forBrightness(palette.brightness, accent), accent),
            ring: palette.text,
            selected: accent == selected,
            onTap: () => onPicked(accent),
          ),
      ],
    );
  }

  static Color _swatchColor(ZenithPalette palette, AccentChoice accent) =>
      accent == AccentChoice.paper ? palette.primary : palette.accent;
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.color,
    required this.ring,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color ring;
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
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? ring : Colors.transparent, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}
