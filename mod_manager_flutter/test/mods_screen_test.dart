import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/character_hero.dart';
import 'package:mod_manager_flutter/screens/components/character_list.dart';
import 'package:mod_manager_flutter/screens/components/mod_card_widget.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/screens/components/tracking_nudge.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/screens/mods_screen.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';
import 'package:path/path.dart' as p;

import 'support/localized_harness.dart';
import 'support/mods_screen_harness.dart';
import 'support/temp_library.dart';

/// The Library page as a whole: the page's one scroll view, the details panel beside or over it, the drop tile, the
/// paste key, and what a toggle that fails says (`docs/library-screen.md`).
void main() {
  late TempLibrary temp;

  setUp(() async {
    temp = await TempLibrary.create(prefix: 'zzz_mods_screen_');
  });

  ModInfo mod(String id, {String characterId = 'ellen', bool isActive = false}) =>
      ModInfo(id: id, name: id, characterId: characterId, isActive: isActive);

  final ellens = [for (var i = 0; i < 30; i++) mod('Ellen ${'$i'.padLeft(2, '0')}')];

  group('at the smallest window', () {
    // The window's minimum is 800×500; less the sidebar, the title bar and the status bar, the page gets 584×428.
    testWidgets('the header, the filters and the tracking reminder scroll away to show the mods', (tester) async {
      await pumpModsScreen(
        tester,
        temp,
        [for (var i = 0; i < 6; i++) mod('Ellen ${'$i'.padLeft(2, '0')}')],
        surfaceSize: const Size(584, 428),
        showTrackingNudge: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(TrackingNudge), findsOneWidget, reason: 'the reminder shows for untracked mods');
      expect(tester.getRect(find.byType(TrackingNudge)).bottom, greaterThan(428),
          reason: 'what sits above the grid is taller than the page, so held in place it would overflow');

      await tester.scrollUntilVisible(
        find.byType(ModCardWidget).hitTestable(),
        100,
        scrollable: pageScrollable(),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ModCardWidget).hitTestable(), findsWidgets);
    });
  });

  group('the details panel keeps the page where it was', () {
    // The page is the same child of the same Stack whether the panel is closed, beside it or over it, so it keeps
    // its scroll position through every open and close.
    Future<void> scrollOpenAndClose(WidgetTester tester, {required bool beside}) async {
      pagePosition(tester).jumpTo(600);
      await tester.pumpAndSettle();
      // A card in the scrolled-to part of the grid, whose name is on screen to be pressed.
      final page = tester.getRect(pageScrollable());
      final name = ellens
          .map((m) => find.descendant(of: cardOf(m.id), matching: find.text(m.name)))
          .firstWhere((f) => f.evaluate().isNotEmpty && page.contains(tester.getCenter(f)));

      await tester.tap(name);
      await tester.pumpAndSettle();
      expect(find.byType(ModDetailsPanel), findsOneWidget);
      final panel = tester.getRect(find.byType(ModDetailsPanel));
      expect(panel.left >= tester.getRect(pageScrollable()).right, beside,
          reason: beside ? 'beside the page' : 'over the page');
      expect(pagePosition(tester).pixels, 600, reason: 'opening the panel');

      await tester.tap(find.byTooltip('Close details'));
      await tester.pumpAndSettle();
      expect(find.byType(ModDetailsPanel), findsNothing);
      expect(pagePosition(tester).pixels, 600, reason: 'closing the panel');
    }

    testWidgets('beside it, in a wide window', (tester) async {
      await pumpModsScreen(tester, temp, ellens);
      expect(find.byType(ModCardWidget), findsWidgets);
      await scrollOpenAndClose(tester, beside: true);
    });

    testWidgets('over it, in a narrow one', (tester) async {
      // 1000 less the character list leaves 720, and 720 less the panel is under the 420 a column of cards needs.
      await pumpModsScreen(tester, temp, ellens, surfaceSize: const Size(1000, 800));
      await scrollOpenAndClose(tester, beside: false);
    });
  });

  group('Ctrl+V', () {
    /// A clipboard holding [text], for the page's paste and a text field's alike.
    void clipboardHolds(WidgetTester tester, String text) {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    /// Inside `runAsync`, so the import's folder check and the note's save can reach the disk.
    Future<void> pressPaste(WidgetTester tester, {bool settle = true}) async {
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        // Past the note's 600ms pause, so its save is done before the library is torn down.
        await Future<void>.delayed(const Duration(milliseconds: 800));
      });
      if (settle) await tester.pumpAndSettle();
    }

    const noValid = 'No mod folders or archives found';

    String nowhere() => p.join(temp.root.path, 'not a folder');

    testWidgets('on the page imports what the clipboard names', (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      clipboardHolds(tester, nowhere());

      await pressPaste(tester);

      // The path is not a folder, which is how far the import gets: it did try.
      expect(find.text(noValid), findsOneWidget);
    });

    testWidgets('of an archive imports the mod inside it', (tester) async {
      final ini = '[TextureOverrideBody]\n'.codeUnits;
      final archive = Archive()..addFile(ArchiveFile('Swimsuit/Swimsuit.ini', ini.length, ini));
      final zip = File(p.join(temp.root.path, 'Swimsuit.zip'))..writeAsBytesSync(ZipEncoder().encode(archive)!);
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      clipboardHolds(tester, zip.path);

      await pressPaste(tester, settle: false);
      // The import raises a progress dialog between its disk steps, so frames and real time take turns. Its
      // spinner never settles.
      final done = find.text('Imported successfully!');
      for (var i = 0; i < 40 && done.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();

      expect(find.text(noValid), findsNothing, reason: 'an existing archive is something to import');
      expect(done, findsOneWidget);
      expect(File(p.join(temp.modFolder('Swimsuit').path, 'Swimsuit.ini')).existsSync(), isTrue);
    });

    testWidgets("in the note is the note's paste, not an import", (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      await tester.tap(find.text('Winter Maid'));
      await tester.pumpAndSettle();
      final note = find.descendant(of: find.byType(ModDetailsPanel), matching: find.byType(TextField));
      await tester.tap(note);
      await tester.pumpAndSettle();
      clipboardHolds(tester, nowhere());

      await pressPaste(tester);

      expect(find.text(noValid), findsNothing);
      expect(find.text('No paths found'), findsNothing);
      expect(tester.widget<TextField>(note).controller!.text, nowhere());
    });

    testWidgets("in the character filter is the field's paste too", (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final filter = find.descendant(of: find.byType(CharacterList), matching: find.byType(TextField));
      await tester.tap(filter);
      await tester.pumpAndSettle();
      clipboardHolds(tester, 'miya');

      await pressPaste(tester);

      expect(find.text(noValid), findsNothing);
      expect(tester.widget<TextField>(filter).controller!.text, 'miya');
    });

    group('across the window going inactive and back', () {
      // Flutter parks focus at the root of the app while the window is inactive on a desktop, and hands it back on
      // return; the page must not take it in between.
      Future<void> switchWindowAwayAndBack(WidgetTester tester) async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
      }

      testWidgets('a dialog over the page keeps its field and its Ctrl+V', (tester) async {
        await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
        final field = TextEditingController();
        addTearDown(field.dispose);
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(ModsScreen)),
            builder: (_) => AlertDialog(content: TextField(controller: field, autofocus: true)),
          ),
        );
        await tester.pumpAndSettle();
        final dialogField = find.descendant(of: find.byType(AlertDialog), matching: find.byType(EditableText));
        expect(tester.state<EditableTextState>(dialogField).widget.focusNode.hasFocus, isTrue);

        await switchWindowAwayAndBack(tester);

        expect(tester.state<EditableTextState>(dialogField).widget.focusNode.hasFocus, isTrue);
        clipboardHolds(tester, nowhere());
        await pressPaste(tester);
        expect(find.text(noValid), findsNothing, reason: 'the paste is the dialog field\'s, not an import under it');
        expect(field.text, nowhere());
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

      testWidgets('the note keeps its caret', (tester) async {
        await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
        await tester.tap(find.text('Winter Maid'));
        await tester.pumpAndSettle();
        final note = find.descendant(of: find.byType(ModDetailsPanel), matching: find.byType(EditableText));
        await tester.tap(note);
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(note).widget.focusNode.hasFocus, isTrue);

        await switchWindowAwayAndBack(tester);

        expect(tester.state<EditableTextState>(note).widget.focusNode.hasFocus, isTrue);
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    });

    testWidgets('after a click away from the character filter is the page\'s again', (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final filter = find.descendant(of: find.byType(CharacterList), matching: find.byType(TextField));
      await tester.tap(filter);
      await tester.enterText(filter, 'ell');
      await tester.pumpAndSettle();

      // A mouse click on the header, which lets go of the field without taking focus itself.
      final header = tester.getTopLeft(find.byType(CharacterHero)) + const Offset(8, 8);
      await tester.tapAt(header, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      clipboardHolds(tester, nowhere());

      await pressPaste(tester);

      expect(find.text(noValid), findsOneWidget);
      expect(tester.widget<TextField>(filter).controller!.text, 'ell');
    });
  });

  group('the drop tile', () {
    const detects = 'Its character is worked out from its name';

    /// What the tile says a drop does: detect, or "It lands on <name> automatically".
    String? hint(WidgetTester tester) {
      if (find.text(detects).evaluate().isNotEmpty) return detects;
      final landsOn = find.textContaining('It lands on');
      return landsOn.evaluate().isEmpty ? null : tester.widget<Text>(landsOn).data;
    }

    /// Clicks the character list's row for [id], scrolling down to it.
    Future<void> pickRow(WidgetTester tester, String id) async {
      final row = find.descendant(of: find.byType(CharacterList), matching: find.byKey(ValueKey('character_$id')));
      final list = find.descendant(of: find.byType(CharacterList), matching: find.byType(ListView));
      await tester.dragUntilVisible(row, list, const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets('works the character out from the name before one is picked', (tester) async {
      // Ellen is on screen as the first agent with a mod, which is the app's fallback, not the user's choice.
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      expect(container.read(currentCharacterIdProvider), 'ellen');
      expect(hint(tester), detects);
    });

    testWidgets('files under the character the user picked, even the one already on screen', (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      expect(hint(tester), detects);

      // The same character stays on screen; only who chose it changes.
      await pickRow(tester, 'ellen');

      expect(hint(tester), 'It lands on Ellen Joe automatically');
    });

    testWidgets("works the character out on one the app picked, as the sidebar's Updates does", (tester) async {
      final container = await pumpModsScreen(
        tester,
        temp,
        [mod('Winter Maid'), mod('Cherry Blossom', characterId: 'miyabi')],
      );
      await pickRow(tester, 'ellen');
      expect(hint(tester), 'It lands on Ellen Joe automatically');

      container.read(selectedCharacterIdProvider.notifier).state = 'miyabi';
      container.read(characterPickedByUserProvider.notifier).state = false;
      await tester.pumpAndSettle();

      expect(container.read(currentCharacterIdProvider), 'miyabi');
      expect(hint(tester), detects);
    });

    testWidgets('works the character out on Unassigned, which has no one to file under', (tester) async {
      final container = await pumpModsScreen(tester, temp, [mod('Loose', characterId: unknownCharacterId)]);
      await pickRow(tester, unknownCharacterId);
      expect(container.read(currentCharacterIdProvider), unknownCharacterId);
      expect(hint(tester), detects);
    });

    testWidgets('stays out of a filtered grid', (tester) async {
      final container = await pumpModsScreen(
        tester,
        temp,
        [mod('Winter Maid'), mod('Swimsuit', isActive: true)],
        selected: 'ellen',
      );
      container.read(modGridFilterProvider.notifier).state = ModGridFilter.active;
      await tester.pumpAndSettle();

      expect(find.byType(ModCardWidget), findsOneWidget);
      expect(hint(tester), isNull, reason: 'it would read as one of the results');
    });

    testWidgets('is all a character with no mods shows, whatever the filter', (tester) async {
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')], selected: 'miyabi');
      container.read(modGridFilterProvider.notifier).state = ModGridFilter.active;
      await tester.pumpAndSettle();

      expect(find.text('Drop a folder, .zip, .7z or .rar'), findsOneWidget);
    });

    testWidgets('pressing it says how to add a mod', (tester) async {
      await pumpModsScreen(tester, temp, [mod('Winter Maid')]);

      await tester.tap(find.text('Drop a folder, .zip, .7z or .rar'));
      await tester.pumpAndSettle();

      expect(find.text('Add mods'), findsOneWidget);
    });
  });

  testWidgets("a card's semantics read the mod's name once", (tester) async {
    final handle = tester.ensureSemantics();
    await pumpModsScreen(tester, temp, [mod('Winter Maid')]);

    // The card's own node, whose label is the name inside it. The switch's label names the mod as well, as its own.
    final label =
        tester.getSemantics(find.descendant(of: cardOf('Winter Maid'), matching: find.byType(ModCardWidget))).label;
    expect('Winter Maid'.allMatches(label).length, 1, reason: 'the label reads "$label"');
    handle.dispose();
  });

  group('a toggle that fails says so', () {
    Finder switchOf(String id) => find.descendant(of: cardOf(id), matching: find.byType(ZenithSwitch));

    testWidgets('turning on a mod whose folder is gone', (tester) async {
      // Listed, but not on disk: there is nothing to link.
      await pumpModsScreen(tester, temp, [mod('Ghost')]);

      await tapWithIo(tester, switchOf('Ghost'));

      expect(find.text('Mod not turned on'), findsOneWidget);
      expect(find.descendant(of: find.byType(NotificationOverlay), matching: find.text('Ghost')), findsOneWidget);
    });

    testWidgets('turning off a mod with no link to remove', (tester) async {
      temp.createMod('Unlinked');
      await pumpModsScreen(tester, temp, [mod('Unlinked', isActive: true)]);

      await tapWithIo(tester, switchOf('Unlinked'));

      expect(find.text('Mod not turned off'), findsOneWidget);
    });

    testWidgets('a toggle that works says nothing', (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'Winter Maid.ini', '[TextureOverrideBody]\n');
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);

      await tapWithIo(tester, switchOf('Winter Maid'));

      expect(find.text('Mod not turned on'), findsNothing);
      expect(container.read(modsProvider).single.isActive, isTrue);
      expect(Link(p.join(temp.saveMods.path, 'Winter Maid')).existsSync(), isTrue);
    });
  });
}
