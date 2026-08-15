import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/install_result_feedback.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// How an install reports itself.
///
/// The rule under test is editorial rather than mechanical: **a success says
/// that the mod arrived and nothing else.** What the install also did — filed it
/// under a character, copied a description and a gallery off the mod page — is
/// visible on the card a second later, and putting it in the notification made
/// the one fact the user was waiting for the hardest line to find.
void main() {
  late ProviderContainer container;
  List<AppNotification> raised() => container.read(notificationsProvider);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  Future<void> report(WidgetTester tester, InstallResult result) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showInstallResult(context, result),
          child: const Text('report'),
        ),
      ),
      container: container,
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
  }

  testWidgets('a clean install is one line', (tester) async {
    await report(tester, InstallResult.success(['Ellen Swimsuit']));

    expect(raised(), hasLength(1));
    expect(raised().single.severity, NotificationSeverity.success);
    expect(raised().single.message, 'Installed Ellen Swimsuit');
    expect(raised().single.title, isNull,
        reason: 'nothing to put above a single sentence');
  });

  testWidgets('several mods are named in that same line', (tester) async {
    await report(tester, InstallResult.success(['Ellen A', 'Ellen B']));
    expect(raised().single.message, 'Installed Ellen A, Ellen B');
  });

  testWidgets('what needs acting on arrives as its own warning',
      (tester) async {
    // Beside the success, not under it: a mod that arrived broken must not be
    // reported in the same breath, and the same colour, as one that is ready to
    // use. As snackbars this was impossible — the second message replaced the
    // first, so a warning cost you the confirmation.
    await report(
      tester,
      InstallResult.success(
        ['Half A Mod'],
        message: 'No .ini found in Half A Mod — the mod may be incomplete.',
      ),
    );

    expect(raised(), hasLength(2));
    expect(raised().first.severity, NotificationSeverity.success);
    expect(raised().first.message, 'Installed Half A Mod');
    expect(raised().last.severity, NotificationSeverity.warning);
    expect(raised().last.message, contains('No .ini found'));
  });

  testWidgets('an install that produced nothing is a warning on its own',
      (tester) async {
    await report(tester, InstallResult.warning('Nothing imported.'));
    expect(raised().single.severity, NotificationSeverity.warning);
  });

  testWidgets('a failure is an error', (tester) async {
    await report(tester, InstallResult.error('Archive is not supported.'));
    expect(raised().single.severity, NotificationSeverity.error);
    expect(raised().single.message, 'Archive is not supported.');
  });

  testWidgets('a cancelled install says nothing at all', (tester) async {
    // The user pressed cancel; they know.
    await report(tester, InstallResult.cancelled());
    expect(raised(), isEmpty);
  });
}
