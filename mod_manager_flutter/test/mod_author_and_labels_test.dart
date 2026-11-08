import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/services/installed_record.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// A mod's author is the one stored in its sidecar, else the page the session holds; and the user's names for its keys
/// replace the sections' own (`docs/library-screen.md` §12, `docs/key-editing.md` §2).
void main() {
  const page = GbMod(idRow: 100, name: 'Maid', submitter: GbSubmitter(idRow: 1, name: ' Frostbyte '));

  ModInfo mod({String? author, List<KeybindInfo>? keybinds, bool tracked = false}) => ModInfo(
    id: 'Winter Maid',
    name: 'Winter Maid',
    characterId: 'ellen',
    isActive: false,
    author: author,
    keybinds: keybinds,
    origin: tracked ? originFixture(modId: 100, modIdConfidence: OriginConfidence.exact) : null,
  );

  group('modAuthor', () {
    test('the stored author wins over the page\'s submitter', () {
      expect(modAuthor(mod(author: 'Me'), page), 'Me');
    });

    test('a blank stored author falls back to the page, trimmed', () {
      expect(modAuthor(mod(author: '  '), page), 'Frostbyte');
      expect(modAuthor(mod(), page), 'Frostbyte');
    });

    test('is null with neither', () {
      expect(modAuthor(mod(), null), isNull);
      expect(modAuthor(mod(), const GbMod(idRow: 100)), isNull);
    });
  });

  group('the details panel', () {
    Future<void> pumpPanel(
      WidgetTester tester,
      ModInfo subject, {
      Map<String, Map<String, String>> labels = const {},
      bool withPage = false,
    }) async {
      final container = ProviderContainer(
        overrides: [
          libraryOf([subject]),
          modKeysProvider.overrideWith((ref) => labels),
          if (withPage) fetchedModPagesProvider.overrideWith((ref) => {100: page}),
        ],
      );
      addTearDown(container.dispose);
      await pumpLocalized(
        tester,
        ModDetailsPanel(
          mod: subject,
          onClose: () {},
          onOpenPage: (_) {},
          onToggle: () {},
          onFavoriteToggle: () {},
          onEdit: () {},
          onOpenFolder: () {},
          onCheckForUpdate: () {},
          onResolveOrigin: () {},
          onDelete: (_) async {},
          noteWriter: (_, _) async => true,
        ),
        container: container,
        surfaceSize: const Size(1200, 1600),
      );
      expectBuilt(ModDetailsPanel);
    }

    testWidgets('shows a stored author with no page held, as plain text when there is nowhere to link', (tester) async {
      await pumpPanel(tester, mod(author: 'frostbyte'));

      expect(find.textContaining('frostbyte', findRichText: true), findsOneWidget);
    });

    testWidgets('shows the page\'s submitter when nothing is stored', (tester) async {
      await pumpPanel(tester, mod(tracked: true), withPage: true);

      expect(find.textContaining('Frostbyte', findRichText: true), findsOneWidget);
    });

    testWidgets('shows the stored author over the page\'s submitter', (tester) async {
      await pumpPanel(tester, mod(author: 'Me', tracked: true), withPage: true);

      expect(find.textContaining('Me', findRichText: true), findsWidgets);
      expect(find.textContaining('Frostbyte', findRichText: true), findsNothing);
    });

    testWidgets('names a key by the user\'s label, and by the section when there is none', (tester) async {
      final keys = [
        KeybindInfo(section: 'KeyCoat', keys: const {'key': 'alt 1'}, file: 'mod.ini'),
        KeybindInfo(section: 'KeyHair', keys: const {'key': 'ctrl 2'}, file: 'mod.ini'),
      ];
      await pumpPanel(
        tester,
        mod(keybinds: keys),
        labels: {
          'Winter Maid': {'keycoat': 'Coat on / off'},
        },
      );

      expect(find.text('Coat on / off'), findsOneWidget);
      expect(find.text('Coat'), findsNothing);
      expect(find.text('Hair'), findsOneWidget);
    });
  });
}
