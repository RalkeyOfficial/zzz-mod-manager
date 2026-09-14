import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/storage/storage_donut.dart';
import 'package:mod_manager_flutter/screens/storage_screen.dart';
import 'package:mod_manager_flutter/services/storage/storage_providers.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:mod_manager_flutter/services/storage/storage_scanner.dart';
import 'package:mod_manager_flutter/services/storage/storage_usage.dart';
import 'package:path/path.dart' as path;

import '../support/localized_harness.dart';

/// A scanner over a temp directory, so nothing here can reach the developer's
/// own app data — the page reads real paths, and a test that picked up the real
/// roots would report the machine it runs on.
StorageScanner scannerOver(Directory root, {String? library}) {
  Directory make(String name) =>
      Directory(path.join(root.path, name))..createSync(recursive: true);
  return StorageScanner(StorageRoots(
    appData: make('appdata'),
    downloads: make('appdata/downloads'),
    logs: make('appdata/logs'),
    legacyImages: Directory(path.join(root.path, 'appdata', 'mod_images')),
    backups: Directory(path.join(root.path, 'appdata', 'backups')),
    temp: make('temp'),
    modsLibrary: library == null ? null : Directory(library),
  ));
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_screen_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String relative, int bytes) {
    final file = File(path.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
  }

  List<Override> overridesFor(StorageScanner scanner) => [
        storageScannerProvider.overrideWithValue(scanner),
      ];

  /// A container whose categories have already been measured.
  ///
  /// The library walk runs in an isolate, which is **real** async I/O —
  /// `pumpAndSettle` returns long before it lands, so a test that only pumps
  /// asserts against a page that is still empty and passes vacuously. Only
  /// `runAsync` turns the real event loop.
  Future<ProviderContainer> warmed(
    WidgetTester tester,
    StorageScanner scanner,
  ) async {
    final container = ProviderContainer(overrides: overridesFor(scanner));
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      for (final id in StorageCategoryId.values) {
        await container.read(storageCategoryProvider(id).future);
      }
    });
    return container;
  }

  testWidgets('every category is named, measured or not', (tester) async {
    await pumpLocalized(
      tester,
      const StorageScreen(),
      overrides: overridesFor(scannerOver(root)),
    );
    await tester.pumpAndSettle();

    expectBuilt(StorageScreen);
    for (final label in [
      'Mods',
      'Saved versions',
      'Downloads',
      'Covers & metadata',
      'Logs',
      'Leftovers',
    ]) {
      expect(find.text(label), findsWidgets, reason: '$label has no row');
    }
    expect(find.byType(StorageDonut), findsOneWidget);
  });

  testWidgets('every category says what it holds, not just its name',
      (tester) async {
    await pumpLocalized(
      tester,
      const StorageScreen(),
      overrides: overridesFor(scannerOver(root)),
    );
    await tester.pumpAndSettle();

    // A bare "Leftovers" or "Covers & metadata" names nothing the reader can
    // act on. Each label carries a one-line explanation, and this test exists
    // because those lines were written and then rendered nowhere.
    expect(
      find.text(
          'Unpacked copies left behind by installing mods, and cover images from older versions. Nothing needs these.'),
      findsOneWidget,
    );
    expect(
      find.text('What each mod looked like before an update.'),
      findsOneWidget,
    );
    expect(
      find.text('Screenshots, descriptions and the files a patch replaced.'),
      findsOneWidget,
    );
  });

  testWidgets('a leftover names what it is, not its folder name',
      (tester) async {
    Directory(path.join(root.path, 'temp', 'zzz_archive_extract_7f3a'))
        .createSync(recursive: true);
    write('temp/zzz_archive_extract_7f3a/body.ini', 500);

    // Measuring an extraction folder walks it in an isolate, which is real
    // async I/O that `pumpAndSettle` returns long before.
    final container = await warmed(tester, scannerOver(root));
    await pumpLocalized(tester, const StorageScreen(), container: container);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Leftovers'));
    await tester.pumpAndSettle();

    expect(
      find.text('Unpacked copy left behind by an install'),
      findsOneWidget,
      reason: 'zzz_archive_extract_7f3a tells the reader nothing',
    );
  });

  testWidgets('a library with no folder set says so, never 0 B',
      (tester) async {
    await pumpLocalized(
      tester,
      const StorageScreen(),
      overrides: overridesFor(scannerOver(root)),
    );
    await tester.pumpAndSettle();

    // "0 B" beside Mods reads as "your mods are gone", which is a different
    // and much more alarming statement than "you haven't chosen a folder".
    // Both library-derived categories say it: the mods and their sidecars.
    expect(find.text('No folder set'), findsNWidgets(2));
    expect(find.text('0 B'), findsWidgets,
        reason: 'the stores that really are empty still report a real zero');
  });

  testWidgets('a measured library shows its size and drills down',
      (tester) async {
    final library = Directory(path.join(root.path, 'mods'))
      ..createSync(recursive: true);
    write('mods/Ellen/body.ini', 2048);
    write('mods/Nicole/body.ini', 1024);

    final container =
        await warmed(tester, scannerOver(root, library: library.path));
    await pumpLocalized(tester, const StorageScreen(), container: container);
    await tester.pumpAndSettle();

    expect(find.text('3.0 KB'), findsWidgets);

    await tester.tap(find.text('Mods').first);
    await tester.pumpAndSettle();

    expect(find.text('Ellen'), findsOneWidget);
    expect(find.text('Nicole'), findsOneWidget);
  });

  testWidgets('the page holds together at a narrow window', (tester) async {
    final library = Directory(path.join(root.path, 'mods'))
      ..createSync(recursive: true);
    write('mods/Ellen/body.ini', 2048);

    await pumpLocalized(
      tester,
      const StorageScreen(),
      overrides: overridesFor(scannerOver(root, library: library.path)),
      surfaceSize: const Size(480, 800),
    );
    await tester.pumpAndSettle();

    expectBuilt(StorageScreen);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a category with nothing in it still has a row', (tester) async {
    await pumpLocalized(
      tester,
      const StorageScreen(),
      overrides: overridesFor(scannerOver(root)),
    );
    await tester.pumpAndSettle();

    // Downloads is genuinely empty rather than unreadable, so it reports a
    // real zero — the opposite of the library case above.
    expect(find.text('0 B'), findsWidgets);
  });

  group('the donut', () {
    testWidgets('draws nothing rather than dividing by zero when empty',
        (tester) async {
      await pumpLocalized(
        tester,
        const StorageDonut(
          slices: [
            DonutSlice(
              id: StorageCategoryId.mods,
              bytes: 0,
              color: Color(0xFF0EA5E9),
            ),
          ],
          centerLabel: '0 B',
          centerCaption: 'Stored by this app',
        ),
      );

      expectBuilt(StorageDonut);
      expect(tester.takeException(), isNull);
    });
  });
}
