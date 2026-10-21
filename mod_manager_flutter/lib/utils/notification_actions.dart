/// The actions several kinds of card carry, built in one place so a label and what pressing it does are the same
/// wherever a card offers it.
///
/// Each takes what it needs up front, never a `BuildContext`: the card is drawn above the `Navigator` and outlives
/// the widget that raised it. An action's own failure is reported on a card of its own, since the card it was on has
/// closed by then.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/platform_service_factory.dart';
import 'notifications.dart';
import 'state_providers.dart';

/// Opens a folder in the system file manager. Production is `PlatformService.openFolderInFileManager`.
typedef NotificationFolderOpener = Future<bool> Function(String folder);

/// **Open folder**: shows [folder] in the file manager. For a file, pass the folder it is in.
NotificationAction openFolderAction(
  AppLocalizations loc,
  NotificationCenter notify,
  String folder, {
  NotificationFolderOpener? opener,
}) =>
    NotificationAction(loc.t('notifications.actions.open_folder'), () async {
      final open = opener ?? PlatformServiceFactory.getInstance().openFolderInFileManager;
      var ok = false;
      try {
        ok = await open(folder);
      } catch (_) {}
      if (!ok) notify.error(loc.t('notifications.open_folder_failed_title'), body: folder);
    });

/// **Copy details**: puts an error's [title] and [body] on the clipboard, for an error whose body is a raw exception
/// the user may want to paste into a bug report. The clipboard can't be seen, so a Done card says it worked.
NotificationAction copyDetailsAction(
  AppLocalizations loc,
  NotificationCenter notify, {
  required String title,
  required String body,
}) =>
    NotificationAction(loc.t('notifications.actions.copy_details'), () async {
      try {
        await Clipboard.setData(ClipboardData(text: '$title\n$body'));
      } catch (_) {
        notify.error(loc.t('notifications.copy_failed_title'), body: title);
        return;
      }
      notify.done(loc.t('notifications.copied_title'), body: title);
    });

/// **Open Settings**: for a card that tells the user to fix a setting. Settings is one column with no anchors, so
/// this opens the page rather than the field.
NotificationAction openSettingsAction(AppLocalizations loc, ProviderContainer container) =>
    NotificationAction(loc.t('notifications.actions.open_settings'), () {
      container.read(destinationProvider.notifier).state = AppDestination.settings;
    });

/// **Open Downloads**: opens the sidebar's Downloads panel, which keeps the per-download view.
NotificationAction openDownloadsAction(AppLocalizations loc, ProviderContainer container) =>
    NotificationAction(loc.t('notifications.actions.open_downloads'), () {
      container.read(downloadsPanelRequestProvider.notifier).state++;
    });

/// **Try again**: runs [retry], for a failure where running the same thing again is safe and may well work.
NotificationAction retryAction(AppLocalizations loc, void Function() retry) =>
    NotificationAction(loc.t('notifications.actions.retry'), retry);

/// **Undo**: runs [undo], for a write that took a snapshot first, so it can be put back.
NotificationAction undoAction(AppLocalizations loc, void Function() undo) =>
    NotificationAction(loc.t('notifications.actions.undo'), undo);
