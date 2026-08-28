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
  final incomplete = outcome.failed.isNotEmpty;

  // Each half is pluralised on its own count rather than composed into a third
  // string with two counts in it: `{count} updates found — {failed} mods
  // couldn't be checked` reads "1 updates found — 1 mods" the moment either
  // lands on one, and this app pluralises every other counted string.
  //
  // **"No updates found" is reserved for a check that finished.** When some
  // mods could not be reached, finding nothing among the rest is a different
  // statement, and the headline has to make that difference itself — a
  // reassuring title with the caveat demoted to the body is the false
  // reassurance this whole three-way split exists to prevent.
  final title = switch ((found, incomplete)) {
    (> 0, _) => plural('mods.update.bulk_found', found),
    (_, true) => loc.t('mods.update.bulk_none_partial'),
    _ => loc.t('mods.update.bulk_none'),
  };
  final (body, severity) = incomplete
      ? (
          plural('mods.update.bulk_failed', outcome.failed.length),
          NotificationSeverity.warning,
        )
      // Finding updates is not a *problem*, so it stays neutral; the badges on
      // the cards are what the user acts on. How many mods were looked at is
      // the half the badges cannot show, which is what the body is for.
      : (
          plural('mods.update.bulk_checked', outcome.checks.length),
          NotificationSeverity.info,
        );

  // No portrait: this is about a count across the whole library, and one
  // arbitrary face would claim the message is about that mod.
  context.notify.show(
    title,
    body: body,
    severity: severity,
    icon: found > 0 ? Icons.system_update_alt_rounded : null,
  );
}
