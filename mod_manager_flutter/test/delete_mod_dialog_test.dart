import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/components/zenith_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/delete_mod_dialog.dart';
import 'package:mod_manager_flutter/services/platform_service.dart' show TrashResult;
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// The question before a delete, and what the flow does with the trash's answer.
void main() {
  ModInfo mod({String name = 'Winter Maid', String characterId = 'ellen', bool active = false}) =>
      ModInfo(id: name, name: name, characterId: characterId, isActive: active);

  Future<void> openDialog(WidgetTester tester, ModInfo mod, {int saved = 0, int bytes = 0}) async {
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => DeleteModDialog(mod: mod, savedVersions: saved, savedBytes: bytes),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectBuilt(DeleteModDialog);
  }

  group('the question', () {
    testWidgets('says the folder goes to the trash, and for an agent that is on what happens to the agent', (tester) async {
      await openDialog(tester, mod(active: true));

      expect(find.text('Delete Winter Maid?'), findsOneWidget);
      expect(
        find.text("The mod folder goes to your system trash. It's active right now, so Ellen Joe goes back to the default look until you turn another mod on."),
        findsOneWidget,
      );
      expect(find.text('Ellen Joe'), findsOneWidget, reason: 'the size is shown once it is measured');
    });

    testWidgets('for a type that is on says the game stops using it, with no "her"', (tester) async {
      await openDialog(tester, mod(characterId: 'cat_ui', active: true));

      expect(find.textContaining("so the game stops using it."), findsOneWidget);
    });

    testWidgets('for a mod that is off says only where the folder goes', (tester) async {
      await openDialog(tester, mod());

      expect(find.text('The mod folder goes to your system trash.'), findsOneWidget);
    });

    testWidgets('has no snapshots box when there are none', (tester) async {
      await openDialog(tester, mod());
      expect(find.byType(Checkbox), findsNothing);
      
    });

    testWidgets('the box carries the count and the size, and is ticked', (tester) async {
      await openDialog(tester, mod(), saved: 2, bytes: 361 * 1024 * 1024);

      expect(find.textContaining('Also delete its 2 snapshots'), findsOneWidget);
      expect(find.textContaining('(361 MB)'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    });

    testWidgets('one snapshot reads in the singular', (tester) async {
      await openDialog(tester, mod(), saved: 1, bytes: 1024);

      expect(find.textContaining('Also delete its 1 snapshot'), findsOneWidget);
      expect(find.textContaining('snapshots'), findsNothing);
    });

    testWidgets('Cancel has the focus, and the dialog is an alert dialog', (tester) async {
      await openDialog(tester, mod());

      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel')).autofocus, isTrue);
      expect(tester.widget<ZenithDialog>(find.byType(ZenithDialog)).alert, isTrue);
    });

    testWidgets('Delete answers with the box as it stands', (tester) async {
      DeleteChoice? answer;
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await showDialog<DeleteChoice>(
              context: context,
              builder: (_) => DeleteModDialog(mod: mod(), savedVersions: 2, savedBytes: 10),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(answer?.deleteSnapshots, isFalse);
    });

    testWidgets('Cancel answers with nothing', (tester) async {
      DeleteChoice? answer = const DeleteChoice(deleteSnapshots: true);
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await showDialog<DeleteChoice>(
              context: context,
              builder: (_) => DeleteModDialog(mod: mod()),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(answer, isNull);
    });
  });

  group('the flow', () {
    late TempLibrary temp;
    late ProviderContainer container;
    late bool deleted;
    late ValueNotifier<bool> hostShown;

    Future<void> run(WidgetTester tester, {TrashResult answer = TrashResult.trashed}) async {
      temp = (await tester.runAsync(() => TempLibrary.create(prefix: 'zzz_delete_dialog_')))!;
      temp.createMod('Winter Maid');
      temp.trash.answer = answer;
      container = ProviderContainer(overrides: temp.overrides);
      addTearDown(container.dispose);
      deleted = false;
      hostShown = ValueNotifier(true);
      addTearDown(hostShown.dispose);
      await pumpLocalized(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: hostShown,
          builder: (_, shown, _) => shown
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDeleteModDialog(context, mod(), onDeleted: () => deleted = true),
                    child: const Text('open'),
                  ),
                )
              : const SizedBox(),
        ),
        container: container,
      );
      await tapWithIo(tester, find.text('open'));
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Delete'));
    }

    testWidgets('a trashed mod is reported to the caller, and nothing is raised', (tester) async {
      await run(tester);

      expect(deleted, isTrue);
      expect(temp.trash.names, ['Winter Maid']);
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('a drive with no trash raises an error offering Copy details and Delete for good…, and deletes nothing', (tester) async {
      await run(tester, answer: TrashResult.unavailable);

      expect(deleted, isFalse);
      expect(temp.modFolder('Winter Maid').existsSync(), isTrue);
      final card = container.read(notificationsProvider).single;
      expect(card.kind, NotificationKind.error);
      expect(card.title, "Couldn't move the mod to the trash");
      expect(card.body, startsWith('Winter Maid is still where it was.'));
      expect([for (final a in card.actions) a.label], ['Copy details', 'Delete for good…']);
    });

    testWidgets('Delete for good… asks again, and then deletes the folder from the disk', (tester) async {
      await run(tester, answer: TrashResult.unavailable);
      final forGood = container.read(notificationsProvider).single.actions.last;

      await tester.runAsync(() async {
        forGood.onPressed();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Delete Winter Maid for good?'), findsOneWidget);
      expect(temp.modFolder('Winter Maid').existsSync(), isTrue, reason: 'nothing happens before the second answer');
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Delete for good'));

      expect(temp.modFolder('Winter Maid').existsSync(), isFalse);
      expect(temp.trash.names, isEmpty);
      expect(deleted, isTrue);
    });

    testWidgets('a delete that finishes after the screen is gone still lets go of the deleted mod', (tester) async {
      await run(tester, answer: TrashResult.unavailable);
      container.read(selectedModIdProvider.notifier).state = 'Winter Maid';
      container.read(allModsSelectionProvider.notifier).state = {'Winter Maid', 'Other'};
      final forGood = container.read(notificationsProvider).single.actions.last;
      hostShown.value = false;
      await tester.pump();

      await tester.runAsync(() async {
        forGood.onPressed();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tapWithIo(tester, find.widgetWithText(FilledButton, 'Delete for good'));

      expect(temp.modFolder('Winter Maid').existsSync(), isFalse);
      expect(deleted, isFalse, reason: 'the caller is gone, so its own cleanup cannot run');
      expect(container.read(selectedModIdProvider), isNull);
      expect(container.read(allModsSelectionProvider), {'Other'});
    });

    testWidgets('cancelling the second question leaves the mod', (tester) async {
      await run(tester, answer: TrashResult.unavailable);
      final forGood = container.read(notificationsProvider).single.actions.last;

      await tester.runAsync(() async {
        forGood.onPressed();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(temp.modFolder('Winter Maid').existsSync(), isTrue);
      expect(deleted, isFalse);
    });

    testWidgets('a refusal that is not "no trash here" offers no permanent delete', (tester) async {
      await run(tester, answer: TrashResult.failed);

      final card = container.read(notificationsProvider).single;
      expect([for (final a in card.actions) a.label], ['Copy details']);
    });
  });
}
