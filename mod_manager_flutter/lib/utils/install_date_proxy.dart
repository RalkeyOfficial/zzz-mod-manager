/// Deriving a stand-in install date for a mod that predates the origin block.
///
/// The real install date was never recorded for anything installed before the
/// origin block existed (`docs/origin-tracking.md`), and it cannot be recovered
/// — so the backfill uses the
/// **oldest file mtime inside the mod folder** as a proxy. Folder mtime and
/// ctime are both bumped by an `.ini` edit, so they skew *later* than the true
/// install and would hide updates; the oldest contained file is the earliest
/// defensible answer.
///
/// **How good the proxy is depends on how the mod got there**, and the two
/// cases are far apart:
///
/// - Imported *through the app*: good. `_extractZip` writes fresh files and
///   `_copyDirectory` copies via `File.copy`, neither of which carries the
///   source timestamps over, so mtimes land at roughly import time.
/// - Placed in `modsPath` *by hand* (`cp -p`, the user's own 7-Zip run, a synced
///   folder): the author's build timestamps survive and the proxy can read
///   *years* early.
///
/// That is why anything reading the date must also read
/// `ModOrigin.installedAtIsProxy` rather than treating it as observed.
library;

import 'dart:io';

import 'package:path/path.dart' as path;

import '../core/constants.dart';

/// The oldest modification time of any file inside [folderPath], or null when
/// the folder holds no files we'd count (or can't be walked at all).
///
/// Our own `.zzz-mod-manager/` directory is skipped: the sidecar and any images
/// migrated into it were written by this app, often long after the mod was
/// installed, so they describe our bookkeeping rather than the mod. They cannot
/// drag the minimum *earlier*, but a folder holding nothing else would
/// otherwise report the sidecar's own write time as an install date — a
/// confident-looking number that means nothing.
///
/// Best-effort throughout: an unreadable entry is skipped rather than failing
/// the whole walk, because a partial answer is still a usable proxy and this
/// runs during an ordinary scan.
///
/// Cost, measured on a real 23-mod / 748-file library (warm cache): **~10 ms for
/// the entire library**, ~0.45 ms per mod. It is also a *one-time* cost per mod
/// rather than a per-scan one — once the backfill writes a block, the mod no
/// longer qualifies and is never walked again.
///
/// That last property depends on the write **succeeding**. A read-only folder
/// or an odd network share would otherwise be re-walked on every scan forever,
/// re-attempting a write that cannot work, which is why
/// `ModMetadataRepository` remembers those folders for the session.
Future<DateTime?> oldestFileMtime(String folderPath) async {
  DateTime? oldest;
  final metadataDirName = AppConstants.modMetadataDirName;

  try {
    final stream = Directory(folderPath).list(
      recursive: true,
      // Never follow links out of the mod folder: a mod may ship one, and
      // following it would both leave the folder and risk a cycle.
      followLinks: false,
    );
    await for (final entity in stream) {
      if (entity is! File) continue;

      final relative = path.relative(entity.path, from: folderPath);
      if (path.split(relative).first == metadataDirName) continue;

      try {
        final modified = (await entity.stat()).modified;
        if (oldest == null || modified.isBefore(oldest)) oldest = modified;
      } catch (e) {
        // One unreadable file shouldn't discard the rest of the walk.
      }
    }
  } catch (e) {
    // Unreadable folder — return whatever we managed to see, likely nothing.
  }

  return oldest?.toUtc();
}
