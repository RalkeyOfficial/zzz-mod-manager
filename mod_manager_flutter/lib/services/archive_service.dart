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
import 'folder_contents.dart';
import 'ini_resources.dart';
import 'log/logger.dart';
import 'platform_service_factory.dart';
import 'shader_fixes/zzmi_layout.dart';

final Logger _log = Logger('archive');
final Logger _files = Logger('fileops');

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

  /// The archive is encrypted and no password was given: its listing said so
  /// before anything was unpacked, or, for a listing that said nothing, 7-Zip
  /// stopped at its password prompt (exit 255). The caller asks for the password
  /// and tries again.
  passwordRequired,

  /// A password was given and did not open the archive. 7-Zip cannot tell a
  /// wrong password from damaged encrypted data, so nothing claims more than
  /// that. The archive is kept and the unpack's directory deleted.
  wrongPassword,

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

  /// Each folder in [extractedFolders] whose `ShaderFixes/` import filled from a
  /// folder of another name, mapped to that folder's name (`docs/shader-fixes.md` §2).
  final Map<String, String> shaderSources;

  const ArchiveExtractionResult({
    required this.success,
    this.error,
    this.failure,
    this.extractedFolders,
    this.archiveMd5,
    this.requiredBytes,
    this.availableBytes,
    this.shaderSources = const {},
  });

  factory ArchiveExtractionResult.successResult(
    List<String> folders, {
    String? archiveMd5,
    Map<String, String> shaderSources = const {},
  }) =>
      ArchiveExtractionResult(
        success: true,
        extractedFolders: folders,
        archiveMd5: archiveMd5,
        shaderSources: shaderSources,
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
  ///
  /// [password] is passed to 7-Zip as one argument, never through a shell, and
  /// never logged (`docs/downloads.md` §12). An encrypted zip is unpacked by
  /// 7-Zip too, since `package:archive` garbles ZipCrypto even with the right
  /// password and fails AES.
  static Future<ArchiveExtractionResult> extractArchive({
    required File archiveFile,
    Directory? destinationDir,
    String? knownMd5,
    String? password,

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
        if (password != null) 'password': true,
      });

      // A try that unpacks nothing leaves nothing behind: a zip leaves its files
      // at 0 bytes, and the next try unpacks into a new directory.
      Future<ArchiveExtractionResult> refusedPassword(ArchiveExtractionResult result) async {
        if (destinationDir == null) await _deleteQuietly(tempExtractDir);
        return result;
      }

      // **The listing first, and once.** It sizes the unpack for the preflight
      // below, and it is where a locked archive shows before anything is
      // written: one that needs a password and was given none, and, for one
      // whose headers are encrypted, a wrong password.
      final passwordMissing = ArchiveExtractionResult.failure(
        'The archive is encrypted',
        reason: ExtractFailure.passwordRequired,
      );
      int? needed;
      var zipEncrypted = false;
      if (extension == '.zip') {
        final listing = _zipListing(archiveFile);
        needed = listing?.size;
        zipEncrypted = listing?.encrypted ?? false;
        if (zipEncrypted && password == null) return refusedPassword(passwordMissing);
      } else if (extension == '.rar' || extension == '.7z') {
        ProbeResult? listing;
        try {
          listing = await _sevenZipListing(archiveFile, password: password);
        } catch (error) {
          _log.debug('could not list the archive', fields: {
            'archive': path.basename(archiveFile.path),
            'reason': '$error',
          });
        }
        if (password == null && _listsLocked(listing)) return refusedPassword(passwordMissing);
        if (password != null && listing != null && !listing.timedOut && listing.exitCode == 2) {
          _log.warning('password did not open the archive', fields: {
            'archive': path.basename(archiveFile.path),
            'stage': 'listing',
          });
          return refusedPassword(ArchiveExtractionResult.failure(
            'The password did not open the archive',
            reason: ExtractFailure.wrongPassword,
          ));
        }
        needed = _listedSize(listing);
      }

      // **Before either extractor writes a byte.** An unpack that runs the
      // volume out leaves a half-written folder tree to clean up and reports an
      // I/O error that names none of it, and the destination is `/tmp` — on
      // most Linux desktops a tmpfs, so filling it fills memory.
      final shortfall = await _spaceShortfall(
        needed,
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

      if (extension == '.zip' && !zipEncrypted) {
        isExtracted = await _extractZip(archiveFile, tempExtractDir);
      } else if (extension == '.zip' || extension == '.rar' || extension == '.7z') {
        final result = await _extractWith7Zip(archiveFile, tempExtractDir, password: password);
        isExtracted = result.success;
        extractionError = result.error;
        failure = result.failure;
      }

      if (failure == ExtractFailure.passwordRequired || failure == ExtractFailure.wrongPassword) {
        return refusedPassword(ArchiveExtractionResult.failure(
          extractionError ?? 'The archive is encrypted',
          reason: failure,
        ));
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

      final placedShaders = <String, String>{};
      final directories = await _prepareDirectoriesForImport(
        tempExtractDir,
        archiveFile,
        nameHint: nameHint,
        placedShaders: placedShaders,
      );
      final shaderSources = await _moveShaderFoldersIn(directories, placedShaders);

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
      return ArchiveExtractionResult.successResult(
        directories,
        archiveMd5: md5,
        shaderSources: shaderSources,
      );
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
      if (extension == '.zip') return _zipListing(archiveFile)?.size;
      if (extension == '.rar' || extension == '.7z') {
        return _listedSize(await _sevenZipListing(archiveFile));
      }
    } catch (error) {
      _log.debug('could not size the archive', fields: {
        'archive': path.basename(archiveFile.path),
        'reason': '$error',
      });
    }
    return null;
  }

  /// Whether [archiveFile] needs a password to unpack, asked without unpacking it.
  ///
  /// A zip is read in-process: bit 0 of a file header's flag, from the central
  /// directory the size listing reads. A 7z or rar is asked by 7-Zip's listing
  /// with stdin closed: exit 0 with any `Encrypted = +` means its files are
  /// locked, and exit 255 means 7-Zip stopped at its password prompt, which only
  /// encrypted headers reach. Exit 2, a file it could not open, is left to the
  /// unpack to report as the extraction failure it is. False whenever the
  /// listing says nothing, since the unpack's exit 255 is the backstop.
  static Future<bool> needsPassword(File archiveFile) async {
    final extension = path.extension(archiveFile.path).toLowerCase();
    try {
      if (extension == '.zip') return _zipListing(archiveFile)?.encrypted ?? false;
      if (extension == '.rar' || extension == '.7z') return _listsLocked(await _sevenZipListing(archiveFile));
    } catch (error) {
      _log.debug('could not list the archive', fields: {
        'archive': path.basename(archiveFile.path),
        'reason': '$error',
      });
    }
    return false;
  }

  /// A zip's unpacked size and whether any of its files is encrypted, from its
  /// central directory. Null when the zip cannot be read.
  static ({int? size, bool encrypted})? _zipListing(File archiveFile) {
    final InputFileStream input;
    try {
      input = InputFileStream(archiveFile.path);
    } catch (_) {
      return null;
    }
    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input);
      var total = 0;
      for (final entry in archive) {
        if (entry.isFile) total += entry.size;
      }
      final encrypted = decoder.directory.fileHeaders.any((header) => header.generalPurposeBitFlag & 1 != 0);
      return (size: total > 0 ? total : null, encrypted: encrypted);
    } catch (error) {
      _log.debug('could not list the zip', fields: {
        'archive': path.basename(archiveFile.path),
        'reason': '$error',
      });
      return null;
    } finally {
      input.closeSync();
    }
  }

  /// `7z l -slt` of [archiveFile], with stdin closed, or null with no 7-Zip.
  ///
  /// [password] goes as one argument, so a header-encrypted archive lists, and a
  /// wrong one exits 2 at once rather than waiting at a prompt.
  static Future<ProbeResult?> _sevenZipListing(File archiveFile, {String? password}) async {
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
    return const ProcessProbe(
      timeout: Duration(seconds: 10),
      maxBytes: 32 * 1024 * 1024,
    ).run(sevenZipPath, ['l', '-slt', archiveFile.path, if (password != null) '-p$password']);
  }

  /// Whether a listing taken without a password says the archive needs one, as [needsPassword] reads it.
  static bool _listsLocked(ProbeResult? listing) {
    if (listing == null || listing.timedOut) return false;
    if (listing.exitCode == 255) return true;
    return listing.exitCode == 0 && sevenZipListsEncryptedEntries(listing.stdout);
  }

  /// The unpacked size a successful, complete listing names, else null.
  static int? _listedSize(ProbeResult? listing) {
    if (listing == null || listing.timedOut || listing.exitCode != 0) return null;
    // Past even the cap, the honest answer is that we do not know the size.
    if (listing.truncated) return null;
    return parseSevenZipUnpackedBytes(listing.stdout);
  }

  /// Deletes the `zzz_archive_extract_*` directories holding [folders], which an
  /// unpack created, and nothing else.
  ///
  /// The nearest such ancestor of each folder, not only its parent: a ZZMI-root
  /// archive's mods come out a level down, as `Mods/<mod>`.
  static Future<void> deleteExtraction(Iterable<String> folders) async {
    final roots = <String>{
      for (final folder in folders)
        if (_extractionRootOf(folder) case final root?) root,
    };
    for (final root in roots) {
      await _deleteQuietly(Directory(root));
    }
  }

  static String? _extractionRootOf(String folder) {
    var directory = path.dirname(folder);
    while (true) {
      if (path.basename(directory).startsWith('zzz_archive_extract_')) return directory;
      final parent = path.dirname(directory);
      if (parent == directory) return null;
      directory = parent;
    }
  }

  static Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (error) {
      // Scratch we own, not the user's data: the reclaim's temp extractions take it later.
      _files.debug('temp cleanup failed', fields: {'path': directory.path, 'reason': '$error'});
    }
  }

  /// A refusal when the unpack provably will not fit, or null to carry on.
  ///
  /// **Null covers three different unknowns, and all of them proceed**: the size
  /// could not be read, the free space could not be read, or there is room. A
  /// refusal is only ever issued against two real numbers, because refusing an
  /// unpack that would have fit is worse than the failure this prevents — the
  /// user has an archive they cannot install and no way to tell why.
  static Future<ArchiveExtractionResult?> _spaceShortfall(
    int? needed,
    Directory destination,
    Future<int?> Function(String path) freeSpace,
  ) async {
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

  /// Unpacks through 7-Zip, with [password] as one `-p` argument when given.
  ///
  /// `Process.run` closes the child's stdin, so an encrypted archive without a
  /// password exits 255 at the prompt rather than waiting, and a wrong password
  /// exits 2 at once.
  static Future<_7ZipResult> _extractWith7Zip(
    File archiveFile,
    Directory destination, {
    String? password,
  }) async {
    final sevenZipPath = await _locate7Zip();
    if (sevenZipPath == null) {
      return const _7ZipResult(
        false,
        '7-Zip not found on PATH',
        ExtractFailure.missingSevenZip,
      );
    }

    _log.debug('using 7-Zip', fields: {'path': sevenZipPath});

    final ProcessResult result;
    try {
      result = await Process.run(sevenZipPath, [
        'x',
        archiveFile.path,
        '-o${destination.path}',
        '-y',
        if (password != null) '-p$password',
      ]);
    } on ProcessException catch (error) {
      // **Only its message and code.** Its text prints the whole command line,
      // which carries the password, and the outer catch would log it as `error:`.
      _log.error('7-Zip did not start', fields: {
        'reason': error.message,
        'code': error.errorCode,
        if (password != null) 'password': true,
      });
      return _7ZipResult(false, '7-Zip did not start: ${error.message}');
    }

    if (result.exitCode != 0) {
      final errorOutput = result.stderr.toString().trim();
      // The exit code and stderr name files and the archive, never the password.
      _log.error('7-Zip failed', fields: {
        'exit': result.exitCode,
        'stderr': errorOutput,
        if (password != null) 'password': true,
      });
      final failure = switch (result.exitCode) {
        255 when password == null => ExtractFailure.passwordRequired,
        2 when password != null => ExtractFailure.wrongPassword,
        _ => ExtractFailure.other,
      };
      return _7ZipResult(
        false,
        errorOutput.isNotEmpty ? errorOutput : 'Extraction failed',
        failure,
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

  /// [placedShaders] collects each shader folder of another name moved from the
  /// root into a mod, by its new path, mapped to the name it has in the archive.
  static Future<List<String>> _prepareDirectoriesForImport(
    Directory extractDir,
    File archiveFile, {
    String? nameHint,
    required Map<String, String> placedShaders,
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
    final hasShaderFixes = dirEntries.any((d) => _isZzmiFolder(d, 'shaderfixes'));
    final renamedShaders = hasShaderFixes ? null : await _rootShaderFolder(extractDir, dirEntries);
    if (hasShaderFixes || renamedShaders != null || dirEntries.any((d) => _isZzmiFolder(d, 'mods'))) {
      return _prepareZzmiRootLayout(
        extractDir,
        dirEntries,
        baseName,
        renamedShaders: renamedShaders,
        placedShaders: placedShaders,
      );
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
  /// one, since that is who they belong to. Beside several, each mod gets its own
  /// copy: nothing says which of them needs the files, and identical files placed
  /// by several mods stay until the last one is off. Only shader files no mod can
  /// take become a mod of their own.
  ///
  /// [renamedShaders] is a shader folder of another name at the root, found when
  /// there is no `ShaderFixes/` there. It goes where a `ShaderFixes/` would, under
  /// its own name, and [_moveShaderFoldersIn] then sorts its files. Each place it
  /// lands is recorded in [placedShaders].
  static Future<List<String>> _prepareZzmiRootLayout(
    Directory extractDir,
    List<Directory> dirEntries,
    String baseName, {
    Directory? renamedShaders,
    required Map<String, String> placedShaders,
  }) async {
    final shaderDir = dirEntries.where((d) => _isZzmiFolder(d, 'shaderfixes')).lastOrNull;
    final source = shaderDir ?? renamedShaders;
    final placedAs = shaderDir != null ? 'ShaderFixes' : path.basename(source?.path ?? '');
    // Out of the root before any mod is named after the archive, so the shader
    // folder never holds the name a mod would take: `Shader Fix.zip` holding
    // `Shader Fix/` is the mod `Shader Fix`, not `Shader Fix (2)`.
    final shared = source == null ? null : await source.rename(_unusedPath(extractDir, '.zzz-shaders'));

    final candidates = <String>[];
    for (final dir in dirEntries) {
      if (source != null && path.equals(dir.path, source.path)) {
        continue;
      } else if (_isZzmiFolder(dir, 'shaderfixes')) {
        // A second spelling of `ShaderFixes/` on a case-sensitive disk is left out, as one set is used.
        continue;
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

    if (shared == null) return candidates;

    // Free means no shader files of its own: a mod with a `ShaderFixes/` or a
    // shader folder that will become one, and a shader folder left at the root,
    // take no copy, since two sets in one folder risk two files of one name.
    final free = <String>[];
    for (final candidate in candidates) {
      final dir = Directory(candidate);
      if (_looksLikeShaderFolder(dir)) continue;
      if (dir.listSync().whereType<Directory>().any((d) => _isZzmiFolder(d, 'shaderfixes'))) continue;
      if (await _shaderFolderIn(candidate) != null) continue;
      free.add(candidate);
    }

    Future<void> place(String target, {required bool copy}) async {
      if (copy) {
        await copyDirectory(shared, Directory(target));
      } else {
        await shared.rename(target);
      }
      if (renamedShaders != null) placedShaders[target] = placedAs;
    }

    if (free.length == 1) {
      await place(_unusedPath(Directory(free.single), placedAs), copy: false);
      return candidates;
    }
    if (free.isNotEmpty) {
      for (final mod in free) {
        await place(_unusedPath(Directory(mod), placedAs), copy: true);
      }
      await shared.delete(recursive: true);
      return candidates;
    }

    final wrapper = Directory(
      _unusedPath(extractDir, candidates.isEmpty ? baseName : '$baseName ShaderFixes'),
    );
    await wrapper.create();
    await place(path.join(wrapper.path, placedAs), copy: false);
    return [...candidates, wrapper.path];
  }

  /// Whether [dir]'s name marks it as a possible shader folder under another name:
  /// it contains "shader" and is not `ShaderFixes`, which is handled as itself.
  static bool _hasShaderName(Directory dir) {
    final name = path.basename(dir.path).toLowerCase();
    return name.contains('shader') && name != 'shaderfixes';
  }

  /// Whether [dir] is a shader folder under another name before any `.ini`
  /// reference is weighed: the name, a shader replacement file directly inside,
  /// and no `.ini` directly inside, since a folder holding one is a mod.
  static bool _looksLikeShaderFolder(Directory dir) {
    if (!_hasShaderName(dir)) return false;
    final names = [
      for (final f in dir.listSync(followLinks: false).whereType<File>()) path.basename(f.path),
    ];
    return !names.any((n) => n.toLowerCase().endsWith('.ini')) && names.any(isShaderReplacementName);
  }

  /// Whether [dir] is a shader folder under another name (`docs/shader-fixes.md` §2).
  ///
  /// Beyond [_looksLikeShaderFolder], no `.ini` refers inside it: [referenced] is
  /// every path the `.ini` files of the folder [dir] sits in point at, relative to
  /// that folder, and a folder the mod loads from itself stays an ordinary part of the mod.
  static bool _isShaderFolder(Directory dir, Set<String> referenced) {
    if (!_looksLikeShaderFolder(dir)) return false;
    final relative = normalizeIniPath(path.basename(dir.path));
    return !referenced.any((p) => p == relative || p.startsWith('$relative/'));
  }

  /// The shader folder under another name directly in [mod] that becomes its
  /// `ShaderFixes/`: the first by name, and none when [mod] already has a `ShaderFixes/`.
  static Future<Directory?> _shaderFolderIn(String mod) async {
    final children = Directory(mod).listSync(followLinks: false).whereType<Directory>().toList();
    if (children.any((d) => _isZzmiFolder(d, 'shaderfixes'))) return null;
    final named = children.where(_hasShaderName).toList()
      ..sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));
    if (named.isEmpty) return null;
    final referenced = (await readFolderContents(Directory(mod))).references.paths;
    return named.where((d) => _isShaderFolder(d, referenced)).firstOrNull;
  }

  /// The first shader folder of another name directly at the archive root, by name.
  static Future<Directory?> _rootShaderFolder(Directory extractDir, List<Directory> dirEntries) async {
    final named = dirEntries.where(_hasShaderName).toList()
      ..sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));
    if (named.isEmpty) return null;
    final referenced = (await readFolderContents(extractDir)).references.paths;
    for (final dir in named) {
      if (_isShaderFolder(dir, referenced)) return dir;
    }
    return null;
  }

  /// Moves the files of a shader folder under another name, directly inside each
  /// of [mods], into that mod's `ShaderFixes/`, and returns each mod that got them
  /// mapped to the folder's name in the archive, which [placedShaders] holds for a
  /// folder moved in from the root.
  ///
  /// A mod that already has a `ShaderFixes/` keeps its folders as they are, since
  /// two sets merged into one risk two files of one name. Of several shader folders
  /// in one mod only the first by name moves, for the same reason.
  ///
  /// Shader replacement files and every subfolder move, since subfolders are `#include`
  /// targets. Anything else stays in the mod under the folder's own name: ZZMI's
  /// folder takes a file only when no other mod placed different bytes under its
  /// name, so two mods each placing a `readme.txt` could never both be on. Files are
  /// renamed, which keeps their times, so a shipped `.bin` stays paired with its `.txt`.
  static Future<Map<String, String>> _moveShaderFoldersIn(
    List<String> mods,
    Map<String, String> placedShaders,
  ) async {
    final sources = <String, String>{};
    for (final mod in mods) {
      final folder = await _shaderFolderIn(mod);
      if (folder == null) continue;

      final target = Directory(path.join(mod, 'ShaderFixes'));
      await target.create();
      var moved = 0;
      for (final entity in folder.listSync(followLinks: false)) {
        final name = path.basename(entity.path);
        if (entity is Directory || (entity is File && isShaderReplacementName(name))) {
          await entity.rename(path.join(target.path, name));
          moved++;
        }
      }
      if (folder.listSync().isEmpty) await folder.delete();

      final name = placedShaders[folder.path] ?? path.basename(folder.path);
      sources[mod] = name;
      _log.info('shader folder moved into ShaderFixes', fields: {
        'mod': path.basename(mod),
        'from': name,
        'entries': moved,
      });
    }
    return sources;
  }

  /// [name] inside [parent], numbered when something already has it.
  ///
  /// Names compare case-insensitively, as on Windows and under Wine, where ZZMI
  /// reads `Shaders/` and `shaders/` as one folder.
  static String _unusedPath(Directory parent, String name) {
    final taken = parent.existsSync()
        ? {for (final e in parent.listSync(followLinks: false)) path.basename(e.path).toLowerCase()}
        : const <String>{};
    var candidate = name;
    for (var n = 2; taken.contains(candidate.toLowerCase()); n++) {
      candidate = '$name ($n)';
    }
    return path.join(parent.path, candidate);
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
