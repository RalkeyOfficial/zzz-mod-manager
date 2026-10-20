import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/install_result_feedback.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

final swimsuit = ModInfo(id: 'Ellen Swimsuit', name: 'Ellen Swimsuit', characterId: 'ellen', isActive: false);

/// A library whose every read waits on the next completer in [scans], so a test decides when a scan finishes.
class _ScanOnDemand extends LibraryNotifier {
  _ScanOnDemand(this.scans);

  final List<Completer<List<ModInfo>>> scans;

  @override
  FutureOr<List<ModInfo>> build() {
    final scan = Completer<List<ModInfo>>();
    scans.add(scan);
    return scan.future;
  }
}

/// How an install reports itself.
///
/// The rule under test is editorial rather than mechanical: **a success says
/// that the mod arrived and names it, and says nothing else.** What the install
/// also did — filed it under a character, copied a description and a gallery off
/// the mod page — is visible on the card a second later, and putting it in the
/// notification made the one fact the user was waiting for the hardest line to
/// find.
void main() {
  late ProviderContainer container;
  List<AppNotification> raised() => container.read(notificationsProvider);
  NotificationCenter center() => container.read(notificationsProvider.notifier);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// Reports [result], into the Working card [into] raises in the same press when given. Raised there rather than
  /// before, since its spinner would keep the harness from settling.
  Future<void> report(
    WidgetTester tester,
    InstallResult result, {
    NotificationHandle Function()? into,
    String? characterId,
  }) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showInstallResult(context, result, into: into?.call(), characterId: characterId),
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
  }

  testWidgets('a clean install names the mod that arrived', (tester) async {
    await report(tester, InstallResult.success(['Ellen Swimsuit']));

    expect(raised(), hasLength(1));
    expect(raised().single.kind, NotificationKind.done);
    expect(raised().single.title, 'Mod installed');
    expect(raised().single.body, 'Ellen Swimsuit');
  });

  testWidgets('several mods are counted and named together, with no portrait and no Open', (tester) async {
    await report(tester, InstallResult.success(['Ellen A', 'Ellen B'], characterId: 'ellen'));
    expect(raised().single.title, '2 mods installed');
    expect(find.text('Ellen A and Ellen B'), findsOneWidget);
    expect(raised().single.characterId, isNull);
    expect(raised().single.actions, isEmpty);
  });

  testWidgets('an archive of three folders and one more mod read "4 mods installed"', (tester) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () {
            showInstallResult(context, InstallResult.success(['A', 'B', 'C']));
            showInstallResult(context, InstallResult.success(['D']));
          },
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    expect(raised().single.title, '4 mods installed');
    expect(find.text('A, B and 2 more'), findsOneWidget);
  });

  testWidgets('the character travels to the card', (tester) async {
    await report(
      tester,
      InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'),
    );
    expect(raised().single.characterId, 'ellen');
  });

  testWidgets('Open on a mod no longer in the library goes nowhere, and says so', (tester) async {
    container.dispose();
    container = ProviderContainer(overrides: [libraryOf(const [])]);
    container.read(destinationProvider.notifier).state = AppDestination.browse;
    await report(
      tester,
      InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(container.read(destinationProvider), AppDestination.browse);
    expect(container.read(selectedModIdProvider), isNull);
    expect(raised().single.kind, NotificationKind.note);
    expect(raised().single.title, 'No longer in the library');
    expect(raised().single.body, 'Ellen Swimsuit');
  });

  testWidgets('Open shows the installed mod in the Characters view, its details panel open', (tester) async {
    container.dispose();
    container = ProviderContainer(overrides: [libraryOf([swimsuit])]);
    container.read(destinationProvider.notifier).state = AppDestination.browse;
    await report(
      tester,
      InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(container.read(destinationProvider), AppDestination.characters);
    expect(container.read(selectedCharacterIdProvider), 'ellen');
    expect(container.read(selectedModIdProvider), 'Ellen Swimsuit');
    expect(container.read(openModPageProvider), isNull);
    expect(raised(), isEmpty, reason: 'pressing an action closes its card');
  });

  testWidgets('Open during the scan the install started waits for it, and finds the mod', (tester) async {
    // The install card is raised before the scan that reads the new mod has finished; the list in hand predates it.
    final scans = <Completer<List<ModInfo>>>[];
    container.dispose();
    container = ProviderContainer(overrides: [libraryProvider.overrideWith(() => _ScanOnDemand(scans))]);
    final keep = container.listen(modsProvider, (_, _) {});
    addTearDown(keep.close);
    scans.last.complete(const []);
    await tester.pump();
    container.read(destinationProvider.notifier).state = AppDestination.browse;

    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () {
            showInstallResult(context, InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'));
            // What DownloadQueueHost does right after.
            container.invalidate(libraryProvider);
          },
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(destinationProvider), AppDestination.browse, reason: 'still waiting for the scan');
    expect(raised(), isEmpty, reason: 'the card closed on the press, and no note is raised while the scan runs');

    scans.last.complete([swimsuit]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(destinationProvider), AppDestination.characters);
    expect(container.read(selectedModIdProvider), 'Ellen Swimsuit');
    expect(raised(), isEmpty, reason: 'no "No longer in the library" note');
  });

  testWidgets('what needs acting on arrives as its own warning', (tester) async {
    // Beside the success, not under it: a mod that arrived broken must not be
    // reported in the same breath, and the same colour, as one that is ready to
    // use.
    await report(
      tester,
      InstallResult.success(
        ['Half A Mod'],
        warnings: const [
          NotificationLines(
            'The mod may be incomplete',
            'No .ini file was found in Half A Mod.',
          ),
        ],
      ),
    );

    expect(raised(), hasLength(2));
    expect(raised().last.kind, NotificationKind.done);
    expect(raised().last.title, 'Mod installed');
    expect(raised().first.kind, NotificationKind.warning);
    expect(raised().first.title, 'The mod may be incomplete');
  });

  testWidgets('a staying line has no clock', (tester) async {
    await report(
      tester,
      InstallResult.success(
        ['Half A Mod'],
        warnings: const [NotificationLines('Patch needs its mod', 'Half A Mod', stays: true)],
      ),
    );
    expect(raised().first.stays, isTrue);
    expect(raised().first.hasClock, isFalse);
  });

  testWidgets("a patch line carries the target's portrait, not the download's", (tester) async {
    await report(
      tester,
      InstallResult.success(
        ['Ellen Fix'],
        characterId: 'ellen',
        warnings: const [
          NotificationLines('Patch applied', 'Into Miyabi Kimono', kind: NotificationKind.done, characterId: 'miyabi'),
        ],
      ),
    );
    expect(raised().first.characterId, 'miyabi');
    expect(raised().last.characterId, 'ellen');
  });

  testWidgets('a lone job\'s Working card becomes its result in place', (tester) async {
    late NotificationHandle working;
    await report(
      tester,
      InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'),
      into: () => working = center().working('Installing…', body: 'Ellen Swimsuit', characterId: 'ellen'),
    );

    expect(raised().single.id, working.id);
    expect(raised().single.kind, NotificationKind.done);
    expect(raised().single.title, 'Mod installed');
    expect(raised().single.progress, isNull);
  });

  testWidgets('a lone job\'s failure takes its Working card too', (tester) async {
    late NotificationHandle working;
    await report(
      tester,
      InstallResult.error("Couldn't extract the archive", 'The file is still on disk.'),
      into: () => working = center().working('Installing…', body: 'Ellen Swimsuit'),
      characterId: 'ellen',
    );

    expect(raised().single.id, working.id);
    expect(raised().single.kind, NotificationKind.error);
    expect(raised().single.characterId, 'ellen');
  });

  testWidgets('a cancelled install takes its Working card away', (tester) async {
    await report(tester, InstallResult.cancelled(),
        into: () => center().working('Installing…', body: 'Ellen Swimsuit'));
    expect(raised(), isEmpty);
  });

  testWidgets('three installs give one "3 mods installed" card', (tester) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () {
            for (final name in ['A', 'B', 'C']) {
              showInstallResult(context, InstallResult.success([name], characterId: 'ellen'));
            }
          },
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();

    expect(raised().single.title, '3 mods installed');
    expect(raised().single.subjects, ['A', 'B', 'C']);
    expect(find.text('A, B and 1 more'), findsOneWidget);
  });

  testWidgets('an install that produced nothing new is a note', (tester) async {
    await report(
      tester,
      InstallResult.note('Nothing imported', 'The mod may already exist.'),
      characterId: 'ellen',
    );
    expect(raised().single.kind, NotificationKind.note);
    expect(raised().single.title, 'Nothing imported');
    expect(raised().single.characterId, 'ellen');
  });

  testWidgets('a failure is an error', (tester) async {
    await report(
      tester,
      InstallResult.error(
        "Couldn't extract the archive",
        'The file is still on disk.',
      ),
    );
    expect(raised().single.kind, NotificationKind.error);
    expect(raised().single.title, "Couldn't extract the archive");
    expect(raised().single.body, 'The file is still on disk.');
  });

  testWidgets('a cancelled install says nothing at all', (tester) async {
    // The user pressed cancel; they know.
    await report(tester, InstallResult.cancelled());
    expect(raised(), isEmpty);
  });
}
