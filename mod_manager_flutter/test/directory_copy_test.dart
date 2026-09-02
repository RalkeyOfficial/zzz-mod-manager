import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/utils/directory_copy.dart';
import 'package:path/path.dart' as path;

/// The one copy both the import and the update path use.
///
/// The link behaviour is the reason there is only one: the import path had its
/// own copy that followed links, and following them on the way *into* a library
/// is worse than useless — a link out of the folder copies unbounded unrelated
/// disk, and one pointing at an ancestor recurses forever.
void main() {
  late Directory root;
  late Directory source;
  late Directory dest;

  setUp(() {
    root = Directory.systemTemp.createTempSync('copydir_test_');
    source = Directory(path.join(root.path, 'source'))..createSync();
    dest = Directory(path.join(root.path, 'dest'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(Directory dir, String relative, String contents) {
    final file = File(path.join(dir.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String? read(Directory dir, String relative) {
    final file = File(path.join(dir.path, relative));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  test('copies files and nested folders, and reports each one', () async {
    write(source, 'mod.ini', 'a');
    write(source, 'textures/skin.dds', 'b');

    final written = await copyDirectory(source, dest);

    expect(written.length, 2);
    expect(read(dest, 'mod.ini'), 'a');
    expect(read(dest, 'textures/skin.dds'), 'b');
  });

  test('overwrites collisions and leaves everything else alone', () async {
    // What an update needs: a mod folder frequently holds a second download,
    // and replacing the folder would destroy it.
    write(source, 'mod.ini', 'new');
    dest.createSync(recursive: true);
    write(dest, 'mod.ini', 'old');
    write(dest, 'patch.ini', 'mine');

    await copyDirectory(source, dest);

    expect(read(dest, 'mod.ini'), 'new');
    expect(read(dest, 'patch.ini'), 'mine', reason: 'the hand-merge survives');
  });

  group('what it reports', () {
    test('paths are destination-relative, `/`-separated, on-disk spelling',
        () async {
      // These paths open files and are shown to a user. The normalised
      // lower-cased key the comparison rules use opens nothing on Linux.
      write(source, 'Ellen.ini', 'a');
      write(source, 'Textures/Body.dds', 'b');

      final written = await copyDirectory(source, dest);

      expect(written.map((f) => f.path).toSet(),
          {'Ellen.ini', 'Textures/Body.dds'});
    });

    test('sizes come off the files it wrote', () async {
      write(source, 'mod.ini', 'abcde');

      final written = await copyDirectory(source, dest);

      expect(written.single.bytes, 5);
    });

    test('a path that was occupied is `replaced`, an empty one `added`',
        () async {
      // The only code that can answer this is the code about to overwrite, and
      // only *before* it does — afterwards every path is occupied by the file
      // just written.
      write(source, 'mod.ini', 'new');
      write(source, 'extra.ini', 'new');
      dest.createSync(recursive: true);
      write(dest, 'mod.ini', 'old');

      final written = await copyDirectory(source, dest);
      final roles = {for (final file in written) file.path: file.role};

      expect(roles['mod.ini'], InstalledFileRole.replaced);
      expect(roles['extra.ini'], InstalledFileRole.added);
    });

    test('a skipped subtree is absent from the report as well as the copy',
        () async {
      write(source, 'mod.ini', 'a');
      write(source, '.zzz-mod-manager/metadata.json', 'theirs');

      final written = await copyDirectory(
        source,
        dest,
        skipRelative: (relative) =>
            relative.split('/').first == '.zzz-mod-manager',
      );

      expect(written.map((f) => f.path), ['mod.ini']);
    });
  });

  group('links', () {
    test('a link to a file outside the folder is skipped, not resolved',
        () async {
      // Following it would copy unrelated disk into the library under a name
      // the archive chose.
      write(root, 'secret.txt', 'not mine to copy');
      write(source, 'mod.ini', 'a');
      Link(path.join(source.path, 'stolen.txt'))
          .createSync(path.join(root.path, 'secret.txt'));

      final written = await copyDirectory(source, dest);

      expect(written.length, 1, reason: 'only mod.ini');
      expect(read(dest, 'stolen.txt'), isNull);
    });

    test('a link to a directory outside the folder is skipped', () async {
      final outside = Directory(path.join(root.path, 'outside'))..createSync();
      write(outside, 'big.bin', 'x' * 64);
      write(source, 'mod.ini', 'a');
      Link(path.join(source.path, 'linked')).createSync(outside.path);

      await copyDirectory(source, dest);

      expect(Directory(path.join(dest.path, 'linked')).existsSync(), isFalse);
    });

    test('a link pointing at an ancestor does not recurse forever', () async {
      // The hazard the import path's own copy carried: `followLinks: true`
      // resolves this to a real directory and the walk never terminates.
      write(source, 'mod.ini', 'a');
      Link(path.join(source.path, 'loop')).createSync(source.path);

      final written = await copyDirectory(source, dest).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the copy did not terminate'),
      );

      expect(written.length, 1);
    });
  }, skip: Platform.isWindows ? 'symlinks need privileges on Windows' : false);

  test('skipRelative drops a whole subtree', () async {
    // How the update path keeps a stranger's sidecar out of a mod folder.
    write(source, 'mod.ini', 'a');
    write(source, '.zzz-mod-manager/metadata.json', 'theirs');

    final written = await copyDirectory(
      source,
      dest,
      skipRelative: (relative) => relative.split('/').first == '.zzz-mod-manager',
    );

    expect(written.length, 1);
    expect(read(dest, '.zzz-mod-manager/metadata.json'), isNull);
  });
}
