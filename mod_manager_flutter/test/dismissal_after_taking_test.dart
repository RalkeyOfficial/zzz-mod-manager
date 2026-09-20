import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

import 'support/origin_shorthand.dart';

/// What taking a file does to the dismissal, given what was listed beside it.
///
/// The bug this pins: the dialog lists every file published since the installed
/// one, the user picks the one below the latest because the latest is somebody
/// else's variant, and the next check reports that same latest file again. The
/// files above the pick were seen and passed over, which is what a dismissal
/// records, so the write has to keep one rather than clear it.
void main() {
  final older = GbFile(idRow: 10, dateAdded: DateTime.utc(2026, 1));
  final sfw = GbFile(idRow: 20, dateAdded: DateTime.utc(2026, 6));
  final nsfw = GbFile(idRow: 21, dateAdded: DateTime.utc(2026, 7));

  test('taking the newest listed clears the dismissal', () {
    expect(dismissalAfterTaking(nsfw, [sfw, nsfw]), isNull);
  });

  test('taking a lower one dismisses up to the newest listed', () {
    // The same value the Ignore button writes for this list.
    expect(dismissalAfterTaking(sfw, [sfw, nsfw]), DateTime.utc(2026, 7));
  });

  test('the dismissal reaches the newest file, not the next one up', () {
    final newest = GbFile(idRow: 30, dateAdded: DateTime.utc(2026, 9));
    expect(
      dismissalAfterTaking(sfw, [sfw, nsfw, newest]),
      DateTime.utc(2026, 9),
    );
  });

  test('a list that is all older than the pick clears', () {
    expect(dismissalAfterTaking(nsfw, [older, sfw]), isNull);
  });

  test('an empty list clears, so a repair behaves as before', () {
    expect(dismissalAfterTaking(sfw, const []), isNull);
  });

  test('a pick with no date clears rather than guessing', () {
    // Nothing can be shown to have been passed over, and erring toward flagging
    // is the direction every dismissal rule takes.
    expect(
      dismissalAfterTaking(const GbFile(idRow: 20), [sfw, nsfw]),
      isNull,
    );
  });

  test('files with no date are ignored, not treated as newest', () {
    expect(
      dismissalAfterTaking(sfw, [sfw, const GbFile(idRow: 99)]),
      isNull,
    );
  });

  test('the next check stays quiet about what was passed over', () {
    // End to end through the comparator: after taking the SFW build with the
    // NSFW one listed above it, the same page no longer reports an update.
    final mod = GbMod(idRow: 1, files: [older, sfw, nsfw]);
    final holding = originFixture(
      modId: 1,
      modIdConfidence: OriginConfidence.exact,
      fileId: sfw.idRow,
      versionConfidence: OriginConfidence.exact,
      updatesDismissedUntil: dismissalAfterTaking(sfw, [sfw, nsfw]),
    );
    final after = checkForUpdate(origin: holding, remote: mod);
    expect(after.dismissed, isTrue);
    expect(after.hasUpdate, isFalse);

    // And a release after the pass-over still gets through.
    final later = GbMod(idRow: 1, files: [
      ...mod.files!,
      GbFile(idRow: 30, dateAdded: DateTime.utc(2026, 9)),
    ]);
    expect(checkForUpdate(origin: holding, remote: later).hasUpdate, isTrue);
  });
}
