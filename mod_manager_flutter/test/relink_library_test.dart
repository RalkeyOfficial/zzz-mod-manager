import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart' show LibraryOverlap;
import 'package:mod_manager_flutter/services/platform_service.dart' show replacementLinkName;
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// **Changing the library points the links into the old folder at the new one.** Only a link whose target is exactly
/// `<old>/<its name>`, live or dead, and only when the new library has a folder of that name.
void main() {
  late TempLibrary temp;
  late String oldRoot;
  late String newRoot;

  const hashA = '1f6ab42231416fdb-vs_replace.txt';
  const hashB = '2b7cc53342527fec-ps_replace.txt';

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_relink_');
    oldRoot = temp.mods.path;
    newRoot = p.join(temp.root.path, 'moved');
  });

  String linkOf(String name) => p.join(temp.saveMods.path, name);
  String targetOf(String name) => Link(linkOf(name)).targetSync();

  Matcher refusal(String folder, LibraryOverlap overlap) => isA<LibraryOverlapsLinksFolder>()
      .having((r) => r.folder, 'folder', folder)
      .having((r) => r.overlap, 'overlap', overlap);

  void writeMod(String root, String name, {Map<String, String> shaders = const {}}) {
    final folder = Directory(p.join(root, name))..createSync(recursive: true);
    File(p.join(folder.path, '$name.ini')).writeAsStringSync('[TextureOverrideBody]\nps-t0 = R\n');
    shaders.forEach((relative, contents) {
      File(p.join(folder.path, 'ShaderFixes', relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);
    });
  }

  /// Gives the copy of [name] in the new library the old one's identity, as copying the library does.
  void copySidecar(String name) {
    final sidecar = p.join(AppConstants.modMetadataDirName, AppConstants.modMetadataFileName);
    File(p.join(newRoot, name, sidecar)).parent.createSync(recursive: true);
    File(p.join(oldRoot, name, sidecar)).copySync(p.join(newRoot, name, sidecar));
  }

  Future<List<String>> relink() async {
    await temp.config.setPaths(newRoot, temp.root.path);
    return temp.service.relinkLibrary(oldRoot, newRoot);
  }

  test('a live link and a dead link into the old folder follow it, and read on', () async {
    writeMod(oldRoot, 'Ellen');
    writeMod(oldRoot, 'Miyabi');
    expect(await temp.service.activateMod('Ellen'), isTrue);
    expect(await temp.service.activateMod('Miyabi'), isTrue);
    writeMod(newRoot, 'Ellen');
    writeMod(newRoot, 'Miyabi');
    temp.deleteMod('Miyabi');

    expect(await relink(), isEmpty);

    expect(targetOf('Ellen'), p.join(newRoot, 'Ellen'));
    expect(targetOf('Miyabi'), p.join(newRoot, 'Miyabi'));
    expect(await temp.service.isModActive('Ellen'), isTrue);
    expect(await temp.service.isModActive('Miyabi'), isTrue);
  });

  test('a library moved by hand has its links back', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    temp.mods.renameSync(newRoot);

    expect(await relink(), isEmpty);

    expect(targetOf('Ellen'), p.join(newRoot, 'Ellen'));
    expect(await temp.service.isModActive('Ellen'), isTrue);
  });

  test('a mod the new library lacks keeps its link into the old folder', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    Directory(newRoot).createSync();

    expect(await relink(), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('a link into a folder whose path only begins like the old one is left alone', () async {
    final sibling = '${oldRoot}2';
    writeMod(sibling, 'Ellen');
    Link(linkOf('Ellen')).createSync(p.join(sibling, 'Ellen'));
    writeMod(newRoot, 'Ellen');

    expect(await relink(), isEmpty);

    expect(targetOf('Ellen'), p.join(sibling, 'Ellen'));
  });

  test('a link named other than the folder it points at is left alone', () async {
    writeMod(oldRoot, 'Ellen');
    Link(linkOf('Ellen Alt')).createSync(p.join(oldRoot, 'Ellen'));
    writeMod(newRoot, 'Ellen');
    writeMod(newRoot, 'Ellen Alt');

    expect(await relink(), isEmpty);

    expect(targetOf('Ellen Alt'), p.join(oldRoot, 'Ellen'));
  });

  test('running it twice changes nothing the second time', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    writeMod(newRoot, 'Ellen');
    expect(await relink(), isEmpty);

    final capture = _Capture();
    Log.install(LogRouter(sinks: [capture]));
    addTearDown(() => Log.install(LogRouter()));

    expect(await temp.service.relinkLibrary(oldRoot, newRoot), isEmpty);

    expect(targetOf('Ellen'), p.join(newRoot, 'Ellen'));
    expect(capture.records.where((r) => r.source == 'fileops'), isEmpty);
  });

  test('a change is logged with where the link pointed', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    writeMod(newRoot, 'Ellen');
    final capture = _Capture();
    Log.install(LogRouter(sinks: [capture]));
    addTearDown(() => Log.install(LogRouter()));

    await relink();

    final replaced = capture.records.singleWhere((r) => r.source == 'fileops');
    expect(replaced.message, 'link replaced');
    expect(replaced.fields['from'], p.join(oldRoot, 'Ellen'));
    expect(replaced.fields['target'], p.join(newRoot, 'Ellen'));
  });

  test('a link that cannot be changed is returned by name and left as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    writeMod(newRoot, 'Ellen');
    await Process.run('chmod', ['555', temp.saveMods.path]);
    addTearDown(() => Process.run('chmod', ['755', temp.saveMods.path]));
    try {
      File(p.join(temp.saveMods.path, '.probe'))
        ..createSync()
        ..deleteSync();
      markTestSkipped('chmod does not stop writes for this user');
      return;
    } on FileSystemException {
      // Read-only, as the test needs.
    }

    expect(await relink(), ['Ellen']);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('ZZMI\'s Mods folder as the new library leaves every link as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    await temp.config.setPaths(temp.saveMods.path, temp.root.path);

    expect(await temp.service.relinkLibrary(oldRoot, temp.saveMods.path), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('ZZMI\'s Mods folder reached through a link as the new library leaves every link as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    final alias = p.join(temp.root.path, 'ZZZMods');
    Link(alias).createSync(temp.saveMods.path);
    await temp.config.setPaths(alias, temp.root.path);

    expect(await temp.service.relinkLibrary(oldRoot, alias), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('a new library within ZZMI\'s Mods folder leaves every link as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    final inside = p.join(temp.saveMods.path, 'Library');
    writeMod(inside, 'Ellen');
    await temp.config.setPaths(inside, temp.root.path);

    expect(await temp.service.relinkLibrary(oldRoot, inside), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('a new library holding ZZMI\'s Mods folder leaves every link as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    writeMod(temp.root.path, 'Ellen');
    await temp.config.setPaths(temp.root.path, temp.root.path);

    expect(await temp.service.relinkLibrary(oldRoot, temp.root.path), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('a new library reached through a link into ZZMI\'s Mods folder leaves every link as it was', () async {
    writeMod(oldRoot, 'Ellen');
    await temp.service.activateMod('Ellen');
    writeMod(p.join(temp.saveMods.path, 'Library'), 'Ellen');
    final alias = p.join(temp.root.path, 'ZZZMods');
    Link(alias).createSync(p.join(temp.saveMods.path, 'Library'));
    await temp.config.setPaths(alias, temp.root.path);

    expect(await temp.service.relinkLibrary(oldRoot, alias), isEmpty);

    expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
  });

  test('a mod whose copy cannot be read is returned by name, and the mods after it still follow', () async {
    for (final name in ['Ellen', 'Lucy', 'Miyabi']) {
      writeMod(oldRoot, name);
      expect(await temp.service.activateMod(name), isTrue);
      writeMod(newRoot, name);
    }
    final unreadable = p.join(newRoot, 'Lucy');
    await Process.run('chmod', ['000', unreadable]);
    addTearDown(() => Process.run('chmod', ['755', unreadable]));
    try {
      Directory(unreadable).listSync();
      markTestSkipped('chmod does not stop reads for this user');
      return;
    } on FileSystemException {
      // Unreadable, as the test needs.
    }
    final capture = _Capture();
    Log.install(LogRouter(sinks: [capture]));
    addTearDown(() => Log.install(LogRouter()));

    expect(await relink(), ['Lucy']);

    expect(targetOf('Ellen'), p.join(newRoot, 'Ellen'));
    expect(targetOf('Miyabi'), p.join(newRoot, 'Miyabi'));
    expect(targetOf('Lucy'), p.join(oldRoot, 'Lucy'));
    final warning = capture.records.singleWhere((r) => r.message == 'could not relink');
    expect(warning.level, LogLevel.warning);
    expect(warning.fields['mod'], 'Lucy');
  });

  group('shader files', () {
    late Directory shaders;

    setUp(() {
      File(p.join(temp.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
      shaders = Directory(p.join(temp.root.path, 'ShaderFixes'))..createSync();
    });

    test('a copy with another identity whose shader file differs is refused, and keeps the old link', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'old bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

      expect(await relink(), ['Jiggle']);

      expect(targetOf('Jiggle'), p.join(oldRoot, 'Jiggle'));
      expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
    });

    test('a copy with another identity places its shader files, then follows', () async {
      writeMod(oldRoot, 'Jiggle');
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

      expect(await relink(), isEmpty);

      expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
      expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'new bytes');
    });

    test('a copy with another identity takes the old copy\'s shader files out, so only its own load', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'old bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      writeMod(newRoot, 'Jiggle', shaders: {hashB: 'new bytes'});

      expect(await relink(), isEmpty);

      expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'new bytes');
    });

    test('a file both copies ship with the same bytes stays, held by the new copy', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      writeMod(newRoot, 'Jiggle', shaders: {hashA: 'bytes'});

      expect(await relink(), isEmpty);
      expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'bytes');

      // Held by the new copy alone now, so turning it off takes the file out.
      expect(await temp.service.deactivateMod('Jiggle'), isTrue);
      expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
    });

    test('an old copy whose folder can\'t be read is known by its recorded folder, and its files go', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'old bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      Directory(p.join(oldRoot, 'Jiggle')).renameSync(p.join(temp.root.path, 'unplugged'));
      writeMod(newRoot, 'Jiggle', shaders: {hashB: 'new bytes'});

      expect(await relink(), isEmpty);

      expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
      expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'new bytes');
    });

    test('a copy with the same identity is the same mod moved, so nothing is placed again', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      writeMod(newRoot, 'Jiggle', shaders: {hashA: 'bytes'});
      copySidecar('Jiggle');
      // A placement would be refused without a shader folder, so a skipped one is what lets this through.
      File(p.join(temp.root.path, 'd3dx.ini')).deleteSync();

      expect(await relink(), isEmpty);

      expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
      expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'bytes');
    });

    test('a link that cannot be changed keeps the shader files of the mod that is on, with its old folder gone', () async {
      writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'bytes'});
      expect(await temp.service.activateMod('Jiggle'), isTrue);
      // The library copied with its sidecars, then the old one deleted: the old identity can't be read.
      writeMod(newRoot, 'Jiggle', shaders: {hashA: 'bytes'});
      copySidecar('Jiggle');
      temp.deleteMod('Jiggle');
      await Process.run('chmod', ['555', temp.saveMods.path]);
      addTearDown(() => Process.run('chmod', ['755', temp.saveMods.path]));
      try {
        File(p.join(temp.saveMods.path, '.probe'))
          ..createSync()
          ..deleteSync();
        markTestSkipped('chmod does not stop writes for this user');
        return;
      } on FileSystemException {
        // Read-only, as the test needs.
      }

      expect(await relink(), ['Jiggle']);

      expect(targetOf('Jiggle'), p.join(oldRoot, 'Jiggle'));
      expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'bytes');
    });

    group('turning a mod on over another copy\'s link', () {
      /// The old copy on, and the library saved as the new one with its link left behind, as a refused relink does.
      Future<void> oldCopyOn(Map<String, String> shaders) async {
        writeMod(oldRoot, 'Jiggle', shaders: shaders);
        expect(await temp.service.activateMod('Jiggle'), isTrue);
        await temp.config.setPaths(newRoot, temp.root.path);
      }

      /// Turns the old copy off from its own library, which takes out whatever it still holds.
      Future<void> turnOldCopyOff() async {
        await temp.config.setPaths(oldRoot, temp.root.path);
        await temp.service.deactivateMod('Jiggle');
      }

      test('takes the other copy\'s shader files out once it is on', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Jiggle', shaders: {hashB: 'new bytes'});

        expect(await ApiService.enableMod('Jiggle'), isTrue);

        expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
        expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
        expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'new bytes');
      });

      test('a mod with no shader files still takes the other copy\'s out', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Jiggle');

        expect(await ApiService.enableMod('Jiggle'), isTrue);

        expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      });

      test('comes on when the other copy\'s own files are what differ, and holds the file alone', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

        expect(await ApiService.enableMod('Jiggle'), isTrue);

        expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
        expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'new bytes');
        expect(await temp.service.deactivateMod('Jiggle'), isTrue);
        expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      });

      test('a swap that comes on logs no refusal, and its lines tell the two copies apart', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});
        final capture = _Capture();
        Log.install(LogRouter(sinks: [capture]));
        addTearDown(() => Log.install(LogRouter()));

        expect(await ApiService.enableMod('Jiggle'), isTrue);

        expect(capture.records.where((r) => r.message.contains('refused')), isEmpty);
        final removed = capture.records.singleWhere((r) => r.message == 'shader file removed');
        final placed = capture.records.singleWhere((r) => r.message == 'shader file placed');
        expect(placed.fields['from'], p.join(newRoot, 'Jiggle'));
        expect([removed.fields['uid'], placed.fields['uid']], everyElement(isNotNull));
        expect(removed.fields['uid'], isNot(placed.fields['uid']));
      });

      test('a file another mod holds is still refused, naming it, and the other copy keeps its files', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Other', shaders: {hashB: 'other bytes'});
        expect(await temp.service.activateMod('Other'), isTrue);
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes', hashB: 'new bytes'});

        await expectLater(
          ApiService.enableMod('Jiggle'),
          throwsA(isA<ShaderPlacementRefused>().having(
            (r) => [for (final c in r.conflicts) (c.path, c.owner)],
            'conflicts',
            [(hashB, 'Other')],
          )),
        );
        await expectLater(temp.service.activateMod('Jiggle'), throwsA(isA<ShaderPlacementRefused>()));

        expect(targetOf('Jiggle'), p.join(oldRoot, 'Jiggle'));
        expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
      });

      test('a link that cannot be made puts the other copy\'s files back, still held by it', () async {
        await oldCopyOn({hashA: 'old bytes'});
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});
        // The replace makes its new link under this name first, so a folder there makes it fail.
        Directory(p.join(temp.saveMods.path, replacementLinkName('Jiggle'))).createSync();

        expect(await ApiService.enableMod('Jiggle'), isFalse);

        expect(targetOf('Jiggle'), p.join(oldRoot, 'Jiggle'));
        expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
        await turnOldCopyOff();
        expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      });

      test('a link that cannot be made puts back every other copy\'s file it can, past one the user edited', () async {
        await oldCopyOn({hashA: 'old a', hashB: 'old b'});
        File(p.join(shaders.path, hashB)).writeAsStringSync('edited by the user');
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new a'});
        Directory(p.join(temp.saveMods.path, replacementLinkName('Jiggle'))).createSync();
        final shortfalls = <ShaderRestoreShortfall>[];
        final subscription = ShaderFixesService.shortfalls.listen(shortfalls.add);
        addTearDown(subscription.cancel);

        expect(await ApiService.enableMod('Jiggle'), isFalse);

        expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old a');
        expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'edited by the user');
        await pumpEventQueue();
        expect(shortfalls, isEmpty);
        await turnOldCopyOff();
        expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
      });

      group('with another link still leading to the other copy', () {
        void handMadeLink() => Link(linkOf('Jiggle by hand')).createSync(p.join(oldRoot, 'Jiggle'));

        test('a conflict with its files is refused, naming that link, and they stay', () async {
          await oldCopyOn({hashA: 'old bytes'});
          handMadeLink();
          writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

          for (final enable in [() => ApiService.enableMod('Jiggle'), () => temp.service.activateMod('Jiggle')]) {
            await expectLater(
              enable(),
              throwsA(isA<ShaderPlacementRefused>()
                  .having((r) => r.stillOn?.link, 'still on through', 'Jiggle by hand')
                  .having((r) => r.conflicts.single.ownerUid == r.stillOn?.uid, 'held by that copy', isTrue)),
            );
          }

          expect(targetOf('Jiggle'), p.join(oldRoot, 'Jiggle'));
          expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
        });

        test('without a conflict, the mod comes on and the other copy keeps its files', () async {
          await oldCopyOn({hashA: 'old bytes'});
          handMadeLink();
          writeMod(newRoot, 'Jiggle', shaders: {hashB: 'new bytes'});

          expect(await ApiService.enableMod('Jiggle'), isTrue);

          expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
          expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'new bytes');
        });
      });

      group('on a drive that is unplugged', () {
        String recordPath() => p.join(temp.root.path, 'shader_fixes.json');
        Map<String, dynamic> record() => jsonDecode(File(recordPath()).readAsStringSync()) as Map<String, dynamic>;

        /// The old copy on, then its folder gone from where its link points.
        Future<void> unplugged(Map<String, String> shaders) async {
          await oldCopyOn(shaders);
          Directory(p.join(oldRoot, 'Jiggle')).renameSync(p.join(temp.root.path, 'unplugged'));
        }

        test('is known by its recorded folder, and its conflicting files go', () async {
          await unplugged({hashA: 'old bytes'});
          writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

          expect(await ApiService.enableMod('Jiggle'), isTrue);

          expect(targetOf('Jiggle'), p.join(newRoot, 'Jiggle'));
          expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'new bytes');
          expect(await temp.service.deactivateMod('Jiggle'), isTrue);
          expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
        });

        test('is known by its recorded folder, and its files go once the mod is on', () async {
          await unplugged({hashA: 'old bytes'});
          writeMod(newRoot, 'Jiggle', shaders: {hashB: 'new bytes'});

          expect(await ApiService.enableMod('Jiggle'), isTrue);

          expect(File(p.join(shaders.path, hashA)).existsSync(), isFalse);
          expect(File(p.join(shaders.path, hashB)).readAsStringSync(), 'new bytes');
        });

        test('a link that cannot be made reports its files, which have nowhere to come back from', () async {
          await unplugged({hashA: 'old bytes'});
          writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});
          Directory(p.join(temp.saveMods.path, replacementLinkName('Jiggle'))).createSync();
          final shortfalls = <ShaderRestoreShortfall>[];
          final subscription = ShaderFixesService.shortfalls.listen(shortfalls.add);
          addTearDown(subscription.cancel);

          expect(await ApiService.enableMod('Jiggle'), isFalse);

          await pumpEventQueue();
          expect([for (final s in shortfalls) [s.folder, ...s.files]], [[p.join(oldRoot, 'Jiggle'), hashA]]);
        });

        test('recorded with no folder, as before, it is not guessed: the conflict is refused as another copy\'s', () async {
          await unplugged({hashA: 'old bytes'});
          File(recordPath()).writeAsStringSync(jsonEncode(record()..remove('sources')));
          writeMod(newRoot, 'Jiggle', shaders: {hashA: 'new bytes'});

          await expectLater(
            ApiService.enableMod('Jiggle'),
            throwsA(isA<ShaderPlacementRefused>()
                .having((r) => [for (final c in r.conflicts) (c.path, c.owner)], 'conflicts', [(hashA, 'Jiggle')])),
          );

          expect(File(p.join(shaders.path, hashA)).readAsStringSync(), 'old bytes');
        });
      });
    });

    group('the folder recorded for placed files', () {
      Map<String, dynamic> sources() =>
          jsonDecode(File(p.join(temp.root.path, 'shader_fixes.json')).readAsStringSync())['sources'] as Map<String, dynamic>;

      test('follows a rename of a mod that is on', () async {
        writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'bytes'});
        expect(await temp.service.activateMod('Jiggle'), isTrue);
        expect(sources().values, [p.join(oldRoot, 'Jiggle')]);

        expect(await temp.service.renameMod('Jiggle', 'Jiggle 2'), isTrue);

        expect(sources().values, [p.join(oldRoot, 'Jiggle 2')]);
      });

      test('follows a library change that moved the mod', () async {
        writeMod(oldRoot, 'Jiggle', shaders: {hashA: 'bytes'});
        expect(await temp.service.activateMod('Jiggle'), isTrue);
        writeMod(newRoot, 'Jiggle', shaders: {hashA: 'bytes'});
        copySidecar('Jiggle');

        expect(await relink(), isEmpty);

        expect(sources().values, [p.join(newRoot, 'Jiggle')]);
      });
    });
  });

  group('saving the library path', () {
    test('a changed path re-points the links', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');
      writeMod(newRoot, 'Ellen');

      expect(await ApiService.updateConfig(modsPath: newRoot, zzmiPath: temp.root.path), isEmpty);

      expect(targetOf('Ellen'), p.join(newRoot, 'Ellen'));
    });

    test('ZZMI\'s Mods folder as the library is refused, and nothing is saved or re-pointed', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');

      await expectLater(
        ApiService.updateConfig(modsPath: temp.saveMods.path, zzmiPath: temp.root.path),
        throwsA(refusal(temp.saveMods.path, LibraryOverlap.same)),
      );

      expect(temp.config.modsPath, oldRoot);
      expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
    });

    test('ZZMI\'s Mods folder reached through a link is refused too', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');
      final alias = p.join(temp.root.path, 'ZZZMods');
      Link(alias).createSync(temp.saveMods.path);

      await expectLater(
        ApiService.updateConfig(modsPath: alias, zzmiPath: temp.root.path),
        throwsA(refusal(alias, LibraryOverlap.leadsTo)),
      );

      expect(temp.config.modsPath, oldRoot);
      expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
    });

    test('a library within ZZMI\'s Mods folder is refused, and nothing is saved or re-pointed', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');
      final inside = p.join(temp.saveMods.path, 'Library');
      writeMod(inside, 'Ellen');

      await expectLater(
        ApiService.updateConfig(modsPath: inside, zzmiPath: temp.root.path),
        throwsA(refusal(inside, LibraryOverlap.inside)),
      );

      expect(temp.config.modsPath, oldRoot);
      expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
    });

    test('a library within ZZMI\'s Mods folder through a link is refused', () async {
      Directory(p.join(temp.saveMods.path, 'Library')).createSync();
      final alias = p.join(temp.root.path, 'ZZZMods');
      Link(alias).createSync(p.join(temp.saveMods.path, 'Library'));

      await expectLater(
        ApiService.updateConfig(modsPath: alias, zzmiPath: temp.root.path),
        throwsA(refusal(alias, LibraryOverlap.inside)),
      );
      expect(temp.config.modsPath, oldRoot);
    });

    test('a library holding ZZMI\'s Mods folder is refused, and nothing is saved', () async {
      await expectLater(
        ApiService.updateConfig(modsPath: temp.root.path, zzmiPath: temp.root.path),
        throwsA(refusal(temp.root.path, LibraryOverlap.contains)),
      );
      expect(temp.config.modsPath, oldRoot);
    });

    test('a library holding ZZMI\'s Mods folder through a link is refused', () async {
      final alias = p.join(Directory.systemTemp.path, '${p.basename(temp.root.path)}_alias');
      Link(alias).createSync(temp.root.path);
      addTearDown(() => Link(alias).deleteSync());

      await expectLater(
        ApiService.updateConfig(modsPath: alias, zzmiPath: temp.root.path),
        throwsA(refusal(alias, LibraryOverlap.contains)),
      );
      expect(temp.config.modsPath, oldRoot);
    });

    test('a library beside ZZMI\'s Mods folder whose name only begins like it is accepted', () async {
      final beside = '${temp.saveMods.path}2';
      Directory(beside).createSync();

      expect(await ApiService.updateConfig(modsPath: beside, zzmiPath: temp.root.path), isEmpty);
      expect(temp.config.modsPath, beside);
    });

    group('a library within ZZMI\'s Mods folder that ZZMI skips is accepted', () {
      // ZZMI's `exclude_recursive = DISABLED*` skips a folder of that name, in any case, at any depth.
      for (final relative in ['DISABLED_Library', 'disabled_x', p.join('DISABLED', 'Library'), p.join('Stash', 'DISABLED_Library')]) {
        test(relative, () async {
          final library = p.join(temp.saveMods.path, relative);
          Directory(library).createSync(recursive: true);

          expect(await ApiService.updateConfig(modsPath: library, zzmiPath: temp.root.path), isEmpty);
          expect(temp.config.modsPath, library);
        });
      }

      test('a folder only named like one below the library does not count', () async {
        final library = p.join(temp.saveMods.path, 'Library');
        Directory(p.join(library, 'DISABLED_old')).createSync(recursive: true);

        await expectLater(
          ApiService.updateConfig(modsPath: library, zzmiPath: temp.root.path),
          throwsA(refusal(library, LibraryOverlap.inside)),
        );
      });

      test('a folder whose name has DISABLED other than at its start does not count', () async {
        final library = p.join(temp.saveMods.path, 'Old_DISABLED');
        Directory(library).createSync(recursive: true);

        await expectLater(
          ApiService.updateConfig(modsPath: library, zzmiPath: temp.root.path),
          throwsA(refusal(library, LibraryOverlap.inside)),
        );
      });
    });

    test('a library that does not exist yet is compared by its path', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');

      expect(await ApiService.updateConfig(modsPath: newRoot, zzmiPath: temp.root.path), isEmpty);

      expect(temp.config.modsPath, newRoot);
      expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
    });

    test('a mod that fails partway is returned, and the save still stands', () async {
      writeMod(oldRoot, 'Ellen');
      writeMod(oldRoot, 'Lucy');
      await temp.service.activateMod('Ellen');
      await temp.service.activateMod('Lucy');
      writeMod(newRoot, 'Ellen');
      writeMod(newRoot, 'Lucy');
      final unreadable = p.join(newRoot, 'Ellen');
      await Process.run('chmod', ['000', unreadable]);
      addTearDown(() => Process.run('chmod', ['755', unreadable]));
      try {
        Directory(unreadable).listSync();
        markTestSkipped('chmod does not stop reads for this user');
        return;
      } on FileSystemException {
        // Unreadable, as the test needs.
      }

      expect(await ApiService.updateConfig(modsPath: newRoot, zzmiPath: temp.root.path), ['Ellen']);

      expect(temp.config.modsPath, newRoot);
      expect(targetOf('Lucy'), p.join(newRoot, 'Lucy'));
    });

    test('with no library before, nothing is re-pointed', () async {
      writeMod(oldRoot, 'Ellen');
      await temp.service.activateMod('Ellen');
      writeMod(newRoot, 'Ellen');
      await temp.config.setPaths('', temp.root.path);

      await ApiService.updateConfig(modsPath: newRoot, zzmiPath: temp.root.path);

      expect(targetOf('Ellen'), p.join(oldRoot, 'Ellen'));
    });
  });
}

class _Capture extends LogSink {
  final records = <LogRecord>[];

  @override
  LogFormat get format => LogFormat.file;

  @override
  LogLevel get threshold => LogLevel.debug;

  @override
  void write(LogRecord record, String line) => records.add(record);
}
