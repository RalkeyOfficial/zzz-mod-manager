import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../utils/state_providers.dart';
import '../tracking_nudge.dart';
import 'settings_row.dart';

/// Persists the startup-check setting. Production is [ApiService].
///
/// A seam because `ApiService` lazily builds a `ConfigService` against the
/// developer's **real** `<appData>/config.json`, so a test that merely mounted
/// this section would rewrite their library paths and favourites.
typedef UpdateSettingWriter = Future<void> Function(bool enabled);

/// The Settings tab's **Updates** section.
///
/// The first switch's wording is load-bearing: it says *check*, never
/// *update*. Applying an update overwrites a live install, and this app never
/// does that unattended — see `docs/applying-updates.md` §7. A switch a user
/// could read as consenting to automatic installs would be promising something
/// deliberately not built.
///
/// The description states the cost rather than the benefit. Turning this on is
/// the one thing in the app that contacts GameBanana without a press, and
/// somebody who would not want that has to be able to see it from the label.
///
/// The second switch brings back the reminder about mods not set up for update checking,
/// which closing the reminder itself turns off.
class UpdatesSettingsSection extends ConsumerWidget {
  const UpdatesSettingsSection({super.key, this.writer, this.nudgeWriter});

  final UpdateSettingWriter? writer;
  final NudgeDismissWriter? nudgeWriter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final enabled = ref.watch(updateCheckOnLaunchProvider);
    final nudgeDismissed = ref.watch(trackingNudgeDismissedProvider);

    return Column(
      children: [
        SettingsRow(
          label: loc.t('settings.updates.check_on_launch'),
          description: loc.t('settings.updates.check_on_launch_hint'),
          trailing: Switch(
            value: enabled,
            onChanged: (value) {
              // The provider first so the switch moves this frame, then the write
              // so the choice survives a restart — the same order and the same
              // reason as the marketplace's content filter.
              ref.read(updateCheckOnLaunchProvider.notifier).state = value;
              (writer ?? ApiService.setUpdateCheckOnLaunch)(value);
            },
          ),
        ),
        const SizedBox(height: 8),
        SettingsRow(
          label: loc.t('settings.updates.tracking_nudge'),
          description: loc.t('settings.updates.tracking_nudge_hint'),
          trailing: Switch(
            value: !nudgeDismissed,
            onChanged: (value) {
              ref.read(trackingNudgeDismissedProvider.notifier).state = !value;
              (nudgeWriter ?? ApiService.setTrackingNudgeDismissed)(!value);
            },
          ),
        ),
      ],
    );
  }
}
