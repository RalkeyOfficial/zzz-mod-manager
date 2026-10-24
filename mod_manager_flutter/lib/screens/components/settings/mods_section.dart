import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/backup/retention.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../zenith_switch.dart';
import 'auto_tag_section.dart';
import 'settings_widgets.dart';

/// Persists the preferences below. Production is [ApiService].
///
/// Seams, so a test that pressed a control never writes the developer's real `config.json`.
class ModsSettingsWriters {
  const ModsSettingsWriters({
    this.oneAtATimeDefault,
    this.snapshotsToKeep,
    this.updateCheckOnLaunch,
    this.remindF10,
  });

  final Future<void> Function(bool enabled)? oneAtATimeDefault;
  final Future<void> Function(int count)? snapshotsToKeep;
  final Future<void> Function(bool enabled)? updateCheckOnLaunch;
  final Future<void> Function(bool enabled)? remindF10;
}

/// Settings' **Mods** section: how turning mods on and off, saved versions and update checks behave.
///
/// Every control takes effect at once. The update check is the one opt-in out of the rule that nothing reaches the
/// network without a press, and it governs *checking* only: nothing here applies an update (`docs/applying-updates.md` §7).
class ModsSection extends ConsumerWidget {
  const ModsSection({super.key, this.writers = const ModsSettingsWriters(), this.autoTagRunner});

  final ModsSettingsWriters writers;
  final AutoTagRunner? autoTagRunner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final onAtStart = ref.watch(updateCheckOnLaunchProvider);

    return SettingsSectionBlock(
      title: loc.t('settings.nav.mods'),
      children: [
        SettingsRow(
          label: loc.t('settings.mods.one_at_a_time'),
          description: loc.t('settings.mods.one_at_a_time_hint'),
          trailing: ZenithSwitch(
            value: ref.watch(oneAtATimeDefaultProvider),
            semanticLabel: loc.t('settings.mods.one_at_a_time'),
            onChanged: (value) {
              ref.read(oneAtATimeDefaultProvider.notifier).state = value;
              (writers.oneAtATimeDefault ?? ApiService.setOneAtATimeDefault)(value);
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.mods.snapshots'),
          description: loc.t('settings.mods.snapshots_hint'),
          trailing: SettingsStepper(
            value: ref.watch(snapshotsToKeepProvider),
            min: minSnapshotsToKeep,
            max: maxSnapshotsToKeep,
            fewerLabel: loc.t('settings.mods.snapshots_fewer'),
            moreLabel: loc.t('settings.mods.snapshots_more'),
            onChanged: (count) {
              final lowered = count < ref.read(snapshotsToKeepProvider);
              ref.read(snapshotsToKeepProvider.notifier).state = count;
              (writers.snapshotsToKeep ?? ApiService.setSnapshotsToKeep)(count);
              // The next saved version prunes every mod, so say so while the number is still easy to put back.
              if (lowered) {
                context.notify.note(
                  loc.t('settings.mods.snapshots_lowered_title'),
                  body: loc.plural('settings.mods.snapshots_lowered_body', count, params: {'count': '$count'}),
                );
              }
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.mods.update_check'),
          description: loc.t('settings.mods.update_check_hint'),
          trailing: SettingsSelect<bool>(
            value: onAtStart,
            semanticLabel: loc.t('settings.mods.update_check'),
            options: [
              (true, loc.t('settings.mods.update_check_start')),
              (false, loc.t('settings.mods.update_check_press')),
            ],
            onChanged: (value) {
              ref.read(updateCheckOnLaunchProvider.notifier).state = value;
              (writers.updateCheckOnLaunch ?? ApiService.setUpdateCheckOnLaunch)(value);
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.mods.remind_f10'),
          description: loc.t('settings.mods.remind_f10_hint'),
          trailing: ZenithSwitch(
            value: ref.watch(remindF10Provider),
            semanticLabel: loc.t('settings.mods.remind_f10'),
            onChanged: (value) {
              ref.read(remindF10Provider.notifier).state = value;
              (writers.remindF10 ?? ApiService.setRemindF10)(value);
            },
          ),
        ),
        AutoTagRow(runner: autoTagRunner),
      ],
    );
  }
}
