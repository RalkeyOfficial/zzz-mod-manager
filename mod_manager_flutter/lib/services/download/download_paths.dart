import 'dart:io';

import 'package:path/path.dart' as path;

/// Filenames and layout for the downloads directory.
///
/// Pure enough to test without a network: everything here is string handling
/// plus plain file operations against an injected directory.
///
/// Layout while a download is in flight:
///
/// ```
/// <appData>/downloads/mod.rar.part        the bytes so far
/// <appData>/downloads/mod.rar.part.json   what's needed to resume it
/// <appData>/downloads/mod.rar             only once complete
/// ```
///
/// The final name appears only on success, so a half-written archive can never
/// be mistaken for a usable one — by us, or by a user browsing the folder.
class DownloadPaths {
  DownloadPaths(this.directory);

  final Directory directory;

  static const String partSuffix = '.part';
  static const String recordSuffix = '.part.json';

  /// How long an abandoned partial is kept before the sweep reclaims it.
  static const Duration staleAfter = Duration(days: 7);

  static final RegExp _illegal = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

  /// Makes an untrusted filename safe to join onto a directory path.
  ///
  /// The name comes from a remote API or a webview's `suggestedFilename`, so it
  /// is untrusted input: it must not be able to escape the downloads directory
  /// or produce a name the OS refuses. Strips path separators and other illegal
  /// characters, flattens `..`, removes leading dots (which would hide the
  /// file), and caps the length while preserving the extension.
  static String sanitizeFilename(String? input, {required String fallback}) {
    var name = (input ?? '').trim();
    if (name.isNotEmpty) {
      // Take only the last segment, so "../../etc/passwd" can't survive as a path.
      name = name.split(RegExp(r'[\\/]')).last;
      name = name.replaceAll(_illegal, '_');
      name = name.replaceAll(RegExp(r'^\.+'), '');
      name = name.trim();
    }
    if (name.isEmpty) name = fallback;

    // Windows refuses these regardless of extension.
    const reserved = {
      'con', 'prn', 'aux', 'nul', //
      'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
      'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
    };
    if (reserved.contains(path.basenameWithoutExtension(name).toLowerCase())) {
      name = '_$name';
    }

    return _capLength(name);
  }

  /// Caps at 150 chars, keeping the extension — long enough for any real mod
  /// name, short enough to leave room for a `.part.json` suffix and a `(2)`
  /// inside common filesystem limits.
  static String _capLength(String name, {int max = 150}) {
    if (name.length <= max) return name;
    final ext = path.extension(name);
    final stem = path.basenameWithoutExtension(name);
    final keep = (max - ext.length).clamp(1, max);
    return '${stem.substring(0, keep)}$ext';
  }

  File finalFile(String filename) => File(path.join(directory.path, filename));

  File partFile(String filename) =>
      File(path.join(directory.path, '$filename$partSuffix'));

  File recordFile(String filename) =>
      File(path.join(directory.path, '$filename$recordSuffix'));

  /// Picks the name to promote a completed download to.
  ///
  /// Never overwrites: an existing `mod.rar` yields `mod (2).rar`, then
  /// `mod (3).rar`. Resolved at promotion time rather than at the start, so a
  /// pre-existing `.part` for the same name stays a **resume candidate** rather
  /// than being mistaken for a collision — those two checks must not merge.
  Future<File> resolveCollision(String filename) async {
    final candidate = finalFile(filename);
    if (!await candidate.exists()) return candidate;

    final stem = path.basenameWithoutExtension(filename);
    final ext = path.extension(filename);
    for (var n = 2; n < 1000; n++) {
      final next = File(path.join(directory.path, '$stem ($n)$ext'));
      if (!await next.exists()) return next;
    }
    // Absurd, but better than looping forever or silently overwriting.
    throw FileSystemException('Too many name collisions', candidate.path);
  }

  /// Removes junk left by crashes and abandoned downloads.
  ///
  /// Without this the directory grows forever: every interrupted download that
  /// the user never resumes leaves a `.part` behind. Removes a `.part` with no
  /// record, a record with no `.part`, and any complete pair untouched for
  /// [staleAfter].
  ///
  /// Best-effort — a file we can't stat or delete is skipped, never thrown.
  Future<int> sweep({DateTime? now}) async {
    if (!await directory.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(staleAfter);
    var removed = 0;

    final entries = await directory.list(followLinks: false).toList();
    final parts = <String, File>{};
    final records = <String, File>{};

    for (final entry in entries) {
      if (entry is! File) continue;
      final name = path.basename(entry.path);
      if (name.endsWith(recordSuffix)) {
        records[name.substring(0, name.length - recordSuffix.length)] = entry;
      } else if (name.endsWith(partSuffix)) {
        parts[name.substring(0, name.length - partSuffix.length)] = entry;
      }
    }

    for (final key in {...parts.keys, ...records.keys}) {
      final part = parts[key];
      final record = records[key];
      final orphaned = part == null || record == null;
      var stale = false;
      if (!orphaned) {
        try {
          stale = (await part.lastModified()).isBefore(cutoff);
        } catch (_) {
          stale = false;
        }
      }
      if (!orphaned && !stale) continue;
      if (await _tryDelete(part)) removed++;
      if (await _tryDelete(record)) removed++;
    }
    return removed;
  }

  static Future<bool> _tryDelete(File? file) async {
    if (file == null) return false;
    try {
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } catch (_) {
      // Locked or gone; nothing useful to do about it here.
    }
    return false;
  }
}
