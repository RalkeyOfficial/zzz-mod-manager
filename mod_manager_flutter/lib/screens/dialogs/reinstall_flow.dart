import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/origin_enums.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/log/logger.dart';
import '../../services/update_apply/update_write_route.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'apply_update_flow.dart';

final Logger _log = Logger('update.reinstall');

/// Whether [mod] can be reinstalled: its base records the file it came from, confirmed or worked out, and it is
/// tracked. A worked-out file reads as the user's file everywhere (`OriginConfidence.namesFile`), so it is offered here
/// too; a wrong one is undone from the snapshot taken first. A date with no file names nothing to download, and a mod
/// marked Local was said not to come from its page. The right-click menu and the History tab of the mod's page both
/// ask this.
bool canReinstall(ModInfo mod) {
  final origin = mod.origin;
  final base = origin?.base;
  return base != null &&
      base.modId != null &&
      base.fileId != null &&
      base.versionConfidence.namesFile &&
      origin!.tracking != OriginTracking.off;
}

/// **Writing the version already installed over the folder again**, to repair
/// it.
///
/// The same operation as an update at the same file id, and deliberately the
/// same code: [applyUpdateFlow] takes a `GbFile` and does not care whether it is
/// newer than what is on disk. So a repair inherits the snapshot, the patch
/// set-aside, the old-file removal and the confirmation without any of them
/// being written twice.
///
/// **What it removes is what the record says the last version wrote and the file does not ship.**
/// With a record, a second mod merged in by hand or a texture the user swapped in stays where it is.
/// With none, the whole folder counts as the last version, and the confirmation names what goes.
///
/// The surface exists because the update dialog only appears when there is a
/// finding, and a repair is wanted precisely when there is none — a mod broken
/// by a game patch, a file deleted by accident, an edit that went wrong.
///
/// Returns true when the mod folder changed, so the caller rescans.
Future<bool> reinstallFlow(
  BuildContext context,
  WidgetRef ref, {
  required ModInfo mod,
}) async {
  final loc = context.loc;
  final notify = context.notify;

  // Both guaranteed by the menu entry, which is only offered for a folder whose
  // bottom layer records the file it came from. Re-checked because this is the
  // call that overwrites a live folder.
  final base = mod.origin?.base;
  final modId = base?.modId;
  final fileId = base?.fileId;
  if (modId == null || fileId == null) return false;

  // **The mod page, not the file list from a version check.** A check asks
  // `Mod/Multi` for the fields a verdict needs; a repair needs the download
  // itself, and the profile is the one response that carries archived files as
  // their own list — which is where the version being repaired usually is by
  // now.
  // Up until the download's modal, which carries on from it; a failure to get the file turns it into that error.
  final fetching = notify.working(
    loc.t('mods.reinstall.fetching_title'),
    body: mod.name,
    characterId: mod.characterId,
  );
  var ended = false;
  void fail(String title, String body) {
    fetching.update(kind: NotificationKind.error, title: title, body: body);
    ended = true;
  }

  final GbFile file;
  final UpdateWriteRoute route;
  try {
    GbMod? profile;
    try {
      profile = await ref.read(gameBananaClientProvider).modProfile(modId);
    } catch (e) {
      _log.warning('could not fetch the page to reinstall from',
          error: e, fields: {'mod': modId, 'file': fileId});
    }

    if (!context.mounted) return false;

    // **Two messages, because they are two different situations.** A page that
    // would not load is worth trying again; a file that is no longer published
    // never will be, and saying "check your connection" about it would send the
    // user round a loop that cannot end.
    if (profile == null) {
      fail(
        loc.t('mods.reinstall.offline_title'),
        loc.t('mods.reinstall.offline_body', params: {'mod': mod.name}),
      );
      return false;
    }

    // GameBanana deletes file ids, so this is the ordinary outcome for a mod the
    // author has re-uploaded — not an error in anything.
    final published = fileWithId(profile.allFiles, fileId);
    if (published == null) {
      fail(
        loc.t('mods.reinstall.unavailable_title'),
        loc.t('mods.reinstall.unavailable_body', params: {'mod': mod.name}),
      );
      return false;
    }
    file = published;

    // **The same route an update takes**, because the folder can hold a patch
    // over this download and rewriting the bottom layer has to set it aside and
    // place it back. Reinstalling with no route would flatten it.
    route = updateWriteRoute(origin: mod.origin, subjectModId: modId);
    if (route.kind != UpdateWriteKind.base) return false;
  } finally {
    if (!ended) fetching.dismiss();
  }

  return applyUpdateFlow(
    context,
    ref,
    mod: mod,
    remoteModId: modId,
    file: file,
    patchFiles: route.patchFiles,
    patchModId: route.patchModId,
    asCompanion: route.asCompanion,
    flattensPatch: route.flattensPatch,
    reinstall: true,
  );
}
