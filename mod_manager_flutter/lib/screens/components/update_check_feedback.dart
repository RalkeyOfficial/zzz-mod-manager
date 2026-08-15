import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bulk_update_check.dart';
import '../../utils/notifications.dart';

/// What a whole-library update check reports back, as one line.
///
/// A notification rather than a dialog, matching the bulk "assume current" action:
/// the *result* of a check is already on the cards as badges, so a modal would
/// stand between the user and the thing they pressed the button to see. What
/// the line has to carry is only what the badges cannot — how many mods were
/// looked at, and whether any could not be.
///
/// The three-way split matters more than it looks. "No updates" and "no updates
/// among the eleven mods we could actually reach" are different statements, and
/// reporting the second as the first is how a network failure turns into false
/// reassurance across a whole library.
void showUpdateCheckOutcome(
  BuildContext context,
  BulkUpdateCheckOutcome outcome,
) {
  final loc = context.loc;
  String plural(String key, int count) => loc.t(
        '$key${count == 1 ? '_single' : '_plural'}',
        params: {'count': '$count'},
      );

  final found = outcome.updatesFound;
  // Composed from the same two pluralised halves rather than a third string
  // with two counts interpolated into it: `{count} updates found — {failed}
  // mods couldn't be checked` reads "1 updates found — 1 mods" the moment
  // either lands on one, and this app pluralises every other counted string.
  final foundText = found > 0
      ? plural('mods.update.bulk_found', found)
      : loc.t('mods.update.bulk_none');
  final (message, severity) = switch (outcome) {
    BulkUpdateCheckOutcome(failed: final f) when f.isNotEmpty => (
        '$foundText — ${plural('mods.update.bulk_failed', f.length)}',
        NotificationSeverity.warning,
      ),
    // Finding updates is not a *problem*, so it stays neutral; the badges on the
    // cards are what the user acts on.
    _ => (foundText, NotificationSeverity.info),
  };

  context.notify.show(
    message,
    severity: severity,
    icon: found > 0 ? Icons.system_update_alt_rounded : null,
  );
}
