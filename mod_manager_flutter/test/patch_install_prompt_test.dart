import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_thumb.dart';
import 'package:mod_manager_flutter/screens/components/question_parts.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart' show DottedGround;
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_modal.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';
import 'package:mod_manager_flutter/services/patch_destination_ranking.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The install asking about a patch **at the moment it finds one**: the patch window in its install context (board `PatchModal`).
///
/// It exists because the warning alone left the user with a research task: read
/// it, understand it, switch tabs, find the folder among the rest of the
/// library, and press a badge. The answer is worth asking for while the app
/// still has the archive open and the user is still looking at the screen.
///
/// Two questions, and they are not the same question:
///
/// - **Where do the files go?** A library folder, because a destination has to
///   exist.
/// - **What mod does this patch?** A mod page, because the mod being patched may
///   not be installed at all — finding the patch first is an ordinary way round.
///
/// Answering the first with "add it to that one" answers the second for free:
/// that folder's own origin *is* the base.
void main() {
  // Built from the endpoints rather than hand-written: the folder name here has
  // a space in it, and how a space is encoded is the endpoints' business.
  final endpoints = GameBananaEndpoints(gameId: 19567);
  final searchUrl = endpoints.search('Ellen Patch');
  // The search's only result, and a mod `mod_multi_files` holds a record for.
  const baseModId = 528481;
  const baseModName = 'Megalodon Maid Ellen';

  FakeHttpTransport transport() => FakeHttpTransport()
    ..stub(searchUrl, body: gbSearchOfMultiRecords(const [baseModId]))
    ..stub(
      endpoints.modsMulti(const [baseModId], updateCheckProperties),
      body: gbMultiRecordFixture(baseModId),
    );

  PatchInstallSubject assetPatch({String name = 'Ellen Patch'}) => PatchInstallSubject(
        modName: name,
        patchModId: 605460,
        kind: PatchKind.assets,
        missingFiles: const ['body.dds', 'face.dds'],
      );

  const iniPatch = PatchInstallSubject(
    modName: 'Ellen Patch',
    patchModId: 605460,
    kind: PatchKind.references,
    missingFiles: [
      'a.ib', 'b.ib', 'c.ib', 'd.ib', 'e.ib', 'f.ib', 'g.ib', //
      'h.ib', 'i.ib', 'j.ib', 'k.ib', 'l.ib', 'm.ib', 'n.ib',
    ],
  );

  ModInfo libraryMod(String name, {String? versionLabel, String? imagePath, String? author}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        imagePath: imagePath,
        author: author,
        origin: originFixture(
          source: 'gamebanana',
          modId: 111,
          modIdConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
          versionLabel: versionLabel,
        ),
      );

  final library = [
    libraryMod('Ellen v1', versionLabel: 'Main file'),
    libraryMod('Ellen v2', versionLabel: 'NSFW Variants Included'),
  ];

  /// Mounts the window behind a button and hands back what it returned.
  Future<_Answer> open(
    WidgetTester tester, {
    List<PatchInstallSubject>? subjects,
    List<ModInfo>? mods,
    bool combined = false,
    String? characterId,
    String? patchAuthor,
    Size surfaceSize = const Size(1440, 900),
  }) async {
    final answer = _Answer();
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer.prompt = await askPatchInstall(
              context,
              subjects: subjects ?? [assetPatch()],
              library: mods ?? library,
              combined: combined,
              source: const PatchSource(fileName: 'WinterMaid_StockingFix.zip', bytes: 3 * 1024 * 1024),
              characterId: characterId,
              patchAuthor: patchAuthor,
            );
            answer.returned = true;
          },
          child: const Text('open'),
        ),
      ),
      overrides: [
        gameBananaClientProvider.overrideWithValue(
          GameBananaClient(transport: transport(), maxRetries: 0),
        ),
      ],
      surfaceSize: surfaceSize,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(PatchModal);
    return answer;
  }

  /// Row titles top to bottom, which is the whole claim the ranking makes.
  List<String> rows(WidgetTester tester) => [for (final row in tester.widgetList<PickRow>(find.byType(PickRow))) row.title];

  FilledButton primary(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton));

  const into = 'Add it to a mod you already have';
  const newMod = 'Install it as a new mod, with the mod it patches';

  group('how it frames what it found', () {
    testWidgets('an asset patch is framed by what it brought, with the file and where it came from', (tester) async {
      // The evidence is intrinsic: game files with nothing to load them. It
      // says that, rather than naming a library folder — the rule no longer
      // consults the library, because doing so made the answer depend on
      // whether the mod being patched happened to be installed first.
      await open(tester);

      expect(find.text('This looks like a patch'), findsOneWidget);
      expect(find.textContaining('it brings 2 game files and no .ini to load them'), findsOneWidget);
      expect(find.textContaining("refers to aren't in the archive"), findsNothing,
          reason: "that is the reference rule's claim, and it did not find this");
      expect(find.textContaining('from GameBanana · 3.0 MB'), findsOneWidget);
    });

    testWidgets('an .ini patch is framed by what it asks for, and lists it behind a disclosure', (tester) async {
      await open(tester, subjects: const [iniPatch]);

      expect(find.textContaining("14 files its .ini refers to aren't in the archive"), findsOneWidget);
      expect(find.textContaining('a.ib ·'), findsNothing, reason: 'closed until asked');
      await tester.tap(find.text('Show the 14 missing files'));
      await tester.pumpAndSettle();
      expect(find.text('a.ib · b.ib · c.ib · d.ib · e.ib · f.ib · g.ib · and 7 more'), findsOneWidget);
    });

    testWidgets('several patch-shaped mods are one window, not one each', (tester) async {
      // An archive can produce more than one. A dialog per folder is a queue of
      // modals the user has to clear rather than a question.
      await open(tester, subjects: [assetPatch(name: 'Ellen Patch'), assetPatch(name: 'Ellen Patch NSFW')]);

      expect(find.text('These look like patches'), findsOneWidget);
      expect(find.text(newMod), findsNWidgets(2));
      expect(find.text('0 of 2 answered'), findsOneWidget);
    });
  });

  group('where the files go', () {
    testWidgets('both destinations are offered, the library chosen with nothing picked in it', (tester) async {
      final answer = await open(tester);

      expect(find.text(into), findsOneWidget);
      expect(find.text(newMod), findsOneWidget);
      expect(find.text('Ellen v1'), findsOneWidget);
      expect(find.text('Pick the mod to patch'), findsOneWidget);
      expect(primary(tester).onPressed, isNull, reason: 'an incomplete answer cannot be confirmed');
      expect(answer.returned, isFalse);
      expect(find.textContaining('NSFW Variants Included'), findsOneWidget,
          reason: 'two folders can be bound to one mod page, and the recorded variant label is what tells them apart');
    });

    testWidgets('picking a mod returns that folder as the destination', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text('Ellen v2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Patch Ellen v2'));
      await tester.pumpAndSettle();

      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallIntoMod>());
      expect((destination as InstallIntoMod).modId, 'Ellen v2');
    });

    testWidgets('the library can be searched, not just scrolled', (tester) async {
      // A real library is long. Scrolling it and reading every folder name is
      // the whole cost this picker was adding, and the answer the user came
      // with is a name they already know.
      await open(tester, mods: [
        libraryMod('Ellen Bikini', versionLabel: 'Main file'),
        libraryMod('Miyabi Kimono'),
        libraryMod('Ellen School'),
      ]);
      await tester.enterText(find.byType(TextField), 'bikini');
      await tester.pumpAndSettle();

      expect(rows(tester), ['Ellen Bikini'], reason: 'case-insensitively');
    });

    testWidgets('what the row shows is what the search matches', (tester) async {
      // The variant label and the author are on the row, so they are searchable too —
      // a list that displays something it will not match on is a list that looks broken when you type the thing you can see.
      await open(tester, mods: [
        libraryMod('Ellen v1', versionLabel: 'Main file', author: 'frostbyte'),
        libraryMod('Ellen v2', versionLabel: 'NSFW Variants Included'),
      ]);
      await tester.enterText(find.byType(TextField), 'nsfw');
      await tester.pumpAndSettle();
      expect(rows(tester), ['Ellen v2']);

      await tester.enterText(find.byType(TextField), 'frost');
      await tester.pumpAndSettle();
      expect(rows(tester), ['Ellen v1']);
    });

    testWidgets('the search box keeps what was typed when its card closes and opens again, as the list does', (tester) async {
      await open(tester, mods: [libraryMod('Ellen Bikini'), libraryMod('Miyabi Kimono')]);
      await tester.enterText(find.byType(TextField), 'bikini');
      await tester.pumpAndSettle();
      await tester.tap(find.text(newMod));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing, reason: 'the library card is closed');

      await tester.tap(find.text(into));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, 'bikini');
      expect(rows(tester), ['Ellen Bikini'], reason: 'the box and the list it filters agree');
    });

    testWidgets('a search matching nothing says so', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'zzzqqq');
      await tester.pumpAndSettle();

      expect(find.textContaining('No mod matches'), findsOneWidget);
    });

    testWidgets("each row carries the mod's own cover", (tester) async {
      // Reading names is the slow way to recognise a mod. The picture is how the user actually knows which one it is.
      final dir = Directory.systemTemp.createTempSync('zzz_patch_cover_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File(p.join(dir.path, 'ellen.png'))..writeAsBytesSync(const [0]);
      await open(tester, mods: [libraryMod('Ellen Bikini', imagePath: cover.path)]);

      // Asserted about the *provider*, never about pixels: a decode failure in a test environment is silent and would make a pixel assertion vacuous.
      final image = tester.widget<Image>(find.descendant(of: find.byType(PickRow), matching: find.byType(Image)));
      final resize = image.image as ResizeImage;
      expect((resize.imageProvider as FileImage).file.path, cover.path);
      final thumb = tester.widget<ModThumb>(find.descendant(of: find.byType(PickRow), matching: find.byType(ModThumb)));
      expect(thumb.width, 40, reason: "the row's thumbnail size");
      expect(
        resize.width,
        (thumb.width * tester.view.devicePixelRatio).round(),
        reason: 'decoded at row size — a library of full screenshots decoded at native size evicts the whole shared '
            'image cache, including the marketplace previews it is shared with',
      );
    });

    testWidgets('a mod with no cover gets a placeholder, not a broken row', (tester) async {
      await open(tester, mods: [libraryMod('Ellen Bikini'), libraryMod('Ellen School', imagePath: '/nonexistent/cover.png')]);

      final rowsFound = find.byType(PickRow);
      expect(rowsFound, findsNWidgets(2));
      expect(find.descendant(of: rowsFound, matching: find.byType(Image)), findsNothing,
          reason: 'a cover that is not on disk is never handed to an Image');
      expect(find.descendant(of: rowsFound, matching: find.byType(DottedGround)), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty library cannot be a destination, says so, and the new mod is chosen', (tester) async {
      // Nowhere to install into. Offering the card anyway would be a control that opens an empty list.
      await open(tester, mods: const []);

      expect(tester.widget<ChoiceCard>(find.widgetWithText(ChoiceCard, into)).onTap, isNull);
      expect(find.text('Your library is empty, so there is nothing to add it to.'), findsOneWidget);
      expect(tester.widget<ChoiceCard>(find.widgetWithText(ChoiceCard, newMod)).selected, isTrue);
    });

    testWidgets('a combined install can only be its own mod, and says why', (tester) async {
      // Merging several extracted folders into one new mod and writing them
      // into an existing one are different destinations. The combine choice was
      // already made, so this one is not offered.
      await open(tester, combined: true);

      expect(tester.widget<ChoiceCard>(find.widgetWithText(ChoiceCard, into)).onTap, isNull);
      expect(find.textContaining('You chose One mod for these folders'), findsOneWidget);
    });

    testWidgets('fits the narrowest window, the intro and its missing files shown', (tester) async {
      await open(tester, subjects: const [iniPatch], surfaceSize: const Size(480, 900));
      expect(tester.takeException(), isNull);
      expect(find.textContaining("14 files its .ini refers to aren't in the archive"), findsOneWidget);
      await tester.tap(find.text('Show the 14 missing files'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('a.ib · b.ib · c.ib · d.ib · e.ib · f.ib · g.ib · and 7 more'), findsOneWidget);
    });

    testWidgets('fits the narrowest window, a row with two hints keeping its name', (tester) async {
      await open(
        tester,
        mods: [libraryMod('Ellen Bikini Long Name', author: 'frostbyte'), libraryMod('Ellen School')],
        patchAuthor: 'frostbyte',
        subjects: const [
          PatchInstallSubject(
            modName: 'Ellen Patch',
            patchModId: 605460,
            kind: PatchKind.references,
            destinations: [DestinationRank(modId: 'Ellen Bikini Long Name', matched: 12, fingerprint: 14)],
          ),
        ],
        surfaceSize: const Size(480, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('12 of 14 missing files are here'), findsOneWidget);
      expect(find.text('Same author'), findsOneWidget);
      final name = find.text('Ellen Bikini Long Name');
      expect(tester.getSize(name).width, greaterThan(100), reason: 'the hints never squeeze the name away');
    });
  });

  /// Ordering the list, and stopping there.
  ///
  /// The signals are measured in `docs/patch-destinations.md`, and the one they
  /// do not support is a decision: with the patch's real target not installed, a
  /// wrong folder still comes top with a perfect score often enough that a
  /// preselected answer would be a wrong answer nobody looked at. So these
  /// pin the two halves — the order changes, and nothing else does.
  group('which folder it offers first', () {
    Future<void> openRanked(
      WidgetTester tester, {
      required List<ModInfo> mods,
      required List<DestinationRank> ranks,
      PatchKind kind = PatchKind.assets,
      String? characterId,
      String? patchAuthor,
    }) =>
        open(
          tester,
          mods: mods,
          characterId: characterId,
          patchAuthor: patchAuthor,
          subjects: [
            PatchInstallSubject(modName: 'Ellen Patch', patchModId: 605460, kind: kind, destinations: ranks),
          ],
        );

    testWidgets("the folder holding the patch's files comes first", (tester) async {
      await openRanked(
        tester,
        mods: [libraryMod('Ellen Bikini'), libraryMod('Miyabi Kimono'), libraryMod('Ellen School')],
        ranks: const [
          DestinationRank(modId: 'Ellen School', matched: 3, fingerprint: 3),
          DestinationRank(modId: 'Ellen Bikini', matched: 1, fingerprint: 3),
          DestinationRank(modId: 'Miyabi Kimono', matched: 0, fingerprint: 3),
        ],
      );

      expect(rows(tester), ['Ellen School', 'Ellen Bikini', 'Miyabi Kimono']);
    });

    testWidgets('a folder with nothing going for it is still in the list', (tester) async {
      // The list may be reordered and must not be shortened: the patch's real
      // target is often not installed at all, and a folder that matches nothing
      // is exactly what the user picks when they know better than the files do.
      await openRanked(
        tester,
        mods: [libraryMod('Ellen School'), libraryMod('Miyabi Kimono')],
        ranks: const [
          DestinationRank(modId: 'Ellen School', matched: 2, fingerprint: 2),
          DestinationRank(modId: 'Miyabi Kimono', matched: 0, fingerprint: 2),
        ],
      );

      expect(rows(tester), hasLength(2));
    });

    testWidgets('a row that is up there says why, and the others stay quiet', (tester) async {
      await openRanked(
        tester,
        mods: [libraryMod('Ellen School'), libraryMod('Miyabi Kimono')],
        ranks: const [
          DestinationRank(modId: 'Ellen School', matched: 2, fingerprint: 3),
          DestinationRank(modId: 'Miyabi Kimono', matched: 0, fingerprint: 3),
        ],
      );

      expect(find.text('Holds 2 of the 3 files this patch replaces'), findsOneWidget);
      expect(find.textContaining('Holds'), findsOneWidget);
    });

    testWidgets('an .ini patch says how many of its missing files a row holds', (tester) async {
      await openRanked(
        tester,
        kind: PatchKind.references,
        mods: [libraryMod('Ellen School')],
        ranks: const [DestinationRank(modId: 'Ellen School', matched: 12, fingerprint: 14)],
      );

      expect(find.text('12 of 14 missing files are here'), findsOneWidget);
    });

    testWidgets('one file is phrased as one file', (tester) async {
      await openRanked(
        tester,
        mods: [libraryMod('Ellen School')],
        ranks: const [DestinationRank(modId: 'Ellen School', matched: 1, fingerprint: 1)],
      );

      expect(find.text('Holds the file this patch replaces'), findsOneWidget);
    });

    testWidgets('what the author said leads, and is attributed to them', (tester) async {
      // The author's own claim outranks the files, and is worded as a claim:
      // measured over ZZZ, two of six such links named a shared prerequisite
      // rather than the mod being patched.
      await openRanked(
        tester,
        mods: [libraryMod('Ellen School'), libraryMod('Ellen Bikini')],
        ranks: const [
          DestinationRank(modId: 'Ellen Bikini', matched: 0, fingerprint: 4, requiredByAuthor: true),
          DestinationRank(modId: 'Ellen School', matched: 4, fingerprint: 4),
        ],
      );

      expect(rows(tester).first, 'Ellen Bikini');
      expect(find.text("The patch's author lists this mod as required"), findsOneWidget);
    });

    testWidgets('the same author is said, and the same character only where nothing else is', (tester) async {
      await openRanked(
        tester,
        characterId: 'ellen',
        patchAuthor: 'Frostbyte',
        mods: [
          libraryMod('Ellen School', author: 'frostbyte'),
          libraryMod('Ellen Bikini'),
        ],
        ranks: const [],
      );

      expect(find.descendant(of: find.widgetWithText(PickRow, 'Ellen School'), matching: find.text('Same author')),
          findsOneWidget);
      expect(find.descendant(of: find.widgetWithText(PickRow, 'Ellen School'), matching: find.text('Same character')),
          findsNothing);
      expect(find.descendant(of: find.widgetWithText(PickRow, 'Ellen Bikini'), matching: find.text('Same character')),
          findsOneWidget);
      expect(rows(tester), ['Ellen School', 'Ellen Bikini'], reason: 'a hint never reorders anything');
    });

    testWidgets('the top of the list is not an answer', (tester) async {
      await openRanked(
        tester,
        mods: [libraryMod('Ellen School'), libraryMod('Miyabi Kimono')],
        ranks: const [
          DestinationRank(modId: 'Ellen School', matched: 3, fingerprint: 3),
          DestinationRank(modId: 'Miyabi Kimono', matched: 0, fingerprint: 3),
        ],
      );

      for (final row in tester.widgetList<PickRow>(find.byType(PickRow))) {
        expect(row.selected, isFalse,
            reason: 'a perfect score is not evidence the right folder is even in the library');
      }
      expect(primary(tester).onPressed, isNull, reason: 'ranked but unanswered is still unanswered');
    });

    testWidgets('an unranked library is left exactly as it was', (tester) async {
      // Nothing to go on — a patch of one oddly-named file. The plain order is
      // the honest one, and reordering it would imply a signal that is absent.
      await openRanked(
        tester,
        mods: [libraryMod('Miyabi Kimono'), libraryMod('Ellen School')],
        ranks: const [],
      );

      expect(rows(tester), ['Miyabi Kimono', 'Ellen School']);
      expect(find.textContaining('Holds'), findsNothing);
    });
  });

  group('what mod does this patch', () {
    Future<void> chooseNewMod(WidgetTester tester) async {
      await tester.tap(find.text(newMod));
      await tester.pumpAndSettle();
    }

    testWidgets('naming it returns a mod underneath on its own folder', (tester) async {
      // The patch gets its own folder, and what it patches is recorded there underneath it —
      // at `user`, never `exact`, because we did not download those bytes.
      final answer = await open(tester);
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(baseModName).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install as new mod'));
      await tester.pumpAndSettle();

      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallAsNewMod>());
      final base = (destination as InstallAsNewMod).base!;
      expect(base.modId, baseModId);
      expect(base.modIdConfidence, OriginConfidence.user);
    });

    testWidgets('it is not asked once a library mod is the destination', (tester) async {
      // Answered for free: that folder's own origin *is* the base mod, so
      // asking again would be a second answer to a settled question — and a
      // chance to give a contradictory one.
      await open(tester);
      expect(find.text('Find the mod it patches…'), findsNothing);
      await chooseNewMod(tester);
      expect(find.text('Find the mod it patches…'), findsOneWidget);
      await tester.tap(find.text(into));
      await tester.pumpAndSettle();
      expect(find.text('Find the mod it patches…'), findsNothing);
    });

    testWidgets('the row says which file, not only which mod', (tester) async {
      // The pushed step asks for a file as well, and a row reporting only the
      // mod leaves a recorded file indistinguishable from "I don't know" —
      // states that are checked differently, one of which marks the card.
      final answer = await open(tester);
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(baseModName).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('v3.4').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('v3.4'), findsOneWidget);
      expect(find.textContaining('the file you chose'), findsOneWidget,
          reason: 'the same wording the resolve dialog uses for the same fact');
      expect(find.textContaining('#$baseModId'), findsNothing);
      expect(find.text('Change'), findsOneWidget);

      // The picked row goes out whole, because installing it needs its url.
      await tester.tap(find.text('Install as new mod'));
      await tester.pumpAndSettle();
      final destination = answer.value!['Ellen Patch']! as InstallAsNewMod;
      expect(destination.baseFile!.idRow, 1462303);
      expect(destination.baseFile!.downloadUrl, isNotNull);
    });

    testWidgets('"I don\'t know which file" says so, with its cutoff', (tester) async {
      await open(tester);
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(baseModName).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text("I don't know which file").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No file recorded'), findsOneWidget);
    });

    testWidgets("the patch's own page can be named as what it patches, all but its own file", (tester) async {
      // A lone fix file from the main file's page: the page is the base, and
      // only the patch's own file is already in the folder.
      await open(
        tester,
        subjects: const [
          PatchInstallSubject(
            modName: 'Ellen Patch',
            // The id the search's result carries, so picking it is picking the patch's own page.
            patchModId: baseModId,
            patchFileId: 1462303,
            kind: PatchKind.assets,
          ),
        ],
      );
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(baseModName).first);
      await tester.pumpAndSettle();

      final held = find.text('v34.zip');
      await tester.ensureVisible(held);
      final scheme = Theme.of(tester.element(held)).colorScheme;
      expect(tester.widget<Text>(held).style?.color, scheme.onSurface.withValues(alpha: 0.38));
      expect(find.text('Already in this folder'), findsOneWidget);

      final other = find.text('v33.zip');
      await tester.ensureVisible(other);
      await tester.tap(other);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining(baseModName), findsWidgets, reason: 'the page is named as the base');
    });

    testWidgets('a library mod whose base is this very file cannot be picked', (tester) async {
      final same = ModInfo(
        id: 'Ellen Main',
        name: 'Ellen Main',
        characterId: 'ellen',
        isActive: false,
        origin: originFixture(
          source: 'gamebanana',
          modId: baseModId,
          fileId: 1462303,
          modIdConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
        ),
      );
      await open(
        tester,
        subjects: const [
          PatchInstallSubject(modName: 'Ellen Patch', patchModId: baseModId, patchFileId: 1462303, kind: PatchKind.assets),
        ],
        mods: [same, ...library],
      );

      expect(tester.widget<PickRow>(find.widgetWithText(PickRow, 'Ellen Main')).onTap, isNull);
      expect(find.text('Already in this folder'), findsOneWidget);
      await tester.tap(find.text('Ellen Main'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(primary(tester).onPressed, isNull, reason: 'tapping it picked nothing');
      expect(tester.widget<PickRow>(find.widgetWithText(PickRow, 'Ellen v1')).onTap, isNotNull,
          reason: 'another mod of any page is an ordinary destination');
    });

    testWidgets('a name out of an archive is searched as words', (tester) async {
      // `Ellen_Patch` is what a folder inside an archive is actually called,
      // and searched verbatim it finds nothing — leaving the user to retype
      // what the app already knew. The stub answers the *spaced* url only, so
      // results appearing at all is the assertion.
      await open(tester, subjects: [assetPatch(name: 'Ellen_Patch')]);
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();

      expect(find.text('Ellen Patch'), findsOneWidget, reason: 'the box shows words, not the filename');
      expect(find.text(baseModName), findsWidgets, reason: 'and the search that ran is the one that finds something');
    });

    testWidgets('a folder with no mod page of its own refuses nothing', (tester) async {
      // A folder dragged off a disk. There is no identity to collide with, so
      // any mod can be named as the one it patches — including one the user
      // happens to have downloaded before.
      await open(
        tester,
        subjects: const [PatchInstallSubject(modName: 'Ellen Patch', patchModId: null, kind: PatchKind.assets)],
      );
      await chooseNewMod(tester);
      await tester.tap(find.text('Find the mod it patches…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(baseModName).first);
      await tester.pumpAndSettle();

      expect(find.text('Already in this folder'), findsNothing);
      expect(find.text('Add'), findsOneWidget, reason: 'the answer can be given, which is the whole point');
    });
  });

  group('the three outcomes', () {
    testWidgets('installing on its own records nothing and is not a cancel', (tester) async {
      // The difference the install flow acts on: a destination of "its own
      // folder, nothing named" installs the mod with its warning, and null does
      // not install it at all.
      final answer = await open(tester);
      await tester.tap(find.text(newMod));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install on its own'));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue, reason: 'the future has to complete, or the install hangs');
      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallAsNewMod>());
      expect((destination as InstallAsNewMod).base, isNull);
    });

    testWidgets("Don't install is an answer of its own", (tester) async {
      // Asked before the copy, so "I don't want this" is an answer the install can still act on.
      final answer = await open(tester);
      await tester.tap(find.text("Don't install"));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue);
      expect(answer.prompt!.declined, isTrue);
    });

    testWidgets('closing the window answers nothing, which leaves a waiting download waiting', (tester) async {
      final answer = await open(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue);
      expect(answer.prompt, isNull);
    });
  });
}

/// What the window returned, read after it has popped.
class _Answer {
  PatchPromptAnswer? prompt;
  bool returned = false;

  Map<String, PatchDestination>? get value => prompt?.destinations;
}
