import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/origin_summary.dart';

/// What the resolve dialog says is *currently* recorded.
///
/// The risk here is not the fold but the **strength of the claim**: the same
/// two fields describe "you downloaded this" and "we guessed it from a link you
/// pasted", and a summary that flattens them tells the user their guesses are
/// facts — in the one dialog they open to find out which is which.
void main() {
  final baseline = DateTime.utc(2026, 6, 29);

  ModOrigin origin({
    int? modId = 1,
    OriginConfidence modIdConfidence = OriginConfidence.inferred,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    OriginProvenance provenance = OriginProvenance.importedFolder,
    int? fileId,
    String? version,
    String? versionLabel,
    DateTime? baselineRemoteDate,
  }) =>
      ModOrigin(
        source: modId == null ? null : 'gamebanana',
        modId: modId,
        modIdConfidence: modIdConfidence,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        provenance: provenance,
        baselineRemoteDate: baselineRemoteDate,
      );

  group('identity', () {
    test('only a download reaches "downloaded"', () {
      // `exact` on the identity axis is written by one path: the marketplace,
      // which knows the mod id before the first byte. A checksum match raises
      // the *version* axis and never this one, because a hash identifies a file
      // and GameBanana offers no reverse lookup from a file to its mod.
      expect(
        summarizeOrigin(origin(modIdConfidence: OriginConfidence.exact))
            .identity,
        IdentitySummary.downloaded,
      );
    });

    test('confirmed and guessed stay apart', () {
      expect(
        summarizeOrigin(origin(modIdConfidence: OriginConfidence.user)).identity,
        IdentitySummary.confirmed,
      );
      expect(
        summarizeOrigin(origin(modIdConfidence: OriginConfidence.inferred))
            .identity,
        IdentitySummary.inferred,
      );
    });

    test('no mod id says nothing about identity at all', () {
      final summary = summarizeOrigin(origin(modId: null));
      expect(summary.identity, IdentitySummary.none);
      expect(summary.isEmpty, isTrue);
    });

    test('a null block is empty rather than a claim', () {
      expect(summarizeOrigin(null).isEmpty, isTrue);
    });
  });

  group('version', () {
    test('the two routes to exact are told apart by provenance', () {
      // Both record a file id at `exact`, and they are different facts. Only one
      // of them may be worded as having obtained the file; the other is a
      // *match*, and this codebase never renders a match as verification.
      expect(
        summarizeOrigin(origin(
          versionConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.downloaded,
          fileId: 9,
        )).version,
        VersionSummary.downloaded,
      );
      expect(
        summarizeOrigin(origin(
          versionConfidence: OriginConfidence.exact,
          provenance: OriginProvenance.importedArchive,
          fileId: 9,
        )).version,
        VersionSummary.checksumMatched,
      );
    });

    test('a chosen file, a guess and a bare date are three different states',
        () {
      expect(
        summarizeOrigin(origin(versionConfidence: OriginConfidence.user))
            .version,
        VersionSummary.chosen,
      );
      expect(
        summarizeOrigin(origin(versionConfidence: OriginConfidence.inferred))
            .version,
        VersionSummary.guessed,
      );
      expect(
        summarizeOrigin(
          origin(versionConfidence: OriginConfidence.assumedLatest),
        ).version,
        VersionSummary.dateOnly,
      );
    });

    test('nothing recorded is its own state, not a weak guess', () {
      expect(summarizeOrigin(origin()).version, VersionSummary.none);
    });
  });

  test('the baseline is read from the block, never recomputed', () {
    // `assumeCurrent` clamps the stored baseline to the mod's creation date, so
    // it can legitimately differ from the install date the dialog would derive
    // today. Quoting a derived one would state a cutoff that is not in force.
    final summary = summarizeOrigin(origin(
      versionConfidence: OriginConfidence.assumedLatest,
      baselineRemoteDate: baseline,
    ));
    expect(summary.baseline, baseline);
  });

  group('the displayed version string', () {
    test('joins the version and the variant label without conflating them', () {
      expect(
        summarizeOrigin(origin(version: '3.0', versionLabel: 'white hair ver'))
            .versionLabel,
        '3.0 · white hair ver',
      );
    });

    test('either half alone is enough', () {
      expect(summarizeOrigin(origin(version: '3.0')).versionLabel, '3.0');
      expect(
        summarizeOrigin(origin(versionLabel: 'Full Mod')).versionLabel,
        'Full Mod',
      );
    });

    test('a file with no version string at all is normal, and reads as null',
        () {
      // GameBanana's `_sVersion` is routinely null on *every* file of a mod, so
      // a recorded file id with no version is the common case rather than an
      // error — and an empty "—" separator would be the only thing shown.
      expect(summarizeOrigin(origin(fileId: 9)).versionLabel, isNull);
    });
  });

  test('the recorded file id is carried through for the row marker', () {
    expect(summarizeOrigin(origin(fileId: 4242)).fileId, 4242);
  });
}
