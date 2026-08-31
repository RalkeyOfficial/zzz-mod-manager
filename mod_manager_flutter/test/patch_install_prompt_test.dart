import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/patch_install_prompt.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';

/// The install asking about a patch **at the moment it finds one**.
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
/// Answering the first with "install it into that one" answers the second for
/// free: that folder's own origin *is* the base.
void main() {
  // Built from the endpoints rather than hand-written: the folder name here has
  // a space in it, and how a space is encoded is the endpoints' business.
  final endpoints = GameBananaEndpoints(gameId: 19567);
  final searchUrl = endpoints.search('Ellen Patch');
  final profileUrl = endpoints.modProfile(527697);

  FakeHttpTransport transport() => FakeHttpTransport()
    ..stub(searchUrl, body: loadGbFixture('search_ellen'))
    ..stub(profileUrl, body: loadGbFixture('mod_profile_rated'));

  PatchInstallSubject assetPatch({String name = 'Ellen Patch'}) =>
      PatchInstallSubject(
        modName: name,
        patchModId: 605460,
        kind: PatchKind.assets,
      );

  const iniPatch = PatchInstallSubject(
    modName: 'Ellen Patch',
    patchModId: 605460,
    kind: PatchKind.references,
  );

  ModInfo libraryMod(String name, {String? versionLabel, String? imagePath}) =>
      ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        imagePath: imagePath,
        origin: ModOrigin(
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

  /// Mounts the prompt behind a button and hands back what it returned.
  Future<_Answer> open(
    WidgetTester tester, {
    List<PatchInstallSubject>? subjects,
    List<ModInfo>? mods,
    bool combined = false,
  }) async {
    final answer = _Answer();
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer.value = await showPatchInstallPrompt(
              context,
              subjects: subjects ?? [assetPatch()],
              library: mods ?? library,
              combined: combined,
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
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(PatchInstallPrompt);
    return answer;
  }

  group('how it frames what it found', () {
    testWidgets('an asset patch is framed by what it brought', (tester) async {
      // The evidence is intrinsic: game files with nothing to load them. It
      // says that, rather than naming a library folder — the rule no longer
      // consults the library, because doing so made the answer depend on
      // whether the mod being patched happened to be installed first.
      await open(tester);

      expect(find.text('This looks like a patch'), findsOneWidget);
      expect(find.textContaining('game files but no .ini'), findsOneWidget);
      expect(
        find.textContaining('asks for content the download'),
        findsNothing,
        reason: 'that is the reference rule\'s claim, and it did not find this',
      );
    });

    testWidgets('an .ini patch is framed without claiming a target',
        (tester) async {
      await open(tester, subjects: const [iniPatch]);

      expect(find.textContaining('asks for content the download'),
          findsOneWidget);
      expect(
        find.textContaining('game files but no .ini'),
        findsNothing,
        reason: 'this download has an .ini, it just asks for more than it '
            'brought',
      );
    });

    testWidgets('several patch-shaped mods are one prompt, not one each',
        (tester) async {
      // An archive can produce more than one. A dialog per folder is a queue of
      // modals the user has to clear rather than a question.
      await open(tester, subjects: [
        assetPatch(name: 'Ellen Patch'),
        assetPatch(name: 'Ellen Patch NSFW'),
      ]);

      expect(find.text('This looks like a patch'), findsOneWidget);
      expect(find.text('Install as a new mod'), findsNWidgets(2));
    });
  });

  group('where the files go', () {
    testWidgets('both destinations are offered, its own folder by default',
        (tester) async {
      // The default is the one that cannot destroy anything: a new folder of
      // its own. Writing into a live mod is the deliberate choice.
      await open(tester);

      expect(find.text('Install as a new mod'), findsOneWidget);
      expect(find.text('Install it into an existing mod'), findsOneWidget);
      expect(
        find.text('Ellen v1'),
        findsNothing,
        reason: 'the library is not shown until that destination is chosen',
      );
    });

    testWidgets('choosing the second one lists the library, unpicked',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      expect(find.text('Ellen v1'), findsOneWidget);
      expect(find.text('Ellen v2'), findsOneWidget);
      expect(
        find.textContaining('NSFW Variants Included'),
        findsOneWidget,
        reason: 'two folders can be bound to one mod page, and the recorded '
            'variant label is what tells them apart',
      );
    });

    testWidgets('picking a mod returns that folder as the destination',
        (tester) async {
      final answer = await open(tester);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ellen v2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallIntoMod>());
      expect((destination as InstallIntoMod).modId, 'Ellen v2');
    });

    testWidgets('nothing is written until a mod is actually picked',
        (tester) async {
      // The radio alone is not an answer. Confirming with it selected and no
      // mod chosen must not silently fall back to installing as a new mod,
      // because the user asked for the other thing.
      final answer = await open(tester);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      final install = find.widgetWithText(FilledButton, 'Install');
      expect(
        tester.widget<FilledButton>(install).onPressed,
        isNull,
        reason: 'an incomplete answer cannot be confirmed',
      );
      expect(answer.returned, isFalse);
    });

    testWidgets('the library can be searched, not just scrolled',
        (tester) async {
      // A real library is long. Scrolling it and reading every folder name is
      // the whole cost this picker was adding, and the answer the user came
      // with is a name they already know.
      await open(tester, mods: [
        libraryMod('Ellen Bikini', versionLabel: 'Main file'),
        libraryMod('Miyabi Kimono'),
        libraryMod('Ellen School'),
      ]);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ellen');
      await tester.pumpAndSettle();

      expect(find.text('Ellen Bikini'), findsOneWidget);
      expect(find.text('Ellen School'), findsOneWidget);
      expect(
        find.text('Miyabi Kimono'),
        findsNothing,
        reason: 'case-insensitively, because nobody types a folder name the '
            'way its author capitalised it',
      );
    });

    testWidgets('what the row shows is what the search matches',
        (tester) async {
      // The variant label is on the row, so it has to be searchable too — a
      // list that displays something it will not match on is a list that looks
      // broken when you type the thing you can see.
      await open(tester, mods: [
        libraryMod('Ellen v1', versionLabel: 'Main file'),
        libraryMod('Ellen v2', versionLabel: 'NSFW Variants Included'),
      ]);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'nsfw');
      await tester.pumpAndSettle();

      expect(find.text('Ellen v2'), findsOneWidget);
      expect(find.text('Ellen v1'), findsNothing);
    });

    testWidgets('a search matching nothing says so', (tester) async {
      await open(tester);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzzqqq');
      await tester.pumpAndSettle();

      expect(find.textContaining('No mod matches'), findsOneWidget);
    });

    testWidgets('each row carries the mod\'s own cover', (tester) async {
      // Reading names is the slow way to recognise a mod. The picture is how
      // the user actually knows which one it is.
      await open(tester, mods: [
        libraryMod('Ellen Bikini', imagePath: '/covers/ellen.png'),
      ]);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      // Asserted about the *provider*, never about pixels: a decode failure in
      // a test environment is silent and would make a pixel assertion vacuous.
      final image = tester.widget<Image>(find.byType(Image));
      final resize = image.image as ResizeImage;
      expect((resize.imageProvider as FileImage).file.path, '/covers/ellen.png');
      expect(
        resize.width,
        AppConstants.modThumbnailDecodeWidth,
        reason: 'decoded at row size — a library of full screenshots decoded '
            'at native size evicts the whole shared image cache, including the '
            'marketplace previews it is shared with',
      );
    });

    testWidgets('a mod with no cover gets a placeholder, not a broken row',
        (tester) async {
      await open(tester, mods: [libraryMod('Ellen Bikini')]);
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('an empty library cannot be a destination, and says so',
        (tester) async {
      // Nowhere to install into. Offering the radio anyway would be a control
      // that opens an empty list.
      await open(tester, mods: const []);

      expect(find.text('Install it into an existing mod'), findsNothing);
      expect(find.textContaining('nothing in your library'), findsOneWidget);
    });

    testWidgets('a combined install can only be its own mod, and says why',
        (tester) async {
      // Merging several extracted folders into one new mod and writing them
      // into an existing one are different destinations. The combine choice was
      // already made, so this one is not offered.
      await open(tester, combined: true);

      expect(find.text('Install it into an existing mod'), findsNothing);
      expect(find.textContaining('one combined mod'), findsOneWidget);
    });
  });

  group('what mod does this patch', () {
    testWidgets('naming it returns a companion on its own folder',
        (tester) async {
      // Branch A: the patch gets its own folder, and what it patches is
      // recorded there as a companion — at `user`, never `exact`, because we
      // did not download those bytes.
      final answer = await open(tester);
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();

      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallAsNewMod>());
      final base = (destination as InstallAsNewMod).base!;
      expect(base.modId, 527697);
      expect(base.modIdConfidence, OriginConfidence.user);
    });

    testWidgets('it is not asked once a library mod is the destination',
        (tester) async {
      // Answered for free: that folder's own origin *is* the base mod, so
      // asking again would be a second answer to a settled question — and a
      // chance to give a contradictory one.
      await open(tester);
      expect(find.text('Say what it patches'), findsOneWidget);

      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();

      expect(find.text('Say what it patches'), findsNothing);
    });

    testWidgets('the row says which file, not only which mod', (tester) async {
      // The pushed step asks for a file as well, and a row reporting only the
      // mod leaves a recorded file indistinguishable from "I don't know" —
      // states that are checked differently, one of which marks the card.
      await open(tester);
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('v3.4').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('v3.4'), findsOneWidget);
      expect(
        find.textContaining('the file you chose'),
        findsOneWidget,
        reason: 'the same wording the resolve dialog uses for the same fact',
      );
      expect(find.textContaining('#527697'), findsNothing);
    });

    testWidgets('"I don\'t know which file" says so, with its cutoff',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('I don\'t know which file').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No file recorded'), findsOneWidget);
    });

    testWidgets('the patch\'s own mod page cannot be named as what it patches',
        (tester) async {
      await open(
        tester,
        subjects: const [
          PatchInstallSubject(
            modName: 'Ellen Patch',
            // The id the search's first result carries, so picking it is
            // picking the patch itself.
            patchModId: 527697,
            kind: PatchKind.assets,
          ),
        ],
      );
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();

      expect(find.text('That is this mod, not another one'), findsOneWidget);
    });

    testWidgets('a name out of an archive is searched as words', (tester) async {
      // `Ellen_Patch` is what a folder inside an archive is actually called,
      // and searched verbatim it finds nothing — leaving the user to retype
      // what the app already knew. The stub answers the *spaced* url only, so
      // results appearing at all is the assertion.
      await open(
        tester,
        subjects: [assetPatch(name: 'Ellen_Patch')],
      );
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();

      expect(find.text('Ellen Patch'), findsOneWidget,
          reason: 'the box shows words, not the filename');
      expect(find.text('ellen joe cheongsam'), findsWidgets,
          reason: 'and the search that ran is the one that finds something');
    });

    testWidgets('a folder with no mod page of its own refuses nothing',
        (tester) async {
      // A folder dragged off a disk. There is no identity to collide with, so
      // any mod can be named as the one it patches — including one the user
      // happens to have downloaded before.
      await open(
        tester,
        subjects: const [
          PatchInstallSubject(
            modName: 'Ellen Patch',
            patchModId: null,
            kind: PatchKind.assets,
          ),
        ],
      );
      await tester.tap(find.text('Say what it patches'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellen joe cheongsam').first);
      await tester.pumpAndSettle();

      expect(find.text('That is this mod, not another one'), findsNothing);
      expect(find.text('Add'), findsOneWidget,
          reason: 'the answer can be given, which is the whole point');
    });
  });

  group('the three outcomes', () {
    testWidgets('installing anyway records nothing and is not a cancel',
        (tester) async {
      // The difference the install flow acts on: a destination of "its own
      // folder, nothing named" installs the mod with its warning, and null does
      // not install it at all.
      final answer = await open(tester);
      await tester.tap(find.text('Install anyway'));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue,
          reason: 'the future has to complete, or the install hangs');
      final destination = answer.value!['Ellen Patch']!;
      expect(destination, isA<InstallAsNewMod>());
      expect((destination as InstallAsNewMod).base, isNull);
    });

    testWidgets('declining the install returns null', (tester) async {
      // Asked before the copy, so "I don't want this" is an answer the install
      // can still act on.
      final answer = await open(tester);
      await tester.tap(find.text('Don\'t install it'));
      await tester.pumpAndSettle();

      expect(answer.returned, isTrue);
      expect(answer.value, isNull);
    });
  });
}

/// What the prompt returned, read after the dialog has popped.
class _Answer {
  Map<String, PatchDestination>? value;
  bool returned = false;
}
