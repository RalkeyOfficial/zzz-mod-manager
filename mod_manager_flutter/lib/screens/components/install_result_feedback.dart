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
/// **A success says one thing: the mod arrived.** It used to carry a paragraph
/// underneath naming the character it was filed under and which fields were
/// copied off the mod page — the app narrating its own routine work at the one
/// moment the user is waiting to hear one fact. All of that is visible on the
/// card a second later anyway.
///
/// What the caller could not leave out travels *beside* it as a second,
/// **warning** notification rather than as body text under the success: a mod
/// that needs something doing to it should not be reported in the same breath,
/// and the same colour, as one that is ready to use. That only became possible
/// with the notification stack — as snackbars the second message replaced the
/// first, so a warning cost you the confirmation.
void showInstallResult(BuildContext context, InstallResult result) {
  final notify = context.notify;
  final loc = context.loc;

  result.when(
    success: (mods, message) {
      final imported = mods.join(', ');
      notify.success(
        loc.t(
          'marketplace.install_success',
          params: {
            'mods': imported.isEmpty
                ? loc.t('marketplace.install_success_default')
                : imported,
          },
        ),
      );
      if (message != null && message.isNotEmpty) notify.warning(message);
    },
    warning: notify.warning,
    error: notify.error,
  );
}
