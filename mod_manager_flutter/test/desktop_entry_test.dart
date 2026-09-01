import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The application id, spelled in five files that must agree.
///
/// A Wayland compositor reads no icon from the window: it matches the surface's
/// app id to `<app id>.desktop` and takes `Icon=` from there. So the id, the
/// desktop entry's **filename** and the installed icon's **filename** are one
/// string, and if any of them drifts the window silently loses its icon and its
/// name in the taskbar. Nothing about that failure shows up at build time, in
/// the analyzer, or anywhere in the app — which is what this test is for.
///
/// See [`docs/desktop-integration.md`](../../docs/desktop-integration.md).
void main() {
  // Tests run from `mod_manager_flutter/`.
  final cmakeLists = File('linux/CMakeLists.txt');
  final packaging = Directory('linux/packaging');
  final pkgbuild = File('../PKGBUILD');
  final workflow = File('../.github/workflows/build-linux.yml');

  /// The one value everything else is checked against.
  String readAppId() {
    final match = RegExp(r'set\(APPLICATION_ID "([^"]+)"\)')
        .firstMatch(cmakeLists.readAsStringSync());
    expect(match, isNotNull,
        reason: 'APPLICATION_ID is missing from ${cmakeLists.path}');
    return match!.group(1)!;
  }

  test('the app id is a real one, not the Flutter placeholder', () {
    final id = readAppId();

    // `com.example.…` is what `flutter create` writes. It matches no desktop
    // entry anyone would install, so a build carrying it cannot have an icon on
    // Wayland however the rest of the packaging is arranged.
    expect(id, isNot(startsWith('com.example.')));
    expect(id.split('.').length, greaterThanOrEqualTo(3),
        reason: 'an application id is reverse-DNS');
  });

  test('the desktop entry is named after the app id', () {
    final id = readAppId();
    final entry = File('${packaging.path}/$id.desktop');

    expect(entry.existsSync(), isTrue,
        reason: 'a Wayland compositor looks up exactly "$id.desktop"');

    // Every `.desktop` in the folder should be that one: a leftover under the
    // old name would install alongside the right one and show up twice in the
    // application menu.
    final entries = packaging
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.desktop'))
        .toList();
    expect(entries, equals(['$id.desktop']));
  });

  test('the entry points its icon and StartupWMClass at the app id', () {
    final id = readAppId();
    final lines = File('${packaging.path}/$id.desktop').readAsLinesSync();

    String? valueOf(String key) {
      final line = lines.firstWhere(
        (l) => l.startsWith('$key='),
        orElse: () => '',
      );
      if (line.length <= key.length) return null;
      return line.substring(key.length + 1).trim();
    }

    // A theme name rather than a path, so the compositor picks the size it
    // wants; it resolves against the icon installed under the same name.
    expect(valueOf('Icon'), id);
    expect(valueOf('StartupWMClass'), id);
  });

  test('the packaging installs it under the app id', () {
    final id = readAppId();

    // The AUR package.
    final pkg = pkgbuild.readAsStringSync();
    expect(pkg, contains("_appid='$id'"),
        reason: 'PKGBUILD installs the entry and the icon as "\$_appid"');

    // The portable tarball, whose installer writes the entry at run time
    // because `Exec=` has to name wherever the user extracted it.
    final installer =
        File('${packaging.path}/install-desktop-entry.sh').readAsStringSync();
    expect(installer, contains("APP_ID='$id'"));

    // And the workflow that puts both of those in the tarball.
    expect(workflow.readAsStringSync(), contains('$id.desktop'));
  });

  test('the window keeps the decoration its desktop draws', () {
    // An undecorated window cannot be resized with the mouse — neither GTK nor
    // the compositor offers an edge to grab — and on Wayland GTK announces
    // client-side decoration only when it draws some, so the compositor adds a
    // title bar of its own above the app's. Both are silent at build time.
    expect(File('lib/main.dart').readAsStringSync(),
        isNot(contains('TitleBarStyle.hidden')));
    expect(File('linux/runner/my_application.cc').readAsStringSync(),
        isNot(contains('gtk_window_set_decorated(window, FALSE)')));
  });
}
