/// One mod folder an update is about to be written into.
///
/// A download can land in several folders at once — the members of a sibling
/// group, one archive that installed as several mods
/// ([`sibling_group.dart`](sibling_group.dart)) — and every one of them needs
/// its own preview, its own patch handling and its own row on the confirmation.
/// This is what the flow, the confirmation and the result dialog all pass
/// around, so none of them has to hold three parallel lists.
///
/// **The write parameters are per folder and not per download.** Two members of
/// one archive can hold different patches over the same mod, so `patchFiles`
/// and `patchModId` come from each folder's own recorded stack.
library;

import '../../models/character_info.dart';
import 'sibling_group.dart';
import 'update_applier.dart';

class UpdateTarget {
  const UpdateTarget({
    required this.mod,
    required this.preview,
    this.patchFiles = const <String>[],
    this.patchModId,
    this.flattensPatch = false,
    this.refusal,
    this.caution,
  });

  final ModInfo mod;
  final UpdatePreview preview;

  /// This folder's recorded patch paths, set aside and placed back on top —
  /// see `UpdateWriteRoute.patchFiles`.
  final List<String> patchFiles;

  /// Whose store of displaced originals to rebuild as the patch goes back.
  final int? patchModId;

  /// This folder holds a patch that **cannot be put back**, because nothing
  /// records which files are its.
  final bool flattensPatch;

  /// Why the group refuses this folder even though its own preview is fine.
  ///
  /// Only ever [SiblingRefusal.sourceCollision], and only for the mod the user
  /// pressed the button on: every other refusal is decided before a preview is
  /// taken. A collision is invisible from one folder — it needs two — so this is
  /// the one refusal a preview cannot carry itself.
  final SiblingRefusal? refusal;

  /// Why this folder is offered but **not pre-ticked**, or null to pre-tick it.
  ///
  /// Distinct from [refusal]: this row can be written, and the user may well
  /// want it — it just is not something to do to them by default.
  final SiblingCaution? caution;

  /// Whether this folder can be written at all. A member whose layout cannot be
  /// reconciled is listed with the reason rather than offered.
  bool get canProceed => refusal == null && preview.canProceed;

  /// Whether this row starts ticked. Every writable folder does, except the
  /// ones a [caution] applies to.
  bool get startsAccepted => canProceed && caution == null;

  /// How many `.ini` files would be removed from this folder as leftovers, if
  /// the user says so.
  int get leftoverCount => preview.staleInis.stale.length;
}

/// What the write did to one folder.
///
/// Carried per folder rather than folded into a total, because a group write is
/// **not all-or-nothing**: each folder has its own snapshot and its own copy, so
/// one failing leaves the others correctly updated. A single number could not
/// say which.
class AppliedUpdate {
  const AppliedUpdate({required this.mod, required this.result});

  final ModInfo mod;
  final UpdateApplyResult result;
}

/// What a write into one or more folders adds up to.
///
/// Every question the flow asks after the loop is about **what happened**, and
/// each one was originally answered from `applied.length` — which is how many
/// folders were attempted. The two are different whenever the user unticks the
/// mod they opened, or a folder fails, and both are ordinary.
class GroupWriteOutcome {
  const GroupWriteOutcome({
    required this.settledMarks,
    required this.changed,
    this.soleFailure,
  });

  /// The folder ids whose "update available" mark this write settled, and
  /// nothing else may be cleared.
  ///
  /// **Empty for a repair**, which writes the version already installed: what
  /// the check found is still outstanding, so clearing its mark would lose the
  /// finding rather than take it. The user picked "Reinstall this version…" to
  /// get working files back and would watch the badge and the toolbar's count
  /// disappear with nothing having been updated.
  final Set<String> settledMarks;

  /// Whether any folder on disk is different, so the caller rescans. A failed
  /// *copy* still moved files; every other failure left its folder alone.
  final bool changed;

  /// The one attempt, when there was exactly one and it failed.
  ///
  /// Its mod — not the mod the dialog was opened on. With the primary unticked
  /// the sole attempt is a sibling, and naming the wrong folder in the error
  /// sends the user to restore something that was never touched.
  final AppliedUpdate? soleFailure;
}

/// [reinstall] is the one thing about the *intent* this needs, and it lives here
/// rather than at the call site so the rule sits with the tests that pin it.
GroupWriteOutcome summariseGroupWrite(
  List<AppliedUpdate> applied, {
  bool reinstall = false,
}) {
  final failedAlone = applied.length == 1 && !applied.single.result.success
      ? applied.single
      : null;
  return GroupWriteOutcome(
    settledMarks: reinstall
        ? const <String>{}
        : {
            for (final entry in applied)
              if (entry.result.success) entry.mod.id,
          },
    changed: applied.any((entry) =>
        entry.result.success ||
        entry.result.failure == UpdateApplyFailure.copy),
    soleFailure: failedAlone,
  );
}
