import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
import 'package:mod_manager_flutter/services/launch_update_check.dart';
import 'package:mod_manager_flutter/services/update_check.dart';

import 'support/origin_shorthand.dart';

/// The two decisions behind the opt-in startup check.
///
/// Both are conditions rather than algorithms, which is exactly why they are
/// worth pinning: each is a rule that reads as arbitrary at the call site, and
/// each fails in a direction nobody would notice — a check that never runs, one
/// that runs on every rescan, or a card that appears on every launch.
void main() {
  ModInfo mod(String name, {int? modId}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: modId == null
            ? null
            : originFixture(
                source: 'gamebanana',
                modId: modId,
                modIdConfidence: OriginConfidence.user,
                provenance: OriginProvenance.downloaded,
              ),
      );

  final tracked = planBulkUpdateCheck([mod('Ellen', modId: 1)]);
  final untracked = planBulkUpdateCheck([mod('Ellen')]);
  final unscanned = planBulkUpdateCheck(const []);

  BulkUpdateCheckOutcome outcome({
    int found = 0,
    int checked = 1,
    Set<String> failed = const {},
  }) {
    final checks = <String, UpdateCheck>{};
    for (var i = 0; i < checked; i++) {
      checks['mod$i'] = UpdateCheck(
        outcome: i < found
            ? UpdateOutcome.updateAvailable
            : UpdateOutcome.upToDate,
      );
    }
    return BulkUpdateCheckOutcome(
      checks: checks,
      failed: failed,
      requests: 1,
    );
  }

  group('the startup moment', () {
    LaunchCheckAction act({
      bool enabled = true,
      bool windowClosed = false,
      BulkUpdateCheckPlan? plan,
    }) =>
        launchCheckAction(
          enabled: enabled,
          windowClosed: windowClosed,
          plan: plan ?? tracked,
        );

    test('runs when it is switched on and there is something to ask', () {
      expect(act(), LaunchCheckAction.run);
    });

    test('waits rather than firing on an empty plan', () {
      // Two different situations, one condition: the library has not been
      // scanned yet, and the library has no tracked mods. Neither needs a rule
      // of its own — an empty plan has no request to make, and a later plan
      // that does will bring the check with it.
      expect(act(plan: unscanned), LaunchCheckAction.wait);
      expect(act(plan: untracked), LaunchCheckAction.wait);
    });

    test('never fires again once the moment has passed', () {
      // The library is rescanned on a favourite, an import, a rename and a
      // resolve, and each rescan rebuilds the plan. Without this the batch
      // would go out a dozen times in an afternoon.
      expect(act(windowClosed: true), LaunchCheckAction.wait);
    });

    test('switched off, it closes the moment instead of running', () {
      // The standing rule is that a check never runs without an explicit
      // press, so a library full of tracked mods stays silent for anyone who
      // has not asked.
      expect(act(enabled: false), LaunchCheckAction.close);
    });

    test('switching it on mid-session waits for the next start', () {
      // The switch says *when the app starts*. Closing the moment even when the
      // check did not run is what keeps that true: otherwise enabling it and
      // then favouriting a mod would fire a pass nobody asked for, at a moment
      // the label does not describe.
      expect(act(enabled: false), LaunchCheckAction.close);
      expect(
        act(enabled: true, windowClosed: true),
        LaunchCheckAction.wait,
        reason: 'the moment is over; the next launch is when it takes effect',
      );
    });

    test('an unscanned library does not close the moment', () {
      // Otherwise a check would be skipped for the commonest ordering there
      // is: the host mounts, and the scan lands a moment later.
      expect(act(enabled: false, plan: unscanned), LaunchCheckAction.wait);
    });
  });

  group('whether to speak', () {
    test('reports the number of updates it found', () {
      expect(launchCheckFindings(outcome(found: 3, checked: 17)), 3);
    });

    test('says nothing when there is nothing to report', () {
      // A card on every launch saying "no updates" is noise nobody asked for,
      // and the badges already carry the answer.
      expect(launchCheckFindings(outcome(checked: 17)), isNull);
    });

    test('says nothing about mods it could not reach', () {
      // The manual check reports those and must — "no updates" and "no updates
      // among the mods we could reach" are different statements. A silent
      // startup check asserts neither, and the commonest cause by far is
      // starting the app offline.
      expect(
        launchCheckFindings(outcome(checked: 5, failed: {'a', 'b'})),
        isNull,
      );
    });

    test('a pass that found updates and also failed reports the updates', () {
      // The finding is the actionable half. The toolbar's check is one click
      // away for the rest.
      expect(
        launchCheckFindings(outcome(found: 2, checked: 5, failed: {'a'})),
        2,
      );
    });
  });
}
