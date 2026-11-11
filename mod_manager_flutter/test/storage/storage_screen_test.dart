import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/button_working.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/screens/components/settings/storage_section.dart';
import 'package:mod_manager_flutter/screens/components/storage/reclaim_actions.dart';
import 'package:mod_manager_flutter/screens/components/storage/saved_versions_detail.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/log/log_rotation.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_plan.dart';
import 'package:mod_manager_flutter/services/storage/reclaim_service.dart';
import 'package:mod_manager_flutter/services/storage/storage_providers.dart';
import 'package:mod_manager_flutter/services/storage/storage_roots.dart';
import 'package:mod_manager_flutter/services/storage/storage_scanner.dart';
import 'package:mod_manager_flutter/services/storage/storage_usage.dart';
import 'package:mod_manager_flutter/utils/process_probe.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as path;

import '../support/all_mods_harness.dart';
import '../support/library_override.dart';
import '../support/localized_harness.dart';

/// A platform that answers only how much space is free, by path.
class _FakePlatform implements PlatformService {
  _FakePlatform(this.free);

  final int? Function(String path) free;

  @override
  Future<int?> freeSpaceBytes(String forPath, {ProcessProbe? probe}) async => free(forPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SeededQueue extends DownloadQueue {
  _SeededQueue(this._seed);

  final List<DownloadJob> _seed;

  @override
  List<DownloadJob> build() {
    super.build();
    return _seed;
  }
}

/// A scanner that counts how often each category is read.
class _CountingScanner extends StorageScanner {
  _CountingScanner(super.roots, {super.snapshots});

  final Map<StorageCategoryId, int> reads = {for (final id in StorageCategoryId.values) id: 0};

  Future<StorageCategory> _count(StorageCategoryId id, Future<StorageCategory> Function() read) {
    reads[id] = reads[id]! + 1;
    return read();
  }

  @override
  Future<StorageCategory> mods() => _count(StorageCategoryId.mods, super.mods);

  @override
  Future<StorageCategory> sidecars() => _count(StorageCategoryId.sidecars, super.sidecars);

  @override
  Future<StorageCategory> savedVersions() => _count(StorageCategoryId.savedVersions, super.savedVersions);

  @override
  Future<StorageCategory> downloads() => _count(StorageCategoryId.downloads, super.downloads);

  @override
  Future<StorageCategory> logs() => _count(StorageCategoryId.logs, super.logs);

  @override
  Future<StorageCategory> leftovers() => _count(StorageCategoryId.leftovers, super.leftovers);
}

/// A sweep that stays running until [release] completes, as one over a large downloads folder does.
class _HeldReclaim extends ReclaimController {
  _HeldReclaim(this.release);

  final Completer<void> release;

  @override
  Future<ReclaimOutcome?> run(Set<ReclaimTarget> targets) async {
    state = const AsyncValue<ReclaimOutcome?>.loading();
    await release.future;
    state = const AsyncValue<ReclaimOutcome?>.data(ReclaimOutcome.nothing);
    return ReclaimOutcome.nothing;
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('storage_section_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Roots entirely inside the test's directory: the section reads real paths, and a test that picked up the real ones would report the machine it runs on.
  StorageRoots rootsOver({String? library}) {
    Directory make(String name) => Directory(path.join(root.path, name))..createSync(recursive: true);
    return StorageRoots(
      appData: make('appdata'),
      downloads: make('appdata/downloads'),
      logs: make('appdata/logs'),
      legacyImages: Directory(path.join(root.path, 'appdata', 'mod_images')),
      backups: Directory(path.join(root.path, 'appdata', 'backups')),
      temp: make('temp'),
      modsLibrary: library == null ? null : Directory(library),
    );
  }

  StorageScanner scannerOver(StorageRoots roots, {PlatformService? platform}) => StorageScanner(
        roots,
        snapshots: SnapshotService(rootPath: roots.backups.path),
        platform: platform,
      );

  _CountingScanner countingScannerOver(StorageRoots roots) =>
      _CountingScanner(roots, snapshots: SnapshotService(rootPath: roots.backups.path));

  void write(String relative, int bytes, {Duration? age}) {
    final file = File(path.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    if (age != null) file.setLastModifiedSync(DateTime.now().subtract(age));
  }

  ModInfo mod(String id, {String name = '', String character = 'ellen', String? uid}) => ModInfo(
        id: id,
        name: name.isEmpty ? id : name,
        characterId: character,
        isActive: false,
        uid: uid,
      );

  /// A library with two mods of known size, and one of every store the actions reach.
  String stockedLibrary() {
    final library = Directory(path.join(root.path, 'mods'))..createSync(recursive: true);
    write('mods/Ellen/body.ini', 2048);
    write('mods/Nicole/body.ini', 1024);
    write('mods/Nicole/${AppConstants.modMetadataDirName}/mod.json', 100);
    write('appdata/downloads/mod.rar', 500);
    write('appdata/downloads/other.rar.part', 200);
    write('appdata/logs/${logFileName(DateTime(2026, 1, 1))}', 10);
    write('appdata/mod_images/Gone.png', 300);
    return library.path;
  }

  /// Takes a snapshot of a folder under [uid], so the Saved versions category has a group.
  Future<void> snapshotOf(WidgetTester tester, StorageRoots roots, String folder, String uid, String name) async {
    await tester.runAsync(() async {
      await SnapshotService(rootPath: roots.backups.path).take(
        modName: name,
        modUid: uid,
        modFolder: Directory(path.join(root.path, folder)),
        reason: SnapshotReason.beforeUpdate,
      );
    });
  }

  ReclaimOutcome outcome({
    int freed = 0,
    int removed = 0,
    int? delta,
    ReclaimSkipReason? refusal,
    ReclaimTarget target = ReclaimTarget.completedArchives,
  }) =>
      ReclaimOutcome(
        freeSpaceDelta: delta,
        targets: [
          ReclaimTargetResult(
            target: target,
            freedBytes: freed,
            removedCount: removed,
            skippedCount: refusal == null ? 0 : 1,
            refusal: refusal,
          ),
        ],
      );

  /// The section as the Settings page holds it: in a scroll view of unbounded height, at most 860 wide.
  Widget sectionPage({ReclaimRunner? runner, StorageFolderOpener? opener, DateTime Function()? now}) {
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: StorageSection(reclaim: runner, openFolder: opener, now: now ?? DateTime.now),
          ),
        ),
      ),
    );
  }

  /// Mounts the section as the Settings page does.
  Future<ProviderContainer> mount(
    WidgetTester tester,
    StorageScanner scanner, {
    List<ModInfo> mods = const [],
    ReclaimRunner? runner,
    StorageFolderOpener? opener,
    DateTime Function()? now,
    Size size = const Size(1200, 900),
    List<Override> overrides = const [],
    bool warm = true,
    Brightness brightness = Brightness.dark,
  }) async {
    final container = ProviderContainer(overrides: [
      storageScannerProvider.overrideWithValue(scanner),
      libraryOf(mods),
      ...overrides,
    ]);
    addTearDown(container.dispose);
    // The library walk runs in an isolate, which is **real** async I/O: `pumpAndSettle` returns long before it lands,
    // so a test that only pumps asserts against a page that is still empty and passes vacuously.
    if (warm) {
      await tester.runAsync(() async {
        for (final id in StorageCategoryId.values) {
          await container.read(storageCategoryProvider(id).future);
        }
        await container.read(storageFreeSpaceProvider.future);
      });
    }
    await pumpLocalized(
      tester,
      sectionPage(runner: runner, opener: opener, now: now),
      container: container,
      surfaceSize: size,
      brightness: brightness,
    );
    expectBuilt(StorageSection);
    return container;
  }

  Finder row(StorageCategoryId id) => find.byKey(ValueKey('row_${id.name}'));
  Finder inRow(StorageCategoryId id, Finder what) => find.descendant(of: row(id), matching: what);
  Finder segment(StorageCategoryId id) => find.byKey(ValueKey('meter_${id.name}'));
  Finder dialogButton(String label) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, label));

  double opacityOf(WidgetTester tester, StorageCategoryId id) =>
      tester.widget<AnimatedOpacity>(find.descendant(of: segment(id), matching: find.byType(AnimatedOpacity))).opacity;

  /// Presses a confirmation whose sweep walks real folders and asks the real controller, then waits for it to land.
  ///
  /// The sweep's own I/O is on the real event loop, which only `runAsync` turns, and what it awaits from the provider container resolves on the fake clock, which only a pump turns: so the two are taken in turns.
  /// Not `tapWithIo`, whose settling would run the working spinner, which turns until the sweep ends and so never settles.
  Future<void> confirmAndWait(WidgetTester tester, Finder button) async {
    final container = ProviderScope.containerOf(tester.element(find.byType(StorageSection)), listen: false);
    await tester.runAsync(() => tester.tap(button));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
      if (i >= 2 && !container.read(reclaimControllerProvider).isLoading) break;
    }
    // The working state is held for half a second once shown.
    for (var i = 0; i < 20 && find.byType(ZenithSpinner).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(target));
    await tester.pumpAndSettle();
    return gesture;
  }

  group('the hero and the meter', () {
    testWidgets('the total, what is free, and when it was measured', (tester) async {
      final library = stockedLibrary();
      final roots = rootsOver(library: library);
      await mount(
        tester,
        scannerOver(roots, platform: _FakePlatform((_) => 212 * 1024 * 1024 * 1024)),
        mods: [mod('Ellen'), mod('Nicole')],
      );

      expect(find.text('Storage used by the manager'.toUpperCase()), findsOneWidget);
      // 2048 + 1024 mods, 100 sidecar, 700 downloads, 10 logs, 300 leftovers.
      expect(find.text('4.1 KB'), findsOneWidget);
      expect(find.text('212 GB free'), findsOneWidget);
      expect(find.text('Measured just now'), findsOneWidget);
      expect(find.text('Only counts what the manager stores. ZZMI itself and the game are not included.'), findsOneWidget);
    });

    testWidgets('two disks are two lines, each named by what it holds', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots, platform: _FakePlatform((p) => p.endsWith('mods') ? 900 * 1024 : 500 * 1024 * 1024)),
        mods: [mod('Ellen'), mod('Nicole')],
      );

      expect(find.text('App data · 500 MB free'), findsOneWidget);
      expect(find.text('Mods library · 900 KB free'), findsOneWidget);
    });

    testWidgets('a segment for each category that has bytes, and none for one that has none', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      for (final id in [
        StorageCategoryId.mods,
        StorageCategoryId.sidecars,
        StorageCategoryId.downloads,
        StorageCategoryId.logs,
        StorageCategoryId.leftovers,
      ]) {
        expect(segment(id), findsOneWidget, reason: '${id.name} has bytes');
      }
      expect(segment(StorageCategoryId.savedVersions), findsNothing, reason: 'no saved versions yet');
    });

    testWidgets('under the pointer a segment says what it is and dims the others', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);
      expect(find.textContaining('of the total'), findsNothing);

      await hover(tester, segment(StorageCategoryId.mods));

      expect(find.textContaining('of the total'), findsOneWidget);
      expect(find.textContaining('3.0 KB'), findsWidgets);
      expect(opacityOf(tester, StorageCategoryId.mods), 1);
      expect(opacityOf(tester, StorageCategoryId.downloads), closeTo(0.3, 0.001));
    });

    testWidgets('the pointer leaving puts it all back', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      final gesture = await hover(tester, segment(StorageCategoryId.mods));
      await gesture.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();

      expect(find.textContaining('of the total'), findsNothing);
      expect(opacityOf(tester, StorageCategoryId.downloads), 1);
    });

    testWidgets('keyboard focus on a segment shows the same tooltip', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      for (var i = 0; i < 12 && find.textContaining('of the total').evaluate().isEmpty; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }

      expect(find.textContaining('of the total'), findsOneWidget);
    });

    testWidgets('pointing at a row dims the meter the same way', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      await hover(tester, row(StorageCategoryId.downloads));

      expect(opacityOf(tester, StorageCategoryId.downloads), 1);
      expect(opacityOf(tester, StorageCategoryId.mods), closeTo(0.3, 0.001));
    });
  });

  group('the rows', () {
    testWidgets('every category is named and says what it holds, measured or not', (tester) async {
      await mount(tester, scannerOver(rootsOver()), warm: false);

      for (final label in ['Installed mods', 'Saved versions', 'Leftovers', 'Downloads', 'Covers & metadata', 'Logs']) {
        expect(find.text(label), findsWidgets, reason: '$label has no row');
      }
      expect(
        find.text('Unpacked copies from past installs and covers from older versions. Nothing uses them.'),
        findsOneWidget,
      );
      expect(find.text('What each mod looked like before an update.'), findsOneWidget);
    });

    testWidgets('what each category holds is counted', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      expect(find.text('2 mods in your library'), findsOneWidget);
      expect(find.text('1 archive waiting to install, 1 partly downloaded'), findsOneWidget);
      // The launch rotation's count, as About says it; Clear takes the rest.
      expect(find.text('The last 7 runs are kept'), findsOneWidget);
      expect(find.textContaining('14 days'), findsNothing);
    });

    testWidgets('a library with no folder set says so, never 0 B', (tester) async {
      await mount(tester, scannerOver(rootsOver()));

      // "0 B" beside Installed mods reads as "your mods are gone", which is a different and much more alarming statement than "you haven't chosen a folder".
      // Both library-derived categories say it.
      expect(find.text('No folder set'), findsNWidgets(2));
      expect(inRow(StorageCategoryId.mods, find.text('0 B')), findsNothing);
      expect(inRow(StorageCategoryId.downloads, find.text('0 B')), findsOneWidget);
    });

    testWidgets('each row carries its size and its share', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      expect(inRow(StorageCategoryId.mods, find.text('3.0 KB')), findsOneWidget);
      expect(inRow(StorageCategoryId.mods, find.text('73%')), findsOneWidget);
      expect(inRow(StorageCategoryId.logs, find.text('<1%')), findsOneWidget);
    });

    testWidgets('Covers & metadata has no Clear: its folder can only be opened', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      // The sidecar holds a mod's origin tracking and the user's own covers, which cannot be fetched again.
      expect(inRow(StorageCategoryId.sidecars, find.byType(OutlinedButton)), findsNothing);
      expect(inRow(StorageCategoryId.sidecars, find.byType(FilledButton)), findsNothing);
      expect(inRow(StorageCategoryId.sidecars, find.byType(IconButton)), findsOneWidget);
      expect(inRow(StorageCategoryId.sidecars, find.textContaining('never cleared here')), findsOneWidget);
    });

    testWidgets('Installed mods has only the open-folder icon, and nothing offers to move the library', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      expect(inRow(StorageCategoryId.mods, find.byType(IconButton)), findsOneWidget);
      expect(inRow(StorageCategoryId.mods, find.byType(OutlinedButton)), findsNothing);
      expect(find.textContaining('Move library'), findsNothing);
    });

    testWidgets('the folder icon opens that category\'s folder', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final opened = <String>[];
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        opener: (folder) async {
          opened.add(folder);
          return true;
        },
      );

      await tester.tap(inRow(StorageCategoryId.downloads, find.byType(IconButton)));
      await tester.pumpAndSettle();
      await tester.tap(inRow(StorageCategoryId.mods, find.byType(IconButton)));
      await tester.pumpAndSettle();

      expect(opened, [roots.downloads.path, roots.modsLibrary!.path]);
    });

    testWidgets('the Covers & metadata icon opens the library, and its tooltip says so', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final opened = <String>[];
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        opener: (folder) async {
          opened.add(folder);
          return true;
        },
      );

      String? tooltip(StorageCategoryId id) => tester.widget<IconButton>(inRow(id, find.byType(IconButton))).tooltip;

      expect(tooltip(StorageCategoryId.sidecars), 'Open the library folder, where each mod keeps its covers and metadata');
      expect(tooltip(StorageCategoryId.mods), 'Open Installed mods folder');
      await tester.tap(inRow(StorageCategoryId.sidecars, find.byType(IconButton)));
      await tester.pumpAndSettle();
      expect(opened, [roots.modsLibrary!.path]);
    });

    testWidgets('a folder that cannot be opened says so', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], opener: (_) async => false);

      await tester.tap(inRow(StorageCategoryId.logs, find.byType(IconButton)));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the folder"), findsOneWidget);
    });
  });

  group('the actions', () {
    /// The four buttons, the confirmation each opens and the stores it may take from.
    final actions = <(String, Finder Function(), String, String, Set<ReclaimTarget>)>[
      (
        'Clean up',
        () => inRow(StorageCategoryId.leftovers, find.widgetWithText(FilledButton, 'Clean up')),
        'Clean up leftovers?',
        'Clean up',
        {ReclaimTarget.legacyImages, ReclaimTarget.tempExtracts},
      ),
      (
        'Downloads Clear',
        () => inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')),
        'Clear downloads?',
        'Clear downloads',
        {ReclaimTarget.completedArchives, ReclaimTarget.abandonedPartials},
      ),
      (
        'Logs Clear',
        () => inRow(StorageCategoryId.logs, find.widgetWithText(OutlinedButton, 'Clear')),
        'Clear old logs?',
        'Clear logs',
        {ReclaimTarget.oldLogs},
      ),
    ];

    for (final (name, button, title, confirm, targets) in actions) {
      testWidgets('$name asks first, and cancelling runs nothing', (tester) async {
        final roots = rootsOver(library: stockedLibrary());
        var ran = false;
        await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], runner: (_) async {
          ran = true;
          return outcome();
        });

        await tester.tap(button());
        await tester.pumpAndSettle();

        expect(find.text(title), findsOneWidget);
        expect(ran, isFalse, reason: 'nothing runs before the answer');

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(ran, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('$name runs over exactly its own stores', (tester) async {
        final roots = rootsOver(library: stockedLibrary());
        Set<ReclaimTarget>? asked;
        await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], runner: (t) async {
          asked = t;
          return outcome(freed: 2048, removed: 3);
        });

        await tester.tap(button());
        await tester.pumpAndSettle();
        await tester.tap(dialogButton(confirm));
        await tester.pumpAndSettle();

        expect(asked, targets);
        expect(find.text('Freed 2.0 KB'), findsOneWidget);
        expect(find.text('Removed 3 items.'), findsOneWidget);
      });
    }

    testWidgets('the confirmations say what goes, and promise no figure', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], runner: (_) async => outcome());

      await tester.tap(inRow(StorageCategoryId.logs, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();

      expect(find.text("This deletes every log file except this run's."), findsOneWidget);
      expect(find.textContaining('Free'), findsNothing);
    });

    testWidgets('one item removed is not "1 items"', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        runner: (_) async => outcome(freed: 100, removed: 1),
      );

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pumpAndSettle();

      expect(find.text('Removed 1 item.'), findsOneWidget);
    });

    testWidgets('the space the volume gave back is the figure, not the sum of file lengths', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        runner: (_) async => outcome(freed: 4096, removed: 1, delta: 1024),
      );

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pumpAndSettle();

      expect(find.text('Freed 1.0 KB'), findsOneWidget);
    });

    testWidgets('says so when there was nothing to take', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], runner: (_) async => outcome());

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing to free up'), findsOneWidget);
      expect(find.text('There was no leftover data to remove.'), findsOneWidget);
    });

    // Each refusal is worded for the stores of the pressed button, and stands in for "nothing to remove".
    final leftoversButton = (
      StorageCategoryId.leftovers,
      () => inRow(StorageCategoryId.leftovers, find.widgetWithText(FilledButton, 'Clean up')),
      'Clean up',
    );
    final downloadsButton = (
      StorageCategoryId.downloads,
      () => inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')),
      'Clear downloads',
    );
    for (final (reason, target, button, text) in [
      (
        ReclaimSkipReason.downloadsActive,
        ReclaimTarget.completedArchives,
        downloadsButton,
        'Left your downloads alone — a transfer is in progress.',
      ),
      (
        ReclaimSkipReason.installInProgress,
        ReclaimTarget.completedArchives,
        downloadsButton,
        'Left your downloads alone — an install is in progress.',
      ),
      (
        ReclaimSkipReason.installInProgress,
        ReclaimTarget.tempExtracts,
        leftoversButton,
        'Left the unpacked files alone — an install is in progress.',
      ),
      (
        ReclaimSkipReason.downloadWaiting,
        ReclaimTarget.tempExtracts,
        leftoversButton,
        'Left the unpacked files alone — a download is waiting for your answer in Downloads.',
      ),
      (
        ReclaimSkipReason.libraryUnreadable,
        ReclaimTarget.legacyImages,
        leftoversButton,
        'Left the old images alone — your mods folder could not be read.',
      ),
      (
        ReclaimSkipReason.libraryHasDeadLink,
        ReclaimTarget.legacyImages,
        leftoversButton,
        'Left the old images alone — a mod in your library is linked to a folder that is missing.',
      ),
    ]) {
      testWidgets('names what it left alone: ${reason.name} on ${target.name}', (tester) async {
        final roots = rootsOver(library: stockedLibrary());
        await mount(
          tester,
          scannerOver(roots),
          mods: [mod('Ellen'), mod('Nicole')],
          runner: (_) async => outcome(refusal: reason, target: target),
        );

        final (_, finder, confirm) = button;
        await tester.tap(finder());
        await tester.pumpAndSettle();
        await tester.tap(dialogButton(confirm));
        await tester.pumpAndSettle();

        expect(find.text(text), findsOneWidget);
        expect(find.textContaining('Left the saved versions'), findsNothing, reason: 'not a store of this button');
        expect(find.text('There was no leftover data to remove.'), findsNothing, reason: 'the refusal is the reason');
      });
    }

    testWidgets('a refused Saved versions clear names the saved versions, and only them', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await snapshotOf(tester, roots, 'mods/Nicole', 'u-gone', 'Deleted mod');
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        runner: (_) async => outcome(refusal: ReclaimSkipReason.libraryUnreadable, target: ReclaimTarget.unclaimedSnapshots),
      );
      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear versions of mods you no longer have'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear versions'));
      await tester.pumpAndSettle();

      expect(find.text('Left the saved versions alone — your mods folder could not be read.'), findsOneWidget);
      expect(find.textContaining('old images'), findsNothing);
    });

    testWidgets('a result and a refusal come in one card', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        runner: (_) async => outcome(freed: 100, removed: 1, refusal: ReclaimSkipReason.downloadsActive),
      );

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pumpAndSettle();

      expect(find.text('Freed 100 B'), findsOneWidget);
      expect(find.textContaining('Left your downloads alone'), findsOneWidget);
    });

    testWidgets('a button that waits shows the spinner, and the others stand still', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final finish = Completer<ReclaimOutcome?>();
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], runner: (_) => finish.future);

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pump(WorkingAction.showAfter + const Duration(milliseconds: 50));
      await tester.pump();

      expect(inRow(StorageCategoryId.downloads, find.byType(ZenithSpinner)), findsOneWidget);
      final logs = tester.widget<OutlinedButton>(inRow(StorageCategoryId.logs, find.byType(OutlinedButton)));
      expect(logs.onPressed, isNull, reason: 'a second sweep would plan against what the first is removing');
      final clean = tester.widget<FilledButton>(inRow(StorageCategoryId.leftovers, find.byType(FilledButton)));
      expect(clean.onPressed, isNull);

      finish.complete(outcome(freed: 10, removed: 1));
      await tester.pumpAndSettle();

      expect(find.byType(ZenithSpinner), findsNothing);
      expect(
        tester.widget<OutlinedButton>(inRow(StorageCategoryId.logs, find.byType(OutlinedButton))).onPressed,
        isNotNull,
      );
    });

    testWidgets('leaving mid-sweep and coming back keeps the other buttons still', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final release = Completer<void>();
      final container = await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        overrides: [reclaimControllerProvider.overrideWith(() => _HeldReclaim(release))],
      );
      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pump();
      expect(container.read(reclaimControllerProvider).isLoading, isTrue);

      await pumpLocalized(tester, const SizedBox.shrink(), container: container);
      expect(find.byType(StorageSection), findsNothing);
      await pumpLocalized(tester, sectionPage(), container: container);

      bool enabled(Finder button) => switch (tester.widget(button)) {
            OutlinedButton(:final onPressed) => onPressed != null,
            FilledButton(:final onPressed) => onPressed != null,
            _ => throw StateError('not a button'),
          };
      final buttons = [
        inRow(StorageCategoryId.leftovers, find.byType(FilledButton)),
        inRow(StorageCategoryId.downloads, find.byType(OutlinedButton)),
        inRow(StorageCategoryId.logs, find.byType(OutlinedButton)),
      ];
      expect(buttons.map(enabled), everyElement(isFalse), reason: 'the sweep outlives the section that started it');

      release.complete();
      await tester.pumpAndSettle();

      expect(buttons.map(enabled), everyElement(isTrue));
    });

    testWidgets('a category with nothing in it has nothing to clear', (tester) async {
      await mount(tester, scannerOver(rootsOver()));

      expect(
        tester.widget<OutlinedButton>(inRow(StorageCategoryId.downloads, find.byType(OutlinedButton))).onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(inRow(StorageCategoryId.leftovers, find.byType(FilledButton))).onPressed,
        isNull,
      );
    });

    testWidgets('a failure of the sweep is reported, not swallowed', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        runner: (_) async => throw StateError('disk went away'),
      );

      await tester.tap(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Clear downloads'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't free the space"), findsOneWidget);
    });
  });

  group('the real sweep, behind the buttons', () {
    DownloadJob job(DownloadJobState state) => DownloadJob(
          seq: 1,
          request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/1')),
          intent: DownloadIntent.install,
          subject: 'Ellen Swimsuit',
          file: const GbFile(idRow: 1),
          mod: const GbMod(idRow: 1001, name: 'Ellen Swimsuit'),
          state: state,
        );

    Future<void> clearDownloads(WidgetTester tester, StorageRoots roots, List<DownloadJob> queue) async {
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        overrides: [
          storageRootsProvider.overrideWithValue(roots),
          downloadQueueProvider.overrideWith(() => _SeededQueue(queue)),
        ],
      );
      await tapWithIo(tester, inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      await confirmAndWait(tester, dialogButton('Clear downloads'));
    }

    testWidgets('a transfer in progress refuses Downloads, and says so', (tester) async {
      final roots = rootsOver(library: stockedLibrary());

      await clearDownloads(tester, roots, [job(DownloadJobState.installing)]);

      expect(File(path.join(roots.downloads.path, 'mod.rar')).existsSync(), isTrue);
      expect(find.textContaining('Left your downloads alone'), findsOneWidget);
    });

    testWidgets('an idle queue lets the archive go', (tester) async {
      final roots = rootsOver(library: stockedLibrary());

      await clearDownloads(tester, roots, const []);

      expect(File(path.join(roots.downloads.path, 'mod.rar')).existsSync(), isFalse);
      expect(find.textContaining('Freed'), findsOneWidget);
    });

    testWidgets('a download waiting for an answer refuses the unpacked folders, however old', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      write('temp/zzz_archive_extract_x/body.ini', 100, age: const Duration(hours: 6));
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        overrides: [
          storageRootsProvider.overrideWithValue(roots),
          downloadQueueProvider.overrideWith(() => _SeededQueue([job(DownloadJobState.waiting)])),
        ],
      );

      await tapWithIo(tester, inRow(StorageCategoryId.leftovers, find.widgetWithText(FilledButton, 'Clean up')));
      await confirmAndWait(tester, dialogButton('Clean up'));

      expect(File(path.join(root.path, 'temp', 'zzz_archive_extract_x', 'body.ini')).existsSync(), isTrue);
      expect(find.textContaining('a download is waiting for your answer'), findsOneWidget);
    });

    testWidgets('an unreadable library refuses the old images, and the sweep leaves them', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        overrides: [
          storageRootsProvider.overrideWithValue(roots),
          libraryFailing(StateError('unreadable')),
        ],
      );

      await tapWithIo(tester, inRow(StorageCategoryId.leftovers, find.widgetWithText(FilledButton, 'Clean up')));
      await confirmAndWait(tester, dialogButton('Clean up'));

      expect(File(path.join(roots.legacyImages.path, 'Gone.png')).existsSync(), isTrue);
      expect(find.textContaining('your mods folder could not be read'), findsOneWidget);
    });

    testWidgets('Logs never takes this run\'s file', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      for (var i = 1; i <= 10; i++) {
        write('appdata/logs/${logFileName(DateTime(2026, 2, i))}', 10);
      }
      final current = logFileName(DateTime(2026, 2, 1));
      final withCurrent = StorageRoots(
        appData: roots.appData,
        downloads: roots.downloads,
        logs: roots.logs,
        legacyImages: roots.legacyImages,
        backups: roots.backups,
        temp: roots.temp,
        modsLibrary: roots.modsLibrary,
        currentLogFile: path.join(roots.logs.path, current),
      );
      await mount(
        tester,
        scannerOver(withCurrent),
        mods: [mod('Ellen'), mod('Nicole')],
        overrides: [storageRootsProvider.overrideWithValue(withCurrent)],
      );

      await tapWithIo(tester, inRow(StorageCategoryId.logs, find.widgetWithText(OutlinedButton, 'Clear')));
      await confirmAndWait(tester, dialogButton('Clear logs'));

      expect(File(path.join(roots.logs.path, current)).existsSync(), isTrue);
      expect(find.textContaining('Freed'), findsOneWidget);
    });
  });

  group('saved versions', () {
    Future<StorageRoots> withVersions(WidgetTester tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await snapshotOf(tester, roots, 'mods/Ellen', 'u-ellen', 'Ellen');
      await snapshotOf(tester, roots, 'mods/Nicole', 'u-gone', 'Deleted mod');
      return roots;
    }

    testWidgets('Manage lists each mod\'s versions in place, under the row', (tester) async {
      final roots = await withVersions(tester);
      await mount(tester, scannerOver(roots), mods: [mod('Ellen', uid: 'u-ellen'), mod('Nicole')]);
      expect(inRow(StorageCategoryId.savedVersions, find.text('Ellen')), findsNothing);
      expect(find.text('2 snapshots kept by updates, across 2 mods'), findsOneWidget);

      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();

      expect(inRow(StorageCategoryId.savedVersions, find.text('Ellen')), findsOneWidget);
      expect(inRow(StorageCategoryId.savedVersions, find.text('Deleted mod')), findsOneWidget);
      expect(inRow(StorageCategoryId.savedVersions, find.textContaining('No longer in your library')), findsOneWidget);
    });

    testWidgets('inside it, clearing the ones nobody has runs over the unclaimed groups only, and says it cannot be undone',
        (tester) async {
      final roots = await withVersions(tester);
      Set<ReclaimTarget>? asked;
      await mount(tester, scannerOver(roots), mods: [mod('Ellen', uid: 'u-ellen'), mod('Nicole')], runner: (t) async {
        asked = t;
        return outcome(freed: 10, removed: 1, target: ReclaimTarget.unclaimedSnapshots);
      });
      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear versions of mods you no longer have'));
      await tester.pumpAndSettle();

      expect(find.text('Deleted saved versions cannot be fetched again.'), findsOneWidget);
      expect(asked, isNull);

      await tester.tap(dialogButton('Clear versions'));
      await tester.pumpAndSettle();

      expect(asked, {ReclaimTarget.unclaimedSnapshots});
      expect(find.text('Freed 10 B'), findsOneWidget);
    });

    testWidgets('there is nothing to clear when the library holds every group\'s mod', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await snapshotOf(tester, roots, 'mods/Ellen', 'u-ellen', 'Ellen');
      await mount(tester, scannerOver(roots), mods: [mod('Ellen', uid: 'u-ellen'), mod('Nicole')]);

      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();

      expect(find.text('Clear versions of mods you no longer have'), findsNothing);
    });

    testWidgets('with no measured library nothing is tagged and nothing offers to clear', (tester) async {
      // The scan answers an empty list for a library it cannot find, which would tag every group.
      write('mods/Nicole/body.ini', 100);
      final roots = rootsOver();
      await snapshotOf(tester, roots, 'mods/Nicole', 'u-gone', 'Deleted mod');
      await mount(tester, scannerOver(roots));

      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();

      expect(inRow(StorageCategoryId.savedVersions, find.text('Deleted mod')), findsOneWidget);
      expect(find.textContaining('No longer in your library'), findsNothing);
      expect(find.text('Clear versions of mods you no longer have'), findsNothing);
    });

    testWidgets('the fold never hides a group the Clear button would take', (tester) async {
      StorageItem group(int i) => StorageItem(
            id: 'uid$i',
            label: 'Mod $i',
            path: '/backups/uid$i',
            bytes: 1000 - i,
            fileCount: 1,
            kind: StorageItemKind.snapshotGroup,
          );
      final items = [for (var i = 0; i < 22; i++) group(i)];
      await pumpLocalized(
        tester,
        SingleChildScrollView(
          child: SavedVersionsDetail(
            category: StorageCategory(
              id: StorageCategoryId.savedVersions,
              read: StorageRead.ok,
              bytes: items.fold<int>(0, (sum, item) => sum + item.bytes),
              fileCount: 22,
              items: items,
            ),
            // The smallest group is past the twenty listed, and it is one the button takes.
            unclaimed: {'uid21'},
            clear: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Mod 19'), findsOneWidget);
      expect(find.text('Mod 20'), findsNothing, reason: 'a group a mod still claims folds away');
      expect(find.text('Mod 21'), findsOneWidget, reason: 'an unclaimed group is listed whatever its size');
      expect(find.text('and 1 more'), findsOneWidget);
    });

    testWidgets('the real sweep takes the unclaimed group and keeps the claimed one', (tester) async {
      final roots = await withVersions(tester);
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen', uid: 'u-ellen'), mod('Nicole')],
        overrides: [
          storageRootsProvider.overrideWithValue(roots),
          // A configured ZZMI folder: with none the library scan answers an empty list and the sweep refuses.
          zzmiPathProvider.overrideWith((_) => 'zzmi'),
        ],
      );
      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(OutlinedButton, 'Clear versions of mods you no longer have'));
      await confirmAndWait(tester, dialogButton('Clear versions'));

      expect(Directory(path.join(roots.backups.path, 'u-gone')).existsSync(), isFalse);
      expect(Directory(path.join(roots.backups.path, 'u-ellen')).existsSync(), isTrue);
    });
  });

  group('largest mods', () {
    testWidgets('names each mod with its character and saved versions, biggest first', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await snapshotOf(tester, roots, 'mods/Nicole', 'u-nicole', 'Nicole');
      await mount(tester, scannerOver(roots), mods: [
        mod('Ellen', name: 'Winter Maid Uniform', uid: 'u-ellen'),
        mod('Nicole', name: 'Crimson Kimono', character: 'nicole', uid: 'u-nicole'),
      ]);

      expect(find.text('Largest mods'), findsOneWidget);
      expect(find.text('Installed version plus its saved versions'), findsOneWidget);
      expect(find.text('Ellen Joe · no saved versions'), findsOneWidget);
      expect(find.text('Nicole Demara · 1 saved version'), findsOneWidget);
      // Nicole: 1024 installed + 1124 in her saved version (the folder and its sidecar) beats Ellen's 2048.
      final names = find.descendant(of: find.byType(InkWell), matching: find.textContaining(RegExp('Maid|Kimono')));
      expect(
        tester.getTopLeft(find.text('Crimson Kimono')).dy,
        lessThan(tester.getTopLeft(find.text('Winter Maid Uniform')).dy),
      );
      expect(names, findsNWidgets(2));
    });

    testWidgets('a mod with no character is Unassigned', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen', character: 'unknown'), mod('Nicole')]);

      expect(find.textContaining('Unassigned · no saved versions'), findsOneWidget);
    });

    testWidgets('a mod that is a link says so, and never 0 B', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final target = Directory(path.join(root.path, 'elsewhere', 'Linked'))..createSync(recursive: true);
      File(path.join(target.path, 'body.ini')).writeAsBytesSync(List<int>.filled(4096, 0));
      Link(path.join(root.path, 'mods', 'Linked')).createSync(target.path);
      await tester.runAsync(() async {
        await SnapshotService(rootPath: roots.backups.path).take(
          modName: 'Linked',
          modUid: 'u-linked',
          modFolder: target,
          reason: SnapshotReason.beforeUpdate,
        );
      });
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole'), mod('Linked', uid: 'u-linked')],
      );

      expect(find.text('Linked elsewhere'), findsWidgets);
      final linkedRow = find.ancestor(of: find.text('Linked'), matching: find.byType(InkWell)).first;
      expect(find.descendant(of: linkedRow, matching: find.text('0 B')), findsNothing);
      expect(find.descendant(of: linkedRow, matching: find.text('Linked elsewhere')), findsOneWidget);
      // Symlinks need privileges on Windows.
    }, skip: Platform.isWindows);

    testWidgets('pressing a row opens that mod\'s page in the Library', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final container = await mount(tester, scannerOver(roots), mods: [
        mod('Ellen', name: 'Winter Maid Uniform', uid: 'u-ellen'),
        mod('Nicole', character: 'nicole'),
      ]);
      container.read(destinationProvider.notifier).state = AppDestination.settings;

      await tester.tap(find.text('Winter Maid Uniform'));
      await tester.pumpAndSettle();

      expect(container.read(destinationProvider), AppDestination.characters);
      final request = container.read(openModPageProvider)!;
      expect(request.modId, 'Ellen');
      expect(request.pageKey, 'u-ellen');
      expect(container.read(selectedModIdProvider), 'Ellen');
      expect(container.read(selectedCharacterIdProvider), 'ellen');
    });

    testWidgets('there is no list without a library to rank', (tester) async {
      await mount(tester, scannerOver(rootsOver()));

      expect(find.text('Largest mods'), findsNothing);
    });
  });

  group('freshness', () {
    testWidgets('a library that has changed since the scan says so', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole'), mod('Arrived')]);

      expect(find.text('Your library has changed since this scan.'), findsOneWidget);
    });

    testWidgets('a mod gone from the library says so too', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen')]);

      expect(find.text('Your library has changed since this scan.'), findsOneWidget);
    });

    testWidgets('an unchanged library says nothing', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      expect(find.text('Your library has changed since this scan.'), findsNothing);
    });

    testWidgets('a dead link in the library folder is not a change', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      Link(path.join(root.path, 'mods', 'Dead')).createSync(path.join(root.path, 'nowhere'));
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')]);

      expect(find.text('Your library has changed since this scan.'), findsNothing);
      // Symlinks need privileges on Windows.
    }, skip: Platform.isWindows);

    testWidgets('Rescan walks the library again, and shows what the new walk found', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      var scanners = 0;
      final container = await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        // Each scanner holds its own memoised walk, so a new walk is a new scanner.
        overrides: [
          storageScannerProvider.overrideWith((ref) {
            scanners++;
            return countingScannerOver(roots);
          }),
        ],
      );
      expect(scanners, 1);
      expect(find.text('4.1 KB'), findsOneWidget);
      write('mods/Fresh/body.ini', 4096);

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Measured just now'));
        await container.read(storageCategoryProvider(StorageCategoryId.mods).future);
      });
      await tester.pumpAndSettle();

      expect(scanners, 2, reason: 'the memoised walk is only left behind with the scanner that holds it');
      expect(find.text('8.1 KB'), findsOneWidget, reason: 'the folder added since was walked');
      expect(
        (container.read(storageScannerProvider) as _CountingScanner).reads[StorageCategoryId.mods],
        greaterThan(0),
      );
    });

    testWidgets('entering the section re-reads the cheap categories but not the library walk', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final scanner = countingScannerOver(roots);
      final container = await mount(tester, scanner, mods: [mod('Ellen'), mod('Nicole')]);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final first = Map.of(scanner.reads);

      await pumpLocalized(tester, const SizedBox.shrink(), container: container);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      expect(scanner.reads, first, reason: 'nothing reads on its own while the user is elsewhere');
      await pumpLocalized(tester, sectionPage(), container: container);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      for (final id in cheapStorageCategories) {
        expect(scanner.reads[id], first[id]! + 1, reason: '${id.name} is re-read on entry');
      }
      for (final id in libraryStorageCategories) {
        expect(scanner.reads[id], first[id], reason: '${id.name} is the walk, kept behind Rescan');
      }
    });

    testWidgets('the measurements survive leaving the section', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      final scanner = countingScannerOver(roots);
      final container = await mount(tester, scanner, mods: [mod('Ellen'), mod('Nicole')]);

      await pumpLocalized(tester, const SizedBox.shrink(), container: container);
      await tester.pump(const Duration(minutes: 5));

      // An `autoDispose` provider would have gone with its last listener and read the scanner again here.
      final mods = container.read(storageCategoryProvider(StorageCategoryId.mods));
      expect(mods.hasValue, isTrue);
      expect(mods.requireValue.bytes, 3072);
      expect(scanner.reads[StorageCategoryId.mods], 1);
    });

    testWidgets('"Measured just now" ages while the section stays open', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      var passed = Duration.zero;
      await mount(
        tester,
        scannerOver(roots),
        mods: [mod('Ellen'), mod('Nicole')],
        now: () => DateTime.now().add(passed),
      );
      expect(find.text('Measured just now'), findsOneWidget);

      passed = const Duration(minutes: 5);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Measured 5 minutes ago'), findsOneWidget);

      passed = const Duration(hours: 3);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Measured 3 hours ago'), findsOneWidget);
    });

    testWidgets('the notice\'s Rescan waits for the walk, as the hero\'s does', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole'), mod('Arrived')]);
      final notice = find.widgetWithText(TextButton, 'Rescan the library');
      expect(tester.widget<TextButton>(notice).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(TextButton, 'Measured just now'));
      await tester.pump();

      expect(find.text('Measuring…'), findsWidgets);
      expect(tester.widget<TextButton>(notice).onPressed, isNull, reason: 'a walk is already measuring');

      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      expect(tester.widget<TextButton>(notice).onPressed, isNotNull);
    });

    testWidgets('while the library is measured the button says so', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], warm: false);

      expect(find.text('Measuring…'), findsWidgets);
      expect(find.text('Measured just now'), findsNothing);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    });
  });

  group('the window', () {
    Future<void> measuredAt(WidgetTester tester, double width) async {
      await loadTableFonts(tester);
      final roots = rootsOver(library: stockedLibrary());
      await snapshotOf(tester, roots, 'mods/Ellen', 'u-ellen', 'Ellen');
      await snapshotOf(tester, roots, 'mods/Nicole', 'u-gone', 'A mod with a rather long name for a narrow window');
      await mount(
        tester,
        scannerOver(roots, platform: _FakePlatform((p) => p.endsWith('mods') ? 900 * 1024 : 500 * 1024 * 1024)),
        mods: [
          mod('Ellen', name: 'Winter Maid Uniform With A Very Long Name Indeed', uid: 'u-ellen'),
          mod('Nicole', character: 'nicole'),
          mod('Arrived'),
        ],
        size: Size(width, 900),
      );
      await tester.tap(inRow(StorageCategoryId.savedVersions, find.widgetWithText(OutlinedButton, 'Manage')));
      await tester.pumpAndSettle();
      await hover(tester, segment(StorageCategoryId.mods));
    }

    /// Every row's buttons and folder icon are there and sit inside the window.
    /// Returns the rows whose actions wrap below the name rather than sharing its line, for the caller to pin.
    Set<StorageCategoryId> expectRowActionsInside(WidgetTester tester, double width) {
      final stacked = <StorageCategoryId>{};
      final actions = <StorageCategoryId, (String, Finder?)>{
        StorageCategoryId.leftovers: ('Leftovers', find.widgetWithText(FilledButton, 'Clean up')),
        StorageCategoryId.downloads: ('Downloads', find.widgetWithText(OutlinedButton, 'Clear')),
        StorageCategoryId.logs: ('Logs', find.widgetWithText(OutlinedButton, 'Clear')),
        StorageCategoryId.savedVersions: ('Saved versions', find.widgetWithText(OutlinedButton, 'Manage')),
        StorageCategoryId.mods: ('Installed mods', null),
        StorageCategoryId.sidecars: ('Covers & metadata', null),
      };
      for (final MapEntry(key: id, value: (label, button)) in actions.entries) {
        final icon = inRow(id, find.byType(IconButton));
        expect(icon, findsOneWidget, reason: '${id.name} has its folder icon');
        final name = tester.getRect(inRow(id, find.text(label)));
        final pressed = [icon, if (button != null) inRow(id, button)];
        for (final finder in pressed) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '${id.name} starts inside the window');
          expect(rect.right, lessThanOrEqualTo(width), reason: '${id.name} ends inside the window');
          if (rect.top >= name.bottom) stacked.add(id);
        }
      }
      expect(tester.getRect(find.widgetWithText(TextButton, 'Measured just now')).right, lessThanOrEqualTo(width));
      expect(segment(StorageCategoryId.mods), findsOneWidget);
      return stacked;
    }

    testWidgets('holds together at 1200 px wide', (tester) async {
      await measuredAt(tester, 1200);

      expect(tester.takeException(), isNull);
      expect(find.byType(StorageSection), findsOneWidget);
      expect(expectRowActionsInside(tester, 1200), <StorageCategoryId>{}, reason: 'every row keeps its actions beside it');
    });

    testWidgets('holds together at 700 px wide', (tester) async {
      await measuredAt(tester, 700);

      expect(tester.takeException(), isNull);
      expect(find.byType(StorageSection), findsOneWidget);
      // Only Covers & metadata, whose description is the longest, wraps its folder icon below the name.
      expect(expectRowActionsInside(tester, 700), {StorageCategoryId.sidecars});
    });

    testWidgets('where the settings page leaves it 420 px, the buttons sit under the text', (tester) async {
      await measuredAt(tester, 468);

      expect(tester.takeException(), isNull);
      final text = tester.getRect(find.descendant(of: row(StorageCategoryId.downloads), matching: find.text('Downloads')));
      final button = tester.getRect(inRow(StorageCategoryId.downloads, find.widgetWithText(OutlinedButton, 'Clear')));
      expect(button.top, greaterThan(text.bottom), reason: 'the buttons wrap below the name');
    });

    testWidgets('holds together on paper', (tester) async {
      final roots = rootsOver(library: stockedLibrary());
      await mount(tester, scannerOver(roots), mods: [mod('Ellen'), mod('Nicole')], brightness: Brightness.light);
      await hover(tester, segment(StorageCategoryId.mods));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('of the total'), findsOneWidget);
      expect(expectRowActionsInside(tester, 1200), <StorageCategoryId>{}, reason: 'every row keeps its actions beside it');

      // On paper the group a bar sits on is `field`, so a `raised` track would be the same colour and invisible.
      final palette = ZenithPalette.of(tester.element(find.byType(StorageSection)));
      final tracks = tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(tracks, isNotEmpty, reason: 'the Largest mods bars are drawn');
      for (final bar in tracks) {
        expect(bar.backgroundColor, palette.barTrack);
        expect(bar.backgroundColor, isNot(palette.field));
        expect(bar.borderRadius, BorderRadius.circular(99), reason: 'the fill ends round, as the canvas draws it');
      }
    });

    for (final brightness in Brightness.values) {
      testWidgets('the meter\'s empty placeholder is the bar track, visible in ${brightness.name}', (tester) async {
        await mount(tester, scannerOver(rootsOver()), brightness: brightness);

        final palette = ZenithPalette.of(tester.element(find.byType(StorageSection)));
        final placeholder = find.byWidgetPredicate(
          (widget) => widget is Container && (widget.decoration as BoxDecoration?)?.color == palette.barTrack,
        );
        expect(placeholder, findsOneWidget);
        expect(palette.barTrack, isNot(palette.card));
        expect(palette.barTrack, isNot(palette.field));
      });
    }
  });
}
