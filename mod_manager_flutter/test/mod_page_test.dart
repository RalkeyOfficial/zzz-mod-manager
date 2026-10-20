import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/mod_page/mod_page.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/mods_screen_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// A mod's page in the Library (`docs/library-screen.md` §15): what opening it fetches, what its History tab lists,
/// and the panel's way in and the page's way back.
void main() {
  const modId = 531649;
  final profileUrl = Uri.parse('https://gamebanana.com/apiv13/Mod/$modId/ProfilePage');
  final updatesUrl = Uri.parse('https://gamebanana.com/apiv13/Mod/$modId/Updates');

  late FakeHttpTransport http;
  // Where the fetch's saved download names are written: a library that is not the developer's.
  late TempLibrary temp;
  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_mod_page_');
    http = FakeHttpTransport()
      ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'))
      // A captured feed of another mod: the page reads only its posts, not which mod they belong to.
      ..stub(updatesUrl, body: loadGbFixture('mod_updates_549029'));
  });

  ModInfo modWith(ModOrigin? origin) =>
      ModInfo(id: 'RabbitFX', name: 'RabbitFX', characterId: 'unknown', isActive: false, uid: 'uid-1', origin: origin);

  ModOrigin tracked({
    OriginTracking tracking = OriginTracking.auto,
    DateTime? updatesDismissedUntil,
    List<ModDownload> patches = const [],
    OriginConfidence versionConfidence = OriginConfidence.exact,
  }) => originFixture(
    modId: modId,
    modIdConfidence: OriginConfidence.exact,
    fileId: 1491924,
    versionLabel: 'RabbitFX Fixer EXE Version',
    versionConfidence: versionConfidence,
    provenance: OriginProvenance.downloaded,
    tracking: tracking,
    updatesDismissedUntil: updatesDismissedUntil,
    patches: patches,
  );

  ModSnapshot snapshotAt(DateTime takenAt) => ModSnapshot(
    modName: 'RabbitFX',
    modUid: 'uid-1',
    id: 'snap',
    takenAt: takenAt,
    sizeBytes: 2048,
    directory: Directory('/nonexistent/snap'),
  );

  final restored = <ModSnapshot>[];
  final takenOut = <ModDownload>[];
  final unignored = <ModDownload>[];
  setUp(() {
    restored.clear();
    takenOut.clear();
    unignored.clear();
  });

  Future<void> open(
    WidgetTester tester,
    ModInfo mod, {
    List<SnapshotEntry> snapshots = const [],
    ModPageTab tab = ModPageTab.history,
    Size surfaceSize = const Size(1400, 2400),
  }) async {
    await pumpLocalized(
      tester,
      LibraryModPage(
        mod: mod,
        initialTab: tab,
        onBack: () {},
        onToggle: () {},
        onFavoriteToggle: () {},
        onEdit: () {},
        onEditKeys: () {},
        onOpenFolder: () {},
        onCheckForUpdate: () {},
        onResolveOrigin: () {},
        onDelete: () {},
        onReinstall: () {},
        onRestore: restored.add,
        onTakeOut: takenOut.add,
        onStopIgnoring: unignored.add,
        noteWriter: (_, _) async => true,
      ),
      overrides: [
        libraryOf([mod]),
        ...temp.overrides,
        gameBananaClientProvider.overrideWithValue(GameBananaClient(transport: http, maxRetries: 0)),
        modBackupsProvider.overrideWith((ref) async => <String>{}),
        modSnapshotsProvider.overrideWith((ref, uid) async => snapshots),
      ],
      surfaceSize: surfaceSize,
    );
    expectBuilt(LibraryModPage);
    // The fetch on open goes through the fake transport, which only the real event loop turns.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('opening the page fetches the mod page, so History names the file in use and the latest post', (
    tester,
  ) async {
    await open(tester, modWith(tracked()));

    expect(http.requests, containsAll([profileUrl, updatesUrl]));
    expect(find.text('rabbitfx_fixer_exe_version.zip'), findsNWidgets(2), reason: "History's row and the Tracking line");
    expect(find.text('In use'), findsOneWidget);
    expect(find.text('Reinstall'), findsOneWidget);
    expect(find.text('Version 1.5'), findsOneWidget, reason: 'the newest post with something to say');
  });

  testWidgets('a file worked out in the tracking screen is badged GameBanana, as a known one is', (tester) async {
    for (final confidence in [OriginConfidence.exact, OriginConfidence.inferred]) {
      await open(tester, modWith(tracked(versionConfidence: confidence)));
      expect(find.widgetWithText(ZenithBadge, 'GameBanana'), findsOneWidget, reason: '$confidence');
    }
  });

  testWidgets('History offers Reinstall for a worked-out file, and not for a date with no file', (tester) async {
    await open(tester, modWith(tracked(versionConfidence: OriginConfidence.inferred)));
    expect(find.text('Reinstall'), findsOneWidget);

    await open(tester, modWith(tracked(versionConfidence: OriginConfidence.assumedLatest)));
    expect(find.text('Reinstall'), findsNothing);
  });

  testWidgets('a mod marked Local fetches nothing and offers no reinstall', (tester) async {
    await open(tester, modWith(tracked(tracking: OriginTracking.off)));

    expect(http.callCount, 0);
    expect(find.text('Reinstall'), findsNothing);
    expect(find.text('File not known yet'), findsOneWidget);
  });

  testWidgets('a snapshot is named by when it was saved until its file is known, and restores itself', (tester) async {
    final snapshot = snapshotAt(DateTime(2026, 10, 2, 14, 5));
    await open(tester, modWith(tracked(tracking: OriginTracking.off)), snapshots: [(snapshot: snapshot, origin: null)]);

    expect(find.text('2026-10-02 14:05'), findsOneWidget);
    expect(find.textContaining('before an update'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    expect(restored, [snapshot]);
  });

  testWidgets('a snapshot whose sidecar names a file this session holds is named by that file', (tester) async {
    final snapshot = snapshotAt(DateTime(2026, 9, 1));
    final then = originFixture(
      modId: modId,
      modIdConfidence: OriginConfidence.exact,
      fileId: 1491926,
      versionConfidence: OriginConfidence.exact,
    );
    await open(tester, modWith(tracked()), snapshots: [(snapshot: snapshot, origin: then)]);

    expect(find.text('rabbitfx_fixer_python_ver.zip'), findsOneWidget);
    expect(find.textContaining('saved 2026-09-01 00:00, before an update'), findsOneWidget);
  });

  testWidgets('a patch is offered for taking out only when the app knows which files are its', (tester) async {
    final recorded = patchFixture(
      modId: 605460,
      files: const [
        InstalledFile(path: 'a.dds'),
        InstalledFile(path: 'b.dds', role: InstalledFileRole.replaced),
      ],
    );
    final unrecorded = patchFixture(modId: 605461);
    await open(tester, modWith(tracked(tracking: OriginTracking.off, patches: [recorded, unrecorded])));

    expect(find.text('PATCHES ON TOP'), findsOneWidget);
    expect(find.text('Take out'), findsOneWidget);
    expect(find.textContaining('1 file added, 1 replaced'), findsOneWidget);
    expect(find.textContaining("Which files are its wasn't recorded"), findsOneWidget);
    await tester.tap(find.text('Take out'));
    expect(takenOut, [recorded]);
  });

  testWidgets('an ignored update says what it covers and can be stopped from History', (tester) async {
    final mod = modWith(tracked(tracking: OriginTracking.off, updatesDismissedUntil: DateTime(2026, 9, 30)));
    await open(tester, mod);

    expect(find.text('IGNORED UPDATE'), findsOneWidget);
    expect(find.text('Ignoring files uploaded up to 2026-09-30'), findsOneWidget);
    await tester.tap(find.text('Stop ignoring'));
    expect(unignored.single.modId, modId);
  });

  testWidgets('the install date reads the same however it was worked out', (tester) async {
    ModOrigin dated({required bool proxy}) => originFixture(
      source: null,
      tracking: OriginTracking.off,
      installedAt: DateTime(2026, 7, 29),
      installedAtIsProxy: proxy,
    );

    for (final proxy in [true, false]) {
      await open(tester, modWith(dated(proxy: proxy)), tab: ModPageTab.overview);
      expect(find.text('installed on 2026-07-29'), findsOneWidget);
      expect(find.text('2026-07-29'), findsOneWidget, reason: 'the Added fact');
    }
  });

  testWidgets('pointing the mod at a page while it is open fetches that page, and marking it Local drops the post', (
    tester,
  ) async {
    final mod = ValueNotifier(modWith(tracked(tracking: OriginTracking.off)));
    addTearDown(mod.dispose);
    await pumpLocalized(
      tester,
      ValueListenableBuilder<ModInfo>(
        valueListenable: mod,
        builder: (context, value, _) => LibraryModPage(
          mod: value,
          initialTab: ModPageTab.history,
          onBack: () {},
          onToggle: () {},
          onFavoriteToggle: () {},
          onEdit: () {},
          onEditKeys: () {},
          onOpenFolder: () {},
          onCheckForUpdate: () {},
          onResolveOrigin: () {},
          onDelete: () {},
          onReinstall: () {},
          onRestore: (_) {},
          onTakeOut: (_) {},
          onStopIgnoring: (_) {},
        ),
      ),
      overrides: [
        libraryOf([mod.value]),
        ...temp.overrides,
        gameBananaClientProvider.overrideWithValue(GameBananaClient(transport: http, maxRetries: 0)),
        modBackupsProvider.overrideWith((ref) async => <String>{}),
        modSnapshotsProvider.overrideWith((ref, uid) async => const <SnapshotEntry>[]),
      ],
      surfaceSize: const Size(1400, 2400),
    );
    expectBuilt(LibraryModPage);
    expect(http.callCount, 0);

    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    mod.value = modWith(tracked());
    await tester.pump();
    await settle();
    expect(http.requests, containsAll([profileUrl, updatesUrl]));
    expect(find.text('Version 1.5'), findsOneWidget);

    mod.value = modWith(tracked(tracking: OriginTracking.off));
    await tester.pump();
    await settle();
    expect(find.text('Version 1.5'), findsNothing);
  });

  testWidgets('every tab lays out in the Library at the smallest window, one column under the other', (tester) async {
    final patch = patchFixture(modId: 605460, files: const [InstalledFile(path: 'a.dds')]);
    final mod = modWith(tracked(updatesDismissedUntil: DateTime(2026, 9, 30), patches: [patch]));
    final snapshot = (snapshot: snapshotAt(DateTime(2026, 10, 2)), origin: null);
    // The 800px window less the sidebar, and its 500px less the title and status bars.
    for (final tab in ModPageTab.values) {
      await open(tester, mod, snapshots: [snapshot], tab: tab, surfaceSize: const Size(584, 428));
    }
  });

  group('from the Library', () {
    final ellen = ModInfo(id: 'Ellen Maid', name: 'Ellen Maid', characterId: 'ellen', isActive: false);

    testWidgets("the panel's full-page button opens the page, and Back returns to the character", (tester) async {
      final container = await pumpModsScreen(tester, temp, [ellen], selected: 'ellen');
      container.read(selectedModIdProvider.notifier).state = ellen.id;
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open the full page'));
      await tester.pumpAndSettle();
      expect(container.read(openModPageProvider)?.modId, ellen.id);
      expect(find.byType(LibraryModPage), findsOneWidget);
      expect(find.text('Characters'), findsOneWidget, reason: 'the breadcrumb');

      await tester.tap(find.byTooltip('Back to the characters'));
      await tester.pumpAndSettle();
      expect(container.read(openModPageProvider), isNull);
      expect(find.byType(LibraryModPage), findsNothing);
      expect(container.read(selectedModIdProvider), ellen.id, reason: 'the mod is still in the details panel');
    });

    testWidgets("a note written on the page is in the details panel after Back, and isn't overwritten there", (
      tester,
    ) async {
      final container = await pumpModsScreen(tester, temp, [ellen], selected: 'ellen');
      container.read(selectedModIdProvider.notifier).state = ellen.id;
      await tester.pumpAndSettle();
      container.read(openModPageProvider.notifier).state = ModPageRequest(ellen.id, tab: ModPageTab.note);
      await tester.pumpAndSettle();

      final pageNote = find.descendant(of: find.byType(LibraryModPage), matching: find.byType(TextField));
      await tester.enterText(pageNote, 'use with the white hairpin');
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

      await tester.tap(find.byTooltip('Back to the characters'));
      await tester.pumpAndSettle();
      final panelNote = find.descendant(of: find.byType(ModDetailsPanel), matching: find.byType(TextField));
      expect(tester.widget<TextField>(panelNote).controller?.text, 'use with the white hairpin');
    });

    testWidgets('a uid assigned after the page opened leaves it on the tab it is on', (tester) async {
      final container = await pumpModsScreen(tester, temp, [ellen], selected: 'ellen');
      container.read(openModPageProvider.notifier).state = ModPageRequest(ellen.id, pageKey: ellen.id);
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Installed files'), findsOneWidget);

      // What the first snapshot of a folder that never had one does.
      container.read(libraryProvider.notifier).put([ellen.copyWith(uid: 'assigned-later')]);
      await tester.pumpAndSettle();
      expect(find.text('Installed files'), findsOneWidget);
    });

    testWidgets('a deleted mod takes its page with it', (tester) async {
      final container = await pumpModsScreen(tester, temp, [ellen], selected: 'ellen');
      container.read(openModPageProvider.notifier).state = ModPageRequest(ellen.id);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryModPage), findsOneWidget);

      container.read(libraryProvider.notifier).put(const []);
      await tester.pumpAndSettle();
      expect(container.read(openModPageProvider), isNull);
    });
  });
}
