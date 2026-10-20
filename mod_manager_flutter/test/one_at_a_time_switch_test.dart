import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// The toolbar's One at a time switch for the character on screen (`docs/library-screen.md` §10): it shows the
/// saved choice, and changes only once the change is saved.
void main() {
  late ProviderContainer container;
  late List<(String, bool)> writes;

  Future<void> pumpToolbar(WidgetTester tester, Future<bool> Function() result) async {
    container = ProviderContainer(overrides: [
      libraryOf([ModInfo(id: 'Winter Maid', name: 'Winter Maid', characterId: 'ellen', isActive: false)]),
    ]);
    addTearDown(container.dispose);
    container.read(selectedCharacterIdProvider.notifier).state = 'ellen';
    writes = [];

    await pumpLocalized(
      tester,
      ModsToolbar(
        oneAtATimeWriter: (groupId, on) {
          writes.add((groupId, on));
          return result();
        },
      ),
      container: container,
    );
    expectBuilt(ModsToolbar);
  }

  Finder theSwitch() => find.descendant(of: find.byType(ModsToolbar), matching: find.byType(ZenithSwitch));

  bool shown(WidgetTester tester) => tester.widget<ZenithSwitch>(theSwitch()).value;

  testWidgets('is on by default for an agent', (tester) async {
    await pumpToolbar(tester, () async => true);
    expect(shown(tester), isTrue);
    expect(find.text('One at a time'), findsOneWidget);
  });

  testWidgets('a saved change is published, and the switch follows it', (tester) async {
    final saved = Completer<bool>();
    await pumpToolbar(tester, () => saved.future);

    await tester.tap(theSwitch());
    await tester.pump();
    expect(writes, [('ellen', false)]);
    expect(container.read(oneAtATimeProvider), isEmpty, reason: 'nothing is published before the write is done');
    expect(shown(tester), isTrue);

    saved.complete(true);
    await tester.pumpAndSettle();
    expect(container.read(oneAtATimeProvider), {'ellen': false});
    expect(shown(tester), isFalse);
    expect(find.text('One at a time not saved'), findsNothing);
  });

  testWidgets('a change that is not saved leaves the switch as it was, and says so', (tester) async {
    await pumpToolbar(tester, () async => false);

    await tester.tap(theSwitch());
    await tester.pumpAndSettle();

    expect(writes, [('ellen', false)]);
    expect(container.read(oneAtATimeProvider), isEmpty);
    expect(shown(tester), isTrue);
    expect(find.text('One at a time not saved'), findsOneWidget);
    expect(find.descendant(of: find.byType(NotificationOverlay), matching: find.text('Ellen Joe')), findsOneWidget);
  });
}
