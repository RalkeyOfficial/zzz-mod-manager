import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/launch_update_check_host.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The opt-in startup check, from the side that has a `BuildContext`.
///
/// Three things are being pinned, and each one fails silently if it breaks:
/// that the pass waits for the library scan instead of racing it, that it runs
/// **once** however often the library is rescanned afterwards, and that it says
/// nothing unless it found something.
void main() {
  ModInfo mod(String name, {int? modId, int? fileId}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: modId == null
            ? null
            : originFixture(
                source: 'gamebanana',
                modId: modId,
                modIdConfidence: OriginConfidence.user,
                fileId: fileId,
                versionConfidence: fileId == null
                    ? OriginConfidence.unknown
                    : OriginConfidence.user,
                provenance: OriginProvenance.downloaded,
              ),
      );

  /// The mod page as the pass sees it: the file the user installed is gone from
  /// the list, which is the strongest verdict the comparator produces.
  ///
  /// Dated, as every real record is: an undated one is a withheld mod's blank,
  /// and the check fetches its profile.
  GbMod superseded(int modId) => GbMod(
        idRow: modId,
        dateAdded: DateTime.utc(2025),
        files: [
          GbFile(
            idRow: 11,
            description: 'Main file',
            dateAdded: DateTime.utc(2026, 6),
          ),
        ],
      );

  /// The same page with the installed file still on it — nothing to report.
  GbMod unchanged(int modId) => GbMod(
        idRow: modId,
        dateAdded: DateTime.utc(2025),
        files: [
          GbFile(
            idRow: 10,
            description: 'Main file',
            dateAdded: DateTime.utc(2026, 1),
          ),
        ],
      );

  late int fetchCalls;
  late ProviderContainer container;

  setUp(() {
    fetchCalls = 0;
    // Empty rather than absent, so nothing reaches the real scan: the host is
    // being tested against a library that arrives, which `libraryLands` does.
    container = ProviderContainer(overrides: [libraryOf(const [])]);
    addTearDown(container.dispose);
  });

  /// A scan landing, as the host sees it. `put` is what the app's own targeted
  /// updates use, so a test making a library appear does it the same way.
  void libraryLands(List<ModInfo> mods) =>
      container.read(libraryProvider.notifier).put(mods);

  Future<void> mount(
    WidgetTester tester, {
    required bool enabled,
    List<ModInfo> mods = const [],
    GbMod Function(int modId)? page,
    Future<List<GbMod>> Function(List<int>)? fetch,
    OriginWriter? originWriter,
    Widget child = const SizedBox.shrink(),
    Size surfaceSize = const Size(1200, 800),
  }) async {
    container.read(updateCheckOnLaunchProvider.notifier).state = enabled;
    libraryLands(mods);

    await pumpLocalized(
      tester,
      LaunchUpdateCheckHost(
        updateFetcher: fetch ??
            (ids) async {
              fetchCalls++;
              return [for (final id in ids) (page ?? superseded)(id)];
            },
        updatesFetcher: (_) async => const <GbUpdate>[],
        // Fails every write by default: no test here reaches a library.
        originWriter: originWriter ?? (_, _) async => OriginWriteResult.writeFailed,
        child: child,
      ),
      container: container,
      surfaceSize: surfaceSize,
    );
    expectBuilt(LaunchUpdateCheckHost);
  }

  /// The library scan landing after the host is already mounted — the real
  /// launch ordering, since `ModsScreen` scans on the way in.
  Future<void> scanLands(WidgetTester tester, List<ModInfo> mods) async {
    libraryLands(mods);
    await tester.pumpAndSettle();
  }

  testWidgets('runs when the scan lands, and reports what it found',
      (tester) async {
    await mount(tester, enabled: true);
    expect(fetchCalls, 0, reason: 'nothing to check before the scan');

    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(fetchCalls, 1);
    expect(container.read(libraryUpdateCountProvider), 1);
    expect(find.text('1 mod has an update'), findsOneWidget);
    expect(
      find.text('Checked 1 mod when the app started.'),
      findsOneWidget,
      reason: 'a card nobody pressed for has to explain its own presence',
    );
  });

  testWidgets('says which mods it has reached while it runs, and keeps them checked once it ends', (tester) async {
    await mount(tester, enabled: true);
    final seen = <String>[];
    container.listen(
      libraryCheckProgressProvider,
      (_, reached) => seen.add('${reached.toList()} ${container.read(modUpdateChecksProvider).containsKey('Ellen')}'),
    );

    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(seen, ['[Ellen] false', '[] true'],
        reason: 'the verdict lands before the progress is cleared, so the mod never reads unchecked in between');
  });

  testWidgets('runs against a library that was already scanned',
      (tester) async {
    // The hot-reload case: the host is rebuilt under a library scanned long
    // ago, so reacting only to *changes* would mean it never runs at all.
    await mount(tester, enabled: true, mods: [mod('Ellen', modId: 1, fileId: 10)]);
    await tester.pumpAndSettle();

    expect(fetchCalls, 1);
    expect(container.read(libraryUpdateCountProvider), 1);
  });

  testWidgets("saves each download's page title on its sidecar", (tester) async {
    // So the details panel names the downloads after a restart, without a request.
    final library = [mod('Ellen', modId: 1, fileId: 10)];
    final written = <String, ModOrigin?>{};
    await mount(
      tester,
      enabled: true,
      mods: library,
      page: (id) => GbMod(idRow: id, name: 'Ellen Swimsuit', files: unchanged(id).files),
      originWriter: (modId, update) async {
        written[modId] = update(library.firstWhere((m) => m.id == modId).origin);
        return OriginWriteResult.written;
      },
    );
    await tester.pumpAndSettle();

    expect(written.keys, ['Ellen']);
    expect(written['Ellen']?.base?.name, 'Ellen Swimsuit');
  });

  testWidgets('does nothing at all when it is switched off', (tester) async {
    await mount(tester, enabled: false);
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(fetchCalls, 0, reason: 'no network on launch unless asked for');
    expect(container.read(modUpdateChecksProvider), isEmpty);
    expect(find.text('1 mod has an update'), findsNothing);
  });

  testWidgets('switching it on mid-session waits for the next start',
      (tester) async {
    // The switch says *when the app starts*, so enabling it and then
    // favouriting a mod must not fire a pass at a moment the label does not
    // describe.
    await mount(tester, enabled: false);
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);
    expect(fetchCalls, 0);

    container.read(updateCheckOnLaunchProvider.notifier).state = true;
    await scanLands(tester, [
      mod('Ellen', modId: 1, fileId: 10),
      mod('Miyabi', modId: 2, fileId: 20),
    ]);

    expect(fetchCalls, 0);
  });

  testWidgets('runs once however often the library is rescanned',
      (tester) async {
    // A favourite, an import, a rename and a resolve each rebuild the plan.
    // Without the guard an ordinary afternoon issues the batch a dozen times.
    await mount(tester, enabled: true);
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);
    expect(fetchCalls, 1);

    await scanLands(tester, [
      mod('Ellen', modId: 1, fileId: 10),
      mod('Miyabi', modId: 2, fileId: 20),
    ]);
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(fetchCalls, 1);
  });

  testWidgets('stays silent when it found nothing', (tester) async {
    await mount(tester, enabled: true, page: unchanged);
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(fetchCalls, 1, reason: 'it still ran — it just has nothing to say');
    expect(container.read(libraryUpdateCountProvider), 0);
    expect(find.text('No updates found'), findsNothing);
    expect(find.textContaining('Checked'), findsNothing);
  });

  testWidgets('stays silent when it could not look', (tester) async {
    // The commonest cause by far is starting the app offline, and a card
    // saying so on every launch is what gets the setting switched off. The
    // toolbar's check is the one that reports an outage.
    await mount(
      tester,
      enabled: true,
      fetch: (_) async {
        fetchCalls++;
        throw const SocketExceptionStub();
      },
    );
    await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

    expect(fetchCalls, 1);
    expect(find.textContaining('has an update'), findsNothing);
    expect(find.textContaining("couldn't be checked"), findsNothing);
  });

  group('shares the running flag with the All mods page', () {
    testWidgets('a check the user started stands in for it', (tester) async {
      container.read(libraryCheckRunningProvider.notifier).state = true;
      await mount(tester, enabled: true);
      await scanLands(tester, [mod('Ellen', modId: 1, fileId: 10)]);

      expect(fetchCalls, 0, reason: 'two passes would race their results into one map');
      expect(container.read(libraryCheckRunningProvider), isTrue, reason: "the user's check is still running");
    });

    testWidgets('while it runs, the All mods page cannot start another', (tester) async {
      final reply = Completer<List<GbMod>>();
      await loadTableFonts(tester);
      await mount(
        tester,
        enabled: true,
        fetch: (_) {
          fetchCalls++;
          return reply.future;
        },
        surfaceSize: const Size(1400, 900),
        child: LibraryActionsHost(
          updateFetcher: (_) async => throw StateError('no fetch expected'),
          originWriter: (_, _) async => OriginWriteResult.writeFailed,
          child: allModsViewForTest(),
        ),
      );
      OutlinedButton checkAll() =>
          tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Check all for updates'));

      // Pumped, not settled: the check button's spinner turns while the pass runs.
      libraryLands([mod('Ellen', modId: 1, fileId: 10)]);
      await tester.pump();

      expect(fetchCalls, 1);
      expect(container.read(libraryCheckRunningProvider), isTrue);
      expect(checkAll().onPressed, isNull);

      reply.complete([superseded(1)]);
      await tester.pumpAndSettle();

      expect(container.read(libraryCheckRunningProvider), isFalse);
      expect(checkAll().onPressed, isNotNull);
    });
  });
}

/// A network failure that is not a `GbApiException`, so the pass abandons the
/// batch rather than bisecting it — an outage repeats for every half.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'network unreachable';
}
