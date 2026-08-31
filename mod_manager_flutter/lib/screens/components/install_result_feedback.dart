import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/install_result.dart';
import '../../utils/notifications.dart';

/// Reports an [InstallResult] to the user.
///
/// Extracted because this block existed twice, byte for byte, in the two places
/// an archive can be installed from — so any wording fix had to be made twice
/// and, predictably, wouldn't be.
///
/// **A success says the mod arrived, and names it.** It does not describe the
/// work: the character it was filed under and the fields copied off the mod page
/// are visible on the card a second later, and listing them buries the one fact
/// being waited for.
///
/// What the caller could not leave out travels *beside* it as its own
/// **warning** rather than as more text under the success: a mod that needs
/// something doing to it should not be reported in the same breath, and the same
/// colour, as one that is ready to use.
void showInstallResult(BuildContext context, InstallResult result) {
  final notify = context.notify;
  final loc = context.loc;

  result.when(
    success: (mods, warnings, characterId) {
      // Warnings first, success last. Four cards is the cap, and three warnings
      // plus a success is exactly four — raised the other way round, the
      // success is the one pushed off, and it is the line that concludes the
      // install. Last also puts it at the bottom, where the eye lands.
      showNotificationLines(context, warnings, characterId: characterId);
      final imported = mods.join(', ');
      notify.success(
        loc.plural('marketplace.install_success_title', mods.length),
        body: imported.isEmpty
            ? loc.t('marketplace.install_success_default')
            : imported,
        characterId: characterId,
      );
    },
    warning: (lines) => notify.warning(lines.title, body: lines.body),
    error: (lines) => notify.error(lines.title, body: lines.body),
  );
}

/// Raises one warning card per line, pinning the ones that say so.
///
/// **A pinned line is one the mod does not work without acting on.** Eight
/// seconds is enough to read that something is wrong and not enough to do
/// anything about it, and these are raised beside the success the user was
/// actually waiting for.
///
/// Shared by the two install paths and by the drag/drop import, which has no
/// [InstallResult] to report but the same things to say.
void showNotificationLines(
  BuildContext context,
  Iterable<NotificationLines> lines, {
  String? characterId,
}) {
  final notify = context.notify;
  for (final line in lines) {
    if (line.pinned) {
      notify.pinned(
        line.title,
        body: line.body,
        severity: NotificationSeverity.warning,
        characterId: characterId,
      );
      continue;
    }
    notify.warning(line.title, body: line.body, characterId: characterId);
  }
}
