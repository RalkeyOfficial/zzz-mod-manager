import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/utils/url_utils.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';

/// Which page a mod's link opens, and whether it is offered at all.
///
/// One answer, derived from the mod the folder is tracked against. The link was
/// a field of its own — typed by the user, read by nothing else, and a second
/// opinion on the question the origin block exists to answer.
void main() {
  ModOrigin origin({int? modId}) => ModOrigin(
        source: 'gamebanana',
        provenance: OriginProvenance.importedFolder,
        downloads: [
          ModDownload(
            modId: modId,
            modIdConfidence:
                modId == null ? OriginConfidence.unknown : OriginConfidence.user,
          ),
        ],
      );

  ModInfo mod({ModOrigin? origin}) => ModInfo(
        id: 'Ellen Swimsuit',
        name: 'Ellen Swimsuit',
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  group('which url', () {
    test('the mod this folder is tracked against names the page', () {
      expect(
        modPageUrl(mod(origin: origin(modId: 549029))),
        'https://gamebanana.com/mods/549029',
      );
    });

    test('a mod nothing knows about has no page', () {
      expect(modPageUrl(mod()), isNull);
      expect(modPageUrl(mod(origin: origin())), isNull);
    });

    test('a patch on top does not change which page the folder belongs to', () {
      // The base layer is what the folder *is*. A patch modifies the mod; it
      // does not make the folder belong to the patch's page.
      final stacked = ModOrigin(
        source: 'gamebanana',
        provenance: OriginProvenance.importedFolder,
        downloads: const [
          ModDownload(modId: 549029, modIdConfidence: OriginConfidence.user),
          ModDownload(
            role: DownloadRole.patch,
            modId: 601234,
            modIdConfidence: OriginConfidence.user,
          ),
        ],
      );

      expect(modPageUrl(mod(origin: stacked)),
          'https://gamebanana.com/mods/549029');
    });
  });

  group('the details panel', () {
    Future<void> pump(WidgetTester tester, ModInfo m) async {
      await pumpLocalized(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: ModDetailsPanel(
            mod: m,
            onClose: () {},
            onToggle: () {},
            onFavoriteToggle: () {},
            onEdit: () {},
            onOpenFolder: () {},
            onCheckForUpdate: () {},
            onResolveOrigin: () {},
            onDelete: () {},
            noteWriter: (_, _) async => true,
          ),
        ),
        // Held in memory: the panel's size row reads the library, and a real scan would reach ApiService.
        overrides: [libraryOf([m])],
        surfaceSize: const Size(1200, 2400),
      );
      expectBuilt(ModDetailsPanel);
    }

    /// The tracking row's label, as the press it is: a link has a tap handler between it and the panel, plain text
    /// has none.
    bool isLink(WidgetTester tester, String label) {
      final presses = find.ancestor(
        of: find.descendant(of: find.byType(ModDetailsPanel), matching: find.text(label)),
        matching: find.byType(GestureDetector),
      );
      return tester.widgetList<GestureDetector>(presses).any((g) => g.onTap != null);
    }

    // The link is the symptom: a mod the app checks for updates every time,
    // on a page it plainly knows, with no way to open it.
    testWidgets('links the page for a mod known only by its id',
        (tester) async {
      await pump(tester, mod(origin: origin(modId: 549029)));

      expect(find.text('GameBanana'), findsOneWidget);
      expect(isLink(tester, 'GameBanana'), isTrue, reason: 'the tracking row opens the mod page');
      expect(find.text('Not tracked'), findsNothing);
    });

    testWidgets('offers no page for a mod with none at all', (tester) async {
      await pump(tester, mod(origin: origin()));

      expect(find.text('GameBanana'), findsNothing);
      expect(find.text('Not tracked'), findsOneWidget);
      expect(isLink(tester, 'Not tracked'), isFalse);
    });

    testWidgets('a mod the user marked as their own says Local, and links nothing', (tester) async {
      final local = ModOrigin(
        source: 'gamebanana',
        provenance: OriginProvenance.importedFolder,
        tracking: OriginTracking.off,
        downloads: const [ModDownload(modId: 549029, modIdConfidence: OriginConfidence.user)],
      );
      await pump(tester, mod(origin: local));

      expect(find.text('GameBanana'), findsNothing);
      final label = find.descendant(of: find.byType(ModDetailsPanel), matching: find.text('Local'));
      expect(label, findsWidgets);
      expect(isLink(tester, 'Local'), isFalse, reason: 'a page the user opted out of is not offered');
    });
  });
}
