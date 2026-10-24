import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/utils/notification_actions.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

import 'support/localized_harness.dart';

/// The actions several kinds of card share. What a press does is checked here once, rather than at every card.
void main() {
  late ProviderContainer container;
  NotificationCenter center() => container.read(notificationsProvider.notifier);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// Answers every clipboard write with [answer].
  void clipboard(Object? Function(MethodCall call) answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => answer(call));
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<AppLocalizations> localizations(WidgetTester tester) async {
    AppLocalizations? loc;
    await pumpLocalized(tester, Builder(builder: (context) {
      loc = context.loc;
      return const SizedBox.shrink();
    }), container: container);
    return loc!;
  }

  group('opening a folder', () {
    testWidgets('says nothing when the file manager opens it', (tester) async {
      final loc = await localizations(tester);
      String? opened;

      await openFolderOrReport(loc, center(), '/home/al/ZZZ Mods', opener: (folder) async {
        opened = folder;
        return true;
      });

      expect(opened, '/home/al/ZZZ Mods');
      expect(container.read(notificationsProvider), isEmpty);
    });

    testWidgets('names the folder in an error when it does not open', (tester) async {
      final loc = await localizations(tester);

      await openFolderOrReport(loc, center(), '/gone/folder', opener: (_) async => false);

      final card = container.read(notificationsProvider).single;
      expect(card.kind, NotificationKind.error);
      expect(card.title, "Couldn't open the folder");
      expect(card.body, '/gone/folder');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('says so too when opening it throws', (tester) async {
      final loc = await localizations(tester);

      await openFolderOrReport(loc, center(), '/gone/folder', opener: (_) async => throw StateError('no xdg-open'));

      expect(container.read(notificationsProvider).single.title, "Couldn't open the folder");
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the Open folder action reports the same way', (tester) async {
      final loc = await localizations(tester);

      final action = openFolderAction(loc, center(), '/gone/folder', opener: (_) async => false);
      action.onPressed();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));

      expect(container.read(notificationsProvider).single.title, "Couldn't open the folder");
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('Copy details says so when the clipboard refuses the write', (tester) async {
    final loc = await localizations(tester);
    clipboard((call) => throw PlatformException(code: 'unavailable'));

    final action = copyDetailsAction(loc, center(), title: 'Something went wrong', body: 'Exception: read-only');
    await tester.runAsync(() async => action.onPressed());
    await tester.pump();

    final card = container.read(notificationsProvider).single;
    expect(card.kind, NotificationKind.error);
    expect(card.title, "Couldn't copy the details");
    expect(card.body, 'Something went wrong');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Copy details puts the title and body on the clipboard, and says so', (tester) async {
    final loc = await localizations(tester);
    String? copied;
    clipboard((call) {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });

    final action = copyDetailsAction(loc, center(), title: 'Something went wrong', body: 'Exception: read-only');
    await tester.runAsync(() async => action.onPressed());
    await tester.pump();

    expect(copied, 'Something went wrong\nException: read-only');
    expect(container.read(notificationsProvider).single.title, 'Details copied');
    await tester.pump(const Duration(seconds: 6));
  });
}
