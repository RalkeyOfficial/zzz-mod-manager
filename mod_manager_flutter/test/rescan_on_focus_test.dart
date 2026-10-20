import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/main.dart';
import 'package:mod_manager_flutter/screens/components/rescan_on_focus.dart';
import 'package:mod_manager_flutter/screens/shell/status_bar.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:window_manager/window_manager.dart';

import 'support/library_override.dart';
import 'support/localized_harness.dart';
import 'support/temp_library.dart';

/// Returning to the window reads the library again, so a mod added or an `.ini` edited outside the app shows up.
void main() {
  testWidgets('the window regaining focus rescans the library', (tester) async {
    final container = ProviderContainer(overrides: [libraryOf(const [])]);
    addTearDown(container.dispose);
    await pumpLocalized(tester, const RescanOnWindowFocus(), container: container);
    final before = container.read(libraryScansProvider);

    (tester.state(find.byType(RescanOnWindowFocus)) as WindowListener).onWindowFocus();
    await tester.pump();

    expect(container.read(libraryScansProvider), before + 1);
  });

  testWidgets('the app mounts it beside the status bar, above the pages', (tester) async {
    final temp = await tester.runAsync(() => TempLibrary.create(prefix: 'zzz_rescan_on_focus_'));
    final container = ProviderContainer(overrides: [libraryOf(const []), ...temp!.overrides]);
    addTearDown(container.dispose);
    await pumpLocalized(tester, const MainScreen(), container: container, settle: false);
    await tester.pump();

    expect(find.byType(AppStatusBar), findsOneWidget);
    expect(find.byType(RescanOnWindowFocus), findsOneWidget);
  });
}
