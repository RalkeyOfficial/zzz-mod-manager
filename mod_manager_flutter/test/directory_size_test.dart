import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/directory_size.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dir_size_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File write(String relative, int bytes) {
    final file = File(path.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  group('measureDirectorySync', () {
    test('sums every file at every depth', () {
      write('a.bin', 100);
      write('nested/b.bin', 250);
      write('nested/deeper/c.bin', 7);

      final size = measureDirectorySync(root.path);

      expect(size.bytes, 357);
      expect(size.fileCount, 3);
      expect(size.complete, isTrue);
    });

    test('an empty directory is zero and complete, not unreadable', () {
      final size = measureDirectorySync(root.path);

      expect(size.bytes, 0);
      expect(size.fileCount, 0);
      expect(size.complete, isTrue);
    });

    test('a missing root is reported as unreadable rather than empty', () {
      final size = measureDirectorySync(path.join(root.path, 'nope'));

      expect(size.bytes, 0);
      expect(size.complete, isFalse,
          reason: 'zero bytes and "could not look" must not read alike');
    });

    test('excluded directories are not descended into', () {
      write('keep.bin', 10);
      write('skip/big.bin', 9000);

      final size = measureDirectorySync(
        root.path,
        excludePaths: {path.join(root.path, 'skip')},
      );

      expect(size.bytes, 10);
      expect(size.fileCount, 1);
    });

    test('an excluded path that does not exist is simply nothing to skip', () {
      write('keep.bin', 10);

      final size = measureDirectorySync(
        root.path,
        excludePaths: {path.join(root.path, 'never_existed')},
      );

      expect(size.bytes, 10);
    });
  });

  group('links', () {
    // The app activates mods by linking them into the game folder, so a walk
    // that follows links either counts a mod twice or leaves the library.
    test('a link to a directory outside the tree contributes nothing', () {
      final outside = Directory.systemTemp.createTempSync('dir_size_outside_');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      File(path.join(outside.path, 'huge.bin'))
          .writeAsBytesSync(List<int>.filled(5000, 0));

      write('own.bin', 42);
      Link(path.join(root.path, 'linked')).createSync(outside.path);

      final size = measureDirectorySync(root.path);

      expect(size.bytes, 42);
      expect(size.fileCount, 1);
    }, testOn: 'linux || mac-os');

    test('a link pointing at an ancestor terminates instead of recursing', () {
      write('own.bin', 42);
      Link(path.join(root.path, 'loop')).createSync(root.path);

      final size = measureDirectorySync(root.path);

      expect(size.bytes, 42);
    }, testOn: 'linux || mac-os');

    test('a link to a file inside the tree does not double-count it', () {
      write('real.bin', 120);
      Link(path.join(root.path, 'alias.bin'))
          .createSync(path.join(root.path, 'real.bin'));

      final size = measureDirectorySync(root.path);

      expect(size.bytes, 120);
      expect(size.fileCount, 1);
    }, testOn: 'linux || mac-os');
  });

  group('unreadable entries', () {
    test('an unreadable folder is counted, and the rest is still measured', () {
      write('readable/a.bin', 60);
      final locked = Directory(path.join(root.path, 'locked'))
        ..createSync(recursive: true);
      File(path.join(locked.path, 'hidden.bin'))
          .writeAsBytesSync(List<int>.filled(9999, 0));
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

      final size = measureDirectorySync(root.path);

      // The whole point of catching per entity: the readable half survives.
      expect(size.bytes, 60);
      expect(size.unreadable, 1);
      expect(size.complete, isFalse);
    }, testOn: 'linux');
  });

  group('measureDirectory', () {
    test('answers the same as the synchronous walk', () async {
      write('a.bin', 100);
      write('nested/b.bin', 250);

      final size = await measureDirectory(root.path);

      expect(size.bytes, 350);
      expect(size.fileCount, 2);
      expect(size.complete, isTrue);
    });
  });
}
