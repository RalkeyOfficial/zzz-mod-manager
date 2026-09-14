import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_card_widget.dart';
import 'package:mod_manager_flutter/utils/url_utils.dart';

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

  group('the card', () {
    Future<void> pump(WidgetTester tester, ModInfo m) => pumpLocalized(
          tester,
          Center(
            child: SizedBox(
              width: 220,
              height: 260,
              child: ModCardWidget(
                mod: m,
                isDarkMode: true,
                onFavoriteToggle: () {},
                onShowDetails: () {},
                onOpenLink: () {},
              ),
            ),
          ),
        );

    // The button is the symptom: a mod the app checks for updates every time,
    // on a page it plainly knows, with no way to open it.
    testWidgets('offers the link for a mod known only by its id',
        (tester) async {
      await pump(tester, mod(origin: origin(modId: 549029)));
      expectBuilt(ModCardWidget);

      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    });

    testWidgets('offers nothing for a mod with no page at all', (tester) async {
      await pump(tester, mod(origin: origin()));

      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });
  });
}
