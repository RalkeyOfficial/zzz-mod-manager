import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/log/logger.dart';
import '../../services/update_apply/update_write_route.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import 'apply_update_flow.dart';

final Logger _log = Logger('update.reinstall');

/// **Writing the version already installed over the folder again**, to repair
/// it.
///
/// The same operation as an update at the same file id, and deliberately the
/// same code: [applyUpdateFlow] takes a `GbFile` and does not care whether it is
/// newer than what is on disk. So a repair inherits the snapshot, the patch
/// set-aside, the leftover removal and the confirmation without any of them
/// being written twice.
///
/// **What it puts back is the author's files, not the folder.** The record
/// licenses removing what this app wrote and nothing else, so a second mod
/// merged in by hand or a texture the user swapped in stays exactly where it is.
/// A repair is therefore *not* a factory reset of the directory, and the
/// confirmation says as much.
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
  // bottom layer records the exact file it came from. Re-checked because this
  // is the call that overwrites a live folder.
  final base = mod.origin?.base;
  final modId = base?.modId;
  final fileId = base?.fileId;
  if (modId == null || fileId == null) return false;

  // **The mod page, not the file list from a version check.** A check asks
  // `Mod/Multi` for the fields a verdict needs; a repair needs the download
  // itself, and the profile is the one response that carries archived files as
  // their own list — which is where the version being repaired usually is by
  // now.
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
    notify.error(
      loc.t('mods.reinstall.offline_title'),
      body: loc.t('mods.reinstall.offline_body', params: {'mod': mod.name}),
      characterId: mod.characterId,
    );
    return false;
  }

  // GameBanana deletes file ids, so this is the ordinary outcome for a mod the
  // author has re-uploaded — not an error in anything.
  final file = fileWithId(profile.allFiles, fileId);
  if (file == null) {
    notify.error(
      loc.t('mods.reinstall.unavailable_title'),
      body: loc.t('mods.reinstall.unavailable_body', params: {'mod': mod.name}),
      characterId: mod.characterId,
    );
    return false;
  }

  // **The same route an update takes**, because the folder can hold a patch
  // over this download and rewriting the bottom layer has to set it aside and
  // place it back. Reinstalling with no route would flatten it.
  final route = updateWriteRoute(origin: mod.origin, subjectModId: modId);
  if (route.kind != UpdateWriteKind.base) return false;

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
