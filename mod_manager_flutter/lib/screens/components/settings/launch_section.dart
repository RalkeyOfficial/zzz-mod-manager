import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/state_providers.dart';
import '../../shell/launch_game.dart';
import 'settings_row.dart';

/// Asks for a new launch target and saves it. Production is [chooseLaunchTarget].
typedef LaunchTargetChooser = Future<String?> Function(BuildContext context);

/// The **Launch game with** setting: the file the sidebar's Launch game button starts. It saves when picked.
class LaunchSettingsSection extends ConsumerWidget {
  const LaunchSettingsSection({super.key, this.chooser});

  final LaunchTargetChooser? chooser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final target = ref.watch(launchTargetProvider);

    return SettingsRow(
      label: loc.t('settings.launch.label'),
      description: target.isEmpty ? loc.t('settings.launch.hint') : target,
      descriptionStyle: target.isEmpty ? null : ZenithType.of(context).mono.copyWith(color: palette.text2),
      trailing: OutlinedButton(
        onPressed: () => (chooser ?? chooseLaunchTarget)(context),
        child: Text(loc.t('settings.launch.choose')),
      ),
    );
  }
}
