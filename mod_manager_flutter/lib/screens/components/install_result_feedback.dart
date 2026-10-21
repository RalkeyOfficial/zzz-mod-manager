import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/install_result.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';

/// Reports an [InstallResult] to the user.
///
/// **A success says the mod arrived, and names it.** It does not describe the work: the character it was filed
/// under and the fields copied off the mod page are visible on the card a second later, and listing them buries the
/// one fact being waited for. Several installs in a row count on one card, "3 mods installed".
///
/// What the caller could not leave out travels *beside* it as its own card rather than as more text under the
/// success: a mod that needs something doing to it should not be reported in the same breath, and the same colour,
/// as one that is ready to use.
///
/// [into] is the install's Working card, turned into the result in place rather than raising a second card.
/// [characterId] leads a failure's card; a success carries its own.
void showInstallResult(
  BuildContext context,
  InstallResult result, {
  NotificationHandle? into,
  String? characterId,
}) {
  final notify = context.notify;

  // A cancelled install reports nothing, and the card it was handed goes with it.
  if (result.mods.isEmpty && result.failure == null) into?.dismiss();

  result.when(
    success: (mods, warnings, installedFor) {
      // Warnings first, the result last, so it concludes the burst at the bottom where the eye lands.
      showNotificationLines(context, warnings, characterId: installedFor);
      _reportInstalled(context, mods, installedFor: installedFor, into: into);
    },
    failed: (lines) {
      if (into != null) {
        into.update(
          kind: lines.kind,
          title: lines.title,
          body: lines.body,
          characterId: characterId,
          clearCharacterId: characterId == null,
          actions: lines.actions,
        );
        return;
      }
      notify.show(lines.kind, lines.title, body: lines.body, characterId: characterId, actions: lines.actions);
    },
  );
}

/// The success line for [mods], "Mod installed / Ellen Swimsuit", turning [into] into it when given. Several in a row
/// count on one card, "3 mods installed".
///
/// [installedFor] is the portrait, drawn only for one folder, which also gets Open.
void _reportInstalled(
  BuildContext context,
  List<String> mods, {
  String? installedFor,
  NotificationHandle? into,
}) {
  final notify = context.notify;
  final loc = context.loc;
  final container = ProviderScope.containerOf(context, listen: false);

  final imported = mods.join(', ');
  final title = loc.plural('marketplace.install_success_title', mods.length);
  final body = imported.isEmpty ? loc.t('marketplace.install_success_default') : imported;
  // A portrait and an Open only for one folder: several are not one mod to show.
  final one = mods.length == 1 ? mods.single : null;
  final portrait = one == null ? null : installedFor;
  final actions = [
    if (one != null)
      NotificationAction(loc.t('notifications.actions.open'), () async {
        // Removed or renamed since it arrived: there is nothing to show. A library that couldn't be read shows its
        // error on the Characters view instead.
        if (await showModInCharacters(container, one) == ShowModResult.notInLibrary) {
          notify.note(loc.t('notifications.mod_gone'), body: one);
        }
      }),
  ];
  // Counted by mod, so an archive of three folders and one more mod read "4 mods installed".
  final repeat = NotificationRepeat(
    'install-done',
    subjects: mods.isEmpty ? [body] : mods,
    title: (count) => loc.plural('notifications.repeat.installed', count, params: {'count': '$count'}),
  );
  if (into != null) {
    into.update(
      kind: NotificationKind.done,
      title: title,
      body: body,
      characterId: portrait,
      clearCharacterId: portrait == null,
      clearIcon: true,
      actions: actions,
      repeat: repeat,
    );
    return;
  }
  notify.done(title, body: body, characterId: portrait, actions: actions, repeat: repeat);
}

/// Raises one card per line, each of its own kind; a staying warning waits until it is closed.
///
/// **A staying line is one the mod does not work without acting on.** Eight seconds is enough to read that
/// something is wrong and not enough to do anything about it, and these are raised beside the success the user was
/// actually waiting for.
///
/// [characterId] is the portrait for a line that names none of its own. Shared by the install path and by the
/// drag/drop import, which has no [InstallResult] to report but the same things to say.
void showNotificationLines(
  BuildContext context,
  Iterable<NotificationLines> lines, {
  String? characterId,
}) {
  final notify = context.notify;
  for (final line in lines) {
    notify.show(
      line.kind,
      line.title,
      body: line.body,
      stays: line.stays,
      characterId: line.characterId ?? characterId,
      repeat: line.repeat,
      actions: line.actions,
    );
  }
}
