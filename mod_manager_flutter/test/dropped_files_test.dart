import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/services/update_apply/dropped_files.dart';

/// **Which of the last version's files the new one leaves stranded**, decided
/// with no folder and no download.
///
/// The rule is a set difference, and every test here is about one of the four
/// ways it must *not* be a plain difference: another download in the folder owns
/// the path, the user deleted the file already, the same file is coming back
/// under the same name, or something is underneath it that has to come back
/// instead.
void main() {
  InstalledFile added(String path) =>
      InstalledFile(path: path, role: InstalledFileRole.added);

  InstalledFile replaced(String path) =>
      InstalledFile(path: path, role: InstalledFileRole.replaced);

  DroppedFiles plan({
    List<InstalledFile> recorded = const [],
    Set<String> incoming = const {},
    Set<String> onDisk = const {},
    Iterable<String> claimedByOthers = const [],
    Set<String> incomingReferences = const {},
    Set<String> storedOriginals = const {},
    bool keepsDisplaced = false,
  }) =>
      planDroppedFiles(
        recorded: recorded,
        incoming: incoming,
        onDisk: onDisk,
        claimedByOthers: claimedByOthers,
        incomingReferences: incomingReferences,
        storedOriginals: storedOriginals,
        keepsDisplaced: keepsDisplaced,
      );

  group('the set difference', () {
    test('a file the new version has no name for is removed', () {
      // The whole feature: the author dropped a shader, and no `.ini` in the
      // folder references it — so nothing else in this app can see it at all.
      final result = plan(
        recorded: [added('ellen.ini'), added('ShaderFixes/glow.hlsl')],
        incoming: {'ellen.ini'},
        onDisk: {'ellen.ini', 'shaderfixes/glow.hlsl'},
      );

      expect(result.remove, ['ShaderFixes/glow.hlsl']);
      expect(result.gone, isEmpty);
    });

    test('a file the new version ships again is left to the copy', () {
      final result = plan(
        recorded: [added('ellen.ini'), added('Body.dds')],
        incoming: {'ellen.ini', 'body.dds'},
        onDisk: {'ellen.ini', 'body.dds'},
      );

      expect(result.isEmpty, isTrue,
          reason: 'the overwrite handles both, so there is nothing to decide');
    });

    test('paths are compared normalised and acted on as recorded', () {
      // 3DMigoto is case-insensitive so the comparison has to be, but a
      // lower-cased path handed to `File` deletes nothing on Linux and names a
      // file the user does not have.
      final result = plan(
        recorded: [added('Textures/BodyA.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/bodya.dds'},
      );

      expect(result.remove, ['Textures/BodyA.dds']);
    });

    test('a download with no record decides nothing', () {
      // A folder installed before the record existed. Guessing which files are
      // the mod's would delete the mod.
      final result = plan(
        incoming: {'ellen.ini'},
        onDisk: {'ellen.ini', 'Body.dds', 'somebody_elses.ini'},
      );

      expect(result, same(DroppedFiles.nothing));
    });
  });

  group('what it refuses to touch', () {
    test('a path another download records belongs to that download', () {
      // The ordinary mixed folder: a patch replaced the mod's `Body.dds`, and
      // the mod's next version stops shipping it. The file sitting there is the
      // patch's, and deleting it is the destruction overwrite exists to avoid.
      final result = plan(
        recorded: [added('ellen.ini'), added('Body.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'ellen.ini', 'body.dds'},
        claimedByOthers: ['Body.dds'],
      );

      expect(result.remove, isEmpty);
      expect(result.claimed, ['Body.dds']);
    });

    test('a file the new version asks for but did not bring stays', () {
      // The template-`.ini` idiom: an author who replaced one component ships a
      // fraction of what their own `.ini` references. Removing this would break
      // a working mod on the update meant to improve it, which is worse than
      // any leftover.
      final result = plan(
        recorded: [added('Textures/Body.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/body.dds'},
        incomingReferences: {'textures/body.dds'},
      );

      expect(result.stillNeeded, ['Textures/Body.dds']);
      expect(result.remove, isEmpty);
    });

    test('a recorded file the user already deleted is reported, not acted on',
        () {
      // The record says what the app wrote. Deleting one of those since is an
      // edit rather than damage.
      final result = plan(
        recorded: [added('ellen.ini'), added('Glow.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'ellen.ini'},
      );

      expect(result.remove, isEmpty);
      expect(result.gone, ['Glow.dds']);
    });
  });

  group('what is underneath it', () {
    test('the bottom layer deletes a replaced file, because that was itself',
        () {
      // **The dangerous half of the role rule.** Every update overwrites the
      // previous version's files, so a base's record is almost entirely
      // `replaced` — and what it replaced was the version this update is
      // getting rid of. Refusing to delete these would make the whole feature
      // do nothing after a mod's first update.
      final result = plan(
        recorded: [replaced('Textures/Body.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/body.dds'},
      );

      expect(result.remove, ['Textures/Body.dds']);
      expect(result.unrecoverable, isEmpty);
    });

    test('a layer that kept what it displaced puts that back instead', () {
      // A patch's own update: the file it wrote over is the mod's, and the mod
      // is still supposed to have it.
      final result = plan(
        recorded: [replaced('Textures/Body.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/body.dds'},
        storedOriginals: {'Textures/Body.dds'},
        keepsDisplaced: true,
      );

      expect(result.restore, ['Textures/Body.dds']);
      expect(result.remove, isEmpty);
    });

    test('and leaves it alone when the original was never kept', () {
      // Keeping it failed at install, or the folder was patched before the
      // store existed. Deleting leaves a hole where the mod's file was;
      // leaving it keeps a file no download claims, which is recoverable.
      final result = plan(
        recorded: [replaced('Textures/Body.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/body.dds'},
        keepsDisplaced: true,
      );

      expect(result.unrecoverable, ['Textures/Body.dds']);
      expect(result.remove, isEmpty);
      expect(result.touchesFiles, isFalse);
    });

    test('a file that layer added is still its own to remove', () {
      final result = plan(
        recorded: [added('Textures/Extra.dds')],
        incoming: {'ellen.ini'},
        onDisk: {'textures/extra.dds'},
        keepsDisplaced: true,
      );

      expect(result.remove, ['Textures/Extra.dds']);
    });
  });

  test('the count is what the folder loses', () {
    final result = plan(
      recorded: [
        added('Gone.dds'),
        added('Removed.dds'),
        replaced('Restored.dds'),
      ],
      incoming: {'ellen.ini'},
      onDisk: {'removed.dds', 'restored.dds'},
      storedOriginals: {'Restored.dds'},
      keepsDisplaced: true,
    );

    expect(result.changedCount, 2,
        reason: 'one deleted and one put back — the file that was already gone '
            'is not something the user is told about');
  });
}
