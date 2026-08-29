/// The two decisions the opt-in startup check makes: whether this is its
/// moment, and whether to say anything afterwards.
///
/// Small, and worth having on its own: each rule reads as an arbitrary
/// condition at the call site, and each fails in a direction nobody would
/// notice — a check that never runs, one that runs on every rescan, or a card
/// that appears on every launch.
///
/// **This decides whether to *check*.** Nothing in this app applies an update
/// unattended — see `docs/applying-updates.md` §7 for why that is a rejected
/// design rather than an unbuilt one.
library;

import 'bulk_update_check.dart';

/// What the startup check should do with the library it has just been handed.
enum LaunchCheckAction {
  /// Not yet, and not never. The library has not been scanned, or has nothing
  /// that can be checked — the next plan may.
  wait,

  /// The startup moment has passed without a check. Stop watching.
  close,

  /// Run the pass. The window closes with it.
  run,
}

/// Decides what to do on each rebuild of the library plan.
///
/// The rules, in the order they are applied:
///
/// - **[windowClosed]** — once per session, not once per scan. A favourite, an
///   import, a rename and a resolve each rebuild the plan; without this an
///   ordinary afternoon issues the batch a dozen times.
/// - **[BulkUpdateCheckPlan.hasWork]** — the plan is derived from the scan the
///   mods screen runs on the way in, so it is empty until that lands, and empty
///   forever for a library with no tracked mods. Waiting on it covers both, so
///   neither an unscanned library nor an unconfigured mods path needs a
///   condition of its own.
/// - **[enabled]** — the standing rule is that a check never runs without an
///   explicit press. This is the one opt-in out of it, and it is off by
///   default, so the rule holds for anyone who has not asked.
///
/// **The window closes whether or not the check ran**, which is the whole
/// reason this returns three states rather than a bool. Turning the setting on
/// mid-session must not fire a pass on the next rescan: the switch says *when
/// the app starts*, and the next start is when it takes effect. Without
/// [close], enabling it and then favouriting a mod would run a check the user
/// did not ask for, at a moment the label does not describe.
LaunchCheckAction launchCheckAction({
  required bool enabled,
  required bool windowClosed,
  required BulkUpdateCheckPlan plan,
}) {
  if (windowClosed || !plan.hasWork) return LaunchCheckAction.wait;
  return enabled ? LaunchCheckAction.run : LaunchCheckAction.close;
}

/// How many updates the startup check should report, or null to stay silent.
///
/// **It speaks only when it found something.** Two silences are deliberate, and
/// neither is an oversight:
///
/// - **Nothing found** — a card saying so on every launch is noise nobody asked
///   for, and the badges already carry the answer for anyone looking.
/// - **Mods it could not reach** — the manual check reports those, and must:
///   "no updates" and "no updates among the mods we could reach" are different
///   statements, and a whole-library check that conflates them turns an outage
///   into false reassurance. A silent startup check asserts *neither*, so the
///   rule is not being broken here — it is being left to the surface the user
///   actually pressed. Reporting a failure they did not ask for, on every
///   offline launch, is what gets a feature switched off.
///
/// A pass that found updates *and* failed on some mods reports the updates. The
/// finding is the actionable half, and the toolbar is one click away for
/// anything else.
int? launchCheckFindings(BulkUpdateCheckOutcome outcome) {
  final found = outcome.updatesFound;
  return found > 0 ? found : null;
}
