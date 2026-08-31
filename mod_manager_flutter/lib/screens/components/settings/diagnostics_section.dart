import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/log/log_setup.dart';
import '../../../services/log/logger.dart';
import '../../../services/platform_service_factory.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import 'settings_row.dart';

/// Persists the log-file setting. Production is [ApiService].
typedef LogSettingWriter = Future<void> Function(bool enabled);

/// Opens the logs folder. Production is the platform service.
typedef LogFolderOpener = Future<bool> Function(String path);

/// Builds the text that goes on the clipboard.
typedef DiagnosticsBuilder = String Function();

/// Puts text on the clipboard. Production is Flutter's own [Clipboard].
typedef ClipboardWriter = Future<void> Function(String text);

/// The Settings tab's **Diagnostics** section: the log file, and the two ways
/// of getting at it.
///
/// Four seams, and each is there because the production version touches
/// something a widget test must not: `ApiService` writes the developer's real
/// `config.json`, the folder opener spawns a file manager, and the clipboard is
/// shared with everything else on the machine.
///
/// The switch's description says **what is in the file**, because the user is
/// being invited to send it to somebody. A control that produces a document
/// about you should say what the document contains.
class DiagnosticsSettingsSection extends ConsumerWidget {
  const DiagnosticsSettingsSection({
    super.key,
    this.writer,
    this.openFolder,
    this.buildDiagnostics,
    this.writeClipboard,
  });

  final LogSettingWriter? writer;
  final LogFolderOpener? openFolder;
  final DiagnosticsBuilder? buildDiagnostics;
  final ClipboardWriter? writeClipboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final enabled = ref.watch(fileLoggingProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: loc.t('settings.diagnostics.write_log'),
          description: loc.t('settings.diagnostics.write_log_hint'),
          trailing: Switch(
            value: enabled,
            onChanged: (value) {
              // The provider first so the switch moves this frame, then the
              // write — the same order and the same reason as every other
              // setting here.
              ref.read(fileLoggingProvider.notifier).state = value;
              (writer ?? ApiService.setFileLogging)(value);
            },
          ),
        ),
        SettingsRow(
          label: loc.t('settings.diagnostics.open_folder'),
          description: loc.t('settings.diagnostics.open_folder_hint'),
          trailing: OutlinedButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(loc.t('settings.diagnostics.open_folder_action')),
            onPressed: () => _openFolder(context),
          ),
        ),
        SettingsRow(
          label: loc.t('settings.diagnostics.copy'),
          description: loc.t('settings.diagnostics.copy_hint'),
          trailing: OutlinedButton.icon(
            icon: const Icon(Icons.copy_all, size: 18),
            label: Text(loc.t('settings.diagnostics.copy_action')),
            onPressed: () => _copy(context),
          ),
        ),
      ],
    );
  }

  Future<void> _openFolder(BuildContext context) async {
    final loc = context.loc;
    final notify = context.notify;
    final opener = openFolder ??
        PlatformServiceFactory.getInstance().openFolderInFileManager;

    // The folder rather than the file: the user is being sent to pick the run
    // that broke out of the last seven, which means seeing all of them.
    final ok = await opener(Log.logsDirectory);
    if (!ok) {
      // Only failure is reported. A file manager that opened is its own
      // confirmation, and a notification saying so would be one more card to
      // dismiss for something already on screen.
      notify.error(
        loc.t('settings.diagnostics.open_failed_title'),
        body: loc.t('settings.diagnostics.open_failed_body'),
      );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final loc = context.loc;
    final notify = context.notify;
    final write = writeClipboard ??
        (String text) => Clipboard.setData(ClipboardData(text: text));

    // From the ring buffer in memory, not by reading the file: it works with
    // the file switched off, it cannot be slow, and the lines are already
    // censored by the same guarantee the file has.
    await write((buildDiagnostics ?? _diagnostics)());
    notify.success(
      loc.t('settings.diagnostics.copied_title'),
      body: loc.t('settings.diagnostics.copied_body'),
    );
  }

  static String _diagnostics() => diagnosticsText();
}
