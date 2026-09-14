/// Measuring a directory tree, once, for everything that asks.
///
/// Its own file because three callers want the same walk for three unrelated
/// reasons — what a snapshot came to, whether an import will fit, and what the
/// Storage page reports — and the rules about links below are the kind that get
/// half-remembered when they are copied.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

/// The size of a directory tree, and how much of it could be read.
///
/// [complete] is the point of the type. A walk that skipped something still
/// returns a number, and a caller that reads that number as a fact can be badly
/// wrong in one direction: an import preflight that under-reads by one
/// unreadable folder refuses nothing and runs out of disk halfway through the
/// copy. So what was skipped travels with the total, and each caller decides
/// for itself whether a floor will do.
class DirSize {
  const DirSize({
    required this.bytes,
    required this.fileCount,
    required this.unreadable,
  });

  static const DirSize empty =
      DirSize(bytes: 0, fileCount: 0, unreadable: 0);

  /// The sum of file lengths — **apparent** size, not what the filesystem
  /// allocated. Compression, sparse files and copy-on-write clones all make the
  /// two disagree, sometimes by a lot, so this never predicts how much space
  /// deleting the tree would free.
  final int bytes;

  final int fileCount;

  /// Entries that could not be listed or measured. Each one means [bytes] is a
  /// floor rather than a total.
  final int unreadable;

  bool get complete => unreadable == 0;
}

/// Every byte under [rootPath], never following a link out of it.
///
/// Synchronous on purpose. The async directory stream turns every entry into a
/// microtask, and a library of a few hundred thousand files is a few hundred
/// thousand of them on whichever isolate asked; [measureDirectory] is this same
/// walk moved off that isolate, and it can only be that because this one takes
/// plain arguments and returns plain data.
///
/// **Containment is decided by resolved path, not by entity type.** A symlinked
/// directory comes back from `listSync(followLinks: false)` as a [Link] and the
/// type test below skips it — but a **Windows junction comes back as a
/// [Directory]** and the walk would happily descend. That matters here more
/// than in most apps: mods are activated by linking them into the game folder,
/// so descending a link either counts a mod twice or leaves the library
/// altogether, and one pointing at an ancestor recurses until something gives.
/// Resolving each directory before descending is the only check that catches
/// symlinks, junctions and bind mounts alike, and it costs one syscall per
/// directory rather than per file.
///
/// A [Link] is never counted: it holds no bytes of its own, and the thing it
/// points at is either inside the tree already or none of the tree's business.
///
/// Directories in [excludePaths] are not descended into. Their paths are
/// resolved the same way, so excluding a directory excludes the link that
/// reaches it too.
DirSize measureDirectorySync(
  String rootPath, {
  Set<String> excludePaths = const <String>{},
}) {
  final String root;
  try {
    root = Directory(rootPath).resolveSymbolicLinksSync();
  } catch (_) {
    // Missing or unreadable at the root: nothing was measured, and saying so is
    // the difference between "empty" and "don't trust this".
    return const DirSize(bytes: 0, fileCount: 0, unreadable: 1);
  }

  final excluded = <String>{};
  for (final candidate in excludePaths) {
    try {
      excluded.add(Directory(candidate).resolveSymbolicLinksSync());
    } catch (_) {
      // Nothing there to exclude.
    }
  }

  var bytes = 0;
  var fileCount = 0;
  var unreadable = 0;

  // Resolved paths throughout, which is what makes the visited set able to stop
  // a cycle: two routes to one directory are one entry.
  final visited = <String>{root};
  final pending = <String>[root];

  while (pending.isNotEmpty) {
    final current = pending.removeLast();

    final List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      unreadable++;
      continue;
    }

    for (final entry in entries) {
      if (entry is File) {
        // Caught per file rather than around the loop. Wrapping the whole walk
        // means one unreadable file ends it, and the truncated total is then
        // reported as if it were the answer.
        try {
          bytes += entry.lengthSync();
          fileCount++;
        } catch (_) {
          unreadable++;
        }
      } else if (entry is Directory) {
        final String resolved;
        try {
          resolved = entry.resolveSymbolicLinksSync();
        } catch (_) {
          unreadable++;
          continue;
        }
        if (excluded.contains(resolved)) continue;
        if (resolved != root && !path.isWithin(root, resolved)) continue;
        if (!visited.add(resolved)) continue;
        pending.add(resolved);
      }
    }
  }

  return DirSize(
    bytes: bytes,
    fileCount: fileCount,
    unreadable: unreadable,
  );
}

/// [measureDirectorySync] on a worker isolate, for a tree big enough that
/// walking it on the caller's isolate would be felt.
///
/// **Not cancellable** — `Isolate.run` has no kill port — so there is no way to
/// abandon a walk in progress, and no UI should offer one. A caller that truly
/// needs to cancel has to move to `Isolate.spawn` and keep the port.
Future<DirSize> measureDirectory(
  String rootPath, {
  Set<String> excludePaths = const <String>{},
}) {
  return Isolate.run(
    () => measureDirectorySync(rootPath, excludePaths: excludePaths),
  );
}
