import '../models/character_info.dart';
import '../models/gamebanana/gb_file.dart';
import '../models/gamebanana/gb_mod.dart';

/// What this session's update check fetched about the download a mod folder is: its mod page, and the file on
/// record if the page lists it.
///
/// Read from the records a check left behind, never fetched: the card and the details panel show a file name, an
/// upload date and an author only once the user has asked GameBanana, and say nothing about them before.
({GbMod? page, GbFile? file}) installedRecord(ModInfo mod, Map<int, GbMod> records) {
  final base = mod.origin?.base;
  final page = base?.modId == null ? null : records[base!.modId];
  if (page == null) return (page: null, file: null);
  final fileId = base!.fileId;
  final file = fileId == null ? null : page.allFiles?.where((f) => f.idRow == fileId).firstOrNull;
  return (page: page, file: file);
}
