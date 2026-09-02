import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/installed_file.dart';

/// Recursive directory copy with **overwrite** semantics, shared by the import
/// path and the update path.
///
/// `Directory.create(recursive: true)` no-ops on a directory that already
/// exists and `File.copy` replaces its destination, so colliding files are
/// replaced and everything else in the destination is left exactly where it is.
/// That is precisely the behaviour an update needs: a mod folder frequently
/// holds files from a second download — a patch, or a hand-merge — and
/// *replacing* the folder destroys them, while overwriting the colliding files
/// leaves them alone.
///
/// [skipRelative] is given each entry's path relative to [source], with `/`
/// separators, and skips both files and whole subtrees. The update path uses it
/// to exclude `.zzz-mod-manager/`: an archive can legitimately contain a sidecar
/// of its own the moment anyone shares a folder they managed with this app, and
/// an unfiltered copy would overwrite the user's description, gallery and origin
/// block with a stranger's — including the block that decides which mod page we
/// check.
///
/// **Returns every file it wrote**, each relative to [destination] in the
/// spelling it now has on disk, sized, and marked by whether something was
/// already at that path.
///
/// This is the one place that can answer any of those three without a second
/// walk: the entry is in hand, the size comes off the copy, and only the code
/// about to overwrite a path knows whether it was occupied. A caller that wants
/// the old count takes `.length`.
///
/// **The check runs before the copy**, or every path would report itself as
/// occupied by the file just written.
Future<List<InstalledFile>> copyDirectory(
  Directory source,
  Directory destination, {
  bool Function(String relativePath)? skipRelative,
}) async {
  final written = <InstalledFile>[];
  await _copy(
    source,
    destination,
    source.path,
    destination.path,
    skipRelative ?? _keepAll,
    written,
  );
  return written;
}

bool _keepAll(String _) => false;

Future<void> _copy(
  Directory source,
  Directory destination,
  String sourceRoot,
  String destinationRoot,
  bool Function(String) skip,
  List<InstalledFile> written,
) async {
  await destination.create(recursive: true);

  await for (final entity in source.list(recursive: false, followLinks: false)) {
    final relative =
        path.relative(entity.path, from: sourceRoot).replaceAll(r'\', '/');
    if (skip(relative)) continue;

    final target = path.join(destination.path, path.basename(entity.path));
    if (entity is Directory) {
      await _copy(
          entity, Directory(target), sourceRoot, destinationRoot, skip, written);
    } else if (entity is File) {
      final existed = await File(target).exists();
      final copied = await entity.copy(target);
      written.add(InstalledFile(
        // Relative to where it landed, not to where it came from: a combined
        // install renames its folders on the way in, so the source-relative
        // path names a file the mod folder does not have.
        path: path.relative(copied.path, from: destinationRoot)
            .replaceAll(r'\', '/'),
        bytes: await _sizeOf(copied),
        role: existed ? InstalledFileRole.replaced : InstalledFileRole.added,
      ));
    }
    // Links are deliberately not followed and not recreated — `followLinks:
    // false` yields a `Link`, which matches neither branch above.
    //
    // Nothing this app installs contains one, and reproducing a link that
    // points outside the folder would make a snapshot claim to hold data it
    // does not. Following them is worse than useless on the **import** path
    // too: a link out of the folder copies an unbounded amount of unrelated
    // disk into the library, and one pointing at an ancestor recurses forever.
  }
}

/// Zero rather than throwing. A size that could not be read is a weaker record
/// of a file that copied successfully, and failing the copy over it would trade
/// a working install for a missing one.
Future<int> _sizeOf(File file) async {
  try {
    return await file.length();
  } catch (_) {
    return 0;
  }
}
