import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/state_providers.dart';
import 'settings_widgets.dart';

/// Persists the content filter. Production is [ApiService.setContentFilter].
typedef ContentFilterWriter = Future<void> Function(ContentFilterMode mode);

/// Settings' **GameBanana** section: how Browse shows mods GameBanana flags as mature.
///
/// The Browse toolbar holds the same control, where the grid is first met. Both write `content_filter` and read
/// [contentFilterProvider], so they cannot disagree.
class GameBananaSection extends ConsumerWidget {
  const GameBananaSection({super.key, this.writer});

  final ContentFilterWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    return SettingsSectionBlock(
      title: loc.t('settings.nav.gamebanana'),
      children: [
        SettingsRow(
          label: loc.t('marketplace.content_filter'),
          description: loc.t('settings.gamebanana.content_filter_hint'),
          trailing: SettingsSegments<ContentFilterMode>(
            value: ref.watch(contentFilterProvider),
            options: [
              for (final mode in ContentFilterMode.values) (mode, loc.t('marketplace.content_filter_${mode.wire}')),
            ],
            onChanged: (mode) {
              ref.read(contentFilterProvider.notifier).state = mode;
              (writer ?? ApiService.setContentFilter)(mode);
            },
          ),
        ),
      ],
    );
  }
}
