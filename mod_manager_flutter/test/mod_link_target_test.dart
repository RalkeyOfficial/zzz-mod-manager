import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_format.dart';
import 'package:mod_manager_flutter/services/log/log_level.dart';
import 'package:mod_manager_flutter/services/log/log_record.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:path/path.dart' as p;

import 'support/link_fails_under.dart';
import 'support/temp_library.dart';

/// **A mod is on only when the link named after it points at its own folder.** A link of that name into any other
/// folder, live or dead, reads as off, is replaced when the mod is turned on, and is never removed by turning it off.
void main() {
  late TempLibrary temp;
  final platform = LinuxPlatformService();

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_link_target_');
  });

  void installMod(String name) {
    temp.createMod(name);
    temp.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
  }

  String linkOf(String name) => p.join(temp.saveMods.path, name);

  group('reading a link target', () {
    test('an absolute target reads as it is stored, normalised', () async {
      Link(linkOf('Ellen')).createSync('/media/drive/library/./Ellen/');
      expect(await platform.readModLinkTarget(linkOf('Ellen')), '/media/drive/library/Ellen');
    });

    test('a relative target is resolved against the links folder', () async {
      Link(linkOf('Ellen')).createSync('../library/Ellen');
      expect(await platform.readModLinkTarget(linkOf('Ellen')), temp.modFolder('Ellen').path);
    });

    test('a folder or a missing path is no link', () async {
      Directory(linkOf('Real')).createSync();
      expect(await platform.readModLinkTarget(linkOf('Real')), isNull);
      expect(await platform.readModLinkTarget(linkOf('Nothing')), isNull);
    });

    test('a Windows junction loses its \\??\\ prefix', () {
      expect(
        normaliseLinkTarget(r'\??\D:\Mods\Library\Ellen', r'C:\ZZMI\Mods', context: p.windows),
        r'D:\Mods\Library\Ellen',
      );
      expect(
        normaliseLinkTarget(r'..\Library\Ellen', r'C:\ZZMI\Mods', context: p.windows),
        r'C:\ZZMI\Library\Ellen',
      );
    });

    test('a Windows target loses a \\\\?\\ prefix, and a network path keeps its \\\\', () {
      expect(normaliseLinkTarget(r'\\?\D:\Mods\Library\Ellen', r'C:\ZZMI\Mods', context: p.windows), r'D:\Mods\Library\Ellen');
      expect(normaliseLinkTarget(r'\\?\UNC\nas\mods\Ellen', r'C:\ZZMI\Mods', context: p.windows), r'\\nas\mods\Ellen');
      expect(normaliseLinkTarget(r'\??\UNC\nas\mods\Ellen', r'C:\ZZMI\Mods', context: p.windows), r'\\nas\mods\Ellen');
    });

    test('a POSIX target keeps a leading \\??\\, which is part of a name there', () {
      expect(normaliseLinkTarget(r'\??\x', '/links', context: p.posix), r'/links/\??\x');
    });
  });

  group('comparing paths', () {
    test('on Linux case matters and a trailing separator does not', () {
      expect(platform.samePath('/mods/Ellen', '/mods/Ellen/'), isTrue);
      expect(platform.samePath('/mods/./Ellen', '/mods/Ellen'), isTrue);
      expect(platform.samePath('/mods/Ellen', '/mods/ellen'), isFalse);
      expect(platform.samePath('/mods/Ellen', '/mods2/Ellen'), isFalse);
    });

    test('on Windows case does not matter', () {
      expect(pathsEqual(r'D:\Mods\Ellen', r'd:\mods\ELLEN\', ignoreCase: true, context: p.windows), isTrue);
      expect(pathsEqual(r'D:\Mods\Ellen', r'D:\Mods2\Ellen', ignoreCase: true, context: p.windows), isFalse);
    });
  });

  group('whether a mod is on', () {
    test('its own link reads on', () async {
      installMod('Ellen');
      expect(await temp.service.activateMod('Ellen'), isTrue);
      expect(await temp.service.isModActive('Ellen'), isTrue);
    });

    test('a link with its name into another folder reads off, live or dead', () async {
      installMod('Ellen');
      final other = Directory(p.join(temp.root.path, 'other', 'Ellen'))..createSync(recursive: true);
      Link(linkOf('Ellen')).createSync(other.path);
      expect(await temp.service.isModActive('Ellen'), isFalse);
      final mods = await temp.service.getModsInfo();
      expect(mods.singleWhere((m) => m.id == 'Ellen').isActive, isFalse);

      other.deleteSync();
      expect(await temp.service.isModActive('Ellen'), isFalse);
    });

    test('a library reached through a link of its own reads on', () async {
      installMod('Ellen');
      final alias = p.join(temp.root.path, 'alias');
      Link(alias).createSync(temp.mods.path);
      // The mod's link names the library through the alias; the config names it directly.
      Link(linkOf('Ellen')).createSync(p.join(alias, 'Ellen'));
      expect(await temp.service.isModActive('Ellen'), isTrue);
    });
  });

  group('a link into another folder', () {
    late Directory other;

    setUp(() {
      installMod('Ellen');
      other = Directory(p.join(temp.root.path, 'other', 'Ellen'))..createSync(recursive: true);
      Link(linkOf('Ellen')).createSync(other.path);
    });

    test('turning the mod off leaves it in place', () async {
      expect(await temp.service.deactivateMod('Ellen'), isFalse);
      expect(Link(linkOf('Ellen')).targetSync(), other.path);
    });

    test('deleting or renaming the mod leaves it in place', () async {
      expect(await temp.service.renameMod('Ellen', 'Ellen Renamed'), isTrue);
      expect(Link(linkOf('Ellen')).targetSync(), other.path);
      expect(FileSystemEntity.isLinkSync(linkOf('Ellen Renamed')), isFalse);

      expect(await temp.service.deleteMod('Ellen Renamed'), isTrue);
      expect(Link(linkOf('Ellen')).targetSync(), other.path);
    });

    test('turning the mod on replaces it with the mod own link', () async {
      expect(await temp.service.activateMod('Ellen'), isTrue);
      expect(Link(linkOf('Ellen')).targetSync(), temp.modFolder('Ellen').path);
      expect(await temp.service.isModActive('Ellen'), isTrue);
    });

    test('turning the mod on, when its link cannot be made, leaves a dead one as it was', () async {
      other.deleteSync();
      // The replace makes its new link under this name first, so a folder there makes it fail.
      Directory(p.join(temp.saveMods.path, replacementLinkName('Ellen'))).createSync();

      expect(await temp.service.activateMod('Ellen'), isFalse);

      expect(Link(linkOf('Ellen')).targetSync(), other.path);
    });
  });

  group('renaming a mod that is on', () {
    late _Capture capture;

    setUp(() async {
      installMod('Ellen');
      expect(await temp.service.activateMod('Ellen'), isTrue);
      capture = _Capture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
    });

    test('replaces a dead link of the new name, and logs where it pointed', () async {
      Link(linkOf('Ellen School')).createSync('/media/unplugged/Ellen School');

      expect(await temp.service.renameMod('Ellen', 'Ellen School'), isTrue);

      expect(Link(linkOf('Ellen School')).targetSync(), temp.modFolder('Ellen School').path);
      expect(await temp.service.isModActive('Ellen School'), isTrue);
      expect(FileSystemEntity.typeSync(linkOf('Ellen'), followLinks: false), FileSystemEntityType.notFound);
      final replaced = capture.records.singleWhere((r) => r.message == 'link replaced');
      expect(replaced.fields['from'], '/media/unplugged/Ellen School');
    });

    test('a folder that cannot be renamed leaves the mod on under its old name', () async {
      await Process.run('chmod', ['555', temp.mods.path]);
      addTearDown(() => Process.run('chmod', ['755', temp.mods.path]));
      try {
        File(p.join(temp.mods.path, '.probe'))
          ..createSync()
          ..deleteSync();
        markTestSkipped('chmod does not stop writes for this user');
        return;
      } on FileSystemException {
        // Read-only, as the test needs.
      }

      await expectLater(
        temp.service.renameMod('Ellen', 'Ellen School'),
        throwsA(isA<RenameFolderFailed>().having((r) => r.mod, 'mod', 'Ellen')),
      );

      expect(temp.modFolder('Ellen').existsSync(), isTrue);
      expect(Link(linkOf('Ellen')).targetSync(), temp.modFolder('Ellen').path);
      expect(await temp.service.isModActive('Ellen'), isTrue);
      expect(FileSystemEntity.typeSync(linkOf('Ellen School'), followLinks: false), FileSystemEntityType.notFound);
      expect(capture.records.where((r) => r.message.startsWith('link ')), isEmpty);
    }, skip: Platform.isWindows ? 'chmod is POSIX-only' : false);

    test('a link that cannot be made under the new name renames the folder back, and the mod stays on', () async {
      Link(linkOf('Ellen School')).createSync('/media/unplugged/Ellen School');
      // The replace makes its new link under this name first, so a folder there makes it fail.
      Directory(p.join(temp.saveMods.path, replacementLinkName('Ellen School'))).createSync();

      await expectLater(
        temp.service.renameMod('Ellen', 'Ellen School'),
        throwsA(isA<RenameLinkFailed>()
            .having((r) => r.mod, 'mod', 'Ellen')
            .having((r) => r.name, 'name', 'Ellen School')
            .having((r) => r.renamed, 'renamed', isFalse)),
      );

      expect(temp.modFolder('Ellen').existsSync(), isTrue);
      expect(temp.modFolder('Ellen School').existsSync(), isFalse);
      expect(await temp.service.isModActive('Ellen'), isTrue);
      expect(Link(linkOf('Ellen School')).targetSync(), '/media/unplugged/Ellen School');
    });

    test('a rename undone records its shader files as placed from the old folder again', () async {
      await temp.service.deactivateMod('Ellen');
      File(p.join(temp.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
      temp.write('Ellen', p.join('ShaderFixes', '1f6ab42231416fdb-vs_replace.txt'), 'bytes');
      expect(await temp.service.activateMod('Ellen'), isTrue);
      Directory(p.join(temp.saveMods.path, replacementLinkName('Ellen School'))).createSync();
      Link(linkOf('Ellen School')).createSync('/media/unplugged/Ellen School');

      await expectLater(temp.service.renameMod('Ellen', 'Ellen School'), throwsA(isA<RenameLinkFailed>()));

      final record = jsonDecode(File(p.join(temp.root.path, 'shader_fixes.json')).readAsStringSync());
      expect((record['sources'] as Map).values, [temp.modFolder('Ellen').path]);
    });

    test('is refused over a live link of the new name into another folder, and changes nothing', () async {
      final other = Directory(p.join(temp.root.path, 'other', 'Ellen School'))..createSync(recursive: true);
      Link(linkOf('Ellen School')).createSync(other.path);

      await expectLater(
        temp.service.renameMod('Ellen', 'Ellen School'),
        throwsA(isA<RenameRefused>().having((r) => r.name, 'name', 'Ellen School')),
      );

      expect(temp.modFolder('Ellen').existsSync(), isTrue);
      expect(temp.modFolder('Ellen School').existsSync(), isFalse);
      expect(Link(linkOf('Ellen')).targetSync(), temp.modFolder('Ellen').path);
      expect(Link(linkOf('Ellen School')).targetSync(), other.path);
      expect(capture.records.where((r) => r.message.startsWith('link ')), isEmpty);
    });

    test('is refused over a folder of the new name in ZZMI\'s Mods folder', () async {
      Directory(linkOf('Ellen School')).createSync();

      await expectLater(temp.service.renameMod('Ellen', 'Ellen School'), throwsA(isA<RenameRefused>()));

      expect(temp.modFolder('Ellen').existsSync(), isTrue);
      expect(Link(linkOf('Ellen')).targetSync(), temp.modFolder('Ellen').path);
    });

    test('a mod that is off is renamed whatever ZZMI\'s Mods folder holds, and the link there stays', () async {
      await temp.service.deactivateMod('Ellen');
      final other = Directory(p.join(temp.root.path, 'other', 'Ellen School'))..createSync(recursive: true);
      Link(linkOf('Ellen School')).createSync(other.path);

      expect(await temp.service.renameMod('Ellen', 'Ellen School'), isTrue);

      expect(Link(linkOf('Ellen School')).targetSync(), other.path);
    });
  });

  group('renaming a mod that is on, with shader files', () {
    const hashA = '1f6ab42231416fdb-vs_replace.txt';
    const hashB = '2b7cc53342527fec-ps_replace.txt';

    void useShaders(TempLibrary library) {
      File(p.join(library.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
      Directory(p.join(library.root.path, 'ShaderFixes')).createSync();
    }

    File shader(TempLibrary library, String name) => File(p.join(library.root.path, 'ShaderFixes', name));

    void installShaderMod(TempLibrary library, String name, String hash) {
      library.createMod(name);
      library.write(name, '$name.ini', '[TextureOverrideBody]\nps-t0 = R\n');
      library.write(name, 'ShaderFixes/$hash', name);
    }

    Map<String, dynamic> sources(TempLibrary library) =>
        jsonDecode(File(p.join(library.root.path, 'shader_fixes.json')).readAsStringSync())['sources'] as Map<String, dynamic>;

    test('left off, with no link and its folder not renamed back, has its shader files taken out', () async {
      final platform = LinkFailsUnder('Ellen School');
      final left = await TempLibrary.create(prefix: 'zzz_left_off_', platform: platform);
      platform.occupying = left.modFolder('Ellen').path;
      useShaders(left);
      installShaderMod(left, 'Ellen', hashA);
      expect(await left.service.activateMod('Ellen'), isTrue);

      await expectLater(
        left.service.renameMod('Ellen', 'Ellen School'),
        throwsA(isA<RenameLinkFailed>().having((r) => r.renamed, 'renamed', isTrue)),
      );

      expect(left.modFolder('Ellen School').existsSync(), isTrue);
      expect(await left.service.isModActive('Ellen School'), isFalse);
      expect(left.config.activeMods, isNot(contains('Ellen School')));
      expect(shader(left, hashA).existsSync(), isFalse);
    });

    test('onto a dead link of another copy takes that copy\'s shader files out, known by its recorded folder', () async {
      useShaders(temp);
      // The other copy, turned on from another library, then its drive unplugged.
      final otherLibrary = p.join(temp.root.path, 'other');
      await temp.config.setPaths(otherLibrary, temp.root.path);
      Directory(otherLibrary).createSync();
      final otherCopy = Directory(p.join(otherLibrary, 'Ellen School'))..createSync();
      File(p.join(otherCopy.path, 'Ellen School.ini')).writeAsStringSync('[TextureOverrideBody]\nps-t0 = R\n');
      File(p.join(otherCopy.path, 'ShaderFixes', hashB))
        ..parent.createSync()
        ..writeAsStringSync('other copy');
      expect(await temp.service.activateMod('Ellen School'), isTrue);
      await temp.config.setPaths(temp.mods.path, temp.root.path);
      otherCopy.renameSync(p.join(temp.root.path, 'unplugged'));
      installShaderMod(temp, 'Ellen', hashA);
      expect(await temp.service.activateMod('Ellen'), isTrue);

      expect(await temp.service.renameMod('Ellen', 'Ellen School'), isTrue);

      expect(await temp.service.isModActive('Ellen School'), isTrue);
      expect(shader(temp, hashB).existsSync(), isFalse);
      expect(shader(temp, hashA).readAsStringSync(), 'Ellen');
    });

    test('undone, moves back only the folders it moved', () async {
      useShaders(temp);
      installShaderMod(temp, 'Ellen', hashA);
      installShaderMod(temp, 'Lucy', hashB);
      expect(await temp.service.activateMod('Ellen'), isTrue);
      expect(await temp.service.activateMod('Lucy'), isTrue);
      // A holder already recorded at the new name's path, which the rename never moved.
      final record = File(p.join(temp.root.path, 'shader_fixes.json'));
      final json = jsonDecode(record.readAsStringSync()) as Map<String, dynamic>;
      final lucy = sources(temp).entries.singleWhere((s) => s.value == temp.modFolder('Lucy').path).key;
      (json['sources'] as Map)[lucy] = temp.modFolder('Ellen School').path;
      record.writeAsStringSync(jsonEncode(json));
      Directory(p.join(temp.saveMods.path, replacementLinkName('Ellen School'))).createSync();
      Link(linkOf('Ellen School')).createSync('/media/unplugged/Ellen School');

      await expectLater(temp.service.renameMod('Ellen', 'Ellen School'), throwsA(isA<RenameLinkFailed>()));

      expect(sources(temp)[lucy], temp.modFolder('Ellen School').path);
      expect(sources(temp).values, contains(temp.modFolder('Ellen').path));
    });
  });

  group('the log', () {
    late _Capture capture;

    setUp(() {
      capture = _Capture();
      Log.install(LogRouter(sinks: [capture]));
      addTearDown(() => Log.install(LogRouter()));
    });

    test('a removed link records where it pointed', () async {
      installMod('Ellen');
      await temp.service.activateMod('Ellen');
      await temp.service.deactivateMod('Ellen');

      final removed = capture.records.singleWhere((r) => r.message == 'link removed');
      expect(removed.fields['target'], temp.modFolder('Ellen').path);
    });

    test('a link replaced by turning a mod on records the target it had', () async {
      installMod('Ellen');
      Link(linkOf('Ellen')).createSync('/media/unplugged/Ellen');
      await temp.service.activateMod('Ellen');

      final replaced = capture.records.singleWhere((r) => r.source == 'fileops');
      expect(replaced.message, 'link replaced');
      expect(replaced.fields['from'], '/media/unplugged/Ellen');
      expect(replaced.fields['target'], temp.modFolder('Ellen').path);
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
