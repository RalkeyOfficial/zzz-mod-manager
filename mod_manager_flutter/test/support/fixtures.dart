import 'dart:io';

/// Loads a checked-in API response from `test/fixtures/`.
///
/// These are **real captured responses**, not hand-written mocks. GameBanana's
/// `apiv13` is undocumented and discoverable only by probing, so a fixture is
/// the only thing that keeps the parser honest about field names and shapes
/// that nobody can look up. Re-capture with curl if the API shifts; don't
/// hand-edit them to make a test pass.
///
/// Captured from **apiv13** on 2026-08-15, pretty-printed for reviewability —
/// only whitespace differs from the wire bytes.
///
/// Two things to know before re-capturing:
///
/// - **Match the original request, not just the endpoint.** `mod_index_p1` is
///   `_sSort=Generic_MostLiked&_nPerpage=5`; capturing it under a different sort
///   silently changes the *content mix*, and `content_filter_test` reads this
///   fixture as evidence that a ZZZ listing skews adult.
/// - **`error_no_such_route` is deliberately still an apiv11 capture.** apiv13
///   answers an unrecognised route with a `200` and an HTML error page rather
///   than the JSON envelope, so there is nothing equivalent to capture — while
///   the shape it holds is still live, because a missing *mod* (the case that
///   actually reaches users) still returns `404` with this exact envelope.
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
