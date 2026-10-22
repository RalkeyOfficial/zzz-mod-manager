import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// Path to a 7-Zip binary, or null when none is installed.
final String? _sevenZip = () {
  for (final candidate in ['7z', '7za', '7zr']) {
    try {
      final which = Process.runSync('which', [candidate]);
      if (which.exitCode == 0) {
        final found = which.stdout.toString().trim();
        if (found.isNotEmpty) return found;
      }
    } catch (_) {
      // `which` missing (Windows); the test skips.
    }
  }
  return null;
}();

/// Whether the 7-Zip found writes zips, which `7zr` does not.
final bool _writesZip = _sevenZip != null && p.basename(_sevenZip!) != '7zr';

const _password = 'SECRETpw-4711';

/// Archive passwords against real encrypted archives, made here with the system 7-Zip as `docs/downloads.md` §12
/// measured them: the listing tells a locked archive apart, a right password unpacks, a wrong one is refused with
/// the archive kept, and the password never reaches the log.
void main() {
  late Directory tmp;
  // A name of its own, so a stray extraction directory can be told apart from other tests'.
  final modName = 'PwTestMod_${DateTime.now().microsecondsSinceEpoch}';

  setUp(() => tmp = Directory.systemTemp.createTempSync('archive_password_test_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A three-file mod folder, as the measurements used.
  Directory source() {
    final mod = Directory(p.join(tmp.path, 'src', modName))..createSync(recursive: true);
    File(p.join(mod.path, 'mod.ini')).writeAsStringSync('[TextureOverrideBody]\nhash = 1\n');
    File(p.join(mod.path, 'body.dds')).writeAsBytesSync(List<int>.generate(20000, (i) => i % 251));
    File(p.join(mod.path, 'notes.txt')).writeAsStringSync('override line\n' * 200);
    return mod;
  }

  /// Packs the mod with 7-Zip's own [switches].
  File make(String name, List<String> switches) {
    final mod = source();
    final archive = p.join(tmp.path, name);
    final made = Process.runSync(_sevenZip!, ['a', ...switches, archive, mod.path]);
    expect(made.exitCode, 0, reason: made.stderr.toString());
    return File(archive);
  }

  File plain7z() => make('plain.7z', []);
  File contents7z() => make('enc.7z', ['-p$_password']);
  File headers7z() => make('enchdr.7z', ['-p$_password', '-mhe=on']);
  File zipCrypto() => make('zipcrypto.zip', ['-tzip', '-p$_password']);
  File aesZip() => make('aes.zip', ['-tzip', '-p$_password', '-mem=AES256']);
  File plainZip() => make('plain.zip', ['-tzip']);

  /// The extraction directories that appeared during [body] and hold this mod.
  Future<List<Directory>> extractionsLeftBy(Future<void> Function() body) async {
    Set<String> now() => {
          for (final e in Directory.systemTemp.listSync())
            if (p.basename(e.path).startsWith('zzz_archive_extract_')) e.path,
        };
    final before = now();
    await body();
    return [
      for (final path in now().difference(before))
        if (Directory(path).listSync(recursive: true).any((e) => e.path.contains(modName))) Directory(path),
    ];
  }

  group('detecting one', () {
    test('a 7z with its files encrypted, and one with its headers too, need a password; a plain one does not',
        () async {
      expect(await ArchiveService.needsPassword(plain7z()), isFalse);
      expect(await ArchiveService.needsPassword(contents7z()), isTrue);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('encrypted headers answer at once, not after the ten-second timeout', () async {
      final archive = headers7z();
      final clock = Stopwatch()..start();
      expect(await ArchiveService.needsPassword(archive), isTrue);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'the listing closes stdin, so 7-Zip stops at its prompt rather than waiting at it');
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('a zip in ZipCrypto or AES needs one, read from its central directory; a plain zip does not', () async {
      expect(await ArchiveService.needsPassword(zipCrypto()), isTrue);
      expect(await ArchiveService.needsPassword(aesZip()), isTrue);
      expect(await ArchiveService.needsPassword(plainZip()), isFalse);
    }, skip: _writesZip ? null : 'no 7-Zip that writes zips');
  });

  group('unpacking with one', () {
    Future<void> unpacksWith(File archive) async {
      final result = await ArchiveService.extractArchive(archiveFile: archive, password: _password);
      expect(result.success, isTrue, reason: result.error);
      final folder = Directory(result.extractedFolders!.single);
      expect(File(p.join(folder.path, 'body.dds')).lengthSync(), 20000);
      await ArchiveService.deleteExtraction(result.extractedFolders!);
    }

    test('the right password unpacks either kind of 7z', () async {
      await unpacksWith(contents7z());
      await unpacksWith(headers7z());
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('the right password unpacks either zip, through 7-Zip', () async {
      await unpacksWith(zipCrypto());
      await unpacksWith(aesZip());
    }, skip: _writesZip ? null : 'no 7-Zip that writes zips');

    test('a wrong one is refused, the archive kept and nothing left unpacked', () async {
      for (final archive in [contents7z(), headers7z(), if (_writesZip) zipCrypto()]) {
        late ArchiveExtractionResult result;
        final left = await extractionsLeftBy(() async {
          result = await ArchiveService.extractArchive(archiveFile: archive, password: 'WRONG');
        });
        expect(result.failure, ExtractFailure.wrongPassword, reason: p.basename(archive.path));
        expect(archive.existsSync(), isTrue, reason: 'kept for the next try');
        expect(left, isEmpty, reason: '${p.basename(archive.path)}: a zip leaves 0-byte files behind');
      }
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('without one, an encrypted 7z is caught by the unpack too, as the backstop', () async {
      final result = await ArchiveService.extractArchive(archiveFile: contents7z());
      expect(result.failure, ExtractFailure.passwordRequired);
    }, skip: _sevenZip == null ? '7z not installed' : null);

    test('the password never reaches a log line', () async {
      final capture = _Capture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));

      final archive = headers7z();
      await ArchiveService.needsPassword(archive);
      await ArchiveService.extractArchive(archiveFile: archive, password: 'WRONG$_password');
      final right = await ArchiveService.extractArchive(archiveFile: contents7z(), password: _password);
      await ArchiveService.deleteExtraction(right.extractedFolders ?? const []);

      expect(capture.lines, isNotEmpty, reason: 'the extraction logs, so the check is not vacuous');
      expect(capture.lines.where((line) => line.contains(_password)), isEmpty);
      expect(capture.records.any((r) => r.fields['password'] == true), isTrue,
          reason: 'that one was given is recorded, never what it was');
    }, skip: _sevenZip == null ? '7z not installed' : null);
  });

  group('the install', () {
    testWidgets('waits for a password, asks again after a wrong one with the archive kept, and installs with the right one',
        (tester) async {
      late TempLibrary temp;
      late File archive;
      await tester.runAsync(() async {
        temp = await TempLibrary.create();
        archive = contents7z();
      });
      late BuildContext context;
      late WidgetRef ref;
      final queue = _HeldQueue();
      await pumpLocalized(
        tester,
        Consumer(
          builder: (c, r, _) {
            context = c;
            ref = r;
            return const SizedBox.shrink();
          },
        ),
        overrides: [...temp.overrides, downloadQueueProvider.overrideWith(() => queue)],
      );

      DownloadJob job({String? password}) => DownloadJob(
            seq: 1,
            request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/1')),
            intent: DownloadIntent.install,
            subject: 'Locked Mod',
            file: const GbFile(idRow: 1, file: 'enc.7z'),
            mod: const GbMod(idRow: 2, name: 'Locked Mod'),
            state: DownloadJobState.installing,
            result: DownloadResult(file: archive, totalBytes: 1),
            password: password,
          );
      Future<InstallStep> run(DownloadJob job) async {
        ref.read(downloadQueueProvider);
        queue.hold(job);
        late InstallStep step;
        await tester.runAsync(() async => step = await runArchiveInstall(context, ref, job));
        return step;
      }

      final asked = await run(job());
      expect(asked, isA<InstallWaits>());
      expect((asked as InstallWaits).wait.question, InstallQuestion.password);
      expect(asked.wait.passwordFailed, isFalse);
      expect(archive.existsSync(), isTrue, reason: 'nothing is unpacked before the password');

      final wrong = await run(job(password: 'WRONG'));
      expect((wrong as InstallWaits).wait.passwordFailed, isTrue);
      expect(archive.existsSync(), isTrue);

      final right = await run(job(password: _password));
      expect(queue.state.single.password, isNull, reason: 'dropped once the unpack it was given for has run');
      expect((right as InstallEnds).result.mods, [modName]);
      expect(Directory(p.join(temp.mods.path, modName)).existsSync(), isTrue);
      expect(archive.existsSync(), isFalse, reason: 'unpacked, so the archive is spent');
    }, skip: _sevenZip == null);
  });
}

/// A queue holding the one job the install runs for, as the host's queue does while it installs.
class _HeldQueue extends DownloadQueue {
  @override
  List<DownloadJob> build() {
    super.build();
    return const [];
  }

  void hold(DownloadJob job) => state = [job];
}

class _Capture extends LogSink {
  final records = <LogRecord>[];
  final lines = <String>[];

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) {
    records.add(record);
    lines.add(line);
  }
}
