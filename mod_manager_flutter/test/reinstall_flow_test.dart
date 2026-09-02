import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/reinstall_flow.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// **Reinstalling the version already installed**, up to the point where it
/// becomes an ordinary update.
///
/// The refusals are what this covers, because they are the only part that is
/// this flow's own: past them it hands the file to `applyUpdateFlow`, which the
/// update tests exercise. And the refusal that matters is the one where the
/// recorded file has gone from the page — substituting the current file there
/// would install a **different version** over a folder the user asked to have
/// put back as it was, which is the failure a repair must never be.
void main() {
  const modId = 531649;
  final profileUrl =
      Uri.parse('https://gamebanana.com/apiv13/Mod/$modId/ProfilePage');

  late TempLibrary library;
  late FakeHttpTransport http;
  bool? changed;

  setUp(() async {
    library = await TempLibrary.create(prefix: 'zzz_reinstall_flow_');
    http = FakeHttpTransport()
      ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'));
    changed = null;
  });

  ModInfo modWith(ModOrigin? origin) => ModInfo(
        id: 'RabbitFX',
        name: 'RabbitFX',
        characterId: 'unknown',
        isActive: false,
        origin: origin,
      );

  /// A folder that knows which mod page and which file it came from.
  ModOrigin tracked({int? fileId}) => originFixture(
        modId: modId,
        modIdConfidence: OriginConfidence.exact,
        fileId: fileId,
      );

  Future<void> press(WidgetTester tester, ModInfo mod) async {
    await pumpLocalized(
      tester,
      Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () async {
            changed = await reinstallFlow(context, ref, mod: mod);
          },
          child: const Text('open'),
        ),
      ),
      overrides: [
        gameBananaClientProvider.overrideWithValue(
          GameBananaClient(transport: http, maxRetries: 0),
        ),
        ...library.overrides,
      ],
    );
    expectBuilt(ElevatedButton);
    await tapWithIo(tester, find.text('open'));
  }

  testWidgets('a file the page no longer carries is refused, not substituted',
      (tester) async {
    // The fixture publishes fourteen files and none of them is 999999 — the
    // ordinary state of a mod whose author has re-uploaded.
    await press(tester, modWith(tracked(fileId: 999999)));

    expect(changed, isFalse);
    expect(find.text("That version isn't on the page any more"), findsOneWidget);
    expect(find.text('RabbitFX?'), findsNothing,
        reason: 'no confirmation, because there is nothing to confirm');
  });

  testWidgets('a mod with no recorded file asks for nothing at all',
      (tester) async {
    // What the menu entry is hidden for. Reaching the network to discover we
    // have no id to look for would be a request the user did not ask for.
    await press(tester, modWith(tracked()));

    expect(changed, isFalse);
    expect(http.requests, isEmpty);
  });

  testWidgets('an untracked folder asks for nothing at all', (tester) async {
    await press(tester, modWith(null));

    expect(changed, isFalse);
    expect(http.requests, isEmpty);
  });

  testWidgets('a page that will not load says so and changes nothing',
      (tester) async {
    // Worth telling apart from the file being gone: this one is worth retrying
    // and that one never is.
    http = FakeHttpTransport()
      ..enqueueError(profileUrl, const SocketFailure());

    await press(tester, modWith(tracked(fileId: 1732269)));

    expect(changed, isFalse);
    expect(find.text("Couldn't reach GameBanana"), findsOneWidget,
        reason: 'this one is worth trying again, and the other never is');
  });
}

/// Stands in for no connectivity.
class SocketFailure implements Exception {
  const SocketFailure();
}
