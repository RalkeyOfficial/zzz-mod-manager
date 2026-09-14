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
/// Two fields can answer it — the user's `source_url` and the origin block's
/// `mod_id` — and the surfaces that offer the link used to read only the first.
/// So a mod resolved through the dialog's search box, which writes only an id,
/// is the case every assertion here is about.
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

  ModInfo mod({String? sourceUrl, ModOrigin? origin}) => ModInfo(
        id: 'Ellen Swimsuit',
        name: 'Ellen Swimsuit',
        characterId: 'ellen',
        isActive: false,
        sourceUrl: sourceUrl,
        origin: origin,
      );

  group('which url', () {
    test('the user\'s own link wins, whatever the origin block says', () {
      // `source_url` is editable and `mod_id` is not, so a user who has
      // corrected the link must not be overruled by the handle behind it.
      expect(
        modPageUrl(mod(
          sourceUrl: 'https://example.com/my-mirror',
          origin: origin(modId: 549029),
        )),
        'https://example.com/my-mirror',
      );
    });

    test('an id with no link opens the page the id names', () {
      expect(
        modPageUrl(mod(origin: origin(modId: 549029))),
        'https://gamebanana.com/mods/549029',
      );
    });

    test('a blank link is not a link', () {
      // The edit dialog writes a trimmed empty string rather than null when the
      // field is cleared, so "" and "   " have to fall through to the id.
      expect(modPageUrl(mod(sourceUrl: '', origin: origin(modId: 549029))),
          'https://gamebanana.com/mods/549029');
      expect(modPageUrl(mod(sourceUrl: '   ', origin: origin(modId: 549029))),
          'https://gamebanana.com/mods/549029');
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
