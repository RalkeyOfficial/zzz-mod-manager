import 'dart:io';

/// Loads a checked-in API response from `test/fixtures/`.
///
/// These are **real captured responses**, not hand-written mocks. GameBanana's
/// `apiv11` is undocumented and discoverable only by probing, so a fixture is
/// the only thing that keeps the parser honest about field names and shapes
/// that nobody can look up. Re-capture with curl if the API shifts; don't
/// hand-edit them to make a test pass.
///
/// Captured 2026-08-01, pretty-printed for reviewability — only whitespace
/// differs from the wire bytes.
String loadFixture(String relativePath) {
  final file = File('test/fixtures/$relativePath');
  if (!file.existsSync()) {
    throw StateError(
      'Missing fixture: ${file.path}\n'
      '(tests run with the package root as the working directory)',
    );
  }
  return file.readAsStringSync();
}

/// Shorthand for the GameBanana fixture directory.
String loadGbFixture(String name) => loadFixture('gamebanana/$name.json');
