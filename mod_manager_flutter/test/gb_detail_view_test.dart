import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/category_picker.dart';
import 'package:mod_manager_flutter/screens/components/marketplace/gb_detail_view.dart';
import 'package:mod_manager_flutter/screens/components/page_crumbs.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/screens/dialogs/install_archive_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_update_dialog.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/gamebanana/content_filter.dart';
import 'package:mod_manager_flutter/services/installed_mods_index.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/marketplace_providers.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart' show loadTableFonts;
import 'support/fixtures.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// A mod's page in Browse: the crumbs, the gallery, the author's update posts, and the panel that decides what an
/// install carries, the character, the files and whether the new mods are turned on.
void main() {
  GbImage image(String name) => GbImage.fromJson({
    '_sBaseUrl': 'https://images.gamebanana.com/img/ss/mods',
    '_sFile': '$name.jpg',
    '_sFile100': '100-_$name.jpg',
    '_sFile220': '220-_$name.jpg',
    '_sFile800': '800-_$name.jpg',
  })!;

  const ellen = GbCategoryRef(idRow: 30306, name: 'Ellen Joe');
  const skins = GbCategoryRef(idRow: 30305, name: 'Character Skins');
  const threeFiles = [
    GbFile(idRow: 11, file: 'first.zip'),
    GbFile(idRow: 12, file: 'second.zip'),
    GbFile(idRow: 13, file: 'third.zip'),
  ];

  GbMod mod({
    int imageCount = 4,
    List<GbFile> files = threeFiles,
    GbCategoryRef? category = ellen,
    GbCategoryRef? superCategory = skins,
    String? text = '<p>Some description</p>',
    List<String> tags = const [],
  }) => GbMod(
    idRow: 700727,
    name: 'A Mod',
    text: text,
    visibility: GbVisibility.show,
    category: category,
    superCategory: superCategory,
    files: files,
    tags: tags,
    images: [for (var i = 0; i < imageCount; i++) image('img$i')],
  );

  /// Every queue press, as the files, the character and the intent.
  late List<(List<int>, String?, DownloadIntent)> queued;

  setUp(() => queued = []);

  Future<ProviderContainer> pumpDetail(
    WidgetTester tester, {
    GbMod? profile,
    Size surfaceSize = const Size(1400, 1400),
    InstalledModsIndex installed = InstalledModsIndex.empty,
    Future<List<GbUpdate>> Function()? updates,
    CharacterPicker? pickCharacter,
    TurnOnAfterInstallWriter? turnOnWriter,
    VoidCallback? onBack,
    List<Override> extra = const [],
  }) async {
    final container = ProviderContainer(overrides: [
      modProfileProvider(700727).overrideWith((ref) async => profile ?? mod()),
      modUpdatesProvider(700727).overrideWith((ref) => (updates ?? () async => const <GbUpdate>[])()),
      contentFilterProvider.overrideWith((ref) => ContentFilterMode.show),
      // Overridden rather than left to load: unoverridden it reaches for `ApiService`, which resolves to an error
      // silently, and every "no badge" assertion would then pass for the wrong reason.
      installedModsIndexProvider.overrideWith((ref) async => installed),
      ...extra,
    ]);
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      GbDetailView(
        modId: 700727,
        onBack: onBack ?? () {},
        onQueue: (mod, files, {required characterId, required intent}) =>
            queued.add(([for (final f in files) f.idRow], characterId, intent)),
        onOpenInBrowser: (_) {},
        pickCharacter: pickCharacter ?? (context, {required currentId}) async => null,
        turnOnWriter: turnOnWriter ?? (_) async {},
      ),
      container: container,
      surfaceSize: surfaceSize,
    );
    expectBuilt(GbDetailView);
    return container;
  }

  /// The url the large picture is showing: the only 800px request on screen.
  String heroUrl(WidgetTester tester) {
    for (final img in tester.widgetList<Image>(find.byType(Image))) {
      final provider = img.image;
      if (provider is ResizeImage && provider.width == 800) {
        return (provider.imageProvider as NetworkImage).url;
      }
    }
    fail('no 800px hero image found');
  }

  /// An icon inside the large picture, which keeps the crumbs' own back chevron out of it.
  Finder inHero(IconData icon) =>
      find.descendant(of: find.byKey(const ValueKey('gallery_hero')), matching: find.byIcon(icon));

  IconButton arrow(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(find.ancestor(of: inHero(icon), matching: find.byType(IconButton)));

  Finder crumb(String label) => find.descendant(of: find.byType(PageCrumbs), matching: find.text(label));

  group('the crumbs', () {
    testWidgets('read Browse / the category / the mod, and Browse goes back', (tester) async {
      var wentBack = 0;
      await pumpDetail(tester, onBack: () => wentBack++);
      expect(crumb('Browse'), findsOneWidget);
      expect(crumb('Ellen Joe'), findsOneWidget);
      expect(crumb('A Mod'), findsOneWidget);
      expect(find.descendant(of: find.byType(PageCrumbs), matching: find.text('Open on GameBanana')), findsOneWidget);

      await tester.tap(crumb('Browse'));
      expect(wentBack, 1);
      await tester.tap(find.byTooltip('Back'));
      expect(wentBack, 2);
    });

    testWidgets('the character crumb filters the grid by it and goes back', (tester) async {
      var wentBack = false;
      final container = await pumpDetail(tester, onBack: () => wentBack = true);

      await tester.tap(crumb('Ellen Joe'));
      await tester.pumpAndSettle();

      final query = container.read(marketplaceQueryProvider);
      expect(query.character, const MarketplaceCharacter(30306, 'Ellen Joe'), reason: 'a Character Skins child');
      expect(query.typeId, 30305, reason: 'which turns Character on');
      expect(wentBack, isTrue);
    });

    testWidgets('a root category sets the type chip', (tester) async {
      final container = await pumpDetail(
        tester,
        profile: mod(category: const GbCategoryRef(idRow: 30702, name: 'Bangboo Skins'), superCategory: null),
      );
      await tester.tap(crumb('Bangboo Skins'));
      await tester.pumpAndSettle();
      expect(container.read(marketplaceQueryProvider).typeId, 30702);
      expect(container.read(marketplaceQueryProvider).character, isNull);
    });

    testWidgets('is plain text when the record carries no id', (tester) async {
      var wentBack = false;
      final container = await pumpDetail(
        tester,
        profile: mod(category: const GbCategoryRef(name: 'Unknown Category'), superCategory: null),
        onBack: () => wentBack = true,
      );
      expect(find.descendant(of: find.byType(PageCrumbs), matching: find.byType(ZenithLink)), findsOneWidget,
          reason: 'Browse is the only link');
      await tester.tap(crumb('Unknown Category'));
      await tester.pumpAndSettle();
      expect(wentBack, isFalse);
      expect(container.read(marketplaceQueryProvider).categoryId, isNull);
    });

    test('a captured profile carries _aSuperCategory for a skin, and none for a mod filed under a root', () {
      final skin = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_rated')))!;
      expect(skin.category?.name, 'Ellen Joe');
      expect(skin.superCategory?.idRow, kCharacterSkinsCategoryId);

      final misc = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
      expect(misc.category?.name, 'Other/Misc');
      expect(misc.superCategory, isNull);
    });
  });

  group('the gallery', () {
    testWidgets('the arrows step forward and back, and clamp at both ends', (tester) async {
      await pumpDetail(tester, profile: mod(imageCount: 2));
      expect(heroUrl(tester), contains('img0'));
      expect(arrow(tester, Icons.chevron_left_rounded).onPressed, isNull, reason: 'nothing before the first');

      await tester.tap(inHero(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img1'));
      expect(arrow(tester, Icons.chevron_right_rounded).onPressed, isNull, reason: 'nothing after the last');
    });

    testWidgets('lays the thumbnails out six to a row at 16:10, wrapping past six', (tester) async {
      await pumpDetail(tester, profile: mod(imageCount: 8));
      final hero = tester.getRect(find.byKey(const ValueKey('gallery_hero')));
      final rects = [for (var i = 0; i < 8; i++) tester.getRect(find.byKey(ValueKey('gallery_thumb_$i')))];

      expect(hero.width / hero.height, closeTo(16 / 9, 0.01));
      for (final r in rects) {
        expect(r.width / r.height, closeTo(16 / 10, 0.01));
      }
      expect(rects.take(6).map((r) => r.top).toSet(), hasLength(1), reason: 'the first six share a row');
      expect(rects[6].top, greaterThan(rects[0].bottom), reason: 'the seventh starts the next');
      expect(rects[1].left - rects[0].right, closeTo(8, 0.1));
      expect(rects[5].right, lessThanOrEqualTo(hero.right + 0.01));
      expect(rects[5].right, closeTo(hero.right, 1), reason: 'six cells and five gaps fill the row');
    });

    testWidgets('the picture shown carries the accent outline, the others are faded', (tester) async {
      await pumpDetail(tester, profile: mod(imageCount: 3));
      Opacity opacity(int i) => tester.widget<Opacity>(
        find.descendant(of: find.byKey(ValueKey('gallery_thumb_$i')), matching: find.byType(Opacity)),
      );
      Decoration? outline(int i) => tester
          .widget<Container>(
            find.descendant(of: find.byKey(ValueKey('gallery_thumb_$i')), matching: find.byType(Container)).first,
          )
          .foregroundDecoration;

      expect(opacity(0).opacity, 1);
      expect(opacity(1).opacity, 0.55);
      final border = (outline(0) as BoxDecoration).border as Border;
      expect(border.top.color, ZenithPalette.dark(AccentChoice.violet).accent);
      expect(border.top.width, 2);
      expect(outline(1), isNull);

      await tester.tap(find.byKey(const ValueKey('gallery_thumb_2')));
      await tester.pumpAndSettle();
      expect(heroUrl(tester), contains('img2'));
      expect(opacity(2).opacity, 1);
      expect(opacity(0).opacity, 0.55);
    });

    testWidgets('a mod with no pictures shows the empty hero alone', (tester) async {
      await pumpDetail(tester, profile: mod(imageCount: 0));
      expect(find.byKey(const ValueKey('gallery_hero')), findsOneWidget);
      expect(find.byType(OutlinedInitials), findsOneWidget);
      expect(find.byKey(const ValueKey('gallery_thumb_0')), findsNothing);
    });

    testWidgets('a single picture has no arrows and no thumbnails', (tester) async {
      await pumpDetail(tester, profile: mod(imageCount: 1));
      expect(inHero(Icons.chevron_left_rounded), findsNothing);
      expect(inHero(Icons.chevron_right_rounded), findsNothing);
      expect(find.byKey(const ValueKey('gallery_thumb_0')), findsNothing);
    });
  });

  group('About this mod', () {
    testWidgets('holds the description, the tags in the form the library stores, and where they came from', (
      tester,
    ) async {
      await pumpDetail(tester, profile: mod(tags: const ['Software Used: Blender', 'Ellen: school uniform']));
      expect(find.text('About this mod'), findsOneWidget);
      expect(find.text('Software Used: Blender'), findsOneWidget);
      expect(find.text('Ellen: school uniform'), findsOneWidget);
      expect(find.text('Text and images come from the GameBanana page.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Ellen: school uniform')).dy,
        greaterThan(tester.getTopLeft(find.text('Some description')).dy),
        reason: 'the tags sit under the description',
      );
    });

    testWidgets('a captured profile renders its own tags', (tester) async {
      final tagged = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_tagged')))!;
      await pumpDetail(tester, profile: tagged, surfaceSize: const Size(1400, 4000));
      expect(tagged.tags, isNotEmpty, reason: 'the fixture must carry tags');
      for (final tag in tagged.tags) {
        expect(find.text(tag), findsOneWidget, reason: tag);
      }
    });

    testWidgets('is absent for a mod with neither text nor tags', (tester) async {
      await pumpDetail(tester, profile: mod(text: null));
      expect(find.text('About this mod'), findsNothing);
    });
  });

  group('Updates', () {
    final captured = parseEnvelope(loadGbFixture('mod_updates_549029'), GbUpdate.fromJson).records;

    testWidgets("lists a captured feed's posts, newest first, with their changelog one line each", (tester) async {
      await pumpDetail(tester, updates: () async => captured.reversed.toList(), surfaceSize: const Size(1400, 2000));

      expect(find.text('Updates'), findsOneWidget);
      final newest = tester.getTopLeft(find.text('Version 1.5')).dy;
      final older = tester.getTopLeft(find.text('Full release | SFW Variants')).dy;
      expect(newest, lessThan(older), reason: 'sorted newest first whatever order the feed came in');
      expect(find.text('Leotard, OG Dress and Tights added'), findsOneWidget);
      expect(find.text('2.1 Compatible'), findsOneWidget);
      // The older post has no changelog, so its text stands in, without its markup.
      expect(find.text('SFW Variants finally released from Patreon, thank you all for your support~'), findsOneWidget);
      expect(find.textContaining('<p>'), findsNothing);
      final ages = tester.widgetList<Text>(find.textContaining(' ago')).map((t) => t.data);
      expect(ages, contains(matches(RegExp(r'^\d+ (year|month)s? ago$'))));
    });

    testWidgets('the title column is 110 wide', (tester) async {
      await pumpDetail(tester, updates: () async => captured);
      expect(tester.getSize(find.ancestor(of: find.text('Version 1.5'), matching: find.byType(SizedBox)).first).width, 110);
    });

    testWidgets('is not drawn when the feed fails', (tester) async {
      await pumpDetail(tester, updates: () async => throw const GbNetworkException('offline'));
      expect(find.text('Updates'), findsNothing);
      expect(find.byKey(const ValueKey('updates_section')), findsNothing);
      expect(find.text("Couldn't reach GameBanana."), findsNothing, reason: 'no error for a section nobody asked about');
    });

    testWidgets('is not drawn for a mod with no posts', (tester) async {
      await pumpDetail(tester);
      expect(find.text('Updates'), findsNothing);
    });
  });

  group('the panel', () {
    testWidgets('badges the type and the category, and counts likes and downloads', (tester) async {
      await pumpDetail(
        tester,
        profile: GbMod(
          idRow: 700727,
          name: 'A Mod',
          category: ellen,
          superCategory: skins,
          likeCount: 1612,
          downloadCount: 18000,
          submitter: const GbSubmitter(idRow: 1, name: 'lacequeen'),
          files: const [GbFile(idRow: 1, file: 'one.zip', filesize: 214 * 1024 * 1024)],
        ),
      );
      final panel = find.byKey(const ValueKey('install_panel'));
      expect(find.descendant(of: panel, matching: find.widgetWithText(ZenithBadge, 'Character')), findsOneWidget);
      expect(find.descendant(of: panel, matching: find.widgetWithText(ZenithBadge, 'Ellen Joe')), findsOneWidget);
      expect(find.text('1.6k likes'), findsOneWidget);
      expect(find.text('18.0k downloads'), findsOneWidget);
      expect(find.text('by lacequeen'), findsOneWidget);
      // The one current file's size sits with the counts, and again on its row.
      expect(find.text('214 MB'), findsNWidgets(2));
    });

    testWidgets('names a Bangboo mod by its type chip', (tester) async {
      await pumpDetail(
        tester,
        profile: mod(
          category: const GbCategoryRef(idRow: 30710, name: 'Eous'),
          superCategory: const GbCategoryRef(idRow: 30702, name: 'Bangboo Skins'),
        ),
      );
      expect(find.widgetWithText(ZenithBadge, 'Bangboo'), findsOneWidget);
    });
  });

  group('Install for', () {
    testWidgets("shows the GameBanana category's character, and the job carries it", (tester) async {
      await pumpDetail(tester, profile: mod(files: const [GbFile(idRow: 11, file: 'only.zip')]));
      final card = find.byKey(const ValueKey('install_for'));
      expect(find.descendant(of: card, matching: find.text('Ellen Joe')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Picked from the GameBanana category')), findsOneWidget);
      expect(find.text('It becomes a mod under Ellen Joe.'), findsOneWidget);

      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$1, [11]);
      expect(queued.single.$2, 'ellen');
      expect(queued.single.$3, DownloadIntent.install);
    });

    testWidgets('Change overrides it for this page, and the job carries the pick', (tester) async {
      String? askedWith;
      await pumpDetail(
        tester,
        profile: mod(files: const [GbFile(idRow: 11, file: 'only.zip')]),
        pickCharacter: (context, {required currentId}) async {
          askedWith = currentId;
          return 'anby';
        },
      );
      await tester.tap(find.byKey(const ValueKey('install_for')));
      await tester.pumpAndSettle();

      expect(askedWith, 'ellen');
      final card = find.byKey(const ValueKey('install_for'));
      expect(find.descendant(of: card, matching: find.text('Anby Demara')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Picked by you')), findsOneWidget);
      expect(find.text('It becomes a mod under Anby Demara.'), findsOneWidget);

      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$2, 'anby');
    });

    testWidgets("picking the category's own character goes back to it", (tester) async {
      var answer = 'anby';
      await pumpDetail(tester, pickCharacter: (context, {required currentId}) async => answer);
      await tester.tap(find.byKey(const ValueKey('install_for')));
      await tester.pumpAndSettle();
      answer = 'ellen';
      await tester.tap(find.byKey(const ValueKey('install_for')));
      await tester.pumpAndSettle();
      expect(find.text('Picked from the GameBanana category'), findsOneWidget);
    });

    testWidgets('a category with no character installs under Unassigned, never a guess from the folder name', (
      tester,
    ) async {
      // "Zhao Nicole" reads as Nicole to the folder-name matcher; the page says Unassigned, so the sidecar must too.
      late TempLibrary temp;
      late File zip;
      await tester.runAsync(() async {
        temp = await TempLibrary.create();
        final downloads = Directory.systemTemp.createTempSync('zzz_detail_zip_');
        addTearDown(() => downloads.deleteSync(recursive: true));
        final archive = Archive();
        final ini = '[TextureOverrideBody]\nhash = 1\n'.codeUnits;
        archive.addFile(ArchiveFile('Zhao Nicole/mod.ini', ini.length, ini));
        zip = File(p.join(downloads.path, 'Zhao Nicole.zip'))..writeAsBytesSync(ZipEncoder().encode(archive)!);
      });
      const file = GbFile(idRow: 11, file: 'Zhao Nicole.zip');
      const page = GbMod(
        idRow: 700727,
        name: 'Zhao Nicole',
        visibility: GbVisibility.show,
        category: GbCategoryRef(idRow: 29874, name: 'Other/Misc'),
        files: [file],
      );
      await pumpDetail(tester, profile: page);

      final card = find.byKey(const ValueKey('install_for'));
      expect(find.descendant(of: card, matching: find.text('No character in the GameBanana category')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Unassigned')), findsOneWidget);
      expect(find.text('It becomes a mod under Unassigned.'), findsOneWidget);
      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$2, unknownCharacterId, reason: 'said on the job, not left for the import to fill');

      // The job, as the queue hands it to the install: the flow over the temp library.
      late BuildContext context;
      late WidgetRef ref;
      await pumpLocalized(
        tester,
        Consumer(
          builder: (c, r, _) {
            context = c;
            ref = r;
            return const SizedBox.shrink();
          },
        ),
        overrides: [...temp.overrides, libraryOf(const [])],
      );
      await tester.runAsync(() async {
        await runArchiveInstall(
          context,
          ref,
          DownloadJob(
            seq: 1,
            request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/11')),
            intent: DownloadIntent.install,
            subject: 'Zhao Nicole',
            file: file,
            mod: page,
            characterId: queued.single.$2,
            state: DownloadJobState.installing,
            result: DownloadResult(file: zip, totalBytes: zip.lengthSync()),
          ),
        );
      });
      await tester.pumpAndSettle();

      final sidecar = temp.read('Zhao Nicole', '.zzz-mod-manager/metadata.json');
      expect(sidecar, isNotNull, reason: 'the mod was installed');
      final character = (jsonDecode(sidecar!) as Map<String, dynamic>)['character_id'] as String?;
      expect(isUnassignedCharacterId(character), isTrue, reason: 'not $character');
    });

    testWidgets("a Bangboo category whose name holds an agent's term installs under Unassigned, not that agent", (
      tester,
    ) async {
      await pumpDetail(
        tester,
        profile: mod(
          files: const [GbFile(idRow: 11, file: 'only.zip')],
          category: const GbCategoryRef(idRow: 30711, name: "Von Lycaon's Bangboo"),
          superCategory: const GbCategoryRef(idRow: 30702, name: 'Bangboo Skins'),
        ),
      );
      final card = find.byKey(const ValueKey('install_for'));
      expect(find.descendant(of: card, matching: find.text('No character in the GameBanana category')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Unassigned')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('Lycaon')), findsNothing);
      expect(find.text('It becomes a mod under Unassigned.'), findsOneWidget);
      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$2, unknownCharacterId);
    });

    testWidgets('Change offers Unassigned, and picking it on a page with a character puts the job there', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        profile: mod(files: const [GbFile(idRow: 11, file: 'only.zip')]),
        pickCharacter: (context, {required currentId}) async => unknownCharacterId,
      );
      await tester.tap(find.byKey(const ValueKey('install_for')));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('install_for'));
      expect(find.descendant(of: card, matching: find.text('Unassigned')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Picked by you')), findsOneWidget);
      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$2, unknownCharacterId);
    });

    testWidgets("the picker it opens lists Unassigned among the categories, and a mod's own editor does not", (
      tester,
    ) async {
      String? picked;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () async => picked = await pickInstallTarget(context, currentId: 'ellen'),
                child: const Text('install'),
              ),
              TextButton(
                onPressed: () => showCategoryPicker(context, currentId: 'ellen'),
                child: const Text('edit'),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('install'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unassigned'));
      await tester.pumpAndSettle();
      expect(picked, unknownCharacterId);

      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      expect(find.text('Select category'), findsOneWidget);
      expect(find.text('Unassigned'), findsNothing);
    });
  });

  group('the files and the button', () {
    testWidgets('nothing is picked when the mod publishes several current files', (tester) async {
      await pumpDetail(tester);
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('install_button')));
      expect(button.onPressed, isNull);
      expect(find.text('Pick a file'), findsOneWidget);
      expect(find.textContaining('becomes'), findsNothing, reason: 'no footnote with nothing picked');
      expect(find.text('Download without installing'), findsNothing);
    });

    testWidgets('the one file is picked when the mod publishes one', (tester) async {
      await pumpDetail(tester, profile: mod(files: const [GbFile(idRow: 11, file: 'only.zip')]));
      expect(find.text('Install 1 file'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('install_button')));
      expect(button.onPressed, isNotNull);
      expect(tester.getSize(find.byKey(const ValueKey('install_button'))).height, 44);
    });

    testWidgets('several picked read as several files, each its own mod', (tester) async {
      await pumpDetail(tester);
      await tester.tap(find.byKey(const ValueKey('file_12')));
      await tester.tap(find.byKey(const ValueKey('file_11')));
      await tester.pump();

      expect(find.text('Install 2 files'), findsOneWidget);
      expect(find.text('Each file becomes its own mod under Ellen Joe.'), findsOneWidget);
      final footnote = tester.widget<Text>(find.text('Each file becomes its own mod under Ellen Joe.'));
      expect(footnote.textAlign, TextAlign.center);
      expect(footnote.style?.color, ZenithPalette.dark(AccentChoice.violet).text3);

      await tester.tap(find.text('Install 2 files'));
      expect(queued.single.$1, [11, 12], reason: 'in list order');
      expect(queued.single.$2, 'ellen');
      expect(queued.single.$3, DownloadIntent.install);
    });

    testWidgets('an older file is pickable once shown', (tester) async {
      await pumpDetail(
        tester,
        profile: GbMod(
          idRow: 700727,
          name: 'A Mod',
          category: ellen,
          superCategory: skins,
          files: threeFiles,
          archivedFiles: const [GbFile(idRow: 9, file: 'old.zip', isArchived: true)],
        ),
      );
      await tester.tap(find.text('Show 1 older file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('file_9')));
      await tester.pump();
      await tester.tap(find.text('Install 1 file'));
      expect(queued.single.$1, [9]);
    });

    testWidgets('a picked older file keeps its row when the older files are hidden, until it is let go', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        profile: GbMod(
          idRow: 700727,
          name: 'A Mod',
          category: ellen,
          superCategory: skins,
          files: threeFiles,
          archivedFiles: const [
            GbFile(idRow: 9, file: 'old.zip', isArchived: true),
            GbFile(idRow: 8, file: 'older.zip', isArchived: true),
          ],
        ),
      );
      await tester.tap(find.text('Show 2 older files'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('file_9')));
      await tester.pump();
      await tester.tap(find.text('Hide older files'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('file_9')), findsOneWidget, reason: 'Install counts it, so it stays in view');
      expect(find.byKey(const ValueKey('file_8')), findsNothing);
      expect(find.text('Install 1 file'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('file_9')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file_9')), findsNothing);
      expect(find.text('Pick a file'), findsOneWidget);
    });

    testWidgets('Download without installing queues the picks as archives', (tester) async {
      await pumpDetail(tester);
      await tester.tap(find.byKey(const ValueKey('file_13')));
      await tester.pump();
      await tester.tap(find.text('Download without installing'));
      expect(queued.single.$1, [13]);
      expect(queued.single.$2, 'ellen');
      expect(queued.single.$3, DownloadIntent.keepArchive);
    });
  });

  group('Turn on after installing', () {
    testWidgets('shows the saved setting, and pressing it saves the other', (tester) async {
      final written = <bool>[];
      await pumpDetail(
        tester,
        turnOnWriter: (on) async => written.add(on),
        extra: [marketplaceTurnOnAfterInstallProvider.overrideWith((ref) => true)],
      );
      expect(tester.widget<ZenithSwitch>(find.byType(ZenithSwitch)).value, isTrue);

      await tester.tap(find.byType(ZenithSwitch));
      await tester.tap(find.text('Turn on after installing'));
      expect(written, [false, false]);
    });
  });

  group('In your library', () {
    ModInfo installedMod(String id) => ModInfo(
      id: id,
      name: id,
      characterId: 'ellen',
      isActive: false,
      origin: originFixture(
        provenance: OriginProvenance.downloaded,
        source: 'gamebanana',
        modId: 700727,
        modIdConfidence: OriginConfidence.exact,
      ),
    );

    testWidgets('is absent for a mod the library does not have', (tester) async {
      await pumpDetail(tester);
      expect(find.textContaining('In your library'), findsNothing);
    });

    testWidgets('names the folder, and Show opens it in the Characters view', (tester) async {
      final mod = installedMod('Remielle Swim');
      final container = await pumpDetail(
        tester,
        installed: InstalledModsIndex.fromMods([mod]),
        extra: [libraryOf([mod])],
      );
      expect(find.text('In your library as Remielle Swim'), findsOneWidget);
      expect(find.text('Update'), findsNothing, reason: 'no newer file was found this session');

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(container.read(destinationProvider), AppDestination.characters);
      expect(container.read(selectedModIdProvider), 'Remielle Swim');
    });

    testWidgets('counts several folders', (tester) async {
      await pumpDetail(
        tester,
        installed: InstalledModsIndex.fromMods([installedMod('Ellen A'), installedMod('Ellen B')]),
      );
      expect(find.text('In your library as 2 mods'), findsOneWidget);
    });

    testWidgets('offers Update for a folder with a confirmed newer file, opening its update dialog', (tester) async {
      final origin = originFixture(
        source: 'gamebanana',
        modId: 700727,
        modIdConfidence: OriginConfidence.user,
        fileId: 1696178,
        versionConfidence: OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
      );
      late TempLibrary temp;
      await tester.runAsync(() async {
        temp = await TempLibrary.create();
        temp.createMod('Ellen');
        await temp.writeOrigin('Ellen', origin);
      });
      final mod = ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false, origin: origin);
      await pumpDetail(
        tester,
        installed: InstalledModsIndex.fromMods([mod]),
        extra: [
          ...temp.overrides,
          libraryOf([mod]),
          modUpdateChecksProvider.overrideWith(
            (ref) => {
              'Ellen': UpdateCheck(
                outcome: UpdateOutcome.updateAvailable,
                candidate: GbFile(idRow: 1732269, dateAdded: DateTime.utc(2026, 6, 19)),
              ),
            },
          ),
        ],
      );

      await tester.tap(find.widgetWithText(ZenithLink, 'Update'));
      await tester.pumpAndSettle();
      expect(tester.widget<ModUpdateDialog>(find.byType(ModUpdateDialog)).mod.id, 'Ellen');
    });
  });

  testWidgets('fits the 800px window, the panel under the main column', (tester) async {
    // The app's fonts: the test font draws every glyph a full em wide, which no layout is chosen for.
    await loadTableFonts(tester);
    await pumpDetail(tester, surfaceSize: const Size(584, 3000), profile: mod(imageCount: 6));
    expect(tester.takeException(), isNull);
    final panel = tester.getRect(find.byKey(const ValueKey('install_panel')));
    final hero = tester.getRect(find.byKey(const ValueKey('gallery_hero')));
    expect(panel.top, greaterThan(hero.bottom));
    expect(panel.width, 584 - 64);
  });
}
