import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gamebanana.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/tags_field.dart';
import 'package:mod_manager_flutter/screens/components/zenith_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/edit_mod/edit_mod_dialog.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart';
import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/temp_library.dart';

/// A widget test with semantics on, which the finders by label need, and off again before the test ends.
void testEdit(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
    }
  });
}

/// **Edit info**: the one window that renames a mod and changes its cover, author, description, tags and keys
/// (`docs/library-screen.md` §13, `docs/key-editing.md`).
void main() {
  late TempLibrary temp;
  EditResult? result;
  var closed = false;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_edit_info_');
    result = null;
    closed = false;
  });

  const keyIni = '[KeyCoat]\nkey = alt 1\n\n[KeyHair]\nkey = ctrl 2\ncondition = \$a == 1\n';

  ModInfo mod(
    String id, {
    String characterId = 'ellen',
    String? description,
    String? author,
    List<String> tags = const [],
    List<String> images = const [],
    bool isActive = false,
    List<KeybindInfo>? keybinds,
    ModOrigin? origin,
  }) => ModInfo(
    id: id,
    name: id,
    characterId: characterId,
    isActive: isActive,
    description: description,
    author: author,
    tags: tags,
    images: images,
    imagePath: images.isEmpty ? null : images.first,
    keybinds: keybinds,
    origin: origin,
  );

  /// The keys the scan would read for [name], read off the disk the way it does.
  Future<List<KeybindInfo>> keysOf(WidgetTester tester, String name) async =>
      (await tester.runAsync(() => temp.service.getModKeybinds(name)))!;

  /// Lets the dialog's file reads and the client's futures finish. A fake-async zone never turns the real event loop,
  /// and each step of a chain of reads started there resumes only at the next pump, so it takes rounds: the keys'
  /// markers need dozens, which a test that looks at them asks for.
  Future<void> settleIo(WidgetTester tester, {int rounds = 2}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();
    }
  }

  Future<ProviderContainer> openEdit(
    WidgetTester tester,
    ModInfo subject, {
    List<ModInfo> others = const [],
    List<Override> overrides = const [],
    Size surfaceSize = const Size(1200, 900),
    Brightness brightness = Brightness.dark,
    EditSection section = EditSection.info,
    int ioRounds = 2,
  }) async {
    await loadTableFonts(tester);
    final container = ProviderContainer(
      overrides: [
        libraryOf([subject, ...others]),
        ...temp.overrides,
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showEditModDialog(context, subject, section: section);
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
      container: container,
      surfaceSize: surfaceSize,
      brightness: brightness,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(EditModDialog);
    await settleIo(tester, rounds: ioRounds);
    return container;
  }

  Finder save() => find.widgetWithText(FilledButton, 'Save changes');
  bool saveEnabled(WidgetTester tester) => tester.widget<FilledButton>(save()).onPressed != null;
  Finder nameField() => find.byKey(const ValueKey('edit_name'));
  Finder authorField() => find.byKey(const ValueKey('edit_author'));
  Finder descriptionField() => find.byKey(const ValueKey('edit_description'));

  Future<void> pressSave(WidgetTester tester) async {
    await tapWithIo(tester, save());
    await settleIo(tester);
  }

  Map<String, dynamic> sidecar(String name) =>
      jsonDecode(File(p.join(temp.modFolder(name).path, '.zzz-mod-manager', 'metadata.json')).readAsStringSync())
          as Map<String, dynamic>;

  group('the dialog', () {
    testEdit('shows what the mod has, and Save waits for a change', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', description: 'A long coat.', author: 'frostbyte', tags: ['Outfit', 'Maid']),
      );

      expect(find.text('Edit mod info'), findsOneWidget);
      expect(find.text('Winter Maid · Ellen Joe'), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, 'Winter Maid');
      expect(tester.widget<TextField>(authorField()).controller!.text, 'frostbyte');
      expect(tester.widget<TextField>(descriptionField()).controller!.text, 'A long coat.');
      expect(find.text('Outfit'), findsOneWidget);
      expect(find.text('Maid'), findsOneWidget);
      expect(find.text('Ellen Joe'), findsWidgets);
      expect(saveEnabled(tester), isFalse);
      expect(
        find.text("An update replaces key changes with the author's keys. The rest of your edits stay."),
        findsOneWidget,
        reason: 'nothing to save, so the footer is the second sentence alone',
      );
    });

    testEdit('a change enables Save, and Cancel leaves with nothing', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));

      await tester.enterText(descriptionField(), 'New text');
      await tester.pump();
      expect(saveEnabled(tester), isTrue);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
      expect(find.byType(ZenithDialog), findsNothing);
    });

    testEdit('is two columns in a wide window and one in a narrow one', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));
      final wideCover = tester.getTopLeft(find.text('Cover'));
      final wideName = tester.getTopLeft(find.text('Name'));
      expect(wideName.dy, lessThan(wideCover.dy + 40), reason: 'the form beside the cover');
      expect(wideName.dx, greaterThan(wideCover.dx + 200));
      expect(tester.takeException(), isNull);
    });

    testEdit('is one column when the dialog is under 740 wide', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'), surfaceSize: const Size(700, 900));

      final cover = tester.getTopLeft(find.text('Cover'));
      final name = tester.getTopLeft(find.text('Name'));
      expect(name.dy, greaterThan(cover.dy + 100), reason: 'the form under the cover');
      expect(name.dx, cover.dx);
      expect(tester.takeException(), isNull);
    });

    testEdit('renders in the paper theme without an error', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'), brightness: Brightness.light);

      expect(tester.takeException(), isNull);
      expect(find.text('Edit mod info'), findsOneWidget);
    });
  });

  group('Name', () {
    testEdit('refuses invalid characters, a taken name in any letter case, and an empty one', (tester) async {
      temp.createMod('Winter Maid');
      temp.createMod('Summer Maid');
      await openEdit(tester, mod('Winter Maid'), others: [mod('Summer Maid')]);

      await tester.enterText(nameField(), 'Win/ter');
      await tester.pump();
      expect(find.text('Name contains invalid characters'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      for (final bad in ['.hidden', '__tmp', 'a:b', 'what?']) {
        await tester.enterText(nameField(), bad);
        await tester.pump();
        expect(find.text('Name contains invalid characters'), findsOneWidget, reason: bad);
      }

      await tester.enterText(nameField(), 'SUMMER maid');
      await tester.pump();
      expect(find.text('A mod with this name already exists'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      await tester.enterText(nameField(), '   ');
      await tester.pump();
      expect(saveEnabled(tester), isFalse);

      await tester.enterText(nameField(), 'Winter Maid Blue');
      await tester.pump();
      expect(find.textContaining('Name contains'), findsNothing);
      expect(saveEnabled(tester), isTrue);
    });

    testEdit('a mod whose folder is being written is not renamed, and the window says why', (tester) async {
      temp.createMod('Winter Maid');
      final container = await openEdit(tester, mod('Winter Maid'));
      holdWrite(container, 'Winter Maid');

      await tester.enterText(nameField(), 'Winter Maid Blue');
      await tester.pump();

      expect(find.textContaining('is being changed by an update'), findsWidgets);
      expect(saveEnabled(tester), isFalse);
      await tapWithIo(tester, save());
      expect(temp.modFolder('Winter Maid').existsSync(), isTrue);
      expect(closed, isFalse);
    });

    testEdit('a write that is running says Save waits, even when the name is unchanged', (tester) async {
      temp.createMod('Winter Maid');
      final container = await openEdit(tester, mod('Winter Maid'));
      holdWrite(container, 'Winter Maid');

      await tester.enterText(descriptionField(), 'text');
      await tester.pump();

      expect(find.textContaining('Save once that'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });

    testEdit('renames the folder last, and the sidecar and the other edits travel with it', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));

      await tester.enterText(nameField(), 'Winter Maid Blue');
      await tester.pump();
      await tester.enterText(descriptionField(), 'The blue one');
      await tester.pump();
      await pressSave(tester);

      expect(result?.renamedTo, 'Winter Maid Blue');
      expect(closed, isTrue);
      expect(temp.modFolder('Winter Maid').existsSync(), isFalse);
      expect(sidecar('Winter Maid Blue')['description'], 'The blue one');
    });

    testEdit('a rename that is refused leaves every other edit saved and the folder where it was', (tester) async {
      temp.createMod('Winter Maid');
      expect(await tester.runAsync(() => temp.service.activateMod('Winter Maid')), isTrue);
      // A folder of the new name that is not the mod's link, in ZZMI's Mods folder.
      Directory(p.join(temp.saveMods.path, 'Winter Maid Blue')).createSync();
      final container = await openEdit(tester, mod('Winter Maid', isActive: true));

      await tester.enterText(nameField(), 'Winter Maid Blue');
      await tester.pump();
      await tester.enterText(descriptionField(), 'Edited anyway');
      await tester.pump();
      await pressSave(tester);

      expect(result?.renamedTo, isNull);
      expect(closed, isTrue);
      expect(temp.modFolder('Winter Maid').existsSync(), isTrue);
      expect(sidecar('Winter Maid')['description'], 'Edited anyway');
      final card = container.read(notificationsProvider).single;
      expect(card.kind, NotificationKind.error);
      expect(card.title, "Couldn't rename the mod");
    });
  });

  group('Author', () {
    testEdit('is seeded from the page the session holds when the mod stores none', (tester) async {
      temp.createMod('Winter Maid');
      final origin = originFixture(modId: 100, modIdConfidence: OriginConfidence.exact);
      await openEdit(
        tester,
        mod('Winter Maid', origin: origin),
        overrides: [
          fetchedModPagesProvider.overrideWith(
            (ref) => {
              100: const GbMod(
                idRow: 100,
                name: 'Maid',
                submitter: GbSubmitter(idRow: 1, name: 'Frostbyte'),
              ),
            },
          ),
        ],
      );

      expect(tester.widget<TextField>(authorField()).controller!.text, 'Frostbyte');
    });

    testEdit('is stored when changed, and not copied from the page just by saving', (tester) async {
      temp.createMod('Winter Maid');
      temp.createMod('Summer Maid');
      final origin = originFixture(modId: 100, modIdConfidence: OriginConfidence.exact);
      final overrides = [
        fetchedModPagesProvider.overrideWith(
          (ref) => {
            100: const GbMod(
              idRow: 100,
              name: 'Maid',
              submitter: GbSubmitter(idRow: 1, name: 'Frostbyte'),
            ),
          },
        ),
      ];
      await openEdit(tester, mod('Winter Maid', origin: origin), overrides: overrides);
      await tester.enterText(descriptionField(), 'x');
      await tester.pump();
      await pressSave(tester);
      expect(sidecar('Winter Maid').containsKey('author'), isFalse, reason: 'the page\'s name is shown, not stored');
      expect(result?.updated.author, isNull);

      closed = false;
      await tester.pumpAndSettle();
      await openEdit(tester, mod('Summer Maid', origin: origin), overrides: overrides);
      await tester.enterText(authorField(), 'Someone Else');
      await tester.pump();
      expect(saveEnabled(tester), isTrue);
      await pressSave(tester);
      expect(sidecar('Summer Maid')['author'], 'Someone Else');
      expect(result?.updated.author, 'Someone Else');
    });

    testEdit('an emptied author removes the stored one', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid', author: 'frostbyte'));

      await tester.enterText(authorField(), '');
      await tester.pump();
      await pressSave(tester);

      expect(sidecar('Winter Maid').containsKey('author'), isFalse);
    });
  });

  group('Tags', () {
    Finder tagInput() => find.widgetWithText(TextField, '').last;

    testEdit('Enter and a comma add tags, a repeat in any letter case is dropped, Backspace takes the last out', (
      tester,
    ) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid', tags: ['Outfit']));

      final input = find.descendant(of: find.byType(TagsField), matching: find.byType(TextField));
      await tester.tap(input);
      await tester.enterText(input, 'Maid');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Maid'), findsOneWidget);

      await tester.enterText(input, 'winter, OUTFIT, Coat,');
      await tester.pump();
      expect(find.text('winter'), findsOneWidget);
      expect(find.text('OUTFIT'), findsNothing, reason: 'Outfit is already there');
      expect(find.text('Coat'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(find.text('Coat'), findsNothing, reason: 'Backspace in the empty field takes the last chip out');
      expect(find.text('winter'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Remove tag Maid'));
      await tester.pump();
      expect(find.text('Maid'), findsNothing);
      expect(closed, isFalse, reason: 'Enter in the tag field never saves the dialog');
      expect(tagInput(), findsOneWidget);

      await pressSave(tester);
      expect(sidecar('Winter Maid')['tags'], ['Outfit', 'winter']);
    });

    testEdit('text still in the field when Save is pressed becomes a tag', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));

      final input = find.descendant(of: find.byType(TagsField), matching: find.byType(TextField));
      await tester.enterText(input, 'Loose');
      await tester.pump();
      expect(saveEnabled(tester), isTrue, reason: 'typing a tag is a change');
      await pressSave(tester);

      expect(sidecar('Winter Maid')['tags'], ['Loose']);
    });

    testEdit('suggests the tags other mods carry that this one lacks, most used first, three at most', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', tags: ['Outfit']),
        others: [
          mod('A', tags: ['Outfit', 'Recolor', 'Accessory']),
          mod('B', tags: ['recolor', 'Accessory', 'Lore']),
          mod('C', tags: ['Recolor', 'Toggleable', 'Zed']),
        ],
      );

      expect(find.text('Suggested'), findsOneWidget);
      expect(find.text('Recolor'), findsOneWidget);
      expect(find.text('Accessory'), findsOneWidget);
      expect(find.text('Lore'), findsOneWidget, reason: 'the third, alphabetical among the single uses');
      expect(find.text('Zed'), findsNothing);
      expect(find.text('Outfit'), findsOneWidget, reason: 'a tag the mod has is not suggested');

      await tester.tap(find.text('Recolor'));
      await tester.pump();
      expect(find.text('Recolor'), findsOneWidget, reason: 'now a chip, no longer a suggestion');
      expect(find.text('Toggleable'), findsOneWidget, reason: 'the next one takes its place');
    });

    testEdit('no suggestion row when no other mod has a tag to offer', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', tags: ['Outfit']),
        others: [
          mod('A', tags: ['outfit']),
        ],
      );

      expect(find.text('Suggested'), findsNothing);
    });
  });

  group('Use GameBanana text', () {
    const modId = 531649;
    final profileUrl = Uri.parse('https://gamebanana.com/apiv13/Mod/$modId/ProfilePage');
    final pageText = RemoteModMetadata.fromMod(
      GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!,
    ).description!;
    late FakeHttpTransport http;

    setUp(() {
      http = FakeHttpTransport()..stub(profileUrl, body: loadGbFixture('mod_profile_531649'));
    });

    List<Override> client() => [
      gameBananaClientProvider.overrideWithValue(GameBananaClient(transport: http, maxRetries: 0)),
    ];

    ModOrigin tracked({OriginTracking tracking = OriginTracking.auto}) =>
        originFixture(modId: modId, modIdConfidence: OriginConfidence.exact, tracking: tracking);

    testEdit('offers the page\'s text and marks a description that differs, and pressing it replaces the text', (
      tester,
    ) async {
      temp.createMod('RabbitFX');
      await openEdit(
        tester,
        mod('RabbitFX', description: 'My own words', origin: tracked()),
        overrides: client(),
      );

      expect(find.text('Edited'), findsOneWidget);
      expect(find.text('Use GameBanana text'), findsOneWidget);

      await tester.tap(find.text('Use GameBanana text'));
      await tester.pump();

      expect(tester.widget<TextField>(descriptionField()).controller!.text, pageText);
      expect(find.text('Edited'), findsNothing);
      expect(find.text('Use GameBanana text'), findsNothing);
      expect(saveEnabled(tester), isTrue, reason: 'the replacement is staged until Save');

      await pressSave(tester);
      expect(sidecar('RabbitFX')['description'], pageText);
    });

    testEdit('an untouched description has no marker and no button, and an empty one has the button only', (
      tester,
    ) async {
      temp.createMod('RabbitFX');
      await openEdit(
        tester,
        mod('RabbitFX', description: pageText, origin: tracked()),
        overrides: client(),
      );
      expect(find.text('Edited'), findsNothing);
      expect(find.text('Use GameBanana text'), findsNothing);

      await tester.enterText(descriptionField(), '');
      await tester.pump();
      expect(find.text('Edited'), findsNothing, reason: 'an empty field is not an edit of the page');
      expect(find.text('Use GameBanana text'), findsOneWidget);
    });

    testEdit('both are absent while the page loads, and when it cannot be fetched', (tester) async {
      temp.createMod('RabbitFX');
      http = FakeHttpTransport()..enqueueError(profileUrl, const SocketException('offline'));
      final container = await openEdit(
        tester,
        mod('RabbitFX', description: 'Mine', origin: tracked()),
        overrides: client(),
      );

      expect(find.text('Use GameBanana text'), findsNothing);
      expect(find.text('Edited'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(container.read(notificationsProvider), isEmpty, reason: 'no error is raised');
    });

    testEdit('a mod that is not tracked, or has no page, fetches nothing', (tester) async {
      temp.createMod('RabbitFX');
      await openEdit(
        tester,
        mod(
          'RabbitFX',
          description: 'Mine',
          origin: tracked(tracking: OriginTracking.off),
        ),
        overrides: client(),
      );
      expect(http.requests, isEmpty);
      expect(find.text('Use GameBanana text'), findsNothing);
    });

    testEdit('a page the session already holds with its text is not fetched again', (tester) async {
      temp.createMod('RabbitFX');
      final held = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
      await openEdit(
        tester,
        mod('RabbitFX', description: 'Mine', origin: tracked()),
        overrides: [
          ...client(),
          fetchedModPagesProvider.overrideWith((ref) => {modId: held}),
        ],
      );

      expect(http.requests, isEmpty);
      expect(find.text('Use GameBanana text'), findsOneWidget);
    });
  });

  group('Cover', () {
    late Directory pictures;

    setUp(() {
      pictures = Directory(p.join(temp.root.path, 'pictures'))..createSync();
    });

    File picture(String name, {int seed = 1}) =>
        File(p.join(pictures.path, name))..writeAsBytesSync(List.generate(64, (i) => (i * seed) % 256));

    testEdit('shows the dotted ground and the initials when the mod has no picture', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));

      expect(find.text('Cover'), findsOneWidget);
      expect(find.text('Pick a screenshot or drop an image here.'), findsOneWidget);
      expect(find.bySemanticsLabel('Choose an image file'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Use screenshot')), findsNothing);
    });

    testEdit('a picture picked, one dropped and one pasted join the gallery and are imported on Save', (tester) async {
      temp.createMod('Winter Maid');
      final picked = picture('picked.png');
      final dropped = picture('dropped.jpg', seed: 3);
      FilePicker.platform = _FakePicker([picked.path]);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pasteboard'),
        (call) async => call.method == 'image' ? Uint8List.fromList(List.generate(32, (i) => i)) : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null),
      );
      await openEdit(tester, mod('Winter Maid'));

      await tester.tap(find.bySemanticsLabel('Choose an image file').first);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Use screenshot 1 as cover'), findsOneWidget);

      final target = tester.widgetList<DropTarget>(find.byType(DropTarget)).single;
      target.onDragDone?.call(
        DropDoneDetails(
          files: [XFile(dropped.path), XFile(p.join(pictures.path, 'notes.txt'))],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Use screenshot 2 as cover'), findsOneWidget);
      expect(find.bySemanticsLabel('Use screenshot 3 as cover'), findsNothing, reason: 'a text file is not a picture');

      // Ctrl+V with focus on a button, not in a text field.
      await tester.tap(find.bySemanticsLabel('Use screenshot 2 as cover'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.bySemanticsLabel('Use screenshot 3 as cover'), findsOneWidget);

      await pressSave(tester);

      final images = (sidecar('Winter Maid')['images'] as List).cast<String>();
      expect(images, hasLength(3));
      // Pressing the second picture made it the cover, so it is first.
      expect(images.first, startsWith('.zzz-mod-manager/images/'));
      for (final image in images) {
        expect(temp.has('Winter Maid', image), isTrue, reason: image);
      }
      expect(result?.updated.imagePath, p.join(temp.modFolder('Winter Maid').path, images.first));
    });

    testEdit('pressing a picture makes it the cover, and the × takes it out, deleting only a managed copy', (
      tester,
    ) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', '.zzz-mod-manager/images/01.png', 'a');
      temp.write('Winter Maid', '.zzz-mod-manager/images/02.png', 'b');
      temp.write('Winter Maid', 'Preview.png', 'c');
      final folder = temp.modFolder('Winter Maid').path;
      final images = [
        p.join(folder, '.zzz-mod-manager/images/01.png'),
        p.join(folder, '.zzz-mod-manager/images/02.png'),
        p.join(folder, 'Preview.png'),
      ];
      await openEdit(tester, mod('Winter Maid', images: images));

      await tester.tap(find.bySemanticsLabel('Use screenshot 3 as cover'));
      await tester.pump();
      expect(find.bySemanticsLabel('Use screenshot 3 as cover'), findsOneWidget);

      // The × shows while the pointer is over a picture.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      expect(find.bySemanticsLabel('Remove screenshot 3'), findsNothing, reason: 'only on hover or focus');
      await gesture.moveTo(tester.getCenter(find.bySemanticsLabel('Use screenshot 3 as cover')));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Remove screenshot 3'));
      await tester.pump();
      expect(find.bySemanticsLabel('Use screenshot 3 as cover'), findsNothing);

      await pressSave(tester);

      // Preview.png first (the cover now), then 01.png; 02.png was a managed copy and is gone.
      expect(sidecar('Winter Maid')['images'], ['Preview.png', '.zzz-mod-manager/images/01.png']);
      expect(temp.has('Winter Maid', '.zzz-mod-manager/images/02.png'), isFalse);
      expect(temp.has('Winter Maid', '.zzz-mod-manager/images/01.png'), isTrue);
    });

    testEdit('a shipped Preview.png that is taken out only leaves the gallery', (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'Preview.png', 'c');
      final images = [p.join(temp.modFolder('Winter Maid').path, 'Preview.png')];
      await openEdit(tester, mod('Winter Maid', images: images));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.bySemanticsLabel('Use screenshot 1 as cover')));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Remove screenshot 1'));
      await tester.pump();
      await pressSave(tester);

      expect(sidecar('Winter Maid')['images'], isEmpty);
      expect(temp.has('Winter Maid', 'Preview.png'), isTrue, reason: 'the mod\'s own file stays');
    });

    testEdit('an empty clipboard says so and adds nothing', (tester) async {
      temp.createMod('Winter Maid');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pasteboard'),
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null),
      );
      final container = await openEdit(tester, mod('Winter Maid'));

      // A press anywhere on the cover puts the keyboard there, off the Name field that had it.
      await tester.tap(find.text('Pick a screenshot or drop an image here.'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(container.read(notificationsProvider).single.title, 'Clipboard is empty');
      expect(find.bySemanticsLabel(RegExp('Use screenshot')), findsNothing);
    });
  });

  group('Tracking', () {
    testEdit('says where an untracked, a Local and a tracked mod stand', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));
      expect(find.text('Not tracked'), findsOneWidget);
      expect(find.text("The app doesn't know where this mod came from, so it can't look for updates."), findsOneWidget);
      expect(find.text('Update tracking…'), findsOneWidget);
    });

    testEdit('a mod marked as your own says it is never checked', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid', origin: originFixture(tracking: OriginTracking.off)));
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('You marked this mod as your own, so it is never checked for updates.'), findsOneWidget);
    });

    testEdit('a tracked mod says newer uploads show up as updates', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', origin: originFixture(modId: 100, modIdConfidence: OriginConfidence.exact)),
      );
      expect(find.text('GameBanana'), findsOneWidget);
      expect(find.text('Newer uploads show up as updates.'), findsOneWidget);
    });

    testEdit('a tracked mod whose file and page the session holds names the file and its date', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod(
          'Winter Maid',
          origin: originFixture(
            modId: 100,
            modIdConfidence: OriginConfidence.exact,
            fileId: 7,
            versionConfidence: OriginConfidence.exact,
          ),
        ),
        overrides: [
          fetchedModPagesProvider.overrideWith(
            (ref) => {
              100: GbMod(
                idRow: 100,
                name: 'Maid',
                files: [GbFile(idRow: 7, file: 'WinterMaid_v1.4.zip', dateAdded: DateTime.utc(2026, 9, 28))],
              ),
            },
          ),
        ],
      );

      expect(find.textContaining('WinterMaid_v1.4.zip, uploaded'), findsOneWidget);
      expect(find.textContaining('Newer uploads show up as updates.'), findsOneWidget);
    });
  });

  group('In-game keys', () {
    Finder keysButton(String section, {String file = 'mod.ini', int occurrence = 0}) =>
        find.byKey(ValueKey('key_${file}_${section}_${occurrence}_null'));

    Future<ProviderContainer> openWithKeys(
      WidgetTester tester, {
      String ini = keyIni,
      List<Override> overrides = const [],
    }) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'mod.ini', ini);
      final keybinds = await keysOf(tester, 'Winter Maid');
      return openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40, overrides: overrides);
    }

    Future<void> record(
      WidgetTester tester,
      Finder button,
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool alt = false,
    }) async {
      await tester.tap(button);
      await tester.pump();
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testEdit('lists a row for each key with its label and keycaps', (tester) async {
      await openWithKeys(tester);

      expect(find.text('In-game keys'), findsOneWidget);
      expect(find.textContaining('Changing a key edits'), findsOneWidget);
      expect(find.text('WHAT IT DOES'), findsOneWidget);
      expect(find.text('KEYS'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Coat'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Hair'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      expect(find.bySemanticsLabel('Keys for action 1: Alt 1'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });

    testEdit('a mod that binds no keys says so, and has the section anyway', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(tester, mod('Winter Maid'));

      expect(find.text('This mod binds no keys.'), findsOneWidget);
    });

    testEdit('pressing a key button records the next combination, and shows "was" for the old one', (tester) async {
      await openWithKeys(tester);

      await tester.tap(keysButton('KeyCoat'));
      await tester.pump();
      expect(find.text('Press a key combo…'), findsOneWidget);
      expect(find.bySemanticsLabel('Recording keys for action 1'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Press a key combo…'), findsOneWidget, reason: 'a modifier alone records nothing');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.text('Press a key combo…'), findsNothing);
      expect(find.text('was Alt 1'), findsOneWidget);
      expect(find.bySemanticsLabel('Keys for action 1: Ctrl 5, changed from Alt 1'), findsOneWidget);
      expect(saveEnabled(tester), isTrue);
      expect(
        find.text(
          'Saving writes 1 changed key to mod.ini. An update replaces key changes with the author\'s keys. The rest of your edits stay.',
        ),
        findsOneWidget,
      );
    });

    testEdit('Tab, Enter and Space are recorded, not acted on', (tester) async {
      await openWithKeys(tester);

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.tab);
      expect(find.bySemanticsLabel('Keys for action 1: TAB, changed from Alt 1'), findsOneWidget);
      expect(closed, isFalse);

      await record(tester, keysButton('KeyHair'), LogicalKeyboardKey.enter);
      expect(find.bySemanticsLabel('Keys for action 2: RETURN, changed from Ctrl 2'), findsOneWidget);
      expect(closed, isFalse, reason: 'Enter while recording never saves the dialog');

      await record(tester, keysButton('KeyHair'), LogicalKeyboardKey.space);
      expect(find.bySemanticsLabel('Keys for action 2: SPACE, changed from Ctrl 2'), findsOneWidget);
    });

    testEdit('Escape cancels the recording and keeps the old value, and does not close the dialog', (tester) async {
      await openWithKeys(tester);

      await tester.tap(keysButton('KeyCoat'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Press a key combo…'), findsNothing);
      expect(find.bySemanticsLabel('Keys for action 1: Alt 1'), findsOneWidget);
      expect(find.byType(EditModDialog), findsOneWidget);
      expect(closed, isFalse);

      // With nothing recording, Escape closes the dialog as it always does.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testEdit('a click elsewhere cancels the recording', (tester) async {
      await openWithKeys(tester);

      await tester.tap(keysButton('KeyCoat'));
      await tester.pump();
      await tester.tap(find.text('Edit mod info'));
      await tester.pump();

      expect(find.text('Press a key combo…'), findsNothing);
      expect(find.bySemanticsLabel('Keys for action 1: Alt 1'), findsOneWidget);
    });

    testEdit('a key with no name in an .ini is refused inline and nothing is staged', (tester) async {
      await openWithKeys(tester);

      await tester.tap(keysButton('KeyCoat'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlay);
      await tester.pump();

      expect(find.text("That key can't be written to an .ini."), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });

    testEdit('the no_ tokens of the old key stay in the new one', (tester) async {
      await openWithKeys(tester, ini: '[KeyCoat]\nkey = ctrl no_shift VK_UP\n');

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit4, ctrl: true);
      await pressSave(tester);

      expect(
        temp.read('Winter Maid', 'mod.ini'),
        '[KeyCoat]\n;zenith: key = ctrl no_shift VK_UP\nkey = ctrl no_shift 4\n',
      );
    });

    testEdit('Save writes the key with a marker, keeps every other line, and the label goes to the config', (
      tester,
    ) async {
      await openWithKeys(tester);

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit5, ctrl: true);
      await tester.enterText(find.widgetWithText(TextField, 'Hair'), 'Hairpin style');
      await tester.pump();
      await pressSave(tester);

      expect(
        temp.read('Winter Maid', 'mod.ini'),
        '[KeyCoat]\n;zenith: key = alt 1\nkey = ctrl 5\n\n[KeyHair]\nkey = ctrl 2\ncondition = \$a == 1\n',
      );
      expect(result?.keysWritten, isTrue);
      expect(temp.config.modKeyLabels, {
        'Winter Maid': {'keyhair': 'Hairpin style'},
      });
    });

    testEdit('a label equal to the default is not stored, and an emptied one removes the stored one', (tester) async {
      temp.createMod('Winter Maid');
      await tester.runAsync(
        () => temp.config.setModKeyLabels('Winter Maid', {'keycoat': 'Coat on / off', 'keyhair': 'Hairpin style'}),
      );
      temp.write('Winter Maid', 'mod.ini', keyIni);
      final keybinds = await keysOf(tester, 'Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', keybinds: keybinds),
        overrides: [
          modKeysProvider.overrideWith(
            (ref) => {
              'Winter Maid': {'keycoat': 'Coat on / off', 'keyhair': 'Hairpin style'},
            },
          ),
        ],
      );

      await tester.enterText(find.widgetWithText(TextField, 'Coat on / off'), 'Coat');
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Hairpin style'), '');
      await tester.pump();
      await pressSave(tester);

      expect(temp.config.modKeyLabels, isEmpty);
      expect(result?.keysWritten, isFalse, reason: 'labels write no .ini');
      expect(temp.read('Winter Maid', 'mod.ini'), keyIni);
    });

    testEdit('a key set back to the author\'s own leaves no marker', (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'mod.ini', '[KeyCoat]\n;zenith: key = alt 1\nkey = ctrl 5\n');
      final keybinds = await keysOf(tester, 'Winter Maid');
      await openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40);

      expect(find.text('was Alt 1'), findsOneWidget, reason: 'the marker is read from the file');
      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit1, alt: true);
      await pressSave(tester);

      expect(temp.read('Winter Maid', 'mod.ini'), '[KeyCoat]\nkey = alt 1\n');
    });

    testEdit('Remove stages unbinding the section, and Save comments it out', (tester) async {
      await openWithKeys(tester);

      await tester.tap(find.byTooltip('Remove action 2'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Hair'), findsNothing);
      expect(saveEnabled(tester), isTrue);
      await pressSave(tester);

      expect(
        temp.read('Winter Maid', 'mod.ini'),
        '[KeyCoat]\nkey = alt 1\n\n;zenith: [KeyHair]\n;zenith: key = ctrl 2\n;zenith: condition = \$a == 1\n',
      );
    });

    testEdit('Restore the author\'s keys is staged, enabled only when something would change, and Cancel drops it', (
      tester,
    ) async {
      temp.createMod('Winter Maid');
      temp.write(
        'Winter Maid',
        'mod.ini',
        '[KeyCoat]\n;zenith: key = alt 1\nkey = ctrl 5\n\n;zenith: [KeyOld]\n;zenith: key = f4\n',
      );
      final keybinds = await keysOf(tester, 'Winter Maid');
      await openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40);

      TextButton restore() => tester.widget<TextButton>(find.widgetWithText(TextButton, "Restore the author's keys"));
      expect(restore().onPressed, isNotNull, reason: 'a marker and a commented-out section');
      expect(find.widgetWithText(TextField, 'Old'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, "Restore the author's keys"));
      await tester.pump();

      expect(find.bySemanticsLabel('Keys for action 1: Alt 1'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Old'), findsOneWidget, reason: 'the commented-out section is a row again');
      expect(restore().onPressed, isNull, reason: 'nothing more to restore');
      expect(temp.read('Winter Maid', 'mod.ini'), contains('key = ctrl 5'), reason: 'nothing is written until Save');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(temp.read('Winter Maid', 'mod.ini'), contains('key = ctrl 5'));
    });

    testEdit('Save after Restore writes the author\'s keys back and uncomments the section', (tester) async {
      temp.createMod('Winter Maid');
      temp.write(
        'Winter Maid',
        'mod.ini',
        '[KeyCoat]\n;zenith: key = alt 1\nkey = ctrl 5\n\n;zenith: [KeyOld]\n;zenith: key = f4\n',
      );
      final keybinds = await keysOf(tester, 'Winter Maid');
      await openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40);

      await tester.tap(find.widgetWithText(TextButton, "Restore the author's keys"));
      await tester.pump();
      await pressSave(tester);

      expect(temp.read('Winter Maid', 'mod.ini'), '[KeyCoat]\nkey = alt 1\n\n[KeyOld]\nkey = f4\n');
    });

    testEdit('Restore is disabled for a mod nobody has changed', (tester) async {
      await openWithKeys(tester);

      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, "Restore the author's keys")).onPressed, isNull);
    });

    testEdit('the footer names the file, and says "and other .ini files" for several', (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'a.ini', '[KeyA]\nkey = 1\n');
      temp.write('Winter Maid', 'parts/b.ini', '[KeyB]\nkey = 2\n');
      final keybinds = await keysOf(tester, 'Winter Maid');
      await openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40);

      await record(tester, keysButton('KeyA', file: 'a.ini'), LogicalKeyboardKey.digit5);
      expect(find.textContaining('Saving writes 1 changed key to a.ini.'), findsOneWidget);

      await record(tester, keysButton('KeyB', file: 'parts/b.ini'), LogicalKeyboardKey.digit6);
      expect(find.textContaining('Saving writes your key changes to a.ini and other .ini files.'), findsOneWidget);
    });

    testEdit('two keys changed in one file are counted as keys', (tester) async {
      await openWithKeys(tester);

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit5);
      await record(tester, keysButton('KeyHair'), LogicalKeyboardKey.digit6);

      expect(find.textContaining('Saving writes 2 changed keys to mod.ini.'), findsOneWidget);
    });

    testEdit('a file that has become something else since the dialog opened is reported, and the others are still written', (
      tester,
    ) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'a.ini', '[KeyA]\nkey = 1\n');
      temp.write('Winter Maid', 'b.ini', '[KeyB]\nkey = 2\n');
      final keybinds = await keysOf(tester, 'Winter Maid');
      final container = await openEdit(tester, mod('Winter Maid', keybinds: keybinds), ioRounds: 40);

      await record(tester, keysButton('KeyA', file: 'a.ini'), LogicalKeyboardKey.digit5);
      await record(tester, keysButton('KeyB', file: 'b.ini'), LogicalKeyboardKey.digit6);
      // Saved in another program as Latin-1 while the dialog was open.
      File(
        p.join(temp.modFolder('Winter Maid').path, 'b.ini'),
      ).writeAsBytesSync([...latin1.encode('[KeyB]\nkey = 2\n; caf'), 0xE9, 0x0A]);
      await pressSave(tester);

      expect(temp.read('Winter Maid', 'a.ini'), contains('key = 5'));
      final warning = container.read(notificationsProvider).single;
      expect(warning.title, "Some keys weren't saved");
      expect(warning.body, contains('b.ini'));
    });

    testEdit('Change keys opens with the keys in view', (tester) async {
      temp.createMod('Winter Maid');
      await openEdit(
        tester,
        mod('Winter Maid', description: List.generate(40, (i) => 'line $i').join('\n')),
        section: EditSection.keys,
        surfaceSize: const Size(1200, 700),
      );

      expect(tester.getTopLeft(find.text('In-game keys')).dy, lessThan(700));
    });

    testEdit('while the game runs, saved keys say F10 is needed; otherwise nothing is said', (tester) async {
      final container = await openWithKeys(
        tester,
        overrides: [isGameRunningProvider.overrideWithValue(() async => true)],
      );

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit5);
      await pressSave(tester);

      final note = container.read(notificationsProvider).single;
      expect(note.title, 'Winter Maid: keys saved');
      expect(note.keycap, 'F10');
    });

    testEdit('with the game closed, saved keys raise no card', (tester) async {
      final container = await openWithKeys(tester);

      await record(tester, keysButton('KeyCoat'), LogicalKeyboardKey.digit5);
      await pressSave(tester);

      expect(container.read(notificationsProvider), isEmpty);
    });
  });
}

/// Answers the picker with [paths] without opening a window.
class _FakePicker extends FilePicker {
  _FakePicker(this.paths);

  final List<String> paths;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => paths.isEmpty
      ? null
      : FilePickerResult([for (final path in paths) PlatformFile(path: path, name: p.basename(path), size: 1)]);
}
