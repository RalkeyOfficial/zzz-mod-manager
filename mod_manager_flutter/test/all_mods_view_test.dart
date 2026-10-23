import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/all_mods/all_mods_view.dart';
import 'package:mod_manager_flutter/screens/components/library_actions_host.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/all_mods_harness.dart';
import 'support/held_write.dart';
import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

/// The All mods page: its Can't be checked filter, "mark as current" from the selection bar, and the Updates column.
void main() {
  late ProviderContainer container;
  final installedAt = DateTime.utc(2026, 5, 8, 12);

  /// Identity known, file not: asks "Which file?", and has a date to mark it current by.
  ModOrigin whichFile() => originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.inferred,
        provenance: OriginProvenance.importedFolder,
        installedAt: installedAt,
      );

  ModOrigin onFile(OriginConfidence versionConfidence) => originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.inferred,
        fileId: 10,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        installedAt: installedAt,
      );

  ModInfo mod(String name, {ModOrigin? origin}) =>
      ModInfo(id: name, name: name, characterId: 'ellen', isActive: false, origin: origin);

  Future<void> pumpAllMods(
    WidgetTester tester,
    List<ModInfo> mods, {
    OriginWriter? originWriter,
    void Function(ModInfo mod)? onShowUpdate,
    void Function(ModInfo mod)? onResolveOrigin,
    List<DeadModLink> missing = const [],
    ValueListenable<bool>? shown,
    Size surfaceSize = const Size(1400, 900),
  }) async {
    container = ProviderContainer(overrides: [
      libraryOf(mods),
      deadModLinksProvider.overrideWith((ref) async => missing),
    ]);
    addTearDown(container.dispose);

    final page = allModsViewForTest(
      originWriter: originWriter,
      onShowUpdate: onShowUpdate,
      onResolveOrigin: onResolveOrigin,
    );
    await loadTableFonts(tester);
    await pumpLocalized(
      tester,
      LibraryActionsHost(
        updateFetcher: (_) async => throw StateError('no fetch expected'),
        updatesFetcher: (_) async => throw StateError('no fetch expected'),
        originWriter: (_, _) async => OriginWriteResult.writeFailed,
        // [shown] false is another page, which disposes this one.
        child: shown == null
            ? page
            : ValueListenableBuilder<bool>(
                valueListenable: shown,
                builder: (_, value, _) => value ? page : const Text('another page'),
              ),
      ),
      container: container,
      surfaceSize: surfaceSize,
    );
    expectBuilt(AllModsView);
  }

  Finder cantCheckChip() => find.widgetWithText(ZenithChip, "Can't be checked");

  /// A row's own box.
  Finder rowBox(String name) => find.byWidgetPredicate((w) => w is Checkbox && w.semanticLabel == 'Select $name');

  /// A mod's box in the "mark as current" confirmation.
  Finder dialogBox(String name) =>
      find.byWidgetPredicate((w) => w is Checkbox && w.semanticLabel == 'Mark $name as current');

  Future<void> tick(WidgetTester tester, List<String> names) async {
    for (final name in names) {
      await tester.tap(rowBox(name));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('holds together at the minimum window', (tester) async {
    // 800x600 less the sidebar.
    await pumpAllMods(
      tester,
      [for (var i = 0; i < 120; i++) mod('mod $i')],
      surfaceSize: const Size(584, 600),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('every sortable header sorts, reverses, then clears, with its arrow fitting each time', (tester) async {
    await pumpAllMods(tester, [mod('one'), mod('two')]);
    for (final label in ['MOD', 'CHARACTER / TYPE', 'STATUS', 'UPDATES', 'SIZE', 'ADDED']) {
      final sorts = <AllModsSort?>[];
      for (var press = 0; press < 3; press++) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$label, press ${press + 1}');
        sorts.add(container.read(allModsSortProvider));
      }
      expect(sorts[0]!.column, sorts[1]!.column, reason: label);
      expect(sorts[0]!.descending, isNot(sorts[1]!.descending), reason: label);
      expect(sorts[2], isNull, reason: '$label: the third press clears the sort');
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
    }
  });

  testWidgets("the Group by menu ends under its button's right edge, off the window's", (tester) async {
    await pumpAllMods(tester, [mod('one')]);
    final button = tester.getRect(find.widgetWithText(TextButton, 'Group by'));
    await tester.tap(find.text('Group by'));
    await tester.pumpAndSettle();

    final first = tester.getRect(find.widgetWithText(MenuItemButton, "Don't group"));
    final second = tester.getRect(find.widgetWithText(MenuItemButton, 'Character / type'));
    expect(first.right, closeTo(button.right, 1));
    expect(first.right, lessThan(1400 - 16));
    // The same width, so each one's hover fills the menu from side to side.
    expect(second.left, first.left);
    expect(second.right, first.right);
  });

  group('folding a group', () {
    testWidgets('hides its rows, keeps its heading, and leaves them out of select all', (tester) async {
      await pumpAllMods(tester, [
        mod('ellen one'),
        ModInfo(id: 'ui one', name: 'ui one', characterId: 'cat_ui', isActive: false),
        ModInfo(id: 'ui two', name: 'ui two', characterId: 'cat_ui', isActive: false),
      ]);
      container.read(allModsGroupingProvider.notifier).state = AllModsGrouping.character;
      await tester.pumpAndSettle();

      // Headings in the character list's order: the agents, then the categories.
      await tester.tap(find.byType(AnimatedRotation).at(1));
      await tester.pumpAndSettle();
      expect(find.text('ui one'), findsNothing);
      expect(find.text('ui two'), findsNothing);
      expect(find.text('ellen one'), findsOneWidget);
      final uiHeading = find.ancestor(of: find.byType(AnimatedRotation).at(1), matching: find.byType(Row)).first;
      expect(find.descendant(of: uiHeading, matching: find.text('2')), findsOneWidget,
          reason: 'the folded heading keeps its count');

      await tester.tap(
        find.byWidgetPredicate((w) => w is Checkbox && w.semanticLabel == 'Select every mod shown'),
      );
      await tester.pumpAndSettle();
      expect(container.read(allModsSelectionProvider), {'ellen one'});

      await tester.tap(find.byType(AnimatedRotation).at(1));
      await tester.pumpAndSettle();
      expect(find.text('ui one'), findsOneWidget);
    });
  });

  group("the Can't be checked filter", () {
    testWidgets('shows with its count while some mods need attention', (tester) async {
      await pumpAllMods(tester, [
        mod('bare'),
        mod('asks', origin: whichFile()),
        mod('fine', origin: onFile(OriginConfidence.exact)),
      ]);

      expect(cantCheckChip(), findsOneWidget);
      expect(tester.widget<ZenithChip>(cantCheckChip()).count, 2);
    });

    testWidgets('is hidden while none do', (tester) async {
      await pumpAllMods(tester, [mod('fine', origin: onFile(OriginConfidence.exact))]);

      expect(cantCheckChip(), findsNothing);
    });

    testWidgets('alone puts a line under the table that opens the Updates page', (tester) async {
      const line = 'Sort these out on Updates';
      await pumpAllMods(tester, [mod('bare'), mod('fine', origin: onFile(OriginConfidence.exact))]);
      expect(find.text(line), findsNothing);

      await tester.tap(cantCheckChip());
      await tester.pumpAndSettle();
      expect(container.read(allModsFilterProvider), AllModsFilter.needsAttention);
      expect(find.text('fine'), findsNothing);
      expect(find.widgetWithText(ZenithLink, line), findsOneWidget);

      await tester.tap(find.text(line));
      await tester.pump();
      expect(container.read(destinationProvider), AppDestination.updates);

      await tester.tap(find.widgetWithText(ZenithChip, 'All'));
      await tester.pumpAndSettle();
      expect(find.text(line), findsNothing);
    });
  });

  group('marking ticked mods as current', () {
    Finder barButton(String label) => find.widgetWithText(OutlinedButton, label);

    testWidgets('is offered only while a ticked mod asks Which file?', (tester) async {
      await pumpAllMods(tester, [
        mod('asks', origin: whichFile()),
        mod('fine', origin: onFile(OriginConfidence.exact)),
        mod('bare'),
      ]);

      await tick(tester, ['fine', 'bare']);
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.textContaining('as current'), findsNothing);

      await tick(tester, ['asks']);
      expect(barButton('Mark 1 as current'), findsOneWidget);
    });

    testWidgets('opens the confirmation listing exactly the eligible ticked mods', (tester) async {
      await pumpAllMods(tester, [
        mod('a', origin: whichFile()),
        mod('b', origin: whichFile()),
        mod('not ticked', origin: whichFile()),
        mod('bare'),
      ]);
      await tick(tester, ['a', 'b', 'bare']);

      await tester.tap(barButton('Mark 2 as current'));
      await tester.pumpAndSettle();

      expect(find.text('Mark 2 mods as current?'), findsOneWidget);
      expect(dialogBox('a'), findsOneWidget);
      expect(dialogBox('b'), findsOneWidget);
      expect(dialogBox('not ticked'), findsNothing);
      expect(dialogBox('bare'), findsNothing);
    });

    testWidgets('unticking one in the confirmation writes only the rest', (tester) async {
      final written = <String>[];
      final library = [
        mod('a', origin: whichFile()),
        mod('b', origin: whichFile()),
        mod('c', origin: whichFile()),
      ];
      await pumpAllMods(
        tester,
        library,
        originWriter: (name, update) async {
          written.add(name);
          return update(library.firstWhere((m) => m.id == name).origin) == null
              ? OriginWriteResult.declined
              : OriginWriteResult.written;
        },
      );
      await tick(tester, ['a', 'b', 'c']);
      final scans = container.read(libraryScansProvider);
      await tester.tap(barButton('Mark 3 as current'));
      await tester.pumpAndSettle();

      await tester.tap(dialogBox('b'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();

      expect(written, ['a', 'c']);
      expect(container.read(libraryScansProvider), scans + 1, reason: 'the badges are read again');
    });

    testWidgets('leaves a mod whose folder is being written, marks the rest, and names it', (tester) async {
      final written = <String>[];
      await pumpAllMods(
        tester,
        [mod('a', origin: whichFile()), mod('b', origin: whichFile())],
        originWriter: (name, _) async {
          written.add(name);
          return OriginWriteResult.written;
        },
      );
      final hold = holdWrite(container, 'b');
      await tick(tester, ['a', 'b']);
      await tester.tap(barButton('Mark 2 as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark 2 as current'));
      await tester.pumpAndSettle();
      await hold.release();

      expect(written, ['a']);
      final titles = [for (final n in container.read(notificationsProvider)) n.title];
      // The result last, so it ends the burst.
      expect(titles, ['1 mod skipped while its folder is being changed', '1 mod marked as current'],
          reason: "the skipped mod isn't counted with what was marked");
    });

    testWidgets('cancelling writes nothing', (tester) async {
      final written = <String>[];
      await pumpAllMods(
        tester,
        [mod('a', origin: whichFile())],
        originWriter: (name, _) async {
          written.add(name);
          return OriginWriteResult.written;
        },
      );
      await tick(tester, ['a']);
      final scans = container.read(libraryScansProvider);
      await tester.tap(barButton('Mark 1 as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(written, isEmpty);
      expect(container.read(libraryScansProvider), scans);
    });

    testWidgets('the bar stays locked, and the run still reports and rescans, after leaving the page and back',
        (tester) async {
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      final write = Completer<OriginWriteResult>();
      await pumpAllMods(
        tester,
        [mod('a', origin: whichFile())],
        originWriter: (_, _) => write.future,
        shown: shown,
      );
      await tick(tester, ['a']);
      final scans = container.read(libraryScansProvider);
      await tester.tap(barButton('Mark 1 as current'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark 1 as current'));
      // Fixed pumps while the write is held: its Working card never settles.
      await tester.pump(const Duration(milliseconds: 500));
      expect([for (final n in container.read(notificationsProvider)) n.kind], [NotificationKind.working]);

      shown.value = false;
      await tester.pump(const Duration(milliseconds: 500));
      shown.value = true;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<OutlinedButton>(barButton('Delete')).onPressed, isNull);

      write.complete(OriginWriteResult.writeFailed);
      await tester.pumpAndSettle();
      expect([for (final n in container.read(notificationsProvider)) n.title], ['Tracking data not saved']);
      expect(container.read(libraryScansProvider), scans + 1);
      expect(tester.widget<OutlinedButton>(barButton('Delete')).onPressed, isNotNull);
    });
  });

  testWidgets("the header names the canvas's columns, with no File uploaded or Source", (tester) async {
    await pumpAllMods(tester, [mod('one')]);

    for (final label in ['MOD', 'CHARACTER / TYPE', 'STATUS', 'UPDATES', 'SIZE', 'ADDED']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('FILE UPLOADED'), findsNothing);
    expect(find.text('SOURCE'), findsNothing);
  });

  group('the Updates column', () {
    final resolved = <String>[];
    final shownUpdates = <String>[];
    setUp(() {
      resolved.clear();
      shownUpdates.clear();
    });

    final patch = originFixture(
      modId: 1,
      modIdConfidence: OriginConfidence.user,
      fileId: 10,
      versionConfidence: OriginConfidence.user,
      ingest: const ModIngest(patchShaped: true),
      installedAt: installedAt,
    );

    Future<void> pumpColumn(WidgetTester tester, List<ModInfo> mods, {List<DeadModLink> missing = const []}) =>
        pumpAllMods(
          tester,
          mods,
          missing: missing,
          onResolveOrigin: (mod) => resolved.add(mod.id),
          onShowUpdate: (mod) => shownUpdates.add(mod.id),
        );

    Future<void> check(WidgetTester tester, Map<String, UpdateCheck> checks) async {
      container.read(modUpdateChecksProvider.notifier).state = checks;
      await tester.pumpAndSettle();
    }

    /// What the column shows on the row [row] is in, read by place: the texts that start under the heading.
    List<String> cell(WidgetTester tester, Finder row) {
      final heading = tester.getRect(find.text('UPDATES'));
      final y = tester.getCenter(row).dy;
      return [
        for (final element in find.byType(Text).evaluate())
          if (element.renderObject case final RenderBox box when box.hasSize)
            if ((box.localToGlobal(Offset.zero) & box.size) case final rect
                when rect.left >= heading.left - 1 && rect.left < heading.left + 20 && (rect.center.dy - y).abs() < 20)
              (element.widget as Text).data!,
      ];
    }

    List<String> cellOf(WidgetTester tester, String name) => cell(tester, find.text(name));

    testWidgets('a Local mod is grey text with nothing to press', (tester) async {
      await pumpColumn(tester, [mod('own', origin: originFixture(modId: 1, tracking: OriginTracking.off))]);
      await check(tester, {'own': const UpdateCheck(outcome: UpdateOutcome.trackingOff)});

      expect(cellOf(tester, 'own'), ['Local']);
      expect(find.widgetWithText(ZenithBadge, 'Local'), findsNothing);
      expect(find.widgetWithText(ZenithLink, 'Local'), findsNothing);
    });

    testWidgets('Not tracked is a link to the resolve dialog', (tester) async {
      await pumpColumn(tester, [mod('bare')]);

      expect(cellOf(tester, 'bare'), ['Not tracked']);
      await tester.tap(find.widgetWithText(ZenithLink, 'Not tracked'));
      await tester.pumpAndSettle();
      expect(resolved, ['bare']);
    });

    testWidgets('Which file? asks, whatever the check said', (tester) async {
      await pumpColumn(tester, [mod('asks', origin: whichFile())]);
      await check(tester, {'asks': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)});

      expect(cellOf(tester, 'asks'), ['Which file?']);
      expect(find.byTooltip('Say which file you have'), findsOneWidget);
      await tester.tap(find.widgetWithText(ZenithBadge, 'Which file?'));
      await tester.pumpAndSettle();
      expect(resolved, ['asks']);
      expect(shownUpdates, isEmpty);
    });

    testWidgets('Base unknown asks for the base mod', (tester) async {
      await pumpColumn(tester, [mod('patch', origin: patch)]);
      await check(tester, {'patch': const UpdateCheck(outcome: UpdateOutcome.tracksPatchOnly)});

      expect(cellOf(tester, 'patch'), ['Base unknown']);
      expect(find.byTooltip('Name the mod this patch was put on'), findsOneWidget);
      await tester.tap(find.widgetWithText(ZenithBadge, 'Base unknown'));
      await tester.pumpAndSettle();
      expect(resolved, ['patch']);
    });

    testWidgets("Base unknown gives way to a live update of the patch's own page", (tester) async {
      await pumpColumn(tester, [mod('patch', origin: patch)]);
      await check(tester, {'patch': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)});

      expect(cellOf(tester, 'patch'), ['Newer file']);
    });

    testWidgets('a known file with no check is "—", never Up to date', (tester) async {
      await pumpColumn(tester, [mod('fine', origin: onFile(OriginConfidence.exact))]);
      expect(cellOf(tester, 'fine'), ['—']);

      await check(tester, {'other': const UpdateCheck(outcome: UpdateOutcome.upToDate)});
      expect(cellOf(tester, 'fine'), ['—'], reason: "a check that didn't cover this mod");
    });

    testWidgets('Newer file opens the update dialog', (tester) async {
      await pumpColumn(tester, [mod('fine', origin: onFile(OriginConfidence.exact))]);
      await check(tester, {'fine': const UpdateCheck(outcome: UpdateOutcome.updateAvailable)});

      expect(cellOf(tester, 'fine'), ['Newer file']);
      expect(find.byTooltip('See the newer file'), findsOneWidget);
      await tester.tap(find.widgetWithText(ZenithBadge, 'Newer file'));
      await tester.pumpAndSettle();
      expect(shownUpdates, ['fine']);
      expect(resolved, isEmpty);
    });

    testWidgets('Maybe newer opens the update dialog too', (tester) async {
      await pumpColumn(tester, [mod('guessed', origin: onFile(OriginConfidence.inferred))]);
      await check(tester, {'guessed': const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated)});

      expect(cellOf(tester, 'guessed'), ['Maybe newer']);
      expect(find.byTooltip('Possibly outdated — click for details'), findsOneWidget);
      await tester.tap(find.widgetWithText(ZenithBadge, 'Maybe newer'));
      await tester.pumpAndSettle();
      expect(shownUpdates, ['guessed']);
    });

    testWidgets('Up to date is grey text', (tester) async {
      await pumpColumn(tester, [mod('fine', origin: onFile(OriginConfidence.exact))]);
      await check(tester, {'fine': const UpdateCheck(outcome: UpdateOutcome.upToDate)});

      expect(cellOf(tester, 'fine'), ['Up to date']);
      expect(find.widgetWithText(ZenithBadge, 'Up to date'), findsNothing);
      expect(find.byTooltip('Checked by the day you added it, not by its file'), findsNothing);
    });

    testWidgets('an ignored update reads Up to date', (tester) async {
      await pumpColumn(tester, [mod('fine', origin: onFile(OriginConfidence.exact))]);
      await check(tester, {'fine': const UpdateCheck(outcome: UpdateOutcome.updateAvailable, dismissed: true)});

      expect(cellOf(tester, 'fine'), ['Up to date']);
    });

    testWidgets('a mod marked as current says it was checked by its date', (tester) async {
      await pumpColumn(tester, [mod('dated', origin: onFile(OriginConfidence.assumedLatest))]);
      await check(tester, {'dated': const UpdateCheck(outcome: UpdateOutcome.upToDate)});

      expect(cellOf(tester, 'dated'), ['Up to date']);
      expect(find.byTooltip('Checked by the day you added it, not by its file'), findsOneWidget);
      expect(find.text('Dated only'), findsNothing);
    });

    testWidgets('a page GameBanana no longer shows is Not on GameBanana, saying why', (tester) async {
      await pumpColumn(tester, [mod('gone', origin: onFile(OriginConfidence.exact))]);
      await check(tester, {'gone': const UpdateCheck(outcome: UpdateOutcome.sourceGone)});

      expect(cellOf(tester, 'gone'), ['Not on GameBanana']);
      expect(find.byTooltip('Its mod page is private, trashed or withheld by GameBanana'), findsOneWidget);
    });

    testWidgets("a check with nothing to judge by is Couldn't check, saying why", (tester) async {
      await pumpColumn(tester, [mod('silent', origin: onFile(OriginConfidence.exact))]);
      await check(tester, {'silent': const UpdateCheck(outcome: UpdateOutcome.indeterminate)});

      expect(cellOf(tester, 'silent'), ["Couldn't check"]);
      expect(
        find.byTooltip("GameBanana listed no files for it, or its mod page couldn't be reached"),
        findsOneWidget,
      );
    });

    testWidgets('a Folder missing row is "—"', (tester) async {
      await pumpColumn(tester, [], missing: const [DeadModLink(name: 'Gone', target: '/drive/Gone')]);

      expect(cell(tester, find.widgetWithText(ZenithBadge, 'Folder missing')), ['—']);
    });

    for (final locale in const [Locale('en'), Locale('uk')]) {
      testWidgets('every state fits the column in ${locale.languageCode}', (tester) async {
        final mods = [
          mod('newer', origin: onFile(OriginConfidence.exact)),
          mod('maybe', origin: onFile(OriginConfidence.inferred)),
          mod('asks', origin: whichFile()),
          mod('patch', origin: patch),
          mod('bare'),
          mod('gone', origin: onFile(OriginConfidence.exact)),
          mod('silent', origin: onFile(OriginConfidence.exact)),
          mod('fine', origin: onFile(OriginConfidence.exact)),
          mod('own', origin: originFixture(modId: 1, tracking: OriginTracking.off)),
        ];
        container = await pumpAllModsTable(tester, mods, locale: locale);
        await check(tester, {
          'newer': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
          'maybe': const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated),
          'gone': const UpdateCheck(outcome: UpdateOutcome.sourceGone),
          'silent': const UpdateCheck(outcome: UpdateOutcome.indeterminate),
          'fine': const UpdateCheck(outcome: UpdateOutcome.upToDate),
        });

        expect(tester.takeException(), isNull);
        for (final paragraph in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) {
          expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
        }
      });
    }
  });
}
