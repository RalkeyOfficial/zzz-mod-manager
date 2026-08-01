import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/install_result.dart';

/// Renders an [InstallResult] as snackbars.
///
/// Extracted because this block existed twice, byte for byte, in the two places
/// an archive can be installed from — so any wording fix had to be made twice
/// and, predictably, wouldn't be.
void showInstallResult(BuildContext context, InstallResult result) {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;

  result.when(
    success: (mods, message) {
      final imported = mods.join(', ');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.loc.t(
              'marketplace.install_success',
              params: {
                'mods': imported.isEmpty
                    ? context.loc.t('marketplace.install_success_default')
                    : imported,
              },
            ),
          ),
        ),
      );
      // A second snackbar rather than one long one: the detail (auto-tags, mods
      // with no `.ini`) is worth reading but shouldn't crowd the headline.
      if (message != null && message.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    },
    warning: (message) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    },
    error: (message) {
      messenger.showSnackBar(
        SnackBar(backgroundColor: errorColor, content: Text(message)),
      );
    },
  );
}
