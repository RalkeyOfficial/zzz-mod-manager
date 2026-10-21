import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/platform_service.dart';
import '../../services/platform_service_factory.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// The settings that say what Launch game starts and how. See `docs/launch-game.md`.
enum LaunchSetting { target, arguments, runner, prefix }

/// Asks for a path for [setting]: a file for the launcher and the runner, a folder for the prefix. Null when the
/// picker was cancelled. Production is [pickLaunchPath].
typedef LaunchPathPicker = Future<String?> Function(BuildContext context, LaunchSetting setting);

/// Saves [value] for [setting], where null goes back to the default. Production is [writeLaunchSetting]; a test
/// passes its own so nothing reaches the real `config.json`.
typedef LaunchSettingWriter = Future<void> Function(LaunchSetting setting, String? value);

Future<String?> pickLaunchPath(BuildContext context, LaunchSetting setting) async {
  final loc = context.loc;
  switch (setting) {
    case LaunchSetting.prefix:
      return FilePicker.platform.getDirectoryPath(dialogTitle: loc.t('settings.launch.prefix_choose'));
    case LaunchSetting.target:
    case LaunchSetting.runner:
      final title = setting == LaunchSetting.target ? 'shell.launch.choose' : 'settings.launch.runner_choose';
      final picked = await FilePicker.platform.pickFiles(dialogTitle: loc.t(title));
      return picked?.files.single.path;
    case LaunchSetting.arguments:
      return null;
  }
}

Future<void> writeLaunchSetting(LaunchSetting setting, String? value) => switch (setting) {
  LaunchSetting.target => ApiService.setLaunchTarget(value ?? ''),
  LaunchSetting.arguments => ApiService.setLaunchArguments(value),
  LaunchSetting.runner => ApiService.setWineRunner(value ?? ''),
  LaunchSetting.prefix => ApiService.setWinePrefix(value ?? ''),
};

/// Starts the game through the XXMI Launcher beside ZZMI, or the file chosen instead, asking for one when there is
/// neither.
///
/// A launch that works is its own feedback, the game opening, so only a failure is reported, including one the
/// game's anti-cheat will cause when names can't be looked up inside umu-run's container.
Future<void> launchGame(
  BuildContext context,
  WidgetRef ref, {
  PlatformService? platform,
  LaunchPathPicker? picker,
  LaunchSettingWriter? writer,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  var target = ref.read(launchTargetProvider);
  // Looked for again on every press, so a launcher installed since the last look is found.
  if (target.isEmpty) target = await ref.refresh(xxmiLauncherProvider.future) ?? '';
  if (!context.mounted) return;
  if (target.isEmpty) {
    final chosen = await (picker ?? pickLaunchPath)(context, LaunchSetting.target);
    if (chosen == null || !context.mounted) return;
    await (writer ?? writeLaunchSetting)(LaunchSetting.target, chosen);
    target = chosen;
  }

  final request = LaunchRequest(
    executable: target,
    arguments: ref.read(launchArgumentsProvider),
    runner: ref.read(wineRunnerProvider),
    prefix: ref.read(winePrefixProvider),
    useUmu: ref.read(wineUseUmuProvider),
  );
  final result = await (platform ?? PlatformServiceFactory.getInstance()).launchGame(request);
  if (!context.mounted) return;

  final loc = context.loc;
  final file = p.basename(target);
  // Every outcome but a failed start is fixed by a setting on the Settings page.
  final settings = [openSettingsAction(loc, container)];
  switch (result.outcome) {
    case LaunchOutcome.started:
      // Captured before the wait, so the warning still shows if the button has gone by then. It stays until closed,
      // since the user is looking at the game when it arrives.
      final notify = context.notify;
      if (await result.containerDns == false) {
        notify.warning(
          loc.t('shell.launch.container_dns_title'),
          body: loc.t('shell.launch.container_dns_body'),
          stays: true,
          actions: settings,
        );
      }
    case LaunchOutcome.notFound:
      context.notify.error(loc.t('shell.launch.not_found_title'), body: target, actions: settings);
    case LaunchOutcome.unsupported:
      context.notify.error(
        loc.t('shell.launch.unsupported_title'),
        body: loc.t('shell.launch.unsupported_body', params: {'file': file}),
        actions: settings,
      );
    case LaunchOutcome.runnerMissing:
      context.notify.error(
        loc.t('shell.launch.runner_missing_title'),
        body: result.program ?? request.runner,
        actions: settings,
      );
    case LaunchOutcome.prefixRequired:
      context.notify.error(
        loc.t('shell.launch.prefix_required_title'),
        body: loc.t('shell.launch.prefix_required_body'),
        actions: settings,
      );
    case LaunchOutcome.failed:
      context.notify.error(loc.t('shell.launch.failed_title'), body: file);
  }
}
