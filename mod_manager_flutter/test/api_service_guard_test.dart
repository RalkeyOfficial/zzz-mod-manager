import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/api_service.dart';

import 'support/temp_library.dart';

/// **That the guard is armed at all.**
///
/// `test/flutter_test_config.dart` arms it, and a suite where nothing reaches
/// the real library looks exactly like a suite where the config file was never
/// picked up: every test passes either way. So the arming is asserted directly,
/// or the whole protection is a file nobody notices has stopped working.
void main() {
  test('reaching the real library is a failure, not a quiet read', () {
    // The message carries the fix, because the stack trace of a real slip
    // points at whichever provider read the facade and not at the missing
    // set-up.
    expect(
      ApiService.initialize(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('TempLibrary.create()'),
        ),
      ),
    );
  });

  test('the wrapped accessors carry the reason through', () {
    // `getMods` is the one a provider reaches — `installedModsIndexProvider`
    // calls it — and it rewraps everything it catches, so what a developer
    // actually reads is this string and not the `StateError` above.
    expect(
      ApiService.getMods(),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('config.json'),
        ),
      ),
    );
  });

  test('a mounted library satisfies it', () async {
    final library = await TempLibrary.create(prefix: 'zzz_guard_');
    final mods = await ApiService.getModManagerService();
    expect(mods.modsPath, library.mods.path);
  });
}
