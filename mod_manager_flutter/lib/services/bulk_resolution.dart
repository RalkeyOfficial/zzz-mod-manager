/// Turning one whole-library update check into a **resolution pass** — who can
/// be asked what, and what each answer is allowed to write.
///
/// There is deliberately no separate migration screen. The bulk check already
/// fetches every tracked mod's record in one or two requests, and that response
/// carries exactly what resolution needs: the mod's name, its full file list
/// (current *and* archived, folded together by `Mod/Multi`) and the explicit
/// upstream-gone flags. So the results list doubles as the resolution list, one
/// screen with two jobs, and nothing here costs a request.
///
/// Four rules govern every decision below, and three of them are inherited
/// rather than invented here:
///
/// - **Bulk acts only on precise handles.** A mod with no `mod_id` gets no row
///   at all. Identifying one means fuzzy-matching a folder name
///   (`Ellen final FIXED v2`, `bikini`, `mod`) against a search, and a wrong
///   match rubber-stamped in bulk would later let an "update" overwrite a mod
///   with an unrelated mod's files. That decision stays one-at-a-time and
///   user-confirmed, in the per-mod resolve dialog, forever.
/// - **It never displaces a better answer.** Every transform re-checks its own
///   precondition against the block as freshly read from disk and abandons the
///   write when it no longer holds — the same guard the bulk "assume current"
///   action needed, and for the same reason: applied blindly, a batch would
///   downgrade a mod somebody resolved exactly while it ran.
/// - **Guesses may inform, never drive.** A file this pass works out on its own
///   is recorded at `inferred`, not at `user`: the user consented to a plan,
///   they did not look at a file list and recognise their download.
/// - **Nothing is written until the user presses Apply.** Writing the safe
///   inferences immediately and offering an undo afterwards was considered and
///   loses twice over. The control that runs this says "check for updates" and
///   nothing about rewriting sidecars, and the placement rule the bulk "assume
///   current" action already follows is that a bulk rewrite acts only on a set
///   the user has *seen*. A pre-ticked row costs the user one glance and one
///   press, where an undo costs them noticing a summary they did not ask for.
library;

import '../models/character_info.dart';
import '../models/gamebanana/gb_file.dart';
import '../models/gamebanana/gb_mod.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import 'origin_resolution.dart';

/// What one row of the results screen may be asked about.
///
/// A row can carry more than one — a legacy mod backfilled from a pasted url
/// has both an unconfirmed identity and no version — which is why this is a set
/// per row rather than a section the mod is filed under.
enum BulkResolutionQuestion {
  /// `mod_id` is on record at a tier nobody established. The glance test:
  /// *is the folder on the left really the mod on the right?*
  identity,

  /// No version at all, and the mod page publishes files that could name one.
  version,

  /// The mod page is private, trashed or withheld, and the block does not say
  /// so yet.
  sourceGone,

  /// The block says the page is gone and the page just answered normally.
  sourceBack,
}

/// One local mod, the record the check fetched for it, and what can be asked.
class BulkResolutionRow {
  const BulkResolutionRow({
    required this.mod,
    required this.remote,
    required this.questions,
    required this.candidates,
    this.suggestion,
  });

  final ModInfo mod;

  /// The record `Mod/Multi` returned. Never null — a row exists only where one
  /// came back, so "we could not look" can never be mistaken for an answer.
  final GbMod remote;

  final Set<BulkResolutionQuestion> questions;

  /// Every file the mod publishes, current and archived, ranked by what is
  /// known locally — the same ranking the per-mod dialog shows, so the two
  /// surfaces cannot suggest different files for the same mod.
  ///
  /// Empty unless [questions] contains [BulkResolutionQuestion.version]: there
  /// is nothing to pick when a version is already on record.
  final List<ResolveCandidate> candidates;

  /// The file this pass would record with no further input, or null when the
  /// honest answer is "you choose".
  ///
  /// Only two things qualify, and the difference between them is the whole
  /// confidence model in miniature:
  ///
  /// - a **banked archive md5** matching a published checksum, which is
  ///   `exact` — a matching key, never an integrity claim; and
  /// - the mod publishing **exactly one file, uploaded at or before the
  ///   install**, which is `inferred`. A single file uploaded *after* the
  ///   install cannot be the one that is installed, so that case suggests
  ///   nothing and stays unknown.
  ///
  /// A folder-name match is deliberately *not* here. It is a suggestion, it is
  /// shown as one in the picker with its reason, and a suggestion may never be
  /// the thing a pre-ticked checkbox writes.
  final ResolveCandidate? suggestion;

  bool get needsIdentity =>
      questions.contains(BulkResolutionQuestion.identity);

  bool get needsVersion => questions.contains(BulkResolutionQuestion.version);

  bool get sourceGone => questions.contains(BulkResolutionQuestion.sourceGone);

  bool get sourceBack => questions.contains(BulkResolutionQuestion.sourceBack);

  /// The name to show on the remote side of the glance test.
  String get remoteName => remote.name ?? '#${remote.idRow}';
}

/// What a whole results screen has to work with.
class BulkResolutionPlan {
  const BulkResolutionPlan({
    required this.rows,
    required this.untracked,
    required this.settled,
    required this.unreachable,
  });

  static const BulkResolutionPlan empty = BulkResolutionPlan(
    rows: <BulkResolutionRow>[],
    untracked: <ModInfo>[],
    settled: 0,
    unreachable: 0,
  );

  /// Mods with something to ask, in library order.
  final List<BulkResolutionRow> rows;

  /// Mods with no remote identity, which bulk may not touch.
  ///
  /// Counted rather than dropped, because a screen that lists eleven mods out
  /// of a library of fifty and says nothing about the other thirty-nine reads
  /// as though it covered them.
  final List<ModInfo> untracked;

  /// Mods whose origin is as known as it needs to be. A number, not rows —
  /// there is nothing to do to them.
  final int settled;

  /// Mods the pass could not reach at all. Distinct from [settled] in exactly
  /// the way "no updates" and "no updates among the mods we could reach" are.
  final int unreachable;

  bool get hasWork => rows.isNotEmpty;

  /// The rows whose questions this pass can answer by itself.
  Iterable<BulkResolutionRow> get autoResolvable =>
      rows.where((row) => row.suggestion != null);
}

/// Sorts an already-fetched check into rows. Pure — no network, no filesystem.
///
/// [records] is `BulkUpdateCheckOutcome.records`: the mod pages the pass
/// actually got back. A mod whose id is missing from it was never reached, and
/// is counted as [BulkResolutionPlan.unreachable] rather than given a row —
/// there is nothing to confirm against.
BulkResolutionPlan planBulkResolution({
  required Iterable<ModInfo> mods,
  required Map<int, GbMod> records,
}) {
  final rows = <BulkResolutionRow>[];
  final untracked = <ModInfo>[];
  var settled = 0;
  var unreachable = 0;

  for (final mod in mods) {
    final origin = mod.origin;
    // "Not from GameBanana / it's my own" is a decision, and this screen is not
    // where it gets revisited. Checked before identity for the same reason the
    // status slot does: a stale `source_url` must not talk the user out of it.
    if (origin?.tracking == OriginTracking.off) {
      settled++;
      continue;
    }
    // **What the folder is** — its bottom layer. This pass confirms identities
    // and fills in versions for the mod a folder holds; the layers above it are
    // the resolve dialog's business, one folder at a time.
    final base = origin?.base;
    if (origin == null || base?.modId == null) {
      untracked.add(mod);
      continue;
    }
    final remote = records[base!.modId];
    if (remote == null) {
      unreachable++;
      continue;
    }

    final questions = <BulkResolutionQuestion>{};
    if (remote.isRemoteMissing) {
      // Nothing else may be asked about a page nobody can read: a file list
      // fetched from it would be empty and an identity confirmed against it
      // would be confirmed against a blank. One question, and it is the only
      // one with an answer.
      if (!base.remoteMissing) {
        questions.add(BulkResolutionQuestion.sourceGone);
      }
      if (questions.isEmpty) {
        settled++;
      } else {
        rows.add(BulkResolutionRow(
          mod: mod,
          remote: remote,
          questions: questions,
          candidates: const <ResolveCandidate>[],
        ));
      }
      continue;
    }
    if (base.remoteMissing) questions.add(BulkResolutionQuestion.sourceBack);
    if (!base.modIdConfidence.isConfirmed) {
      questions.add(BulkResolutionQuestion.identity);
    }

    var candidates = const <ResolveCandidate>[];
    ResolveCandidate? suggestion;
    if (base.versionConfidence == OriginConfidence.unknown) {
      // `Mod/Multi` folds archived files into `_aFiles` and flags them with
      // `_bIsArchived`, where a profile splits them across two keys. Passing
      // `allFiles` and nothing else is what makes one ranking serve both shapes
      // — and matching archived files is not a nicety: an old install matches a
      // superseded file far more often than the current one.
      final resolution = rankResolveCandidates(
        files: remote.allFiles,
        archivedFiles: null,
        folderName: mod.name,
        installedAt: origin.installedAt,
        archiveMd5: base.archiveMd5,
      );
      if (!resolution.isEmpty) {
        candidates = resolution.candidates;
        suggestion = _autoAnswer(resolution, origin.installedAt);
        questions.add(BulkResolutionQuestion.version);
      }
    }

    if (questions.isEmpty) {
      settled++;
      continue;
    }
    rows.add(BulkResolutionRow(
      mod: mod,
      remote: remote,
      questions: questions,
      candidates: candidates,
      suggestion: suggestion,
    ));
  }

  return BulkResolutionPlan(
    rows: rows,
    untracked: untracked,
    settled: settled,
    unreachable: unreachable,
  );
}

/// The file a pre-ticked row would record, or null when the user must choose.
///
/// Built **on top of [FileResolution.preselected]** rather than re-deriving it:
/// "what may start out selected" is the per-mod dialog's rule (a checksum match,
/// or a mod publishing exactly one file) and expressing it twice in two places
/// is how the two surfaces would come to disagree. This adds one condition to
/// it and nothing else.
///
/// That condition is the install-date test on the single-file case, and it is
/// load-bearing rather than a refinement: a mod that published its only file
/// *after* the mod was installed is one whose original file has been deleted
/// outright, so the single thing on the page is provably **not** what the user
/// has. Recording it would invent a version, and then report the mod as up to
/// date. A checksum match needs no such test — it identifies the file directly.
ResolveCandidate? _autoAnswer(FileResolution resolution, DateTime? installedAt) {
  final top = resolution.preselected;
  if (top == null) return null;
  if (top.isExact) return top;
  if (installedAt == null) return null;
  final added = top.file.dateAdded;
  if (added == null || added.isAfter(installedAt)) return null;
  return top;
}

/// What the user ticked for one row.
///
/// Deliberately one object per mod rather than one per question: the answers
/// land in a single `updateOrigin` call, so a row can never half-write itself
/// and a re-read can never happen between two halves of the same decision.
class BulkResolutionAnswer {
  const BulkResolutionAnswer({
    required this.modId,
    this.confirmIdentity = false,
    this.file,
    this.fileConfidence = OriginConfidence.inferred,
    this.remoteMissing,
  });

  /// The mod the answers are about. The transform abandons the write if the
  /// block no longer names it.
  final int modId;

  /// Raise `mod_id_confidence` to `user`.
  final bool confirmIdentity;

  /// The file to record, if any.
  final GbFile? file;

  /// The tier [file] may be recorded at.
  ///
  /// `exact` for a banked-hash match, `user` when the user picked the row off
  /// the list themselves, `inferred` for the pass's own single-file inference.
  final OriginConfidence fileConfidence;

  /// Set `remote_missing`, or clear it. Null leaves it alone.
  final bool? remoteMissing;

  bool get isEmpty =>
      !confirmIdentity && file == null && remoteMissing == null;
}

/// The transform one row is written through.
///
/// [current] is the block **as it is on disk now** — `updateOrigin` re-reads
/// before applying — so every precondition is re-checked here rather than
/// trusted from the plan the screen was built from. Returning null abandons
/// that one mod's write, which is what a decision that no longer makes sense is
/// supposed to do instead of clobbering whatever replaced it.
///
/// **An identity is confirmed only by evidence, never as a side effect.** The
/// tick does it, and so does a file recorded at `user` or `exact` — the user
/// picking a row off this mod's own file list is a stronger statement that this
/// is their mod than ticking a box beside its name, and a banked checksum
/// matching a file the page publishes is proof rather than testimony.
///
/// A file at `inferred` does **not**, and getting that wrong was a real bug:
/// the pass pre-ticks its own single-file inference, so pressing Save on a row
/// whose *"yes, this is the right mod page"* was deliberately left unticked
/// would have raised `mod_id_confidence` to `user` anyway. That is precisely the
/// "never-confirmed ≠ safe" rule inverted — laundering a guess from a pasted url
/// into the tier that lets an update overwrite files, on a screen where the user
/// had visibly declined to confirm it. Both axes stay guesses instead, which
/// caps the mod's verdict at *possibly outdated*: honest, and exactly what the
/// two confidences are for.
ModOrigin? applyBulkResolution(
  ModOrigin? current,
  BulkResolutionAnswer answer,
) {
  if (current == null || current.base?.modId != answer.modId) return null;
  var next = current;

  if (answer.remoteMissing case final gone?) {
    next = OriginResolution.setRemoteMissing(
          next,
          modId: answer.modId,
          gone: gone,
        ) ??
        next;
  }

  final confirmsIdentity = answer.confirmIdentity ||
      (answer.file != null && answer.fileConfidence.isConfirmed);
  if (confirmsIdentity && !(next.base?.modIdConfidence.isConfirmed ?? false)) {
    next = OriginResolution.bind(next, answer.modId);
  }

  if (answer.file case final file?) {
    final written = switch (answer.fileConfidence) {
      // `user` and `exact` go through the same path the dialog writes, so the
      // no-demotion rule that path owns applies here too.
      OriginConfidence.user || OriginConfidence.exact =>
        OriginResolution.pickFile(
          next,
          modId: answer.modId,
          file: file,
          exact: answer.fileConfidence == OriginConfidence.exact,
        ),
      // Anything weaker is this pass's own inference and may only fill a
      // genuinely empty version.
      _ => OriginResolution.inferFile(next, modId: answer.modId, file: file),
    };
    // A declined *file* does not abandon a confirmed identity: the two are
    // independent answers about the same mod, and the version being resolved
    // meanwhile is no reason to throw away the user's "yes, that's the mod".
    if (written != null) next = written;
  }

  return next == current ? null : next;
}
