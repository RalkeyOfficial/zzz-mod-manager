import 'dart:io';

import 'package:path/path.dart' as p;

import 'log/logger.dart';

final Logger _log = Logger('platform');

enum WineRunnerKind { proton, wine }

/// Which tool installed a build. `system` is a distro package.
enum WineRunnerSource { steam, heroic, lutris, bottles, system }

/// A Wine or Proton build found on disk, offered in Settings › Wine or Proton. See `docs/launch-game.md`.
class WineRunner {
  const WineRunner({required this.path, required this.name, required this.kind, required this.source});

  /// The `proton` script, or the build's `bin/wine`. This is what `wine_runner` stores.
  final String path;

  /// The build's folder name, which is how Steam, Heroic and Lutris name it too: `dwproton-11.0-5`.
  final String name;

  final WineRunnerKind kind;

  final WineRunnerSource source;

  /// How a stored runner the scan didn't find is named: the build folder above `proton` or `bin/wine`. A system
  /// binary such as `/usr/bin/wine-staging` has no build folder, so it is named by the file itself.
  static String nameOf(String runner) {
    final parent = p.dirname(runner);
    if (p.basename(parent) != 'bin') return p.basename(parent);
    final build = p.dirname(parent);
    return _systemFolders.contains(build) ? p.basename(runner) : p.basename(build);
  }

  static const Set<String> _systemFolders = {'/', '/usr', '/usr/local'};

  /// Whether a stored runner is Proton: a file named `proton`. Any other file is a wine binary.
  static bool isProton(String runner) => p.basename(runner) == 'proton';
}

/// Every Wine and Proton build in the places Steam, Heroic, Lutris and Bottles install them, Proton first, each kind
/// in name order with numbers compared as numbers. A build reached by two paths, such as `~/.steam/root` and
/// `~/.local/share/Steam`, is listed once.
///
/// [systemDirs] holds the folders outside home that system packages install Proton into; a test passes none.
Future<List<WineRunner>> findWineRunners({
  required String home,
  List<String> systemDirs = const ['/usr/share/steam/compatibilitytools.d'],
}) async {
  String inHome(String relative) => p.join(home, relative);

  // Steam's own data folders, native and Flatpak. `~/.steam/root` is usually a link to the first.
  final steamRoots = [
    inHome('.local/share/Steam'),
    inHome('.steam/root'),
    inHome('.steam/steam'),
    inHome('.var/app/com.valvesoftware.Steam/.local/share/Steam'),
  ];
  final protonDirs = <(String, WineRunnerSource)>[
    for (final root in steamRoots) (p.join(root, 'compatibilitytools.d'), WineRunnerSource.steam),
    for (final dir in systemDirs) (dir, WineRunnerSource.system),
    (inHome('.config/heroic/tools/proton'), WineRunnerSource.heroic),
    (inHome('.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/proton'), WineRunnerSource.heroic),
    (inHome('.local/share/lutris/runners/proton'), WineRunnerSource.lutris),
  ];
  // Flatpak Heroic downloads the same release builds as native Heroic, which run on the host. Bottles' Flatpak
  // runners are left out: they rely on libraries the Bottles runtime supplies, so they may not run on a bare host.
  final wineDirs = <(String, WineRunnerSource)>[
    (inHome('.config/heroic/tools/wine'), WineRunnerSource.heroic),
    (inHome('.var/app/com.heroicgameslauncher.hgl/config/heroic/tools/wine'), WineRunnerSource.heroic),
    (inHome('.local/share/lutris/runners/wine'), WineRunnerSource.lutris),
    (inHome('.local/share/bottles/runners'), WineRunnerSource.bottles),
  ];

  final found = <WineRunner>[];
  final seen = <String>{};

  Future<void> add(String file, String name, WineRunnerKind kind, WineRunnerSource source) async {
    try {
      if (!await File(file).exists()) return;
      // Resolved only to spot the same build twice; the path offered is the one found.
      if (!seen.add(await File(file).resolveSymbolicLinks())) return;
      found.add(WineRunner(path: file, name: name, kind: kind, source: source));
    } on FileSystemException {
      return;
    }
  }

  Future<List<Directory>> children(String dir) async {
    try {
      return await Directory(dir).list().where((e) => e is Directory || e is Link).map((e) => Directory(e.path)).toList();
    } on FileSystemException {
      return const [];
    }
  }

  for (final (dir, source) in protonDirs) {
    for (final build in await children(dir)) {
      await add(p.join(build.path, 'proton'), p.basename(build.path), WineRunnerKind.proton, source);
    }
  }
  // Valve's own Proton builds are apps in a Steam library, each library listed in `libraryfolders.vdf`.
  for (final root in steamRoots) {
    for (final library in await _steamLibraries(root)) {
      for (final app in await children(p.join(library, 'steamapps', 'common'))) {
        final name = p.basename(app.path);
        if (name.startsWith('Proton')) {
          await add(p.join(app.path, 'proton'), name, WineRunnerKind.proton, WineRunnerSource.steam);
        }
      }
    }
  }
  for (final (dir, source) in wineDirs) {
    for (final build in await children(dir)) {
      await add(p.join(build.path, 'bin', 'wine'), p.basename(build.path), WineRunnerKind.wine, source);
    }
  }

  found.sort((a, b) => a.kind != b.kind ? a.kind.index - b.kind.index : compareNatural(a.name, b.name));
  _log.debug('wine runners found', fields: {'count': found.length});
  return found;
}

/// The library folders Steam lists in [steamRoot]'s `libraryfolders.vdf`, the root itself included.
Future<List<String>> _steamLibraries(String steamRoot) async {
  final libraries = {steamRoot};
  try {
    final vdf = await File(p.join(steamRoot, 'steamapps', 'libraryfolders.vdf')).readAsString();
    for (final match in RegExp(r'"path"\s+"((?:[^"\\]|\\.)*)"').allMatches(vdf)) {
      libraries.add(match.group(1)!.replaceAll(r'\\', r'\'));
    }
  } on FileSystemException {
    // No Steam here, or no second library.
  }
  return libraries.toList();
}

/// Orders names the way a person reads versions: `GE-Proton8-28` before `GE-Proton10-34`, ignoring case.
int compareNatural(String a, String b) {
  final chunk = RegExp(r'\d+|\D+');
  final left = chunk.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final right = chunk.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final order = x != null && y != null ? x.compareTo(y) : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return left.length - right.length;
}
