import 'dart:io';
// `archive_io` for `InputFileStream`, which is what lists a zip's contents
// without reading the archive itself; it re-exports the decoders too.
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;

import '../utils/byte_format.dart';
import '../utils/directory_copy.dart';
import '../utils/process_probe.dart';
import '../utils/seven_zip_listing.dart';
import 'archive_activity.dart';
import 'archive_hash.dart';
import 'log/logger.dart';
import 'platform_service_factory.dart';

final Logger _log = Logger('archive');

/// Why an extraction failed, where the answer changes what the user does next.
///
/// The message beside it is diagnostics — tool output, a `FormatException` —
/// and is not shown. This is the part the UI is allowed to branch on.
enum ExtractFailure {
  /// A RAR or 7z archive with no 7-Zip on the system. The one failure the user
  /// can fix: nothing about the archive is wrong, we just cannot open it.
  missingSevenZip,

  /// The unpacked files will not fit where they have to be written. Also
  /// something the user can fix, and the numbers say by how much — see
  /// [ArchiveExtractionResult.requiredBytes].
  insufficientSpace,

  /// Everything else — a corrupt archive, a permission error, a format the
  /// tool rejected. Nothing to tell the user beyond where the file is.
  other,
}

class ArchiveExtractionResult {
  final bool success;
  final String? error;

  /// Set whenever [success] is false.
  final ExtractFailure? failure;

  final List<String>? extractedFolders;

  /// md5 of the archive these folders came out of, when it could be computed.
  ///
  /// Carried here because this is the last moment it exists: the archive is
  /// deleted once extracted, and a zip cannot be reproduced byte-for-byte from
  /// its extracted contents. Recording it lets us later say *which* published
  /// file a local install came from — including for archives the user supplied
  /// by hand, which is otherwise unknowable.
  ///
  /// A **matching key only**, never an integrity or authenticity claim; see
  /// `services/archive_hash.dart`.
  final String? archiveMd5;

  /// What the unpack needed and what the volume had, in bytes.
  ///
  /// Set only for [ExtractFailure.insufficientSpace], where they are the whole
  /// message: "not enough space" without a number leaves the user guessing how
  /// much to clear.
  final int? requiredBytes;
  final int? availableBytes;

  const ArchiveExtractionResult({
    required this.success,
    this.error,
    this.failure,
    this.extractedFolders,
    this.archiveMd5,
    this.requiredBytes,
    this.availableBytes,
  });

  factory ArchiveExtractionResult.successResult(
    List<String> folders, {
    String? archiveMd5,
  }) =>
      ArchiveExtractionResult(
        success: true,
        extractedFolders: folders,
        archiveMd5: archiveMd5,
      );

  /// Deliberately carries no md5: a failed extraction installs nothing, so
  /// there is no sidecar for a hash to be attached to.
  factory ArchiveExtractionResult.failure(
    String error, {
    ExtractFailure reason = ExtractFailure.other,
  }) =>
      ArchiveExtractionResult(
        success: false,
        error: error,
        failure: reason,
      );

  /// Refused before writing anything, because the unpack does not fit.
  ///
  /// The message is formatted rather than raw byte counts because one caller —
  /// the drag-in path — shows `error` to the user verbatim.
  factory ArchiveExtractionResult.noSpace({
    required int requiredBytes,
    required int availableBytes,
  }) =>
      ArchiveExtractionResult(
        success: false,
        error: 'Unpacking needs ${formatBytes(requiredBytes)}, '
            '${formatBytes(availableBytes)} free',
        failure: ExtractFailure.insufficientSpace,
        requiredBytes: requiredBytes,
        availableBytes: availableBytes,
      );
}

class ArchiveService {
  static bool isArchiveFile(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return extension == '.zip' || extension == '.rar' || extension == '.7z';
  }

  /// Whether [folderPath] contains a `.ini` file at any depth — the strongest
  /// signal that a folder is an actual mod rather than auxiliary content (a
  /// `previews`/images folder). Stops at the first match. Best-effort: any
  /// error is treated as "no .ini".
  static Future<bool> containsIniFile(String folderPath) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return false;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File &&
            path.extension(entity.path).toLowerCase() == '.ini') {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Extracts [archiveFile] and reports the top-level folders to import.
  ///
  /// Also fingerprints the archive — see [ArchiveExtractionResult.archiveMd5].
  /// The hash is taken **here**, at the one point both format branches meet
  /// with the file still in hand: `_extractZip` already holds the whole archive
  /// in memory and would be the tempting place, but `_extractWith7Zip` shells
  /// out and rar/7z bytes never enter Dart, so hashing there would silently
  /// cover zips only.
  ///
  /// Pass [knownMd5] when the bytes were already hashed as they streamed past
  /// (the download path), to avoid re-reading a file that can reach 1.24 GB. It
  /// is trusted verbatim and never verified: there is nothing here to verify it
  /// against, and re-reading to "check" would defeat the point of passing it.
  static Future<ArchiveExtractionResult> extractArchive({
    required File archiveFile,
    Directory? destinationDir,
    String? knownMd5,

    /// What to call the folder invented for an archive that has none inside it,
    /// when the file on disk is not named what the download asked for.
    ///
    /// The downloads directory never overwrites, so a leftover archive of the
    /// same name pushes a new one to `mod (2).rar` — and for a rootless archive
    /// that filename **becomes the mod's name**. The caller knows the name it
    /// asked for, so it passes it rather than this guessing at a suffix: a mod
    /// genuinely called `Ellen (2024)` must not be renamed by a heuristic.
    ///
    /// Null for an archive nobody renamed — one the user dragged in or picked —
    /// where the file's own name is the right one.
    String? nameHint,

    /// Free space on the volume being written to, for the preflight below.
    ///
    /// The same seam `DownloadService` takes, and for the same reason: the real
    /// answer comes from a `df` this app spawns, and a test about *refusing* an
    /// unpack cannot fill a disk to ask the question.
    Future<int?> Function(String path)? freeSpace,
  }) async {
    final started = DateTime.now();
    // Held for the whole unpack so the storage reclaim can see work the
    // download queue cannot: a dragged-in archive has no job behind it.
    ArchiveActivity.begin();
    try {
      final tempExtractDir = destinationDir ??
          await Directory.systemTemp.createTemp('zzz_archive_extract_');

      final extension = path.extension(archiveFile.path).toLowerCase();
      _log.info('extracting', fields: {
        'archive': path.basename(archiveFile.path),
        'format': extension,
      });

      // **Before either extractor writes a byte.** An unpack that runs the
      // volume out leaves a half-written folder tree to clean up and reports an
      // I/O error that names none of it, and the destination is `/tmp` — on
      // most Linux desktops a tmpfs, so filling it fills memory.
      final shortfall = await _spaceShortfall(
        archiveFile,
        tempExtractDir,
        freeSpace ?? PlatformServiceFactory.getInstance().freeSpaceBytes,
      );
      if (shortfall != null) {
        _log.warning('refused for space', fields: {
          'archive': path.basename(archiveFile.path),
          'required': shortfall.requiredBytes,
          'available': shortfall.availableBytes,
          'into': tempExtractDir.path,
        });
        return shortfall;
      }

      bool isExtracted = false;
      String? extractionError;
      var failure = ExtractFailure.other;

      if (extension == '.zip') {
        isExtracted = await _extractZip(archiveFile, tempExtractDir);
      } else if (extension == '.rar' || extension == '.7z') {
        final result = await _extractWith7Zip(archiveFile, tempExtractDir);
        isExtracted = result.success;
        extractionError = result.error;
        failure = result.failure;
      }

      if (!isExtracted) {
        final error = extractionError ?? 'Unsupported archive format';
        _log.error('extraction failed', fields: {
          'archive': path.basename(archiveFile.path),
          'format': extension,
          'reason': failure.name,
          'detail': error,
        });
        return ArchiveExtractionResult.failure(error, reason: failure);
      }

      // After the success check, so a failed extraction (e.g. no 7-Zip
      // installed) doesn't pay for a full read of a very large archive.
      // Extraction only reads the file, so it is still intact and hashable.
      final md5 = knownMd5 ?? await md5OfFile(archiveFile);

      final directories = await _prepareDirectoriesForImport(
        tempExtractDir,
        archiveFile,
        nameHint: nameHint,
      );

      if (directories.isEmpty) {
        _log.error('archive held no mod folders', fields: {
          'archive': path.basename(archiveFile.path),
        });
        // English: this string is shown to the user verbatim by the drag-in
        // path, which renders `error` into a notification body.
        return ArchiveExtractionResult.failure(
          'The archive contains no mod folders',
        );
      }

      _log.info('extracted', fields: {
        'archive': path.basename(archiveFile.path),
        'folders': directories.length,
        'took': DateTime.now().difference(started),
      });
      return ArchiveExtractionResult.successResult(directories, archiveMd5: md5);
    } catch (error, stack) {
      _log.error('extraction failed',
          error: error,
          stack: stack,
          fields: {'archive': path.basename(archiveFile.path)});
      return ArchiveExtractionResult.failure('Extraction failed: $error');
    } finally {
      ArchiveActivity.end();
    }
  }

  /// The unpacked size of [archiveFile], or null when it cannot be read.
  ///
  /// **Both formats are asked without unpacking anything.** A zip carries every
  /// entry's uncompressed size in its central directory, which
  /// `InputFileStream` reaches with a seek rather than a read of the file — so
  /// a 1.24 GB archive is listed in milliseconds. A rar or 7z is listed by the
  /// same 7-Zip that will extract it, at the cost of one extra process.
  ///
  /// Null for a format nothing here handles, for a listing that fails, and for
  /// an archive whose entries report nothing — every one of which means the
  /// space check is skipped rather than guessed at.
  static Future<int?> unpackedSize(File archiveFile) async {
    final extension = path.extension(archiveFile.path).toLowerCase();
    try {
      if (extension == '.zip') return _unpackedZipSize(archiveFile);
      if (extension == '.rar' || extension == '.7z') {
        return await _unpackedSizeVia7Zip(archiveFile);
      }
    } catch (error) {
      _log.debug('could not size the archive', fields: {
        'archive': path.basename(archiveFile.path),
        'reason': '$error',
      });
    }
    return null;
  }

  static int? _unpackedZipSize(File archiveFile) {
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      var total = 0;
      for (final entry in archive) {
        if (entry.isFile) total += entry.size;
      }
      return total > 0 ? total : null;
    } finally {
      input.closeSync();
    }
  }

  static Future<int?> _unpackedSizeVia7Zip(File archiveFile) async {
    final sevenZipPath = await _locate7Zip();
    // No 7-Zip is not this method's failure to report: the extraction below
    // reports it as the one thing the user can fix, and answering "unknown"
    // here lets it get there.
    if (sevenZipPath == null) return null;

    // **The cap is sized for a listing, not for a banner.** `-slt` prints a
    // block of 150–300 bytes per entry, so the default 64 KB is spent by a few
    // hundred files — and a cut listing still parses, still exits 0, and sums
    // to a number that is too small. That number would say an install fits when
    // it does not, which is the failure this check exists to prevent. 32 MB is
    // past any real mod (~100k entries) and the output is our own tool's.
    final result = await const ProcessProbe(
      timeout: Duration(seconds: 10),
      maxBytes: 32 * 1024 * 1024,
    ).run(sevenZipPath, ['l', '-slt', archiveFile.path]);
    if (result == null || result.timedOut || result.exitCode != 0) return null;
    // Past even that, the honest answer is that we do not know the size.
    if (result.truncated) return null;
    return parseSevenZipUnpackedBytes(result.stdout);
  }

  /// A refusal when the unpack provably will not fit, or null to carry on.
  ///
  /// **Null covers three different unknowns, and all of them proceed**: the size
  /// could not be read, the free space could not be read, or there is room. A
  /// refusal is only ever issued against two real numbers, because refusing an
  /// unpack that would have fit is worse than the failure this prevents — the
  /// user has an archive they cannot install and no way to tell why.
  static Future<ArchiveExtractionResult?> _spaceShortfall(
    File archiveFile,
    Directory destination,
    Future<int?> Function(String path) freeSpace,
  ) async {
    final needed = await unpackedSize(archiveFile);
    if (needed == null || needed <= 0) return null;

    final available = await freeSpace(destination.path);
    if (available == null || needed <= available) return null;

    return ArchiveExtractionResult.noSpace(
      requiredBytes: needed,
      availableBytes: available,
    );
  }

  static Future<bool> _extractZip(File archiveFile, Directory destination) async {
    try {
      final bytes = await archiveFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      _log.debug('zip decoded', fields: {
        'bytes': bytes.length,
        'entries': archive.length,
      });

      int extracted = 0;
      for (final file in archive) {
        // Some archivers write Windows separators into entry names. A Windows
        // filename cannot contain one, so it is always a folder boundary.
        final sanitizedPath = _sanitizeArchivePath(
          destination.path,
          file.name.replaceAll(r'\', '/'),
        );
        if (sanitizedPath == null) {
          // An entry trying to escape the destination. A security event, not
          // a note — somebody built this archive deliberately.
          _log.warning('unsafe archive path skipped', fields: {
            'entry': file.name,
            'archive': path.basename(archiveFile.path),
          });
          continue;
        }

        if (file.isFile) {
          final outFile = File(sanitizedPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
          await _keepArchiveTime(outFile, file);
          extracted++;
        } else {
          final dir = Directory(sanitizedPath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
      }

      _log.debug('zip written', fields: {'files': extracted});
      return true;
    } catch (error, stack) {
      _log.error('zip extraction failed',
          error: error,
          stack: stack,
          fields: {'archive': path.basename(archiveFile.path)});
      return false;
    }
  }

  static Future<_7ZipResult> _extractWith7Zip(
    File archiveFile,
    Directory destination,
  ) async {
    final sevenZipPath = await _locate7Zip();
    if (sevenZipPath == null) {
      return const _7ZipResult(
        false,
        '7-Zip not found on PATH',
        ExtractFailure.missingSevenZip,
      );
    }

    _log.debug('using 7-Zip', fields: {'path': sevenZipPath});

    final result = await Process.run(sevenZipPath, [
      'x',
      archiveFile.path,
      '-o${destination.path}',
      '-y',
    ]);

    if (result.exitCode != 0) {
      final errorOutput = result.stderr.toString().trim();
      _log.error('7-Zip failed', fields: {
        'exit': result.exitCode,
        'stderr': errorOutput,
      });
      return _7ZipResult(
        false,
        errorOutput.isNotEmpty ? errorOutput : 'Extraction failed',
      );
    }

    _log.debug('7-Zip finished');
    return const _7ZipResult(true);
  }

  /// A 7-Zip shipped alongside the app, or null.
  ///
  /// Checked **before** the system one so a portable build is self-contained
  /// rather than depending on what happens to be installed. The AUR package
  /// bundles nothing and falls straight through to the `7zip` it declares.
  ///
  /// `Platform.resolvedExecutable` rather than `Directory.current`: the working
  /// directory is wherever the user launched from, which is how the F10 Python
  /// fallback ended up unreachable in every installed build.
  static Future<String?> _locateBundled7Zip() async {
    final bundleDir = path.dirname(Platform.resolvedExecutable);
    for (final name in PlatformServiceFactory.getInstance().bundledSevenZipNames) {
      for (final candidate in [
        path.join(bundleDir, name),
        path.join(bundleDir, 'tools', name),
      ]) {
        if (await File(candidate).exists()) return candidate;
      }
    }
    return null;
  }

  static Future<String?> _locate7Zip() async {
    final bundled = await _locateBundled7Zip();
    if (bundled != null) return bundled;

    if (Platform.isWindows) {
      final whereResult = await Process.run('where', ['7z']);
      if (whereResult.exitCode == 0) {
        final lines = whereResult.stdout
            .toString()
            .split(RegExp(r'[\r\n]+'))
            .where((line) => line.trim().isNotEmpty);
        if (lines.isNotEmpty) {
          return lines.first.trim();
        }
      }

      final candidates = [
        path.join(
          Platform.environment['ProgramFiles'] ?? '',
          '7-Zip',
          '7z.exe',
        ),
        path.join(
          Platform.environment['ProgramFiles(x86)'] ?? '',
          '7-Zip',
          '7z.exe',
        ),
      ];

      for (final candidate in candidates) {
        if (candidate.trim().isEmpty) continue;
        final file = File(candidate);
        if (await file.exists()) {
          return file.path;
        }
      }
      return null;
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final commands = ['7z', '7za', '7zr'];
      for (final command in commands) {
        try {
          final whichResult = await Process.run('which', [command]);
          if (whichResult.exitCode == 0) {
            final pathResult = whichResult.stdout
                .toString()
                .split(RegExp(r'[\r\n]+'))
                .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
                .trim();
            if (pathResult.isNotEmpty) {
              return pathResult;
            }
          }
        } catch (_) {
          continue;
        }
      }
    }

    return null;
  }

  /// Gives an extracted file the time its archive entry carries. ZZMI uses a
  /// shipped shader `.bin` only when its time equals its `.txt`'s, so extracting
  /// both at "now" would make it recompile every shader at runtime.
  static Future<void> _keepArchiveTime(File file, ArchiveFile entry) async {
    try {
      await file.setLastModified(entry.lastModDateTime);
    } on Object catch (error) {
      _log.warning('entry time not kept', error: error, fields: {'entry': entry.name});
    }
  }

  static Future<List<String>> _prepareDirectoriesForImport(
    Directory extractDir,
    File archiveFile, {
    String? nameHint,
  }) async {
    final entries = extractDir.listSync();
    final directories = <String>[];

    if (entries.isEmpty) {
      return directories;
    }

    final dirEntries = entries.whereType<Directory>().toList();

    // A `.ini` sitting directly at the archive root means the whole root IS one
    // mod (the sibling folders are that mod's resource folders — res/, buffer/,
    // textures/ — referenced by the .ini). Without this, an archive laid out as
    // `res/  buffer/  textures/  name.ini` would be treated as several unrelated
    // folders and the root .ini silently dropped.
    final hasRootIni = entries.whereType<File>().any(
      (f) => path.extension(f.path).toLowerCase() == '.ini',
    );

    // Wrap the whole root into a single mod folder when it is one mod: either a
    // .ini lives at the root (folders beside it are its resources), or there are
    // no subfolders at all (a flat pile of files). This keeps everything —
    // especially the root .ini — instead of returning bare subfolders.
    if (hasRootIni || dirEntries.isEmpty) {
      // **This becomes the mod's name**, so it is the name the caller asked for
      // rather than whatever the file ended up called on disk — see [nameHint].
      final baseName =
          path.basenameWithoutExtension(nameHint ?? archiveFile.path);
      final wrapperDir = Directory(path.join(extractDir.path, baseName));
      await wrapperDir.create(recursive: true);

      for (final entity in entries) {
        // Guard the rare archive-name == folder-name collision: never move the
        // wrapper into itself; the other siblings just move into it.
        if (path.equals(entity.path, wrapperDir.path)) continue;
        final targetPath = path.join(
          wrapperDir.path,
          path.basename(entity.path),
        );
        if (entity is File) {
          await copyKeepingTime(entity, targetPath);
          await entity.delete();
        } else if (entity is Directory) {
          await Directory(entity.path).rename(targetPath);
        }
      }
      directories.add(wrapperDir.path);
      return directories;
    }

    final baseName = path.basenameWithoutExtension(nameHint ?? archiveFile.path);
    if (dirEntries.any((d) => _isZzmiFolder(d, 'mods') || _isZzmiFolder(d, 'shaderfixes'))) {
      return _prepareZzmiRootLayout(extractDir, dirEntries, baseName);
    }

    // Otherwise the root is a container of independent mod folders.
    for (final dir in dirEntries) {
      directories.add(dir.path);
    }

    return directories;
  }

  static bool _isZzmiFolder(Directory dir, String name) =>
      path.basename(dir.path).toLowerCase() == name;

  /// An archive laid out like ZZMI's own folder, to be merged into it by hand:
  /// `Mods/` holding the mod and `ShaderFixes/` beside it (`docs/shader-fixes.md` §2).
  ///
  /// The mods are the folders inside `Mods/`, or `Mods/` itself when an `.ini`
  /// sits directly in it. The shader files join the one mod when there is exactly
  /// one, since that is who they belong to; beside several they become a mod of
  /// their own, so each can be switched on and off and none is guessed at.
  static Future<List<String>> _prepareZzmiRootLayout(
    Directory extractDir,
    List<Directory> dirEntries,
    String baseName,
  ) async {
    final candidates = <String>[];
    Directory? shaderDir;
    for (final dir in dirEntries) {
      if (_isZzmiFolder(dir, 'shaderfixes')) {
        shaderDir = dir;
      } else if (_isZzmiFolder(dir, 'mods')) {
        final inside = dir.listSync();
        final iniAtTop = inside.whereType<File>().any(
          (f) => path.extension(f.path).toLowerCase() == '.ini',
        );
        if (iniAtTop) {
          final named = _unusedPath(extractDir, baseName);
          await dir.rename(named);
          candidates.add(named);
        } else {
          candidates.addAll(inside.whereType<Directory>().map((d) => d.path));
        }
      } else {
        candidates.add(dir.path);
      }
    }

    if (shaderDir == null) return candidates;

    if (candidates.length == 1) {
      final mod = Directory(candidates.single);
      final taken = mod.listSync().whereType<Directory>().any((d) => _isZzmiFolder(d, 'shaderfixes'));
      if (!taken) {
        await shaderDir.rename(path.join(mod.path, 'ShaderFixes'));
        return candidates;
      }
    }

    final wrapper = Directory(
      _unusedPath(extractDir, candidates.isEmpty ? baseName : '$baseName ShaderFixes'),
    );
    await wrapper.create();
    await shaderDir.rename(path.join(wrapper.path, 'ShaderFixes'));
    return [...candidates, wrapper.path];
  }

  /// [name] inside [parent], numbered when something already has it.
  static String _unusedPath(Directory parent, String name) {
    var candidate = path.join(parent.path, name);
    for (var n = 2; FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound; n++) {
      candidate = path.join(parent.path, '$name ($n)');
    }
    return candidate;
  }

  static String? _sanitizeArchivePath(String base, String relativePath) {
    final normalized = path.normalize(relativePath);
    if (normalized.contains('..')) {
      return null;
    }
    final fullPath = path.join(base, normalized);
    if (!path.isWithin(base, fullPath)) {
      return null;
    }
    return fullPath;
  }
}

class _7ZipResult {
  final bool success;
  final String? error;
  final ExtractFailure failure;

  const _7ZipResult(
    this.success, [
    this.error,
    this.failure = ExtractFailure.other,
  ]);
}
