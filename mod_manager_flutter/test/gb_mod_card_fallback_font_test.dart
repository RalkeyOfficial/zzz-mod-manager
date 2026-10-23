import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/localized_harness.dart';

/// The card's text block under a fallback font.
///
/// A glyph Geist lacks, such as a Chinese title or author, is drawn from another font, and a line holding two fonts
/// with different ascents grows past its style's height. The block's height is fixed, so the card must keep each
/// line at its style's height. On Linux the system's Noto Sans CJK grows the title and the byline a pixel each, a
/// 2px overflow. Here the test font stands in as the fallback beside the real Geist; it grows the title by a pixel
/// for these glyphs. The test is in its own file since the loaded fonts stay for the rest of the isolate.
void main() {
  const title = 'Ellen Maid Outfit 中文';
  const author = '名前';

  for (final brightness in Brightness.values) {
    for (final (state, installedAs, overrides) in <(String, List<String>, List<Override>)>[
      ('Install', const [], const []),
      ('Queued', const [], [marketplacePendingInstallsProvider.overrideWith((ref) => {1})]),
      ('In library', const ['Ellen'], const []),
      (
        'Update',
        const ['Ellen'],
        [
          modUpdateChecksProvider.overrideWith(
            (ref) => {'Ellen': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)},
          ),
        ],
      ),
    ]) {
      testWidgets('$state on ${brightness.name}: a Chinese title and author fit the 264.5px card', (tester) async {
        await loadTableFonts(tester);
        await pumpLocalized(
          tester,
          Center(
            child: Builder(
              builder: (context) {
                final theme = Theme.of(context);
                return Theme(
                  data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const ['FlutterTest'])),
                  child: Builder(
                    builder: (context) => SizedBox(
                      width: 264.5,
                      height: GbModCard.extentFor(context, 264.5),
                      child: GbModCard(
                        mod: GbMod(
                          idRow: 1,
                          name: title,
                          likeCount: 1200,
                          submitter: const GbSubmitter(idRow: 2, name: author),
                          dateAdded: DateTime.now().subtract(const Duration(days: 30)),
                        ),
                        treatment: ContentTreatment.show,
                        installedAs: installedAs,
                        onOpen: () {},
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          overrides: overrides,
          brightness: brightness,
        );
        expectBuilt(GbModCard);

        expect(tester.takeException(), isNull);
        expect(find.text(state), findsOneWidget);
        // titleSmall's 14 × 1.35 and bodySmall's 12 × 1.4, each rounded up to whole pixels.
        expect(tester.getSize(find.text(title)).height, 19);
        expect(tester.getSize(find.textContaining(author)).height, 17);
      });
    }
  }
}
