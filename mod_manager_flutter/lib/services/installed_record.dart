import '../models/character_info.dart';
import '../models/gamebanana/gb_file.dart';
import '../models/gamebanana/gb_mod.dart';
import '../models/mod_download.dart';

/// What this session holds about the download a mod folder is: its mod page, and the file on record if the page
/// lists it.
///
/// Read from [records], the pages a check, an install or a dialog fetched (`knownModPagesProvider`), never fetched
/// here: the card and the details panel show a file name, an upload date and an author only once the app has asked
/// GameBanana, and say nothing about them before.
({GbMod? page, GbFile? file}) installedRecord(ModInfo mod, Map<int, GbMod> records) =>
    downloadRecord(mod.origin?.base, records);

/// [installedRecord] for one layer of a folder's stack, a patch included.
({GbMod? page, GbFile? file}) downloadRecord(ModDownload? download, Map<int, GbMod> records) {
  final page = download?.modId == null ? null : records[download!.modId];
  if (page == null) return (page: null, file: null);
  final fileId = download!.fileId;
  final file = fileId == null ? null : page.allFiles?.where((f) => f.idRow == fileId).firstOrNull;
  return (page: page, file: file);
}
