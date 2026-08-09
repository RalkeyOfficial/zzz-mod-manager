import 'dart:io';

import 'package:path/path.dart' as path;

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
/// Returns how many files were written.
Future<int> copyDirectory(
  Directory source,
  Directory destination, {
  bool Function(String relativePath)? skipRelative,
}) async {
  return _copy(source, destination, source.path, skipRelative ?? _keepAll);
}

bool _keepAll(String _) => false;

Future<int> _copy(
  Directory source,
  Directory destination,
  String root,
  bool Function(String) skip,
) async {
  await destination.create(recursive: true);
  var written = 0;

  await for (final entity in source.list(recursive: false, followLinks: false)) {
    final relative =
        path.relative(entity.path, from: root).replaceAll(r'\', '/');
    if (skip(relative)) continue;

    final target = path.join(destination.path, path.basename(entity.path));
    if (entity is Directory) {
      written += await _copy(entity, Directory(target), root, skip);
    } else if (entity is File) {
      await entity.copy(target);
      written++;
    }
    // Links are deliberately not followed and not recreated. Nothing this app
    // installs contains one, and reproducing a link that points outside the
    // folder would make a snapshot claim to hold data it does not.
  }

  return written;
}
