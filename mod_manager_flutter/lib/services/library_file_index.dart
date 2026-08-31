/// What file names each library folder holds — the disk half of
/// `patch_destination_ranking.dart`.
///
/// Separate from `folder_contents.dart`, which answers *everything* about one
/// folder: `.ini` text, directories, on-disk spellings. Here the question is
/// only "does this folder hold a file called this?", asked of the **whole
/// library at once**, so reading a few kilobytes of `.ini` per folder and
/// building three more sets per folder is work with no reader.
///
/// Names, not paths: a patch author ships files bare and has no idea what layout
/// the folder ended up with. Same rule as `patch_placement.dart`.
library;

import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/constants.dart';

/// Lower-cased basenames of every file in each of [modIds]' folders.
///
/// A folder that is missing or unreadable maps to an **empty set** rather than
/// dropping out: the ranking must return every candidate the user can see, and a
/// folder we could not read is one we know nothing about — not one to hide.
///
/// Best-effort by design, and cheap enough to run while a dialog is opening: one
/// non-recursive-read per entry, no file contents.
Future<Map<String, Set<String>>> readLibraryFileNames({
  required Iterable<String> modIds,
  required String modsPath,
}) async {
  final index = <String, Set<String>>{};
  for (final modId in modIds) {
    index[modId] = await _fileNamesIn(Directory(path.join(modsPath, modId)));
  }
  return index;
}

final String _ours = AppConstants.modMetadataDirName.toLowerCase();

Future<Set<String>> _fileNamesIn(Directory directory) async {
  final names = <String>{};
  try {
    if (!await directory.exists()) return names;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = path
          .relative(entity.path, from: directory.path)
          .replaceAll(r'\', '/')
          .toLowerCase();
      // Ours, not the mod's — a sidecar image must not answer for a texture.
      if (relative == _ours || relative.startsWith('$_ours/')) continue;
      names.add(path.basename(relative));
    }
  } catch (_) {
    // An unreadable folder contributes nothing and takes nothing down.
  }
  return names;
}
