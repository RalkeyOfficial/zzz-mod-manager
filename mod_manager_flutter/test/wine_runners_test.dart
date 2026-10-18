@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/wine_runners.dart';
import 'package:path/path.dart' as p;

/// The Wine and Proton builds Settings offers, found in the folders each tool installs them into.
void main() {
  late Directory home;
  late Directory system;

  setUp(() {
    home = Directory.systemTemp.createTempSync('zzz_runners_home_');
    system = Directory.systemTemp.createTempSync('zzz_runners_system_');
    addTearDown(() {
      home.deleteSync(recursive: true);
      system.deleteSync(recursive: true);
    });
  });

  String file(String root, String relative) {
    final f = File(p.join(root, relative))..createSync(recursive: true);
    return f.path;
  }

  Future<List<WineRunner>> scan() => findWineRunners(home: home.path, systemDirs: [system.path]);

  test('finds Proton and Wine builds where Steam, Heroic, Lutris, Bottles and the system put them', () async {
    final dw = file(home.path, '.local/share/Steam/compatibilitytools.d/dwproton-11.0-5/proton');
    final heroicProton = file(home.path, '.config/heroic/tools/proton/GE-Proton10-34/proton');
    final systemProton = file(system.path, 'proton-cachyos-slr/proton');
    final heroicWine = file(home.path, '.config/heroic/tools/wine/wine-11.11-staging-amd64/bin/wine');
    final lutrisWine = file(home.path, '.local/share/lutris/runners/wine/wine-ge-8-26-x86_64/bin/wine');
    final bottlesWine = file(home.path, '.local/share/bottles/runners/soda-9.0-1/bin/wine');

    final runners = await scan();
    expect([for (final r in runners) (r.name, r.kind, r.source, r.path)], [
      ('dwproton-11.0-5', WineRunnerKind.proton, WineRunnerSource.steam, dw),
      ('GE-Proton10-34', WineRunnerKind.proton, WineRunnerSource.heroic, heroicProton),
      ('proton-cachyos-slr', WineRunnerKind.proton, WineRunnerSource.system, systemProton),
      ('soda-9.0-1', WineRunnerKind.wine, WineRunnerSource.bottles, bottlesWine),
      ('wine-11.11-staging-amd64', WineRunnerKind.wine, WineRunnerSource.heroic, heroicWine),
      ('wine-ge-8-26-x86_64', WineRunnerKind.wine, WineRunnerSource.lutris, lutrisWine),
    ]);
  });

  test("Valve's Proton is found in every Steam library, and games beside it are not", () async {
    final library = Directory.systemTemp.createTempSync('zzz_runners_library_');
    addTearDown(() => library.deleteSync(recursive: true));
    file(home.path, '.local/share/Steam/steamapps/common/Proton 10.0/proton');
    file(home.path, '.local/share/Steam/steamapps/common/SomeGame/proton');
    file(library.path, 'steamapps/common/Proton Hotfix/proton');
    File(p.join(home.path, '.local/share/Steam/steamapps/libraryfolders.vdf')).writeAsStringSync(
      '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"${home.path}/.local/share/Steam"\n\t}\n'
      '\t"1"\n\t{\n\t\t"path"\t\t"${library.path}"\n\t}\n}\n',
    );

    expect([for (final r in await scan()) r.name], ['Proton 10.0', 'Proton Hotfix']);
  });

  test("Flatpak Heroic's Wine builds are found, since they run on the host", () async {
    final wine = file(home.path, '.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/wine/Wine-GE-Proton8-26/bin/wine');

    final runners = await scan();
    expect([for (final r in runners) (r.name, r.kind, r.source, r.path)], [
      ('Wine-GE-Proton8-26', WineRunnerKind.wine, WineRunnerSource.heroic, wine),
    ]);
  });

  test('a build reached through a linked Steam folder is listed once, by the path found first', () async {
    final real = file(home.path, '.local/share/Steam/compatibilitytools.d/GE-Proton8-28/proton');
    Directory(p.join(home.path, '.steam')).createSync();
    Link(p.join(home.path, '.steam/root')).createSync(p.join(home.path, '.local/share/Steam'));

    final runners = await scan();
    expect(runners.single.path, real);
  });

  test('a folder without a proton or bin/wine file is not a build', () async {
    file(home.path, '.local/share/Steam/compatibilitytools.d/broken/README');
    Directory(p.join(home.path, '.config/heroic/tools/wine/empty/bin')).createSync(recursive: true);
    expect(await scan(), isEmpty);
  });

  test('versions sort as numbers, so GE-Proton8 comes before GE-Proton10', () async {
    for (final name in ['GE-Proton10-34', 'GE-Proton7-20', 'GE-Proton8-28']) {
      file(home.path, '.local/share/Steam/compatibilitytools.d/$name/proton');
    }
    expect([for (final r in await scan()) r.name], ['GE-Proton7-20', 'GE-Proton8-28', 'GE-Proton10-34']);
  });

  test('a stored runner the scan did not find is named by its build folder', () {
    expect(WineRunner.nameOf('/opt/proton/My-Proton/proton'), 'My-Proton');
    expect(WineRunner.nameOf('/opt/wine-tkg/bin/wine'), 'wine-tkg');
    // A system binary has no build folder, so it is named by the file.
    expect(WineRunner.nameOf('/usr/bin/wine'), 'wine');
    expect(WineRunner.nameOf('/usr/local/bin/wine-staging'), 'wine-staging');
    expect(WineRunner.nameOf('/bin/wine'), 'wine');
  });

  test('a file named proton is Proton, and any other file is a wine binary', () {
    expect(WineRunner.isProton('/opt/proton/My-Proton/proton'), isTrue);
    expect(WineRunner.isProton('/usr/bin/wine'), isFalse);
    expect(WineRunner.isProton(''), isFalse);
  });
}
