import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/app_notification.dart';
import 'package:mod_manager_flutter/models/install_result.dart';
import 'package:mod_manager_flutter/screens/components/install_result_feedback.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

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

  testWidgets('a clean install names the mod that arrived', (tester) async {
    await report(tester, InstallResult.success(['Ellen Swimsuit']));

    expect(raised(), hasLength(1));
    expect(raised().single.severity, NotificationSeverity.success);
    expect(raised().single.title, 'Mod installed');
    expect(raised().single.body, 'Ellen Swimsuit');
  });

  testWidgets('several mods are named together, under a plural headline',
      (tester) async {
    await report(tester, InstallResult.success(['Ellen A', 'Ellen B']));
    expect(raised().single.title, 'Mods installed');
    expect(raised().single.body, 'Ellen A, Ellen B');
  });

  testWidgets('the character travels to the card', (tester) async {
    // One archive comes from one mod page, so a result naming five folders
    // still has one character to lead with.
    await report(
      tester,
      InstallResult.success(['Ellen Swimsuit'], characterId: 'ellen'),
    );
    expect(raised().single.characterId, 'ellen');
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
        warnings: const [
          NotificationLines(
            'The mod may be incomplete',
            'No .ini file was found in Half A Mod.',
          ),
        ],
      ),
    );

    expect(raised(), hasLength(2));
    expect(raised().last.severity, NotificationSeverity.success);
    expect(raised().last.title, 'Mod installed');
    expect(raised().first.severity, NotificationSeverity.warning);
    expect(raised().first.title, 'The mod may be incomplete');
  });

  testWidgets('three warnings still leave the success on screen',
      (tester) async {
    // Three warnings plus a success is exactly the four-card cap. Raised the
    // other way round the success is the one pushed off — and it is the line
    // that concludes the install.
    await report(
      tester,
      InstallResult.success(
        ['Half A Mod'],
        warnings: const [
          NotificationLines('one', 'a'),
          NotificationLines('two', 'b'),
          NotificationLines('three', 'c'),
        ],
      ),
    );

    expect(raised(), hasLength(kMaxVisibleNotifications));
    expect(raised().last.title, 'Mod installed');
  });

  testWidgets('an install that produced nothing is a warning on its own',
      (tester) async {
    await report(
      tester,
      InstallResult.warning('Nothing imported', 'The mod may already exist.'),
    );
    expect(raised().single.severity, NotificationSeverity.warning);
    expect(raised().single.title, 'Nothing imported');
  });

  testWidgets('a failure is an error', (tester) async {
    await report(
      tester,
      InstallResult.error(
        "Couldn't extract the archive",
        'The file is still on disk.',
      ),
    );
    expect(raised().single.severity, NotificationSeverity.error);
    expect(raised().single.title, "Couldn't extract the archive");
    expect(raised().single.body, 'The file is still on disk.');
  });

  testWidgets('a cancelled install says nothing at all', (tester) async {
    // The user pressed cancel; they know.
    await report(tester, InstallResult.cancelled());
    expect(raised(), isEmpty);
  });
}
