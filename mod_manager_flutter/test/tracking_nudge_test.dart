import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/components/tracking_nudge.dart';
import 'package:mod_manager_flutter/screens/dialogs/bulk_resolution_dialog.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The reminder above the toolbar that some mods are not set up for update checking.
void main() {
  late ProviderContainer container;

  ModOrigin tracked() => originFixture(
        source: 'gamebanana',
        modId: 1,
        modIdConfidence: OriginConfidence.user,
        fileId: 10,
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
      );

  ModInfo mod(String name, {ModOrigin? origin, String characterId = 'ellen'}) => ModInfo(
        id: name,
        name: name,
        characterId: characterId,
        isActive: false,
        origin: origin,
      );

  Future<void> pumpToolbar(
    WidgetTester tester,
    List<ModInfo> mods, {
    bool dismissed = false,
    List<bool>? written,
    Size surfaceSize = const Size(1200, 800),
  }) async {
    container = ProviderContainer(overrides: [libraryOf(mods)]);
    addTearDown(container.dispose);
    container.read(selectedCharacterIdProvider.notifier).state = 'ellen';
    container.read(trackingNudgeDismissedProvider.notifier).state = dismissed;

    await pumpLocalized(
      tester,
      LibraryActionsHost(
        updateFetcher: (_) async => throw StateError('no fetch expected'),
        updatesFetcher: (_) async => throw StateError('no fetch expected'),
        originWriter: (_, __) async => OriginWriteResult.writeFailed,
        child: ModsToolbar(
          originWriter: (_, __) async => OriginWriteResult.writeFailed,
          nudgeWriter: (value) async => written?.add(value),
        ),
      ),
      container: container,
      surfaceSize: surfaceSize,
    );
    expectBuilt(ModsToolbar);
  }

  testWidgets('holds together at the minimum window', (tester) async {
    // 800px less the sidebar and the character list.
    await pumpToolbar(
      tester,
      [for (var i = 0; i < 120; i++) mod('mod $i')],
      surfaceSize: const Size(304, 600),
    );

    expect(find.byType(TrackingNudge), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('counts the whole library, not the view', (tester) async {
    // Ellen is on screen; the second untracked mod is Miyabi's.
    await pumpToolbar(tester, [
      mod('bare'),
      mod('also bare', characterId: 'miyabi'),
      mod('fine', origin: tracked()),
    ]);

    expect(find.byType(TrackingNudge), findsOneWidget);
    expect(
      find.text("2 mods aren't set up for update checking"),
      findsOneWidget,
    );
  });

  testWidgets('says nothing when every mod is tracked', (tester) async {
    await pumpToolbar(tester, [mod('fine', origin: tracked())]);

    expect(find.byType(TrackingNudge), findsNothing);
  });

  testWidgets('stays away once dismissed', (tester) async {
    await pumpToolbar(tester, [mod('bare')], dismissed: true);

    expect(find.byType(TrackingNudge), findsNothing);
  });

  testWidgets('its button lists the untracked mods with nothing to check',
      (tester) async {
    // It must never end in a notification that leaves those mods out of reach.
    await pumpToolbar(tester, [mod('bare'), mod('also bare')]);

    await tester.tap(find.descendant(
      of: find.byType(TrackingNudge),
      matching: find.byType(OutlinedButton),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(BulkResolutionDialog), findsOneWidget);
    expect(find.textContaining("2 mods aren't linked to a GameBanana page"),
        findsOneWidget);
  });

  testWidgets('closing it hides it now and writes the dismissal', (tester) async {
    final written = <bool>[];
    await pumpToolbar(tester, [mod('bare')], written: written);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.byType(TrackingNudge), findsNothing);
    expect(container.read(trackingNudgeDismissedProvider), isTrue);
    expect(written, [true]);
  });
}
