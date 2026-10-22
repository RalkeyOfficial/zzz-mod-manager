import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_mod_card.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_thumbnail.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_update_dialog.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/fixtures.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// The results-grid card, as the Browse artboard draws it.
///
/// Its width is not fixed — auto-fill columns of at least 230px, wider in a wide window — and its height is the 4:3
/// cover plus a fixed text block, so the layout claims are asserted across widths. The button's four states and the
/// one-file Install rule are built on captured `Mod/Multi` responses.
void main() {
  final enrichedP1 = enrichmentByMod(parseBareList(loadGbFixture('mod_multi_enrich_p1'), GbMod.fromJson));
  final enrichedNewest = enrichmentByMod(parseBareList(loadGbFixture('mod_multi_enrich_newest'), GbMod.fromJson));

  GbMod mod({
    int id = 1,
    int? likes = 298000,
    String name = 'Remielle Black & White - OG Variety Pack',
    String? category = 'Alexandrina Sebastiane',
    GbVisibility visibility = GbVisibility.show,
    DateTime? added,
    DateTime? updated,
    bool obsolete = false,
  }) {
    return GbMod(
      idRow: id,
      name: name,
      likeCount: likes,
      visibility: visibility,
      isObsolete: obsolete,
      submitter: const GbSubmitter(idRow: 2, name: 'Outbreaksurvivler'),
      subCategory: category == null ? null : GbCategoryRef(name: category),
      dateAdded: added ?? DateTime.now().subtract(const Duration(days: 800)),
      dateUpdated: updated ?? DateTime.now().subtract(const Duration(days: 3, hours: 2)),
    );
  }

  Future<ProviderContainer> pumpCard(
    WidgetTester tester, {
    required double width,
    required GbMod card,
    double? height,
    GbMod? enrichment,
    ContentTreatment treatment = ContentTreatment.show,
    List<String> installedAs = const <String>[],
    VoidCallback? onOpen,
    void Function(GbFile file)? onInstallFile,
    List<Override> overrides = const [],
    Brightness brightness = Brightness.dark,
    Locale locale = const Locale('en'),
  }) async {
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      Center(
        child: Builder(
          builder: (context) => SizedBox(
            width: width,
            // The grid's own extent for this width, unless a test squeezes it.
            height: height ?? GbModCard.extentFor(context, width),
            child: GbModCard(
              mod: card,
              treatment: treatment,
              enrichment: enrichment,
              onOpen: onOpen ?? () {},
              installedAs: installedAs,
              onInstallFile: onInstallFile,
            ),
          ),
        ),
      ),
      container: container,
      brightness: brightness,
      locale: locale,
    );
    expectBuilt(GbModCard);
    return container;
  }

  group('the text block keeps its height at any width', () {
    for (final width in <double>[230, 260, 300, 400]) {
      testWidgets('${width.toInt()}px, without overflow and with a 4:3 cover', (tester) async {
        await pumpCard(tester, width: width, card: mod(), enrichment: enrichedP1[533785]);
        expect(tester.takeException(), isNull, reason: 'card overflowed at ${width}px');

        final cover = tester.getSize(find.byType(GbThumbnail));
        expect(cover.width, moreOrLessEquals(width - 2, epsilon: 0.5));
        expect(cover.height, moreOrLessEquals((width - 2) * 3 / 4, epsilon: 1));
        expect(find.text('Install'), findsOneWidget);
      });
    }

    testWidgets('a blurred cover at 230px still fits', (tester) async {
      await pumpCard(
        tester,
        width: 230,
        card: mod(visibility: GbVisibility.warn),
        treatment: ContentTreatment.blur,
        installedAs: const ['Ellen'],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('stats', () {
    testWidgets('downloads come from the enrichment', (tester) async {
      await pumpCard(tester, width: 300, card: mod(id: 533785), enrichment: enrichedP1[533785]);
      expect(find.text('298.0k'), findsOneWidget, reason: 'likes');
      expect(find.text('151.1k'), findsOneWidget, reason: 'the captured download count');
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    });

    testWidgets('no enrichment, no download count — never a zero', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      expect(find.byIcon(Icons.download_rounded), findsNothing);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a real zero from the enrichment is shown', (tester) async {
      // Mod 730505 was a day old when captured and had no downloads yet: a number, not an unknown.
      await pumpCard(tester, width: 300, card: mod(id: 730505), enrichment: enrichedNewest[730505]);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    });
  });

  group('the byline', () {
    testWidgets('reads the author and the update age in words', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      expect(find.text('Outbreaksurvivler · updated 3 days ago'), findsOneWidget);
    });

    testWidgets('a mod never updated reads its release age', (tester) async {
      final added = DateTime.now().subtract(const Duration(days: 15));
      await pumpCard(
        tester,
        width: 300,
        card: mod(added: added, updated: added),
      );
      expect(find.text('Outbreaksurvivler · added 2 weeks ago'), findsOneWidget);
    });
  });

  group('the cover', () {
    testWidgets('names the character at its top-right', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      final cover = tester.getRect(find.byType(GbThumbnail));
      final badge = tester.getRect(find.text('Alexandrina Sebastiane'));
      expect(badge.right, lessThanOrEqualTo(cover.right - 10));
      expect(badge.center.dx, greaterThan(cover.center.dx));
      expect(badge.top, lessThan(cover.center.dy));
    });

    testWidgets('a mod the library has reads Installed, filled in the accent', (tester) async {
      await pumpCard(tester, width: 300, card: mod(), installedAs: const ['Ellen', 'Ellen (NSFW)']);
      expect(find.text('Installed'), findsOneWidget);
      expect(find.byTooltip('In your library as Ellen, Ellen (NSFW)'), findsOneWidget);

      final box = tester.widget<Container>(
        find.ancestor(of: find.text('Installed'), matching: find.byType(Container)).first,
      );
      final palette = ZenithPalette.dark(AccentChoice.violet);
      expect((box.decoration! as BoxDecoration).color, palette.accent);
    });

    testWidgets('a newer file reads Update ready in amber instead', (tester) async {
      await pumpCard(
        tester,
        width: 300,
        card: mod(),
        installedAs: const ['Ellen'],
        overrides: [
          modUpdateChecksProvider.overrideWith(
            (ref) => {'Ellen': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)},
          ),
        ],
      );
      expect(find.text('Update ready'), findsOneWidget);
      expect(find.text('Installed'), findsNothing);
      final box = tester.widget<Container>(
        find.ancestor(of: find.text('Update ready'), matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).color, ZenithPalette.dark(AccentChoice.violet).badgeUpdate.background);
    });

    testWidgets('a possibly outdated mod reads Installed, not Update ready', (tester) async {
      // A guess is the Library's to raise; Browse claims an update only when a newer file is confirmed.
      await pumpCard(
        tester,
        width: 300,
        card: mod(),
        installedAs: const ['Ellen'],
        overrides: [
          modUpdateChecksProvider.overrideWith(
            (ref) => {'Ellen': const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated, isGuess: true)},
          ),
        ],
      );
      expect(find.text('Installed'), findsOneWidget);
      expect(find.text('Update ready'), findsNothing);
    });

    testWidgets('an obsolete mod says so beside Installed', (tester) async {
      await pumpCard(tester, width: 300, card: mod(obsolete: true), installedAs: const ['Ellen']);
      final installed = tester.getRect(
        find.ancestor(of: find.text('Installed'), matching: find.byType(Container)).first,
      );
      final obsolete = tester.getRect(
        find.ancestor(of: find.text('Obsolete'), matching: find.byType(Container)).first,
      );
      expect(obsolete.width, greaterThan(0));
      expect(obsolete.height, 22);
      expect(obsolete.top, installed.top);
      expect(obsolete.left, moreOrLessEquals(installed.right + 6, epsilon: 0.5));
    });

    testWidgets('the veil is painted over the whole cover', (tester) async {
      await pumpCard(
        tester,
        width: 300,
        card: mod(visibility: GbVisibility.warn),
        treatment: ContentTreatment.blur,
      );
      final scrim = ZenithPalette.dark(AccentChoice.violet).artworkScrim;
      final veil = find.descendant(
        of: find.byType(GbModCard),
        matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == scrim),
      );
      expect(veil, findsOneWidget);
      expect(tester.getRect(veil), tester.getRect(find.byType(GbThumbnail)));
    });

    testWidgets('on paper, what is drawn over the art keeps its ink colours', (tester) async {
      await pumpCard(
        tester,
        // Wide enough for the character beside both badges in the test font, which draws every glyph an em wide.
        width: 400,
        card: mod(visibility: GbVisibility.warn, obsolete: true),
        treatment: ContentTreatment.blur,
        installedAs: const ['Ellen'],
        brightness: Brightness.light,
      );
      final paper = ZenithPalette.light(AccentChoice.violet);
      final ink = ZenithPalette.dark(AccentChoice.violet);
      BoxDecoration badge(String label) =>
          tester.widget<Container>(find.ancestor(of: find.text(label), matching: find.byType(Container)).first).decoration!
              as BoxDecoration;

      expect(badge('Installed').color, paper.accent, reason: 'Installed is still violet on paper');
      expect((badge('Obsolete').border! as Border).top.color, ink.line, reason: 'not the beige paper line');
      expect((badge('Alexandrina Sebastiane').border! as Border).top.color, ink.line);
      expect(tester.widget<Text>(find.text('Mature content')).style?.color, ink.text);
    });

    testWidgets('blur mode veils it, and a click opens the mod rather than revealing', (tester) async {
      var opened = 0;
      await pumpCard(
        tester,
        width: 300,
        card: mod(visibility: GbVisibility.warn),
        treatment: ContentTreatment.blur,
        onOpen: () => opened++,
      );
      expect(find.text('Mature content'), findsOneWidget);
      expect(find.text('Blurred in Settings'), findsOneWidget);

      await tester.tap(find.text('Mature content'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('Mature content'), findsOneWidget, reason: 'the card has no reveal of its own');
    });

    testWidgets('the cover and the name open the mod, the card around them does not', (tester) async {
      var opened = 0;
      await pumpCard(tester, width: 300, card: mod(), onOpen: () => opened++);

      await tester.tap(find.byType(GbThumbnail));
      await tester.tap(find.text('Remielle Black & White - OG Variety Pack'));
      await tester.pumpAndSettle();
      expect(opened, 2);

      // The stats row is part of the card and opens nothing.
      await tester.tap(find.text('298.0k'));
      await tester.pumpAndSettle();
      expect(opened, 2);
    });
  });

  group('the button', () {
    testWidgets('Install queues the one current file straight away', (tester) async {
      // Mod 730505 publishes exactly one file in the captured response.
      GbFile? queued;
      var opened = 0;
      await pumpCard(
        tester,
        width: 300,
        card: mod(id: 730505),
        enrichment: enrichedNewest[730505],
        onOpen: () => opened++,
        onInstallFile: (file) => queued = file,
      );

      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Install'));
      expect(button.onPressed, isNotNull);
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(queued?.idRow, 1858310);
      expect(opened, 0);
    });

    testWidgets('Install opens the mod page when there are several current files', (tester) async {
      // Mod 541825 lists four current files and four archived ones — the archived ones do not make it ambiguous,
      // the four current ones do.
      GbFile? queued;
      var opened = 0;
      await pumpCard(
        tester,
        width: 300,
        card: mod(id: 541825),
        enrichment: enrichedP1[541825],
        onOpen: () => opened++,
        onInstallFile: (file) => queued = file,
      );
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      expect(queued, isNull, reason: 'a file is never picked for the user');
      expect(opened, 1);
    });

    testWidgets('Install with no enrichment opens the mod page', (tester) async {
      var opened = 0;
      await pumpCard(tester, width: 300, card: mod(), onOpen: () => opened++, onInstallFile: (_) => fail('queued'));
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('Install is the primary fill', (tester) async {
      await pumpCard(tester, width: 300, card: mod());
      final material = tester.widget<Material>(
        find.descendant(of: find.widgetWithText(FilledButton, 'Install'), matching: find.byType(Material)).first,
      );
      expect(material.color, ZenithPalette.dark(AccentChoice.violet).primary);
    });

    testWidgets('Install on paper is the paper primary fill', (tester) async {
      await pumpCard(tester, width: 300, card: mod(), brightness: Brightness.light);
      final material = tester.widget<Material>(
        find.descendant(of: find.widgetWithText(FilledButton, 'Install'), matching: find.byType(Material)).first,
      );
      expect(material.color, ZenithPalette.light(AccentChoice.violet).primary);
    });

    testWidgets('Queued, inert, while the queue holds a job for any file of the mod', (tester) async {
      final job = DownloadJob(
        seq: 1,
        request: DownloadRequest(url: Uri()),
        intent: DownloadIntent.install,
        subject: 'x',
        file: const GbFile(idRow: 99),
        mod: const GbMod(idRow: 7),
        state: DownloadJobState.running,
      );
      await pumpCard(
        tester,
        width: 300,
        card: mod(id: 7),
        overrides: [
          downloadQueueProvider.overrideWith(() => _HeldQueue([job])),
        ],
      );
      final button = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Queued'));
      expect(button.onPressed, isNull);
      expect(find.text('Install'), findsNothing);
      // Inert, but drawn as the default button rather than greyed out.
      final label = tester.widget<RichText>(
        find.descendant(of: find.widgetWithText(OutlinedButton, 'Queued'), matching: find.byType(RichText)),
      );
      expect(label.text.style?.color, ZenithPalette.dark(AccentChoice.violet).text);
    });

    testWidgets('Queued while the mod page is being fetched for the install', (tester) async {
      await pumpCard(
        tester,
        width: 300,
        card: mod(id: 7),
        overrides: [
          marketplacePendingInstallsProvider.overrideWith((ref) => {7}),
        ],
      );
      expect(find.text('Queued'), findsOneWidget);
    });

    testWidgets('In library, ghost, opens the mod in the Characters view', (tester) async {
      final container = await pumpCard(
        tester,
        width: 300,
        card: mod(id: 7),
        installedAs: const ['Ellen Maid'],
        overrides: [
          libraryOf([ModInfo(id: 'Ellen Maid', name: 'Ellen Maid', characterId: 'ellen', isActive: false)]),
        ],
      );
      expect(find.widgetWithText(TextButton, 'In library'), findsOneWidget);

      await tester.tap(find.text('In library'));
      await tester.pumpAndSettle();

      expect(container.read(destinationProvider), AppDestination.characters);
      expect(container.read(selectedModIdProvider), 'Ellen Maid');
    });

    testWidgets('Update when a folder of the mod has a newer file opens that folder\'s update', (tester) async {
      // Both folders are on disk, with a real sidecar for the one with the update, so the dialog's write is the
      // app's own and the rescan after it is the card's.
      final altOrigin = originFixture(
        source: 'gamebanana',
        modId: 531649,
        modIdConfidence: OriginConfidence.user,
        fileId: 1696178,
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
      );
      late TempLibrary temp;
      await tester.runAsync(() async {
        temp = await TempLibrary.create();
        temp.createMod('Ellen');
        temp.createMod('Ellen (alt)');
        await temp.writeOrigin('Ellen (alt)', altOrigin);
      });
      final container = await pumpCard(
        tester,
        width: 300,
        card: mod(id: 7),
        installedAs: const ['Ellen', 'Ellen (alt)'],
        overrides: [
          ...temp.overrides,
          libraryOf([
            ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false),
            ModInfo(id: 'Ellen (alt)', name: 'Ellen (alt)', characterId: 'ellen', isActive: false, origin: altOrigin),
          ]),
          modUpdateChecksProvider.overrideWith(
            (ref) => {
              'Ellen (alt)': UpdateCheck(
                outcome: UpdateOutcome.updateAvailable,
                candidate: GbFile(idRow: 1732269, dateAdded: DateTime.utc(2026, 6, 19)),
              ),
            },
          ),
        ],
      );
      expect(find.text('In library'), findsNothing);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Update'));
      await tester.pumpAndSettle();
      expect(tester.widget<ModUpdateDialog>(find.byType(ModUpdateDialog)).mod.id, 'Ellen (alt)');
      expect(container.read(libraryScansProvider), 0);

      await tapWithIo(tester, find.text('Ignore this update'));
      expect(temp.originOf('Ellen (alt)')?.updatesDismissedUntil, DateTime.utc(2026, 6, 19));

      await tester.tap(find.text('View in marketplace'));
      await tester.pumpAndSettle();
      expect(find.byType(ModUpdateDialog), findsNothing);
      expect(container.read(libraryScansProvider), 1, reason: 'the dialog wrote, so the library is read again');
    });

    testWidgets('a dismissed update is not an Update', (tester) async {
      await pumpCard(
        tester,
        width: 300,
        card: mod(id: 7),
        installedAs: const ['Ellen'],
        overrides: [
          modUpdateChecksProvider.overrideWith(
            (ref) => {'Ellen': const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true)},
          ),
        ],
      );
      expect(find.text('In library'), findsOneWidget);
    });
  });

  testWidgets('relative ages read as words in Ukrainian too', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      Center(
        child: Builder(
          builder: (context) => SizedBox(
            width: 300,
            height: GbModCard.extentFor(context, 300),
            child: GbModCard(mod: mod(), treatment: ContentTreatment.show, onOpen: () {}),
          ),
        ),
      ),
      locale: const Locale('uk'),
      container: container,
    );
    expect(find.text('Outbreaksurvivler · оновлено 3 дні тому'), findsOneWidget);
  });

  // Last in the file: the real fonts stay loaded for every test after the first load, and these measure text.
  group('the cover badges never cover each other', () {
    const character = 'Alexandrina Sebastiane';
    for (final (locale, installed, obsolete) in [
      (const Locale('en'), 'Installed', 'Obsolete'),
      (const Locale('uk'), 'Встановлено', 'Застарілий'),
    ]) {
      for (final width in <double>[230, 276, 400]) {
        testWidgets('${locale.languageCode}, ${width.toInt()}px', (tester) async {
          await loadTableFonts(tester);
          await pumpCard(
            tester,
            width: width,
            card: mod(obsolete: true, category: character),
            installedAs: const ['Ellen'],
            locale: locale,
          );
          expect(tester.takeException(), isNull);

          Rect badge(String label) =>
              tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(Container)).first);
          final cover = tester.getRect(find.byType(GbThumbnail));
          final left = [badge(installed), badge(obsolete)];
          expect(left[0].overlaps(left[1]), isFalse);
          for (final rect in left) {
            expect(rect.left, greaterThanOrEqualTo(cover.left + 10 - 0.5));
            expect(rect.right, lessThanOrEqualTo(cover.right - 10 + 0.5));
          }
          // The character may be cut short, or left out where there is no room; never drawn over the others.
          if (find.text(character).evaluate().isNotEmpty) {
            final right = badge(character);
            for (final rect in left) {
              expect(right.overlaps(rect), isFalse, reason: 'the character badge covers one on the left');
            }
            expect(right.right, moreOrLessEquals(cover.right - 10, epsilon: 0.5));
          } else {
            expect(width, lessThan(400), reason: 'a 400px cover has room for the character');
          }
        });
      }
    }
  });
}

/// A queue holding [jobs] and starting nothing.
class _HeldQueue extends DownloadQueue {
  _HeldQueue(this.jobs);

  final List<DownloadJob> jobs;

  @override
  List<DownloadJob> build() {
    super.build();
    return jobs;
  }
}
