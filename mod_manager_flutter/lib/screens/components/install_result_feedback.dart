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
      for (final warning in warnings) {
        notify.warning(
          warning.title,
          body: warning.body,
          characterId: characterId,
        );
      }
      final imported = mods.join(', ');
      notify.success(
        loc.t(mods.length == 1
            ? 'marketplace.install_success_title_single'
            : 'marketplace.install_success_title_plural'),
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
