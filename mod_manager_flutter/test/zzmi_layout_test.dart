import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/shader_fixes/zzmi_layout.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('zzz_zzmi_layout_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String dir(String relative) =>
      (Directory(p.join(temp.path, relative))..createSync(recursive: true)).path;

  void ini(String folder, [String contents = '[Rendering]\n']) =>
      File(p.join(folder, 'd3dx.ini')).writeAsStringSync(contents);

  group('resolveZzmiFolder', () {
    test('a folder holding d3dx.ini is the ZZMI folder', () async {
      final zzmi = dir('ZZMI');
      ini(zzmi);
      expect(await resolveZzmiFolder(zzmi), zzmi);
    });

    test("the XXMI Launcher's folder resolves to its ZZMI child", () async {
      final launcher = dir('XXMI Launcher');
      ini(dir('XXMI Launcher/ZZMI'));
      expect(await resolveZzmiFolder(launcher), p.join(launcher, 'ZZMI'));
    });

    test("ZZMI's Mods folder resolves to the ZZMI folder above it", () async {
      final zzmi = dir('ZZMI');
      ini(zzmi);
      expect(await resolveZzmiFolder(dir('ZZMI/Mods')), zzmi);
      expect(await resolveZzmiFolder(dir('ZZMI/mods')), zzmi);
    });

    test('a mods folder with no d3dx.ini above it resolves to nothing', () async {
      expect(await resolveZzmiFolder(dir('Elsewhere/Mods')), isNull);
    });

    test('a folder with neither resolves to nothing', () async {
      expect(await resolveZzmiFolder(dir('Downloads')), isNull);
    });
  });

  group('linksFolderIn', () {
    test('finds an existing mods child in any case', () {
      final zzmi = dir('ZZMI');
      dir('ZZMI/mODs');
      expect(linksFolderIn(zzmi), p.join(zzmi, 'mODs'));
    });

    test('prefers Mods when both spellings exist', () {
      final zzmi = dir('ZZMI');
      dir('ZZMI/mods');
      dir('ZZMI/Mods');
      expect(linksFolderIn(zzmi), p.join(zzmi, 'Mods'));
    });

    test('falls back to Mods when there is no such child', () {
      final zzmi = dir('ZZMI');
      File(p.join(zzmi, 'mods')).writeAsStringSync('a file, not a folder');
      expect(linksFolderIn(zzmi), p.join(zzmi, 'Mods'));
    });

    test('falls back to Mods when the folder is missing', () {
      final missing = p.join(temp.path, 'nowhere');
      expect(linksFolderIn(missing), p.join(missing, 'Mods'));
    });
  });

  group('shaderFolderIn', () {
    test('gives the same folder as findShaderFolder on the links folder', () async {
      final zzmi = dir('ZZMI');
      ini(zzmi, '[Rendering]\noverride_directory = Custom\n');

      final direct = await shaderFolderIn(zzmi);
      expect(direct, p.join(zzmi, 'Custom'));
      expect(await findShaderFolder(p.join(zzmi, 'Mods')), direct);
    });

    test('is null without a d3dx.ini', () async {
      expect(await shaderFolderIn(dir('ZZMI')), isNull);
    });
  });

  group('xxmiLauncherBeside', () {
    test("is the launcher's exe in the folder above ZZMI", () {
      expect(xxmiLauncherBeside('/home/al/XXMI Launcher/ZZMI'), '/home/al/XXMI Launcher/Resources/Bin/XXMI Launcher.exe');
    });

    test('a trailing separator on the ZZMI folder changes nothing', () {
      expect(xxmiLauncherBeside('/home/al/XXMI Launcher/ZZMI/'), '/home/al/XXMI Launcher/Resources/Bin/XXMI Launcher.exe');
    });

    test('a path through a link is kept as written, not normalised', () {
      expect(
        xxmiLauncherBeside('/mnt/Game/XXMI Launcher/../XXMI Launcher/ZZMI'),
        '/mnt/Game/XXMI Launcher/../XXMI Launcher/Resources/Bin/XXMI Launcher.exe',
      );
    });
  });
}
