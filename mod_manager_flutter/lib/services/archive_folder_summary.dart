/// What each folder offered to the folders window holds, read once before the window opens (board `FoldersModal`):
/// how many files, the first `.ini`, how many images, the size, and the guesses drawn as hints beside it.
///
/// The hints inform and never tick, untick or order anything.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../core/constants.dart';

const Set<String> _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};

/// One folder, summarised.
class FolderSummary {
  const FolderSummary({
    required this.path,
    required this.files,
    required this.images,
    required this.bytes,
    this.firstIni,
    this.shaderOnly = false,
  });

  /// Absolute path of the folder.
  final String path;

  /// Every file in it, its subfolders' included; the app's own sidecar folder is not counted.
  final int files;

  final int images;

  /// The sum of the files' lengths.
  final int bytes;

  /// The first `.ini` by path, its file name in the spelling it has on disk.
  final String? firstIni;

  /// It holds shader files and nothing else, a mod of its own that needs no `.ini`.
  final bool shaderOnly;

  String get name => p.basename(path);

  /// No `.ini`, and every file an image: most likely the archive's previews.
  bool get looksLikePreviews => firstIni == null && !shaderOnly && files > 0 && images == files;
}

/// Each of [folders], summarised, in the order given. The walks run off the caller's isolate.
Future<List<FolderSummary>> summariseFolders(List<String> folders) =>
    Isolate.run(() => [for (final folder in folders) summariseFolderSync(folder)]);

/// [folder], summarised, on the caller's isolate. A folder that cannot be read counts as empty.
FolderSummary summariseFolderSync(String folder) {
  var files = 0;
  var images = 0;
  var bytes = 0;
  var shaderFiles = 0;
  final inis = <String>[];
  try {
    for (final entity in Directory(folder).listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: folder);
      final parts = p.split(relative);
      if (parts.first == AppConstants.modMetadataDirName) continue;
      files++;
      try {
        bytes += entity.lengthSync();
      } catch (_) {}
      final extension = p.extension(relative).toLowerCase();
      if (extension == '.ini') inis.add(relative);
      if (_imageExtensions.contains(extension)) images++;
      if (parts.first.toLowerCase() == 'shaderfixes') shaderFiles++;
    }
  } catch (_) {
    return FolderSummary(path: folder, files: 0, images: 0, bytes: 0);
  }
  inis.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return FolderSummary(
    path: folder,
    files: files,
    images: images,
    bytes: bytes,
    firstIni: inis.isEmpty ? null : p.basename(inis.first),
    shaderOnly: inis.isEmpty && files > 0 && shaderFiles == files,
  );
}

/// Whether [folderName] is named like [mod]'s own folder or one of the folders its record says it was installed from.
bool namedLikeMod(String folderName, {required String modId, Iterable<String> recorded = const <String>[]}) {
  final name = folderName.toLowerCase();
  return name == modId.toLowerCase() || recorded.any((folder) => folder.toLowerCase() == name);
}

/// Whether [folderName] is named like the archive [archiveName], its extension left out.
bool namedLikeArchive(String folderName, String? archiveName) {
  if (archiveName == null || archiveName.isEmpty) return false;
  return folderName.toLowerCase() == p.basenameWithoutExtension(archiveName).toLowerCase();
}
