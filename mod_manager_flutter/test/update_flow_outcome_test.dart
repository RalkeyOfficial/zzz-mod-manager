import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/screens/dialogs/apply_update_flow.dart';
import 'package:mod_manager_flutter/screens/dialogs/download_with_progress.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/services/update_apply/update_target.dart';

/// How a one-mod update flow reports its end: what a download that returned nothing means, and what a write into
/// several folders adds up to.
void main() {
  test('only a written update, or one that failed after moving files, may have changed the folder', () {
    expect({for (final o in UpdateFlowOutcome.values) o: o.changed}, {
      UpdateFlowOutcome.written: true,
      UpdateFlowOutcome.failedAfterChange: true,
      UpdateFlowOutcome.declined: false,
      UpdateFlowOutcome.failed: false,
      UpdateFlowOutcome.notStarted: false,
    });
  });

  group('a download that returned nothing', () {
    test('is the user saying no only when the user cancelled', () {
      expect(outcomeOfStoppedDownload(DownloadStop.cancelled), UpdateFlowOutcome.declined);
    });

    test('is a failure when the transfer failed', () {
      expect(outcomeOfStoppedDownload(DownloadStop.failed), UpdateFlowOutcome.failed);
    });

    test('is nothing begun when the file was already being fetched', () {
      expect(outcomeOfStoppedDownload(DownloadStop.alreadyRunning), UpdateFlowOutcome.notStarted);
    });

    test('with no reason given is never read as a refusal', () {
      expect(outcomeOfStoppedDownload(null), UpdateFlowOutcome.notStarted);
    });
  });

  group('a write into several folders', () {
    AppliedUpdate applied(String id, {UpdateApplyFailure? failure}) => AppliedUpdate(
          mod: ModInfo(id: id, name: id, characterId: 'ellen', isActive: false),
          result: UpdateApplyResult(
            snapshot: null,
            filesWritten: failure == null ? 3 : 0,
            keybindChanges: const [],
            reactivated: false,
            failure: failure,
          ),
        );

    test('is written when any folder took the new version, even if another failed', () {
      expect(
        outcomeOfGroupWrite([applied('A', failure: UpdateApplyFailure.copy), applied('B')]),
        UpdateFlowOutcome.written,
      );
    });

    test('is failed after a change when no folder took it and a copy had moved files', () {
      final outcome = outcomeOfGroupWrite([
        applied('A', failure: UpdateApplyFailure.snapshot),
        applied('B', failure: UpdateApplyFailure.copy),
      ]);

      expect(outcome, UpdateFlowOutcome.failedAfterChange);
      expect(outcome.changed, isTrue, reason: 'the library is read again');
    });

    test('is failed, with the folders as they were, when every failure left them alone', () {
      final outcome = outcomeOfGroupWrite([
        applied('A', failure: UpdateApplyFailure.snapshot),
        applied('B', failure: UpdateApplyFailure.layout),
      ]);

      expect(outcome, UpdateFlowOutcome.failed);
      expect(outcome.changed, isFalse);
    });

    test('agrees with the summary on whether any folder changed', () {
      for (final set in [
        [applied('A')],
        [applied('A', failure: UpdateApplyFailure.copy)],
        [applied('A', failure: UpdateApplyFailure.snapshot), applied('B', failure: UpdateApplyFailure.copy)],
        [applied('A', failure: UpdateApplyFailure.snapshot), applied('B', failure: UpdateApplyFailure.layout)],
      ]) {
        expect(outcomeOfGroupWrite(set).changed, summariseGroupWrite(set).changed);
      }
    });
  });
}
