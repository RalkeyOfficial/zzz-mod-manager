import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/platform_service.dart';
import '../../services/platform_service_factory.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// Asks which file Launch game should start, and saves the answer. Returns it, or null when the picker was cancelled.
Future<String?> chooseLaunchTarget(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(dialogTitle: context.loc.t('shell.launch.choose'));
  final path = picked?.files.single.path;
  if (path == null) return null;
  await ApiService.setLaunchTarget(path);
  return path;
}

/// Starts the game through the chosen file, asking for one first when none is set.
///
/// A launch that works is its own feedback, the game opening, so only a failure is reported.
Future<void> launchGame(BuildContext context, WidgetRef ref, {PlatformService? platform}) async {
  var target = ref.read(launchTargetProvider);
  if (target.isEmpty) {
    final chosen = await chooseLaunchTarget(context);
    if (chosen == null || !context.mounted) return;
    target = chosen;
  }

  final outcome = await (platform ?? PlatformServiceFactory.getInstance()).launchGame(target);
  if (!context.mounted) return;

  final loc = context.loc;
  final file = p.basename(target);
  switch (outcome) {
    case LaunchOutcome.started:
      return;
    case LaunchOutcome.notFound:
      context.notify.error(loc.t('shell.launch.not_found_title'), body: target);
    case LaunchOutcome.unsupported:
      context.notify.warning(
        loc.t('shell.launch.unsupported_title'),
        body: loc.t('shell.launch.unsupported_body', params: {'file': file}),
      );
    case LaunchOutcome.failed:
      context.notify.error(loc.t('shell.launch.failed_title'), body: file);
  }
}
