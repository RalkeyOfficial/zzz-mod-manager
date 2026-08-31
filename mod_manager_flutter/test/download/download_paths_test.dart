import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/download/download_paths.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temp;
  late DownloadPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('download_paths_test_');
    paths = DownloadPaths(temp);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('sanitizeFilename', () {
    test('keeps an ordinary name unchanged', () {
      expect(
        DownloadPaths.sanitizeFilename('remielleswimlite.rar', fallback: 'x'),
        'remielleswimlite.rar',
      );
    });

    test('cannot escape the directory', () {
      // The name arrives from a remote API or a webview — untrusted input.
      expect(DownloadPaths.sanitizeFilename('../../etc/passwd', fallback: 'x'),
          'passwd');
      expect(DownloadPaths.sanitizeFilename(r'..\..\windows\system32', fallback: 'x'),
          'system32');
      expect(DownloadPaths.sanitizeFilename('/absolute/path.zip', fallback: 'x'),
          'path.zip');
      expect(DownloadPaths.sanitizeFilename('..', fallback: 'fb'), 'fb');
    });

    test('replaces characters the filesystem rejects', () {
      expect(
        DownloadPaths.sanitizeFilename('a:b*c?d"e<f>g|h.zip', fallback: 'x'),
        'a_b_c_d_e_f_g_h.zip',
      );
    });

    test('strips leading dots so the file is not hidden', () {
      expect(DownloadPaths.sanitizeFilename('...mod.zip', fallback: 'x'), 'mod.zip');
    });

    test('falls back on empty or whitespace input', () {
      expect(DownloadPaths.sanitizeFilename(null, fallback: 'fb.zip'), 'fb.zip');
      expect(DownloadPaths.sanitizeFilename('', fallback: 'fb.zip'), 'fb.zip');
      expect(DownloadPaths.sanitizeFilename('   ', fallback: 'fb.zip'), 'fb.zip');
    });

    test('escapes reserved Windows device names', () {
      expect(DownloadPaths.sanitizeFilename('CON.zip', fallback: 'x'), '_CON.zip');
      expect(DownloadPaths.sanitizeFilename('nul', fallback: 'x'), '_nul');
      // Not reserved — must not be mangled.
      expect(DownloadPaths.sanitizeFilename('console.zip', fallback: 'x'),
          'console.zip');
    });

    test('caps the length but keeps the extension', () {
      final long = '${'a' * 400}.rar';
      final result = DownloadPaths.sanitizeFilename(long, fallback: 'x');
      expect(result.length, lessThanOrEqualTo(150));
      expect(path.extension(result), '.rar');
    });

    test('keeps unicode, which is common in mod names', () {
      expect(DownloadPaths.sanitizeFilename('Эллен ダウンロード.zip', fallback: 'x'),
          'Эллен ダウンロード.zip');
    });
  });

  group('path derivation', () {
    test('part and record sit beside the final file', () {
      expect(path.basename(paths.finalFile('mod.rar').path), 'mod.rar');
      expect(path.basename(paths.partFile('mod.rar').path), 'mod.rar.part');
      expect(path.basename(paths.recordFile('mod.rar').path), 'mod.rar.part.json');
      expect(paths.partFile('mod.rar').parent.path, temp.path);
    });
  });

  group('resolveCollision', () {
    test('uses the plain name when nothing is there', () async {
      final file = await paths.resolveCollision('mod.rar');
      expect(path.basename(file.path), 'mod.rar');
    });

    test('never overwrites an existing archive', () async {
      paths.finalFile('mod.rar').writeAsStringSync('old');
      final file = await paths.resolveCollision('mod.rar');
      expect(path.basename(file.path), 'mod (2).rar');
      expect(paths.finalFile('mod.rar').readAsStringSync(), 'old');
    });

    test('counts up past several collisions', () async {
      paths.finalFile('mod.rar').writeAsStringSync('a');
      File(path.join(temp.path, 'mod (2).rar')).writeAsStringSync('b');
      File(path.join(temp.path, 'mod (3).rar')).writeAsStringSync('c');
      final file = await paths.resolveCollision('mod.rar');
      expect(path.basename(file.path), 'mod (4).rar');
    });

    test('an existing .part is NOT a collision', () async {
      // It's a resume candidate. Merging these two checks would make every
      // interrupted download rename itself and lose the partial.
      paths.partFile('mod.rar').writeAsStringSync('partial');
      final file = await paths.resolveCollision('mod.rar');
      expect(path.basename(file.path), 'mod.rar');
    });
  });

  group('sweep', () {
    test('removes a .part with no record', () async {
      paths.partFile('orphan.rar').writeAsStringSync('bytes');

      expect(await paths.sweep(), 1);
      expect(paths.partFile('orphan.rar').existsSync(), isFalse);
    });

    test('removes a record with no .part', () async {
      paths.recordFile('orphan.rar').writeAsStringSync('{}');

      expect(await paths.sweep(), 1);
      expect(paths.recordFile('orphan.rar').existsSync(), isFalse);
    });

    test('keeps a fresh, complete pair — that is a resumable download', () async {
      paths.partFile('live.rar').writeAsStringSync('bytes');
      paths.recordFile('live.rar').writeAsStringSync('{}');

      expect(await paths.sweep(), 0);
      expect(paths.partFile('live.rar').existsSync(), isTrue);
      expect(paths.recordFile('live.rar').existsSync(), isTrue);
    });

    test('removes a pair nobody has touched for a week', () async {
      paths.partFile('stale.rar').writeAsStringSync('bytes');
      paths.recordFile('stale.rar').writeAsStringSync('{}');

      final later = DateTime.now().add(const Duration(days: 8));
      expect(await paths.sweep(now: later), 2);
      expect(paths.partFile('stale.rar').existsSync(), isFalse);
      expect(paths.recordFile('stale.rar').existsSync(), isFalse);
    });

    test('never touches completed archives', () async {
      paths.finalFile('keep.rar').writeAsStringSync('done');

      final later = DateTime.now().add(const Duration(days: 400));
      expect(await paths.sweep(now: later), 0);
      expect(paths.finalFile('keep.rar').existsSync(), isTrue);
    });

    test('a missing directory is not an error', () async {
      final gone = DownloadPaths(Directory(path.join(temp.path, 'nope')));
      expect(await gone.sweep(), 0);
    });
  });

  /// **At launch, and only at launch.**
  ///
  /// An install deletes the archive it consumed, so what is left here is an
  /// archive whose install never ran: one whose extraction failed and was kept
  /// on purpose, one interrupted by the app closing, or one whose delete failed.
  /// Nothing swept those, so the folder grew forever — and a leftover with the
  /// same name as a new download is what pushes that download to `mod (2).rar`.
  ///
  /// Safe at startup for one reason: nothing is queued or installing yet, so
  /// every complete archive here is by definition finished with. Run at any other
  /// moment it would delete the archive of an install still in progress.
  group('sweepCompleted', () {
    test('it removes a completed archive', () async {
      paths.finalFile('leftover.rar').writeAsStringSync('done');

      expect(await paths.sweepCompleted(), 1);
      expect(paths.finalFile('leftover.rar').existsSync(), isFalse);
    });

    test('it leaves a resumable download alone', () async {
      // The `.part` and its record are the one thing in here that is still
      // wanted: they are what lets a download continue instead of restarting.
      paths.partFile('live.rar').writeAsStringSync('bytes');
      paths.recordFile('live.rar').writeAsStringSync('{}');

      expect(await paths.sweepCompleted(), 0);
      expect(paths.partFile('live.rar').existsSync(), isTrue);
      expect(paths.recordFile('live.rar').existsSync(), isTrue);
    });

    test('it clears the collision that renames the next download', () async {
      // The reason this exists rather than being tidiness: a leftover
      // `mod.rar` makes the next download of the same file `mod (2).rar`, and
      // for an archive with no folder inside it that suffix becomes the name of
      // the user's mod.
      paths.finalFile('mod.rar').writeAsStringSync('old');
      await paths.sweepCompleted();

      final promoted = await paths.resolveCollision('mod.rar');
      expect(path.basename(promoted.path), 'mod.rar');
    });

    test('a missing directory is not an error', () async {
      final gone = DownloadPaths(Directory(path.join(temp.path, 'nope')));
      expect(await gone.sweepCompleted(), 0);
    });
  });
}
