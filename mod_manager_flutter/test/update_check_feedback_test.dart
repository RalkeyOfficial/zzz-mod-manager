import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/update_check_feedback.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// What a whole-library check says: an Update card with Review when it found something, a warning when some mods
/// could not be reached, and a note when there was nothing to find.
void main() {
  late ProviderContainer container;
  List<AppNotification> raised() => container.read(notificationsProvider);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  BulkUpdateCheckOutcome outcome({int found = 0, int upToDate = 0, Set<String> failed = const {}}) =>
      BulkUpdateCheckOutcome(
        checks: {
          for (var i = 0; i < found; i++) 'new $i': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
          for (var i = 0; i < upToDate; i++) 'same $i': const UpdateCheck(outcome: UpdateOutcome.upToDate),
        },
        failed: failed,
        requests: 1,
      );

  Future<void> report(WidgetTester tester, BulkUpdateCheckOutcome outcome) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showUpdateCheckOutcome(context, outcome),
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
  }

  testWidgets('found updates raise the Update kind, and Review opens the Updates page', (tester) async {
    container.read(openModPageProvider.notifier).state = const ModPageRequest('Ellen Swimsuit');
    await report(tester, outcome(found: 2, upToDate: 3));

    expect(raised().single.kind, NotificationKind.update);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(container.read(destinationProvider), AppDestination.updates);
    expect(container.read(openModPageProvider), isNull, reason: 'a mod page would cover the Updates page');
  });

  testWidgets('nothing found with some mods unreached is a warning', (tester) async {
    await report(tester, outcome(upToDate: 3, failed: {'a'}));
    expect(raised().single.kind, NotificationKind.warning);
    expect(raised().single.actions, isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('nothing found is a note', (tester) async {
    await report(tester, outcome(upToDate: 3));
    expect(raised().single.kind, NotificationKind.note);
    expect(raised().single.actions, isEmpty);
    await tester.pump(const Duration(seconds: 6));
  });
}
