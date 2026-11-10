import '../models/character_info.dart';
import 'update_apply/update_write_route.dart';
import 'update_check.dart';

/// The mods with an update to show, each with its check, the most recently uploaded newer file first. The same set
/// the sidebar's Updates count covers.
List<(ModInfo, UpdateCheck)> newerFilesOf(List<ModInfo> mods, Map<String, UpdateCheck> checks) {
  final found = [
    for (final mod in mods)
      if (checks[mod.id] case final check? when check.hasUpdate) (mod, check),
  ];
  found.sort(_newestFirst);
  return found;
}

/// The mods with a newer file to install, in the order of [newerFilesOf]: the ones the bulk "Update N" lists.
///
/// Narrower than [newerFilesOf], whose count is the sidebar's: a verdict with no file to name ("its page changed", a
/// taken-down file whose page lists only files released with it) is an update to know about and has nothing to
/// install, and so is a verdict about a mod the folder does not claim to hold, which no write could apply.
List<(ModInfo, UpdateCheck)> installableUpdatesOf(List<ModInfo> mods, Map<String, UpdateCheck> checks) => [
  for (final (mod, check) in newerFilesOf(mods, checks))
    if (check.newerFiles.isNotEmpty && updateWriteRoute(origin: mod.origin, subject: check.subject).kind != UpdateWriteKind.none)
      (mod, check),
];

int _newestFirst((ModInfo, UpdateCheck) a, (ModInfo, UpdateCheck) b) {
  final da = a.$2.dismissableUpTo;
  final db = b.$2.dismissableUpTo;
  if (da == null || db == null) return (da == null ? 1 : 0) - (db == null ? 1 : 0);
  return db.compareTo(da);
}
