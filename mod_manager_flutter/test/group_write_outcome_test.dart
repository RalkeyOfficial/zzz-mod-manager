import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';

/// What a write into one or more folders adds up to.
///
/// Every question asked after the write loop is about **what happened**, and
/// each one is easy to answer from how many folders were *attempted* instead.
/// The two differ in two ordinary cases — the user unticking the mod they
/// opened, and a folder failing — and answering from the count gets both wrong
/// in a way nothing on screen would reveal.
void main() {
  ModInfo mod(String id) =>
      ModInfo(id: id, name: id, characterId: 'ellen', isActive: false);

  AppliedUpdate ok(String id) => AppliedUpdate(
        mod: mod(id),
        result: const UpdateApplyResult(
          snapshot: null,
          filesWritten: 12,
          removedInis: [],
          keybindChanges: [],
          reactivated: false,
        ),
      );

  AppliedUpdate failed(String id, UpdateApplyFailure failure) => AppliedUpdate(
        mod: mod(id),
        result: UpdateApplyResult(
          snapshot: null,
          filesWritten: 0,
          removedInis: const [],
          keybindChanges: const [],
          reactivated: false,
          failure: failure,
        ),
      );

  group('which marks may be cleared', () {
    test('only the folders that took the new version', () {
      final outcome = summariseGroupWrite([
        ok('Ellen Red'),
        failed('Ellen Blue', UpdateApplyFailure.copy),
        ok('Ellen Green'),
      ]);

      expect(outcome.settledMarks, {'Ellen Red', 'Ellen Green'});
    });

    test('a folder whose write failed keeps its mark', () {
      // It needs the mark more than before: the update is still to take.
      final outcome = summariseGroupWrite(
          [failed('Ellen Red', UpdateApplyFailure.snapshot)]);

      expect(outcome.settledMarks, isEmpty);
    });

    test('a lone sibling written without its primary is named', () {
      // The user unticked the mod they opened. Answering from the count would
      // read this as an ordinary single update of that mod.
      final outcome = summariseGroupWrite([ok('Ellen Blue')]);

      expect(outcome.settledMarks, {'Ellen Blue'});
    });

    test('a repair settles nothing, because it installs no new version', () {
      // "Reinstall this version…" writes the file id already recorded. The
      // update the check found is still outstanding, so clearing the mark
      // would lose the finding rather than take it — the user would watch the
      // badge and the toolbar's count vanish with nothing updated.
      final outcome = summariseGroupWrite([ok('Ellen Red')], reinstall: true);

      expect(outcome.settledMarks, isEmpty);
      expect(outcome.changed, isTrue,
          reason: 'the folder did change, so the caller still rescans');
    });
  });

  group('whether the folder on disk changed', () {
    test('a success changed it', () {
      expect(summariseGroupWrite([ok('Ellen Red')]).changed, isTrue);
    });

    test('a failed copy changed it, because files had already moved', () {
      expect(
        summariseGroupWrite([failed('Ellen Red', UpdateApplyFailure.copy)])
            .changed,
        isTrue,
      );
    });

    test('every other failure left it alone', () {
      for (final failure in [
        UpdateApplyFailure.snapshot,
        UpdateApplyFailure.modMissing,
        UpdateApplyFailure.layout,
      ]) {
        expect(
          summariseGroupWrite([failed('Ellen Red', failure)]).changed,
          isFalse,
          reason: '$failure writes nothing',
        );
      }
    });

    test('one folder failing does not hide the ones that landed', () {
      expect(
        summariseGroupWrite([
          failed('Ellen Red', UpdateApplyFailure.snapshot),
          ok('Ellen Blue'),
        ]).changed,
        isTrue,
      );
    });
  });

  group('the failure a notification reports', () {
    test('names the folder that was attempted, not the one opened', () {
      // With the primary unticked the sole attempt is a sibling. Naming the
      // wrong mod sends the user to restore something never touched.
      final outcome =
          summariseGroupWrite([failed('Ellen Blue', UpdateApplyFailure.copy)]);

      expect(outcome.soleFailure?.mod.id, 'Ellen Blue');
    });

    test('is absent when the one attempt succeeded', () {
      expect(summariseGroupWrite([ok('Ellen Red')]).soleFailure, isNull);
    });

    test('is absent for a group, which reports in the dialog instead', () {
      // Three notifications would bury the one thing worth reading: which
      // folders landed.
      final outcome = summariseGroupWrite([
        ok('Ellen Red'),
        failed('Ellen Blue', UpdateApplyFailure.copy),
      ]);

      expect(outcome.soleFailure, isNull);
    });
  });
}
