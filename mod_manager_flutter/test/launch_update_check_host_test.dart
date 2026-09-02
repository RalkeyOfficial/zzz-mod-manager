import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_update.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/launch_update_check_host.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

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

  List<CharacterInfo> library(List<ModInfo> mods) => [
        CharacterInfo(id: 'ellen', name: 'Ellen', skins: mods),
      ];

  /// The mod page as the pass sees it: the file the user installed is gone from
  /// the list, which is the strongest verdict the comparator produces.
  GbMod superseded(int modId) => GbMod(
        idRow: modId,
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
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Future<void> mount(
    WidgetTester tester, {
    required bool enabled,
    List<ModInfo> mods = const [],
    GbMod Function(int modId)? page,
    Future<List<GbMod>> Function(List<int>)? fetch,
  }) async {
    container.read(updateCheckOnLaunchProvider.notifier).state = enabled;
    container.read(charactersProvider.notifier).state = library(mods);

    await pumpLocalized(
      tester,
      LaunchUpdateCheckHost(
        updateFetcher: fetch ??
            (ids) async {
              fetchCalls++;
              return [for (final id in ids) (page ?? superseded)(id)];
            },
        updatesFetcher: (_) async => const <GbUpdate>[],
        child: const SizedBox.shrink(),
      ),
      container: container,
    );
    expectBuilt(LaunchUpdateCheckHost);
  }

  /// The library scan landing after the host is already mounted — the real
  /// launch ordering, since `ModsScreen` scans on the way in.
  Future<void> scanLands(WidgetTester tester, List<ModInfo> mods) async {
    container.read(charactersProvider.notifier).state = library(mods);
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

  testWidgets('runs against a library that was already scanned',
      (tester) async {
    // The hot-reload case: the host is rebuilt under a library scanned long
    // ago, so reacting only to *changes* would mean it never runs at all.
    await mount(tester, enabled: true, mods: [mod('Ellen', modId: 1, fileId: 10)]);
    await tester.pumpAndSettle();

    expect(fetchCalls, 1);
    expect(container.read(libraryUpdateCountProvider), 1);
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
}

/// A network failure that is not a `GbApiException`, so the pass abandons the
/// batch rather than bisecting it — an outage repeats for every half.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'network unreachable';
}
