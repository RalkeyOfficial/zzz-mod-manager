import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

import 'support/origin_shorthand.dart';

/// `ModOrigin.updatedTo` — the block after an applied update.
///
/// Its whole job is **what it clears**, and one of those clears is load-bearing
/// in a way nothing else would catch: keeping `updates_dismissed_until` would
/// silence the *next* release after the user takes this one, because the
/// dismissal is stored as a date at or after the file they just installed. A
/// future refactor to `copyWith` — which cannot express clearing — would
/// reintroduce every one of these silently.
void main() {
  final installedAt = DateTime.utc(2026, 8, 9, 12);

  ModOrigin before({
    OriginTracking tracking = OriginTracking.auto,
    OriginProvenance provenance = OriginProvenance.importedArchive,
  }) =>
      originFixture(
        source: 'gamebanana',
        modId: 700727,
        modIdConfidence: OriginConfidence.inferred,
        fileId: 111,
        version: '1.1',
        versionLabel: 'Main file',
        versionConfidence: OriginConfidence.assumedLatest,
        provenance: provenance,
        ingest: const ModIngest(folders: ['MiyabiStudent']),
        installedAt: DateTime.utc(2025, 1, 1),
        installedAtIsProxy: true,
        baselineRemoteDate: DateTime.utc(2025, 1, 1),
        archiveMd5: 'aaaa',
        tracking: tracking,
        remoteMissing: true,
        updatesDismissedUntil: DateTime.utc(2026, 8, 8),
      );

  /// The write an update performs, in the shape it now has: the **layer** is
  /// what `updatedTo` amends, and the folder's install date is set beside it.
  ModOrigin updated(ModOrigin origin) => origin
      .withBase((download) => download.updatedTo(
            modId: 700727,
            fileId: 222,
            version: '1.2',
            versionLabel: 'Main file',
            archiveMd5: 'bbbb',
          ))
      .copyWith(
        source: 'gamebanana',
        provenance: OriginProvenance.downloaded,
        installedAt: installedAt,
        // Observed, not proxied: we watched it happen.
        installedAtIsProxy: false,
      );

  test('the dismissal is cleared, or the next release stays silent', () {
    expect(before().updatesDismissedUntil, isNotNull);
    expect(updated(before()).updatesDismissedUntil, isNull);
  });

  test('the date-only baseline is cleared once a file id is known', () {
    // A weaker, date-based answer sitting beside a stronger one.
    expect(updated(before()).baselineRemoteDate, isNull);
  });

  test('remote_missing is cleared — we just fetched the page', () {
    expect(updated(before()).remoteMissing, isFalse);
  });

  test('the install date is observed, not proxied', () {
    expect(updated(before()).installedAt, installedAt);
    expect(updated(before()).installedAtIsProxy, isFalse);
  });

  test('both confidences reach exact, on the same grounds a download does', () {
    final after = updated(before());
    expect(after.modIdConfidence, OriginConfidence.exact);
    expect(after.versionConfidence, OriginConfidence.exact);
    expect(after.allowsUnattendedUpdate, isTrue);
  });

  test('provenance becomes downloaded even for a hand-imported folder', () {
    // Whatever it was before, the bytes in the folder now came from an archive
    // this app fetched and extracted.
    expect(
      updated(before(provenance: OriginProvenance.importedFolder)).provenance,
      OriginProvenance.downloaded,
    );
  });

  test('tracking survives — it is the user\'s statement, not ours', () {
    expect(
      updated(before(tracking: OriginTracking.off)).tracking,
      OriginTracking.off,
    );
  });

  test('the new file replaces the old identity fields', () {
    final after = updated(before());
    expect(after.fileId, 222);
    expect(after.version, '1.2');
    expect(after.archiveMd5, 'bbbb');
  });

  test('a null archive hash keeps the one already banked', () {
    // Null-or-exact: a hash we could not compute must not erase one we have.
    final after = before().withBase((download) => download.updatedTo(
          modId: 700727,
          fileId: 222,
        ));
    expect(after.archiveMd5, 'aaaa');
    expect(after.ingest?.folders, ['MiyabiStudent']);
  });
}
