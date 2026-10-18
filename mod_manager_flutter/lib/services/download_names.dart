import '../models/character_info.dart';
import '../models/gamebanana/gb_mod.dart';
import '../models/mod_origin.dart';
import 'log/logger.dart';
import 'origin_write.dart';

final Logger _log = Logger('origin');

/// [origin] with every layer that [pages] holds a page for carrying that page's title, or null when no layer's
/// name changes.
///
/// `ModDownload.name` is a display copy of the remote's name, written back here by the update checks: a folder
/// then lists its downloads by name after a restart, with no request (`docs/origin-tracking.md` §10).
ModOrigin? withPageNames(ModOrigin? origin, Map<int, GbMod> pages) {
  if (origin == null) return null;
  var changed = false;
  final downloads = [...origin.downloads];
  for (final (i, download) in origin.downloads.indexed) {
    if (_nameIn(pages, download.modId) case final name? when name != download.name) {
      downloads[i] = download.copyWith(name: name);
      changed = true;
    }
  }
  return changed ? origin.copyWith(downloads: downloads) : null;
}

/// Writes the names [pages] give to the layers of [mods] whose sidecars hold a different one. True when any
/// sidecar was written, so the caller can rescan.
///
/// Each write re-reads the sidecar and is declined when the name is already there, so a page fetched twice writes
/// once. A failed write is logged and otherwise left alone: the name is a convenience, and the next fetch tries again.
Future<bool> rememberDownloadNames({
  required Iterable<ModInfo> mods,
  required Map<int, GbMod> pages,
  required OriginWriter write,
}) async {
  if (pages.isEmpty) return false;
  var wrote = false;
  for (final mod in mods) {
    // Read off the scan first, so a library of a hundred mods with nothing to change touches no file.
    if (withPageNames(mod.origin, pages) == null) continue;
    final result = await write(mod.id, (current) => withPageNames(current, pages));
    if (result.ok) {
      wrote = true;
    } else if (result != OriginWriteResult.declined) {
      _log.warning('a download name was not saved', fields: {'mod': mod.id, 'result': result.name});
    }
  }
  return wrote;
}

String? _nameIn(Map<int, GbMod> pages, int? modId) {
  if (modId == null) return null;
  final name = pages[modId]?.name?.trim();
  return name == null || name.isEmpty ? null : name;
}
