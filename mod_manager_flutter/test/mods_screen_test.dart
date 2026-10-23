import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/character_hero.dart';
import 'package:mod_manager_flutter/screens/components/character_list.dart';
import 'package:mod_manager_flutter/screens/components/mod_card_widget.dart';
import 'package:mod_manager_flutter/screens/components/mod_details_panel.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/components/notification_overlay.dart';
import 'package:mod_manager_flutter/screens/components/zenith_switch.dart';
import 'package:mod_manager_flutter/screens/mod_page/mod_page.dart';
import 'package:mod_manager_flutter/screens/mods_screen.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:mod_manager_flutter/services/update_apply/mod_activation_port.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';
import 'package:path/path.dart' as p;

import 'support/all_mods_harness.dart';
import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/link_fails_under.dart';
import 'support/localized_harness.dart';
import 'support/mods_screen_harness.dart';
import 'support/origin_shorthand.dart';
import 'support/recording_service.dart';
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
    testWidgets('the header and the filters scroll away to show the mods', (tester) async {
      await pumpModsScreen(
        tester,
        temp,
        [for (var i = 0; i < 6; i++) mod('Ellen ${'$i'.padLeft(2, '0')}')],
        surfaceSize: const Size(584, 428),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(ModsToolbar)).bottom, greaterThan(428),
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
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final raised = <AppNotification>[];
      container.listen(notificationsProvider, (_, next) => raised.addAll(next));
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
      final unpacking = raised.where((n) => n.kind == NotificationKind.working).toList();
      expect(unpacking.map((n) => n.title), contains('Unpacking 1 archive…'));
      expect(unpacking.first.body, 'Swimsuit.zip');
      expect(container.read(notificationsProvider).where((n) => n.kind == NotificationKind.working), isEmpty,
          reason: 'the card is down before the import goes on');
    });

    testWidgets("of a locked archive whose password is not given raises no Working card and says nothing", (tester) async {
      final ini = '[TextureOverrideBody]\n'.codeUnits;
      final archive = Archive()..addFile(ArchiveFile('Locked/Locked.ini', ini.length, ini));
      final zip = File(p.join(temp.root.path, 'Locked.zip'))
        ..writeAsBytesSync(ZipEncoder(password: 'SECRET').encode(archive)!);
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final raised = <AppNotification>[];
      container.listen(notificationsProvider, (_, next) => raised.addAll(next));
      clipboardHolds(tester, zip.path);

      await pressPaste(tester);
      expect(find.text("Don't install"), findsOneWidget, reason: 'the password is asked for first');
      await tester.runAsync(() async {
        await tester.tap(find.text("Don't install"));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(raised.where((n) => n.kind == NotificationKind.working), isEmpty, reason: 'there is nothing to unpack');
      expect(find.text('Nothing to import'), findsNothing, reason: 'the user was asked and answered');
      expect(temp.modFolder('Locked').existsSync(), isFalse);
    });

    testWidgets('of a patch put into an existing mod shows a Working card, which becomes the patch applied', (tester) async {
      temp.write('Ellen Maid', 'Ellen Maid.ini', '[TextureOverrideBody]\n');
      temp.write('Ellen Maid', 'Textures/Body.dds', 'v1');
      final fix = Directory(p.join(temp.root.path, 'Ellen Fix'));
      File(p.join(fix.path, 'Textures', 'Body.dds'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v2');
      final container = await pumpModsScreen(tester, temp, [mod('Ellen Maid')]);
      final raised = <AppNotification>[];
      container.listen(notificationsProvider, (_, next) => raised.addAll(next));
      clipboardHolds(tester, fix.path);

      Future<void> pumpUntil(Finder finder) async {
        for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsWidgets);
      }

      await pressPaste(tester, settle: false);
      await pumpUntil(find.text('Install it into an existing mod'));
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Ellen Maid')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Install')));
      await tester.pump();
      final applied = find.descendant(of: find.byType(NotificationOverlay), matching: find.text('Patch applied'));
      await pumpUntil(applied);

      expect(temp.read('Ellen Maid', 'Textures/Body.dds'), 'v2');
      final working = raised.firstWhere((n) => n.kind == NotificationKind.working && n.title == 'Applying the patch…');
      expect(working.body, 'Ellen Maid');
      final card = container.read(notificationsProvider).single;
      expect(card.id, working.id, reason: 'the Working card became the patch applied rather than raising a second card');
      expect(card.kind, NotificationKind.done);
      // Past the Done card's clock, so the test ends with nothing on one.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets("of a patch put into an existing mod drops that mod's update verdict, and only its", (tester) async {
      // The verdict names the folder's layers, and the patch is a new one.
      temp.write('Ellen Maid', 'Ellen Maid.ini', '[TextureOverrideBody]\n');
      temp.write('Ellen Maid', 'Textures/Body.dds', 'v1');
      temp.createMod('Winter Maid');
      final fix = Directory(p.join(temp.root.path, 'Ellen Fix'));
      File(p.join(fix.path, 'Textures', 'Body.dds'))
        ..createSync(recursive: true)
        ..writeAsStringSync('v2');
      final container = await pumpModsScreen(tester, temp, [mod('Ellen Maid'), mod('Winter Maid')]);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Ellen Maid': const UpdateCheck(outcome: UpdateOutcome.upToDate),
        'Winter Maid': const UpdateCheck(outcome: UpdateOutcome.upToDate),
      };
      clipboardHolds(tester, fix.path);

      Future<void> pumpUntil(Finder finder) async {
        for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsWidgets);
      }

      await pressPaste(tester, settle: false);
      await pumpUntil(find.text('Install it into an existing mod'));
      await tester.tap(find.text('Install it into an existing mod'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Ellen Maid')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text('Install')));
      await tester.pump();
      await pumpUntil(find.descendant(of: find.byType(NotificationOverlay), matching: find.text('Patch applied')));

      expect(container.read(modUpdateChecksProvider).keys, ['Winter Maid']);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets("of an archive that can't be unpacked turns its Working card into the error, and Copy details copies it",
        (tester) async {
      final zip = File(p.join(temp.root.path, 'Broken.zip'))..writeAsStringSync('not a zip');
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final raised = <AppNotification>[];
      container.listen(notificationsProvider, (_, next) => raised.addAll(next));
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': zip.path};
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pressPaste(tester);

      final working = raised.firstWhere((n) => n.kind == NotificationKind.working);
      expect(working.title, 'Unpacking 1 archive…');
      final error = container.read(notificationsProvider).firstWhere((n) => n.kind == NotificationKind.error);
      expect(error.id, working.id, reason: 'the Working card became the error rather than raising a second card');
      expect(error.title, 'Import failed');
      expect(error.body, startsWith('Broken.zip: '));

      await tester.runAsync(() async {
        await tester.tap(find.descendant(of: find.byType(NotificationOverlay), matching: find.text('Copy details')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(copied, '${error.title}\n${error.body}');
      expect(find.text('Details copied'), findsOneWidget);
      // Past the Done card's clock, so the test ends with nothing on one.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
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

    testWidgets('works the character out on one the app picked', (tester) async {
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

  testWidgets('All mods says why the library failed to load, with Retry, as the character view does', (tester) async {
    final container = await pumpModsScreen(
      tester,
      temp,
      const [],
      library: libraryFailing(const FileSystemException('Permission denied', '/mods')),
    );
    for (final view in [AppDestination.characters, AppDestination.allMods]) {
      container.read(destinationProvider.notifier).state = view;
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget, reason: '$view');
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '$view');
    }
  });

  testWidgets('a renamed mod keeps its All mods tick under its new name', (tester) async {
    // The menu's items are sized for the app's font, not the test font's full-em glyphs.
    await loadTableFonts(tester);
    temp.createMod('Winter Maid');
    final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
    container.read(allModsSelectionProvider.notifier).state = {'Winter Maid'};
    await tester.pumpAndSettle();

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Winter Maid Blue');
    await tester.pump();
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Rename'));

    expect(temp.modFolder('Winter Maid Blue').existsSync(), isTrue);
    expect(container.read(allModsSelectionProvider), {'Winter Maid Blue'});
  });

  testWidgets('a rename left off under its new name moves the tick and the selection with it', (tester) async {
    await loadTableFonts(tester);
    final platform = LinkFailsUnder('Winter Maid Blue');
    final left = (await tester.runAsync(() => TempLibrary.create(prefix: 'zzz_left_off_', platform: platform)))!;
    platform.occupying = left.modFolder('Winter Maid').path;
    left.createMod('Winter Maid');
    expect(await tester.runAsync(() => left.service.activateMod('Winter Maid')), isTrue);
    final container = await pumpModsScreen(tester, left, [mod('Winter Maid', isActive: true)]);
    container.read(allModsSelectionProvider.notifier).state = {'Winter Maid'};
    container.read(selectedModIdProvider.notifier).state = 'Winter Maid';
    await tester.pumpAndSettle();

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Winter Maid Blue');
    await tester.pump();
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Rename'));

    expect(left.modFolder('Winter Maid Blue').existsSync(), isTrue);
    expect(container.read(allModsSelectionProvider), {'Winter Maid Blue'});
    expect(container.read(selectedModIdProvider), 'Winter Maid Blue');
  });

  testWidgets('a rename that leaves the mod off raises a warning that stays until closed', (tester) async {
    // The mod won't load until it is turned back on, so the warning must not leave on its own.
    await loadTableFonts(tester);
    final platform = LinkFailsUnder('Winter Maid Blue');
    final left = (await tester.runAsync(() => TempLibrary.create(prefix: 'zzz_left_off_', platform: platform)))!;
    platform.occupying = left.modFolder('Winter Maid').path;
    left.createMod('Winter Maid');
    expect(await tester.runAsync(() => left.service.activateMod('Winter Maid')), isTrue);
    final container = await pumpModsScreen(tester, left, [mod('Winter Maid', isActive: true)]);

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Winter Maid Blue');
    await tester.pump();
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Rename'));

    final warning = container.read(notificationsProvider).single;
    expect(warning.kind, NotificationKind.warning);
    expect(warning.title, 'The mod is renamed, but off');
    expect(warning.stays, isTrue);
    expect(warning.hasClock, isFalse);
  });

  testWidgets('a mod whose folder is being written is not renamed, and the dialog says why', (tester) async {
    await loadTableFonts(tester);
    temp.createMod('Winter Maid');
    final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
    // Never released: the test ends with the write still running.
    holdWrite(container, 'Winter Maid');

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Winter Maid Blue');
    await tester.pump();

    expect(find.textContaining('is being changed by an update'), findsOneWidget);
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Rename'));
    expect(temp.modFolder('Winter Maid').existsSync(), isTrue);
    expect(temp.modFolder('Winter Maid Blue').existsSync(), isFalse);
  });

  testWidgets('a right-click names each patch by the page the session already has', (tester) async {
    // The menu's items are sized for the app's font, not the test font's full-em glyphs.
    await loadTableFonts(tester);
    temp.createMod('Winter Maid');
    InstalledFile added(String path) => InstalledFile(path: path, role: InstalledFileRole.added);
    final origin = originFixture(
      modId: 100,
      modIdConfidence: OriginConfidence.exact,
      patches: [
        patchFixture(modId: 1001, files: [added('a.dds')]),
        patchFixture(modId: 1002, files: [added('b.dds')]),
      ],
    );
    final container = await pumpModsScreen(tester, temp, [
      ModInfo(id: 'Winter Maid', name: 'Winter Maid', characterId: 'ellen', isActive: false, origin: origin),
    ]);
    container.read(fetchedModPagesProvider.notifier).state = {1001: const GbMod(idRow: 1001, name: 'Ellen Fix')};
    await tester.pump();

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Remove patch: Ellen Fix'), findsOneWidget);
    expect(find.text('Remove patch: #1002'), findsOneWidget, reason: 'nothing is fetched for a menu');
  });

  testWidgets('an Ignore still written after the page is left still has the library read again', (tester) async {
    // The update dialog answers once its writes end, and by then the screen that opened it can be gone.
    await loadTableFonts(tester);
    temp.createMod('Winter Maid');
    final origin = originFixture(
      modId: 100,
      modIdConfidence: OriginConfidence.exact,
      fileId: 10,
      versionConfidence: OriginConfidence.exact,
    );
    await tester.runAsync(() => temp.writeOrigin('Winter Maid', origin));
    final service = RecordingService(temp)..holdOriginWrites = Completer<void>();
    final container = await pumpModsScreen(
      tester,
      temp,
      [ModInfo(id: 'Winter Maid', name: 'Winter Maid', characterId: 'ellen', isActive: false, origin: origin)],
      services: service.overrides,
    );
    container.read(modUpdateChecksProvider.notifier).state = {
      'Winter Maid': UpdateCheck(
        outcome: UpdateOutcome.updateAvailable,
        candidate: GbFile(idRow: 11, dateAdded: DateTime.utc(2026, 6, 19)),
      ),
    };
    await tester.pump();

    await tester.tap(cardOf('Winter Maid'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore this update'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // Another page in the screen's place, so the screen that opened the dialog is gone.
    await pumpLocalized(tester, const SizedBox(), container: container);
    expect(find.byType(ModsScreen), findsNothing);
    final scans = container.read(libraryScansProvider);

    // The write reaches the disk, so frames and real time take turns until the rescan lands.
    service.holdOriginWrites!.complete();
    for (var i = 0; i < 40 && container.read(libraryScansProvider) == scans; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }

    expect(container.read(libraryScansProvider), scans + 1);
    expect(container.read(modUpdateChecksProvider)['Winter Maid']?.dismissed, isTrue);
  });

  testWidgets("a mod deleted from its details takes its All mods tick with it", (tester) async {
    // Or a mod installed later under the same name comes in ticked.
    temp.createMod('Winter Maid');
    final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
    container.read(allModsSelectionProvider.notifier).state = {'Winter Maid', 'Other'};
    container.read(selectedModIdProvider.notifier).state = 'Winter Maid';
    await tester.pumpAndSettle();

    await tapWithIo(tester, find.byTooltip('Delete mod'));
    await tapWithIo(tester, find.widgetWithText(FilledButton, 'Delete'));

    expect(temp.modFolder('Winter Maid').existsSync(), isFalse);
    expect(container.read(allModsSelectionProvider), {'Other'});
  });

  testWidgets('a drag onto a row that fails turns its Working card into the error, with no second card',
      (tester) async {
    // Listed, but not on disk: there is no sidecar to write the character into.
    final container = await pumpModsScreen(tester, temp, [mod('Ghost')], selected: 'ellen');

    final gesture = await tester.startGesture(tester.getCenter(cardOf('Ghost')));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('character_cat_ui'))));
    await tester.pump();
    final ids = <int>{};
    final sub = container.listen(notificationsProvider, (_, next) => ids.addAll(next.map((n) => n.id)), fireImmediately: true);
    addTearDown(sub.close);
    await tester.runAsync(() async {
      await gesture.up();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final card = container.read(notificationsProvider).single;
    expect(card.kind, NotificationKind.error);
    expect(card.title, 'Mod not moved');
    expect(ids, {card.id}, reason: 'the Working card became the error rather than raising a second card');
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

    testWidgets('one that throws offers Open folder on the mod first, then Copy details', (tester) async {
      final throwing = (await tester.runAsync(
        () => TempLibrary.create(prefix: 'zzz_toggle_throws_', platform: _LinkUnreadable()),
      ))!;
      // Shader files make the enable's dry run read the link, which is what throws.
      throwing.write('Lab Coat', 'ShaderFixes/fix.txt', 'x');
      final container = await pumpModsScreen(tester, throwing, [mod('Lab Coat')]);
      container.read(modsPathProvider.notifier).state = throwing.mods.path;

      await tapWithIo(tester, switchOf('Lab Coat'));

      final card = container.read(notificationsProvider).single;
      expect(card.kind, NotificationKind.error);
      expect(card.actions.map((a) => a.label), ['Open folder', 'Copy details']);
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

    testWidgets('the switch is greyed out and a press ignored while a bulk action runs', (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'Winter Maid.ini', '[TextureOverrideBody]\n');
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      container.read(allModsBulkRunningProvider.notifier).state = true;
      await tester.pump();

      expect(tester.widget<ZenithSwitch>(switchOf('Winter Maid')).onChanged, isNull);
      await tapWithIo(tester, switchOf('Winter Maid'));
      expect(Link(p.join(temp.saveMods.path, 'Winter Maid')).existsSync(), isFalse);
    });

    testWidgets("the details panel's and the mod page's switches are greyed out while a bulk action runs",
        (tester) async {
      temp.createMod('Winter Maid');
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      container.read(selectedModIdProvider.notifier).state = 'Winter Maid';
      container.read(allModsBulkRunningProvider.notifier).state = true;
      await tester.pumpAndSettle();

      final panelSwitch = find.descendant(of: find.byType(ModDetailsPanel), matching: find.byType(ZenithSwitch));
      expect(tester.widget<ZenithSwitch>(panelSwitch).onChanged, isNull);

      container.read(openModPageProvider.notifier).state = const ModPageRequest('Winter Maid');
      await tester.pumpAndSettle();
      final pageSwitch = find.descendant(of: find.byType(LibraryModPage), matching: find.byType(ZenithSwitch));
      expect(tester.widget<ZenithSwitch>(pageSwitch).onChanged, isNull);
    });

    testWidgets('a switch press holds the bulk actions off until it is done, and greys out no switch',
        (tester) async {
      temp.createMod('Winter Maid');
      temp.write('Winter Maid', 'Winter Maid.ini', '[TextureOverrideBody]\n');
      final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
      final presses = <int>[];
      container.listen(libraryTogglesProvider, (_, waiting) => presses.add(waiting));
      final bulk = <bool>[];
      container.listen(allModsBulkRunningProvider, (_, running) => bulk.add(running));

      await tapWithIo(tester, switchOf('Winter Maid'));

      expect(presses, [1, 0]);
      expect(bulk, isEmpty, reason: 'that flag greys out the switches');
      expect(container.read(modsProvider).single.isActive, isTrue);
    });

    testWidgets('a press that fails lets the bulk actions run again', (tester) async {
      // Listed, but not on disk: the enable fails.
      final container = await pumpModsScreen(tester, temp, [mod('Ghost')]);

      await tapWithIo(tester, switchOf('Ghost'));

      expect(find.text('Mod not turned on'), findsOneWidget);
      expect(container.read(libraryTogglesProvider), 0);
    });

    group("while a mod's folder is being written", () {
      bool linked(String id) => Link(p.join(temp.saveMods.path, id)).existsSync();

      /// Holds a write on [id], as an update or a restore does, until [done] completes. Started on the real event
      /// loop, so it can end there.
      Future<void> holdWrite(WidgetTester tester, ProviderContainer container, String id, Completer<void> done) async {
        await tester.runAsync(() async => unawaited(whileWritingMod(container, id, () => done.future)));
        await tester.pump();
      }

      /// Ends the write [holdWrite] started, and lets what waited on it land.
      Future<void> endWrite(WidgetTester tester, Completer<void> done) async {
        await tester.runAsync(() async {
          done.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      Future<void> pressAndWait(WidgetTester tester, String id) => tester.runAsync(() async {
            await tester.tap(switchOf(id));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });

      testWidgets('a press on it waits for the write, then lands', (tester) async {
        temp.createMod('Winter Maid');
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);
        final done = Completer<void>();
        await holdWrite(tester, container, 'Winter Maid', done);

        expect(tester.widget<ZenithSwitch>(switchOf('Winter Maid')).onChanged, isNotNull);
        await pressAndWait(tester, 'Winter Maid');
        expect(linked('Winter Maid'), isFalse, reason: 'the folder is still being written');
        expect(container.read(libraryTogglesProvider), 1);

        await endWrite(tester, done);

        expect(linked('Winter Maid'), isTrue);
        expect(container.read(modsProvider).single.isActive, isTrue);
        expect(container.read(libraryTogglesProvider), 0);
      });

      testWidgets("a press on another mod doesn't wait, even behind a press that does", (tester) async {
        temp.createMod('Winter Maid');
        temp.createMod('Starlight');
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid'), mod('Starlight')]);
        // So both can be on, and the second press doesn't turn the first mod off.
        container.read(oneAtATimeProvider.notifier).state = {'ellen': false};
        final done = Completer<void>();
        await holdWrite(tester, container, 'Winter Maid', done);

        await pressAndWait(tester, 'Winter Maid');
        await pressAndWait(tester, 'Starlight');

        expect(linked('Starlight'), isTrue);
        expect(linked('Winter Maid'), isFalse);

        await endWrite(tester, done);
        expect(linked('Winter Maid'), isTrue);
      });

      // Read off: a rescan during the write sees the link the write took out.
      for (final readOff in [false, true]) {
      testWidgets(
          "One at a time turns it off at once for another of its character's mods, and the write leaves it off"
          "${readOff ? ', when the library already reads it off' : ''}", (tester) async {
        File(p.join(temp.root.path, 'd3dx.ini')).writeAsStringSync('[Rendering]\noverride_directory = ShaderFixes\n');
        temp.createMod('Winter Maid');
        temp.write('Winter Maid', 'ShaderFixes/abc123-ps_replace.txt', 'shader');
        temp.createMod('Starlight');
        await tester.runAsync(() => temp.service.activateMod('Winter Maid'));
        final placed = File(p.join(temp.root.path, 'ShaderFixes', 'abc123-ps_replace.txt'));
        expect(placed.existsSync(), isTrue);
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid', isActive: true), mod('Starlight')]);

        // A write's own turn-off and turn-back-on, held between the two, as an update holds them around its copy.
        final done = Completer<void>();
        await tester.runAsync(() async {
          unawaited(whileWritingMod(container, 'Winter Maid', () async {
            final port = ModManagerActivationPort(temp.service, leaveOff: (m) => leftOffAfterWrite(container, m));
            await port.deactivate('Winter Maid');
            await done.future;
            await port.activate('Winter Maid');
          }));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        if (readOff) container.read(libraryProvider.notifier).put([mod('Winter Maid'), mod('Starlight')]);
        await tester.pump();

        await pressAndWait(tester, 'Starlight');
        expect(linked('Starlight'), isTrue, reason: "it doesn't wait for the other mod's write");

        await endWrite(tester, done);
        expect(linked('Starlight'), isTrue);
        expect(linked('Winter Maid'), isFalse);
        expect(placed.existsSync(), isFalse, reason: 'its shader files are not placed again');
        expect(find.text('Mod not turned on'), findsNothing);
        expect(leftOffAfterWrite(container, 'Winter Maid'), isFalse, reason: 'the mark ends with the write');
      });
      }
    });

    group('while a press is landing', () {
      late RecordingService service;

      setUp(() {
        service = RecordingService(temp)
          ..install()
          ..holdActivation = Completer<void>();
      });

      /// Presses [id]'s switch with the key the keyboard uses, and leaves the enable held.
      Future<void> pressWithKeyboard(WidgetTester tester, String id) async {
        final node = Focus.of(tester.element(find.descendant(of: switchOf(id), matching: find.byType(GestureDetector))));
        node.requestFocus();
        await tester.pump();
        await tester.runAsync(() async {
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
      }

      Future<void> release(WidgetTester tester) async {
        await tester.runAsync(() async {
          service.holdActivation!.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      testWidgets('every switch stays live, and the one pressed keeps the keyboard', (tester) async {
        temp.createMod('Winter Maid');
        temp.createMod('Starlight');
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid'), mod('Starlight')]);
        container.read(selectedModIdProvider.notifier).state = 'Winter Maid';
        await tester.pumpAndSettle();

        await pressWithKeyboard(tester, 'Winter Maid');

        expect(container.read(libraryTogglesProvider), 1, reason: 'the press is held mid-way');
        for (final element in find.byType(ZenithSwitch).evaluate()) {
          expect((element.widget as ZenithSwitch).onChanged, isNotNull);
        }
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(focused?.findAncestorWidgetOfExactType<ZenithSwitch>(), isNotNull,
            reason: 'a switch greyed out mid-press drops the focus, and the next Space reaches the card');

        await release(tester);
        expect(container.read(modsProvider).firstWhere((m) => m.id == 'Winter Maid').isActive, isTrue);
      });

      testWidgets('a second switch waits its turn, so One at a time leaves one mod on', (tester) async {
        // Ellen's mods are One at a time unless the user turned it off.
        temp.createMod('Winter Maid');
        temp.createMod('Starlight');
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid'), mod('Starlight')]);

        await tester.runAsync(() async {
          await tester.tap(switchOf('Winter Maid'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.tap(switchOf('Starlight'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        expect(container.read(libraryTogglesProvider), 2);
        await release(tester);

        expect(container.read(libraryTogglesProvider), 0);
        expect({for (final m in container.read(modsProvider)) m.id: m.isActive}, {
          'Winter Maid': false,
          'Starlight': true,
        });
        expect(Link(p.join(temp.saveMods.path, 'Winter Maid')).existsSync(), isFalse);
        expect(Link(p.join(temp.saveMods.path, 'Starlight')).existsSync(), isTrue);
      });

      testWidgets('pressing the same switch again asks for the same thing, not the opposite', (tester) async {
        temp.createMod('Winter Maid');
        final container = await pumpModsScreen(tester, temp, [mod('Winter Maid')]);

        await tester.runAsync(() async {
          await tester.tap(switchOf('Winter Maid'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.tap(switchOf('Winter Maid'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await release(tester);

        expect(container.read(modsProvider).single.isActive, isTrue);
        expect(Link(p.join(temp.saveMods.path, 'Winter Maid')).existsSync(), isTrue);
      });
    });
  });
}

/// Links as Linux makes them, except that reading one throws: a toggle that fails with an exception.
class _LinkUnreadable extends LinuxPlatformService {
  @override
  Future<String?> readModLinkTarget(String linkPath) async => throw FileSystemException('unreadable', linkPath);
}
