import 'dart:async';

import 'package:mod_manager_flutter/services/api_service.dart';

/// **Suite-wide set-up.** Flutter runs this before `main()` in every test file
/// under `test/`, one isolate per file — there is nothing to import and nothing
/// to remember, which is the whole reason the guard lives here.
///
/// It closes the hole left by `ApiService.useLibraryForTests` being opt-in.
/// That method protects the tests that call it; this makes the tests that
/// *don't* fail loudly instead of quietly reading the developer's own
/// `<appData>/config.json` and scanning their real mod folder.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ApiService.refuseRealLibraryInTests();
  await testMain();
}
