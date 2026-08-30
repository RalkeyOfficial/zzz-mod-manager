/// Deciding whether one installed mod has an update — with no network, no
/// dialog and no filesystem around it.
///
/// The fetching is plumbing. What is easy to get wrong is *what the answer is
/// allowed to claim*, and two locked decisions govern every line below:
///
/// - **Update detection is heuristic, never presented as exact.** GameBanana
///   publishes no orderable version: `_sVersion` is a free-form author string
///   and is routinely null on *every* file of a mod, with the version written
///   into `_sDescription` — the field that is otherwise the *variant* marker.
///   Measured across the three captured profiles, authors use that one field
///   both ways: `Main file` / `Glow demo` / `NSFW Variants Included` are
///   variants, while `v3.4` / `v3.3` / `v3.0` are versions of one variant. So
///   no rule can separate "newer release" from "different variant" in general,
///   and this file does not pretend to. It reports what it can prove and
///   downgrades everything else to *possibly* outdated.
/// - **Guesses may inform, never drive.** A verdict resting on an identity we
///   inferred from a pasted url, or on a file id we guessed, can never be the
///   strong claim — [UpdateOutcome.updateAvailable] is reserved for evidence at
///   `user` or `exact` on **both** axes, and anything weaker is folded down to
///   [UpdateOutcome.possiblyOutdated]. See [UpdateCheck.isGuess].
///
/// The failure modes are deliberately asymmetric. A false "up to date" hides an
/// update silently and the feature simply fails; a false "possibly outdated"
/// costs the user one look at the file list and corrects itself. This file errs
/// toward flagging, the same way `assumeCurrent`'s baseline does.
///
/// **Every rule that can turn a flag *off* is a statement by the author, never
/// an inference about their habits.** There are two: `_aFileRowIds` from
/// `Mod/<id>/Updates` ("I released these files together", see [ReleaseGroups]),
/// and two still-offered files carrying an equal `_sVersion` ("these are the
/// same version"). Both are declarative, both are checkable, neither has a
/// threshold.
///
/// That line is deliberate and two better-performing rules were rejected to
/// hold it. Recorded because both are the obvious next idea:
///
/// - **A co-publication time window** — treat a file uploaded within an hour of
///   the installed one as a sibling. It measures *well*: taking `_aFileRowIds`
///   as ground truth across 300 ZZZ mods, a 1 h window agrees with the author's
///   own grouping on 85 of 106 known co-releases while wrongly grouping 2 of
///   277 cross-post pairs, on a flat plateau from 15 min to 2 h. It was still
///   rejected. Its unique contribution over the two rules above is 99 pairs,
///   and every one of those rests solely on "authors don't upload twice in a
///   session for different reasons" — which a single hotfix published minutes
///   after a broken file breaks, in the **silent** direction. Nothing in the
///   data can confirm that assumption, only fail to contradict it.
/// - **"A file that already existed when you installed cannot be an update"** —
///   causal rather than statistical, threshold-free, and it kills every
///   remaining false positive on a real library outright. It rests on
///   `installed_at`, which is a **proxy** derived from file mtimes for anything
///   not installed by this build. A plain `cp -r` of a mods folder resets every
///   mtime to the copy time; the proxy then reads *late*, every published file
///   predates it, and the whole feature goes quiet with no way for the user to
///   notice. That is the exact hazard `docs/origin-tracking.md` §3 already
///   names as the reason the proxy uses the oldest contained file rather than
///   the folder's own mtime — "they skew later than the true install and would
///   hide updates". A suppression built on that date reintroduces it.
///
/// The residue is a small number of soft "possibly outdated" marks on variants
/// the author gave no machine-readable way to distinguish. That is what
/// `updates_dismissed_until` is for: one click, permanent, and the mark returns
/// only if something genuinely newer appears.
library;

import '../models/gamebanana/gb_file.dart';
import '../models/gamebanana/gb_mod.dart';
import '../models/gamebanana/gb_update.dart';
import '../models/mod_companion.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import 'installed_mods_index.dart';

/// Which files a mod's author published **together**, from its update feed.
///
/// The one authoritative signal in this file. Everything else compares strings
/// and dates the author never meant as a version; this is the author saying "I
/// shipped these two at once", which settles the question those comparisons
/// cannot: *is this newer file a new version of mine, or the other variant of
/// mine?*
///
/// Both false positives found on a real library were exactly that — an
/// `SFW Variants Only` install with an `NSFW Variants Included` published
/// ninety seconds later, and a mod that shipped four proportion variants in one
/// post. Under this rule both go quiet, and neither needed a heuristic tuned.
///
/// Absent groups mean *no suppression*, never a suppressed flag: a mod with no
/// update posts, or whose relevant post has scrolled off the feed's first page,
/// simply gets the unrefined verdict. That is the safe direction — the rule can
/// only ever remove a flag it can prove wrong.
class ReleaseGroups {
  const ReleaseGroups(this._groups);

  static const ReleaseGroups empty = ReleaseGroups(<Set<int>>[]);

  factory ReleaseGroups.fromUpdates(Iterable<GbUpdate> updates) =>
      ReleaseGroups([
        for (final update in updates)
          if (update.fileRowIds.length > 1) update.fileRowIds,
      ]);

  final List<Set<int>> _groups;

  bool get isEmpty => _groups.isEmpty;

  /// Whether [a] and [b] shipped in the same release.
  bool sameRelease(int a, int b) {
    if (a == b) return true;
    for (final group in _groups) {
      if (group.contains(a) && group.contains(b)) return true;
    }
    return false;
  }
}

/// The single thing an update check concludes about one mod.
enum UpdateOutcome {
  /// The user declared this mod their own. Not checked, and never will be.
  trackingOff,

  /// No remote identity, so there is nothing to check it against. The resolve
  /// dialog is the fix, not this.
  untracked,

  /// The mod page is private, trashed or withheld. Read from the remote's own
  /// flags rather than inferred from a status code.
  sourceGone,

  /// The response carried no current file list, so nothing may be concluded.
  /// Distinct from "no update": silence is not evidence.
  indeterminate,

  /// Identity is known and the installed file is not, and nothing local
  /// identifies it. We could ask what this mod publishes but could not judge
  /// the answer — one pass through the resolve dialog fixes it.
  versionUnknown,

  /// Nothing has been published that could be newer than what is installed.
  upToDate,

  /// The folder holds a **patch** and the origin block names the patch's page,
  /// so nothing here is a statement about the mod the folder actually contains.
  ///
  /// Distinct from [upToDate] for the reason [indeterminate] is: the patch
  /// genuinely has no newer file, and saying so would be true about the page we
  /// asked and false about the folder the user is looking at. Distinct from
  /// [indeterminate] because the cause is ours to explain rather than the
  /// server's silence — and the remedy is different.
  tracksPatchOnly,

  /// Something newer exists, but which file it corresponds to — or whether the
  /// installed file is even what we think it is — is a guess. The strongest
  /// claim available for anything short of confirmed evidence.
  possiblyOutdated,

  /// The installed file has been superseded, or a newer file carrying the same
  /// variant label has been published. Confirmed evidence on both axes.
  updateAvailable,
}

/// How the check decided which file is installed.
enum InstalledFileEvidence {
  /// The origin block names a `file_id`.
  recorded,

  /// The banked archive md5 matched a published checksum. Exact — and a
  /// **matching key, never an integrity claim**.
  archiveHash,

  /// Nothing identified it.
  none,
}

/// What one mod's update check concluded.
class UpdateCheck {
  const UpdateCheck({
    required this.outcome,
    this.installedFile,
    this.candidate,
    this.evidence = InstalledFileEvidence.none,
    this.isGuess = false,
    this.isObsolete = false,
    this.comparedAgainst,
    this.dismissed = false,
    this.newerFiles = const <GbFile>[],
    this.candidateMatchesVariant = false,
    this.subjectModId,
    this.companions = const <CompanionCheck>[],
  });

  /// The same evidence under a different verdict.
  ///
  /// Narrow on purpose rather than a general `copyWith`: the one caller
  /// downgrades [UpdateOutcome.upToDate] for a patch-shaped folder, and
  /// everything else it found — which file is installed, what evidence named
  /// it — is still true and still worth showing.
  UpdateCheck withOutcome(UpdateOutcome next) => UpdateCheck(
        outcome: next,
        installedFile: installedFile,
        candidate: candidate,
        evidence: evidence,
        isGuess: isGuess,
        isObsolete: isObsolete,
        comparedAgainst: comparedAgainst,
        dismissed: dismissed,
        newerFiles: newerFiles,
        candidateMatchesVariant: candidateMatchesVariant,
        subjectModId: subjectModId,
        companions: companions,
      );

  /// The same verdict, re-attributed to [modId] and carrying [others].
  ///
  /// Used only by [foldCompanions], where the winning identity's fields become
  /// the folder's.
  UpdateCheck asSubject(int? modId, List<CompanionCheck> others) => UpdateCheck(
        outcome: outcome,
        installedFile: installedFile,
        candidate: candidate,
        evidence: evidence,
        isGuess: isGuess,
        isObsolete: isObsolete,
        comparedAgainst: comparedAgainst,
        dismissed: dismissed,
        newerFiles: newerFiles,
        candidateMatchesVariant: candidateMatchesVariant,
        subjectModId: modId,
        companions: others,
      );

  final UpdateOutcome outcome;

  /// The published record of what is installed, when the check could find one.
  ///
  /// Null does not mean "not installed" — a recorded `file_id` that no longer
  /// appears on the mod page is exactly the [UpdateOutcome.updateAvailable]
  /// case, and there is no record left to point at.
  final GbFile? installedFile;

  /// The file being offered as the update, when one could be named.
  ///
  /// Null alongside [UpdateOutcome.updateAvailable] is a real state and not an
  /// oversight: the installed file is definitely gone, but the mod publishes
  /// several current files and none is identifiable as its successor. The
  /// honest thing then is "pick one", not a guess dressed as an answer.
  final GbFile? candidate;

  /// **Every** file this check considered a possible update, newest first, with
  /// [candidate] among them when there is one.
  ///
  /// Carried because naming a single file is the wrong shape for the mods this
  /// feature actually meets. A ZZZ mod routinely ships an SFW and an NSFW build
  /// together, and the pair the check has to choose between is exactly the pair
  /// the *user* is best placed to choose between — they know which one they
  /// installed and why. Reporting only the winner hides the choice; reporting
  /// the list, and saying which one we would pick and on what grounds, leaves
  /// the decision with them.
  ///
  /// Already filtered by every suppression, so a co-released sibling or a file
  /// stamped with the installed version never appears here.
  final List<GbFile> newerFiles;

  /// Whether [candidate] was chosen because it carries the **same variant
  /// label** as the installed file, rather than merely being the newest thing
  /// published.
  ///
  /// The difference is the whole reason to show a list: "this is the new build
  /// of *your* variant" is a real match, while "this is the newest file" is a
  /// fallback that may well be somebody else's variant.
  final bool candidateMatchesVariant;

  final InstalledFileEvidence evidence;

  /// Whether the conclusion rests on something weaker than confirmed evidence,
  /// on **either** axis.
  ///
  /// An `inferred` identity came from a free-form text field a human typed and
  /// may name an entirely different mod; an `assumed_latest` version is the
  /// user having said "I don't know which file". Either makes the whole verdict
  /// a suggestion, which is why this also caps [outcome] at
  /// [UpdateOutcome.possiblyOutdated].
  final bool isGuess;

  /// `_bIsObsolete` — the author flagged the mod superseded. **Orthogonal to
  /// [outcome]**: the mod still exists and still downloads, and an obsolete mod
  /// can be perfectly up to date. It wants its own wording, never
  /// [UpdateOutcome.sourceGone]'s.
  final bool isObsolete;

  /// The date the check compared against, for the UI to quote.
  ///
  /// The installed file's upload date on the file-identified path, or the
  /// clamped baseline on the `assumed_latest` one. Worth surfacing because on
  /// the second path it is frequently *not* the stored baseline — see the clamp
  /// in [checkForUpdate].
  final DateTime? comparedAgainst;

  /// Which identity the fields above describe, when it is **not** the folder's
  /// own primary. Null means the primary, which is every ordinary mod.
  ///
  /// A mixed folder is checked against two mod pages and the card still shows
  /// one verdict, so the top-level fields carry whichever identity won the fold
  /// — see [foldCompanions]. Without this the UI would render a verdict about
  /// one mod under the name of another.
  final int? subjectModId;

  /// Every companion's own verdict, in the order the block records them.
  ///
  /// The card folds to one state; the dialog shows all of them. Empty for an
  /// ordinary mod, and empty for a folder the user declared local — nothing is
  /// asked about those at all.
  final List<CompanionCheck> companions;

  /// The user has seen this much and said "not this one".
  ///
  /// The verdict is **kept**, not rewritten: the dialog still shows what is
  /// published, because "there is an update and you dismissed it" and "there is
  /// nothing new" are different facts and the user is entitled to change their
  /// mind. Only [hasUpdate] — the badge — goes quiet.
  final bool dismissed;

  /// Whether the card should say something. The three "we couldn't look"
  /// outcomes are the origin status slot's business, not this one's.
  bool get hasUpdate =>
      !dismissed &&
      (outcome == UpdateOutcome.updateAvailable ||
          outcome == UpdateOutcome.possiblyOutdated);

  /// What a dismissal would have to cover to silence this verdict — the date of
  /// the newest thing it is reporting.
  ///
  /// Read by the dialog's "ignore this update", so the dismissal is written from
  /// the same value the check compared, rather than from "now": a mod page can
  /// publish something between the check and the press, and dismissing to `now`
  /// would swallow it unseen.
  ///
  /// **The newest of [newerFiles], not the candidate's date**, and the two come
  /// apart exactly where the label rule is doing its job: when your variant's
  /// successor is *older* than some other file on the page, the candidate is
  /// deliberately not the newest thing listed. Keyed on the candidate, a
  /// dismissal then left every later file silenced while claiming — in this
  /// doc and in the user-facing copy — that anything newer would speak up
  /// again. The user was shown the whole list and ignored the whole finding, so
  /// the dismissal covers the whole list.
  DateTime? get dismissableUpTo {
    DateTime? newest;
    for (final file in newerFiles) {
      final date = file.dateAdded;
      if (date == null) continue;
      if (newest == null || date.isAfter(newest)) newest = date;
    }
    return newest ?? candidate?.dateAdded ?? comparedAgainst;
  }

  /// The same verdict with [dismissed] flipped.
  ///
  /// Exists so a surface that has *already* got a verdict can reflect the user
  /// ignoring it without re-deriving one. That is not a shortcut: the dialog
  /// opened from a card badge never fetches a mod page (the bulk pass already
  /// answered), so it has no `GbMod` to fold against — and re-folding was
  /// silently producing nothing there, leaving the badge, the toolbar count and
  /// the dialog all showing the pre-dismissal state after a write that had
  /// actually succeeded.
  UpdateCheck asDismissed(bool value) => UpdateCheck(
        outcome: outcome,
        installedFile: installedFile,
        candidate: candidate,
        newerFiles: newerFiles,
        candidateMatchesVariant: candidateMatchesVariant,
        evidence: evidence,
        isGuess: isGuess,
        isObsolete: isObsolete,
        comparedAgainst: comparedAgainst,
        dismissed: value,
        subjectModId: subjectModId,
        companions: companions,
      );
}

/// One companion identity's own verdict, kept beside the folded one.
class CompanionCheck {
  const CompanionCheck({required this.companion, required this.check});

  final ModCompanion companion;
  final UpdateCheck check;
}

/// The verdict for a mod **no request could improve on**, or null when a mod
/// page is needed.
///
/// One copy of the rule, because three callers need it and they must agree:
/// [checkForUpdate] starts here, the bulk pass uses it to decide which mods to
/// spend a request on, and the per-mod dialog uses it to avoid opening with a
/// spinner over a question that has an offline answer.
///
/// Order matters. "Not from GameBanana / it's my own" is checked **before**
/// identity, the same precedence the status slot uses: a stale `source_url`
/// still sitting in the block must not talk the user out of a decision they
/// made.
UpdateCheck? verdictWithoutAsking(ModOrigin? origin) {
  if (origin == null) {
    return const UpdateCheck(outcome: UpdateOutcome.untracked);
  }
  if (origin.tracking == OriginTracking.off) {
    return const UpdateCheck(outcome: UpdateOutcome.trackingOff);
  }
  if (!origin.hasIdentity) {
    return const UpdateCheck(outcome: UpdateOutcome.untracked);
  }
  return null;
}

/// Compares one mod's origin block against what its mod page publishes now.
///
/// [remote] must carry a **current** file list (`_aFiles`); with none the answer
/// is [UpdateOutcome.indeterminate] rather than "no update", since a response
/// that was never asked for files says nothing about whether any exist.
///
/// Both response shapes are handled without the caller having to say which:
/// `ProfilePage` splits current and superseded files across `_aFiles` and
/// `_aArchivedFiles`, while `Mod/Multi` returns the **union** under `_aFiles`.
/// `_bIsArchived` is the authority in both, which is what [GbMod.currentFiles]
/// reads.
/// [companionRemotes] and [companionReleases] are keyed by remote mod id and
/// supply the records for the folder's *other* downloads. **A caller that omits
/// one for a companion the block names gets [UpdateOutcome.indeterminate]**,
/// never a clean bill — see [foldCompanions].
UpdateCheck checkForUpdate({
  required ModOrigin? origin,
  required GbMod remote,
  ReleaseGroups releases = ReleaseGroups.empty,
  Map<int, GbMod> companionRemotes = const <int, GbMod>{},
  Map<int, ReleaseGroups> companionReleases = const <int, ReleaseGroups>{},
}) {
  // "It's my own" and "no identity at all" are answers about the **folder**,
  // and they short-circuit before a single companion is consulted. That is the
  // folder-level mute doing its job, and it is why a companion carries no
  // `tracking` of its own.
  if (verdictWithoutAsking(origin) case final settled?) return settled;

  final primary = _checkForUpdate(
    origin: origin,
    remote: remote,
    releases: releases,
  );

  final companions = <CompanionCheck>[
    for (final companion in origin!.companions)
      CompanionCheck(
        companion: companion,
        check: _checkCompanion(
          origin: origin,
          companion: companion,
          remote: companionRemotes[companion.modId],
          releases: companionReleases[companion.modId] ?? ReleaseGroups.empty,
        ),
      ),
  ];

  // **A patch-shaped folder may not be called up to date.** The origin block
  // names the patch's page, so "nothing newer" is true about the page we asked
  // and says nothing about the mod the folder actually contains — which is the
  // false clean §4 calls the one failure this feature cannot afford.
  //
  // Only that verdict is downgraded, and only while nobody has said what the
  // patch applies to. A patch with a genuine new release is still
  // [UpdateOutcome.updateAvailable], and that is a real finding; a folder whose
  // base mod *has* been named gets a real answer about both halves instead of
  // this admission.
  final settledPrimary = primary.outcome == UpdateOutcome.upToDate &&
          (origin.needsCompanion)
      ? primary.withOutcome(UpdateOutcome.tracksPatchOnly)
      : primary;

  return foldCompanions(settledPrimary, companions);
}

/// One companion identity, judged the same way the primary is.
///
/// The companion's fields are lifted into a `ModOrigin` shape because that is
/// what the comparator takes — and the fields it does **not** carry are lifted
/// from the folder: [ModOrigin.source] and [ModOrigin.tracking] belong to the
/// folder rather than to either download in it.
UpdateCheck _checkCompanion({
  required ModOrigin origin,
  required ModCompanion companion,
  required GbMod? remote,
  required ReleaseGroups releases,
}) {
  // **Never fetched is not "nothing new".** Silence is not evidence — the same
  // rule this file applies to a response that carried no file list — and
  // reporting clean because we only looked at half the folder is precisely the
  // false clean the whole feature exists to remove.
  if (remote == null) {
    return const UpdateCheck(outcome: UpdateOutcome.indeterminate);
  }
  return _checkForUpdate(
    origin: ModOrigin(
      source: origin.source,
      modId: companion.modId,
      modIdConfidence: companion.modIdConfidence,
      fileId: companion.fileId,
      version: companion.version,
      versionLabel: companion.versionLabel,
      versionConfidence: companion.versionConfidence,
      provenance: origin.provenance,
      archiveMd5: companion.archiveMd5,
      baselineRemoteDate: companion.baselineRemoteDate,
      remoteMissing: companion.remoteMissing,
      updatesDismissedUntil: companion.updatesDismissedUntil,
      tracking: origin.tracking,
    ),
    remote: remote,
    releases: releases,
  );
}

/// Most actionable first. The fold reports the first outcome any identity
/// reached, so `upToDate` is only claimed when every one of them agrees.
///
/// The order is the file's existing asymmetry applied across identities: a
/// false "up to date" hides an update silently and the feature fails, while a
/// false "possibly outdated" costs one look at a file list.
const List<UpdateOutcome> _foldOrder = <UpdateOutcome>[
  UpdateOutcome.updateAvailable,
  UpdateOutcome.possiblyOutdated,
  UpdateOutcome.versionUnknown,
  UpdateOutcome.tracksPatchOnly,
  UpdateOutcome.indeterminate,
  UpdateOutcome.sourceGone,
  UpdateOutcome.upToDate,
];

/// Collapses a folder's identities into the one verdict its card can show.
///
/// **The winner's fields become the folder's**, which is load-bearing rather
/// than convenient: every existing consumer reads `candidate` and `newerFiles`,
/// and [UpdateCheck.dismissableUpTo] is computed from the latter. An outcome
/// taken from the companion sitting on top of the primary's file list would
/// illustrate a verdict about one mod with another's files — and would write a
/// dismissal cutoff derived from the wrong mod's dates.
///
/// **A live finding beats a dismissed stronger one.** Ranking by outcome alone
/// picks a dismissed `updateAvailable` and then reports `hasUpdate: false`,
/// leaving a folder with a real update on its other identity rendering as
/// though it had none. A dismissal is a statement about one page's releases, so
/// it disqualifies that identity from winning rather than the whole folder.
UpdateCheck foldCompanions(
  UpdateCheck primary,
  List<CompanionCheck> companions,
) {
  if (companions.isEmpty) return primary;

  final candidates = <(int?, UpdateCheck)>[
    (null, primary),
    for (final entry in companions) (entry.companion.modId, entry.check),
  ];

  (int?, UpdateCheck)? best;
  for (final live in [true, false]) {
    for (final outcome in _foldOrder) {
      for (final candidate in candidates) {
        if (candidate.$2.outcome != outcome) continue;
        if (candidate.$2.hasUpdate != live) continue;
        best = candidate;
        break;
      }
      if (best != null) break;
    }
    if (best != null) break;
  }

  final winner = best ?? (null, primary);
  return winner.$2.asSubject(winner.$1, companions);
}

UpdateCheck _checkForUpdate({
  required ModOrigin? origin,
  required GbMod remote,
  ReleaseGroups releases = ReleaseGroups.empty,
}) {
  if (verdictWithoutAsking(origin) case final settled?) return settled;
  origin!;
  if (remote.isRemoteMissing) {
    return UpdateCheck(
      outcome: UpdateOutcome.sourceGone,
      isObsolete: remote.isObsolete,
    );
  }

  final current = remote.currentFiles;
  if (current == null || current.isEmpty) {
    return UpdateCheck(
      outcome: UpdateOutcome.indeterminate,
      isObsolete: remote.isObsolete,
    );
  }
  final all = remote.allFiles ?? current;

  // Identity is a guess unless the user confirmed it or we downloaded the mod.
  // It caps the verdict on its own: binding the wrong mod page means every
  // file below belongs to a mod the user does not own.
  final identityConfirmed = _isConfirmed(origin.modIdConfidence);

  final installed = _findInstalledFile(origin, all);
  if (installed.evidence != InstalledFileEvidence.none ||
      origin.fileId != null) {
    return _withDismissal(
      origin,
      _judgeAgainstFile(
        origin: origin,
        remote: remote,
        current: current,
        installed: installed,
        identityConfirmed: identityConfirmed,
        releases: releases,
      ),
    );
  }

  if (origin.versionConfidence == OriginConfidence.assumedLatest &&
      origin.baselineRemoteDate != null) {
    return _withDismissal(
      origin,
      _judgeAgainstBaseline(
        origin: origin,
        remote: remote,
        current: current,
      ),
    );
  }

  return UpdateCheck(
    outcome: UpdateOutcome.versionUnknown,
    isObsolete: remote.isObsolete,
  );
}

/// Marks a verdict the user has already waved away.
///
/// Applied **after** the verdict is computed rather than as an early return,
/// deliberately: the dialog goes on showing what is published, and the moment
/// the author releases something later than the dismissal the badge comes back
/// on its own. A dismissal that short-circuited the comparison would have to be
/// cleared by hand, which is the behaviour "not now" is supposed to avoid.
UpdateCheck _withDismissal(ModOrigin origin, UpdateCheck check) {
  final until = origin.updatesDismissedUntil;
  if (until == null || !check.hasUpdate) return check;
  final reporting = check.dismissableUpTo;
  // No date on the finding at all: a dismissal cannot be shown to cover it, so
  // it does not. Erring toward still flagging is the safe direction.
  if (reporting == null || reporting.isAfter(until)) return check;
  return check.asDismissed(true);
}

/// The published record of the installed file, and how we found it.
class _Installed {
  const _Installed(this.file, this.evidence);
  final GbFile? file;
  final InstalledFileEvidence evidence;
}

/// A recorded `file_id` first, then a banked archive hash.
///
/// The hash is used **read-only** here. A match is exact-grade knowledge and it
/// costs nothing to apply — it is the same lookup the resolve dialog runs — but
/// *recording* it is a resolution, and resolutions are written by the dialog
/// and by the bulk pass, never as a side effect of asking a question.
_Installed _findInstalledFile(ModOrigin origin, List<GbFile> all) {
  if (origin.fileId case final id?) {
    for (final file in all) {
      if (file.idRow == id) {
        return _Installed(file, InstalledFileEvidence.recorded);
      }
    }
    // Recorded, and no longer published in either list. Not "not found" — that
    // absence is itself the answer, and the caller reads `origin.fileId` to
    // tell this apart from having nothing recorded at all.
    return const _Installed(null, InstalledFileEvidence.recorded);
  }

  final banked = InstalledModsIndex.normalizeArchiveMd5(origin.archiveMd5);
  if (banked == null) return const _Installed(null, InstalledFileEvidence.none);
  for (final file in all) {
    if (InstalledModsIndex.normalizeArchiveMd5(file.md5Checksum) == banked) {
      return _Installed(file, InstalledFileEvidence.archiveHash);
    }
  }
  return const _Installed(null, InstalledFileEvidence.none);
}

/// The path taken when we know which file is installed.
///
/// Three questions in order, and the order is the design:
///
/// 1. **Is that file still offered?** If it has moved to the archived list — or
///    vanished from the page entirely — it has been superseded, and that is a
///    fact rather than a comparison. No version string is involved.
/// 2. **Is there a newer file wearing the same variant label?** `Main file`
///    v7.6 → `Main file` v7.7 is the shape an update actually takes on
///    GameBanana, and the label is what survives across releases. Both labels
///    must be non-empty: two unlabelled files matching each other is not
///    evidence of anything, it is two nulls.
/// 3. **Is there anything newer at all?** Then say only that. `v3.4` beside an
///    installed `v3.0` and `Glow demo` beside an installed `Main file` are
///    indistinguishable from here, and one of them is an update while the other
///    is not.
///
/// [releases] is applied **before** any of them: a file the author shipped in
/// the same post as the installed one is a sibling variant and cannot be an
/// update of it, whatever its date or label says. That is the author's own
/// grouping rather than a guess, so it filters the candidate pool outright
/// instead of merely ranking it — which is why it can turn a flag off where
/// nothing else in this file can.
UpdateCheck _judgeAgainstFile({
  required ModOrigin origin,
  required GbMod remote,
  required List<GbFile> current,
  required _Installed installed,
  required bool identityConfirmed,
  required ReleaseGroups releases,
}) {
  final file = installed.file;
  final hashMatched = installed.evidence == InstalledFileEvidence.archiveHash;
  // A checksum match is exact on its own, whatever tier the block records.
  final versionConfirmed =
      hashMatched || _isConfirmed(origin.versionConfidence);
  final isGuess = !identityConfirmed || !versionConfirmed;

  // The label the block stored at install time is preferred over the published
  // record's, and that is load-bearing rather than tidy: `Mod/Multi` is the
  // bulk path and the *file* it names may since have been deleted outright, in
  // which case there is no published record to read a label from at all.
  final label = _labelKey(origin.versionLabel) ?? _labelKey(file?.description);

  UpdateCheck result({
    required UpdateOutcome outcome,
    GbFile? candidate,
    List<GbFile> options = const <GbFile>[],
    bool matchesVariant = false,
  }) =>
      UpdateCheck(
        // The cap the locked decision asks for: with a guessed identity or a
        // guessed file, the strongest available claim is "possibly".
        outcome: isGuess && outcome == UpdateOutcome.updateAvailable
            ? UpdateOutcome.possiblyOutdated
            : outcome,
        installedFile: file,
        candidate: candidate,
        newerFiles: _newestFirst(options),
        candidateMatchesVariant: matchesVariant,
        evidence: installed.evidence,
        isGuess: isGuess,
        isObsolete: remote.isObsolete,
        comparedAgainst: file?.dateAdded,
      );

  // Everything the author did *not* ship alongside the installed file. With no
  // recorded file id there is nothing to be a sibling of, so the pool is
  // untouched — which is also the state for every mod with no update feed.
  final installedId = file?.idRow ?? origin.fileId;
  final offered = installedId == null || releases.isEmpty
      ? current
      : [
          for (final f in current)
            if (!releases.sameRelease(installedId, f.idRow)) f,
        ];

  final stillOffered = file != null && !file.isArchived;
  if (!stillOffered) {
    final byLabel = _newestWithLabel(offered, label);
    return result(
      outcome: UpdateOutcome.updateAvailable,
      // The successor by label, or — when the mod now publishes exactly one
      // file — that one, because there is nothing to choose between.
      candidate: byLabel ?? (offered.length == 1 ? offered.single : null),
      matchesVariant: byLabel != null,
      // Every current file, because the installed one is gone and *any* of them
      // could be its replacement. This is the case where naming one file is
      // least defensible and showing the list matters most.
      options: offered,
    );
  }

  final installedAt = file.dateAdded;
  if (installedAt == null) {
    // Nothing to compare against. Rare, and reported as up to date rather than
    // indeterminate: the file we installed is still the one being offered.
    return result(outcome: UpdateOutcome.upToDate);
  }

  // **Same declared version = same release, different variant.** The one use
  // the free-form `_sVersion` reliably supports: comparing two of them for an
  // *ordering* is hopeless, but comparing them for *equality* is not, and an
  // author who stamps two still-offered files `1.01` has said they are the same
  // version. Measured: a `FULL MOD` install with an `NSFW MOD` published nine
  // days later in its own update post, both `1.01` — no release group could
  // catch that one, and no label rule should.
  //
  // Scoped to this branch on purpose, and note this is where it differs from
  // the release groups above: two files stamped alike says something about
  // *those two files*, and against an archived install it would be arguing with
  // the archive flag. A release group survives onto that branch because it says
  // something different — a sibling shipped alongside your file is the old build
  // of the other variant, so it cannot be your replacement whatever happened to
  // yours since.
  final mine = _versionKey(file.version);
  final newer = [
    for (final f in offered)
      if (f.idRow != file.idRow &&
          (f.dateAdded?.isAfter(installedAt) ?? false) &&
          !(mine != null && _versionKey(f.version) == mine))
        f,
  ];
  if (newer.isEmpty) return result(outcome: UpdateOutcome.upToDate);

  final sameVariant = _newestWithLabel(newer, label);
  if (sameVariant != null) {
    return result(
      outcome: UpdateOutcome.updateAvailable,
      candidate: sameVariant,
      matchesVariant: true,
      options: newer,
    );
  }
  return result(
    outcome: UpdateOutcome.possiblyOutdated,
    candidate: _newest(newer),
    options: newer,
  );
}

/// The path taken for `assumed_latest` — "I don't know which file, I got it
/// around then."
///
/// **This is where the baseline clamp lives**, and this is the correct home for
/// it: the clamp is a fact about the mod page, not about the sidecar. The
/// per-mod resolve dialog clamps as it writes because it has the page in hand;
/// the zero-network bulk action cannot, by design. So stored baselines are a
/// mix of clamped and unclamped and the comparison must not assume otherwise —
/// an install date proxied from file timestamps can read *years* early for a
/// hand-copied library, leaving a baseline from before the mod existed.
///
/// It is a **sanity floor, not a false-positive filter**: every file a mod
/// publishes is at or after the mod's own creation date, so clamping there
/// excludes only whatever was uploaded at creation.
///
/// The verdict is capped at [UpdateOutcome.possiblyOutdated] structurally —
/// nothing here knows what is installed, only when it arrived.
UpdateCheck _judgeAgainstBaseline({
  required ModOrigin origin,
  required GbMod remote,
  required List<GbFile> current,
}) {
  final stored = origin.baselineRemoteDate!;
  final created = remote.dateAdded;
  final baseline =
      created != null && created.isAfter(stored) ? created : stored;

  final newer = [
    for (final f in current)
      if (f.dateAdded?.isAfter(baseline) ?? false) f,
  ];

  UpdateCheck result(
    UpdateOutcome outcome, {
    GbFile? candidate,
    List<GbFile> options = const <GbFile>[],
  }) =>
      UpdateCheck(
        outcome: outcome,
        candidate: candidate,
        newerFiles: _newestFirst(options),
        isGuess: true,
        isObsolete: remote.isObsolete,
        comparedAgainst: baseline,
      );

  if (newer.isNotEmpty) {
    // Every file published since the baseline, and on this path they are all
    // equally plausible: nothing here knows which file is installed, so the
    // "candidate" is only the newest, and the list is the honest answer.
    return result(
      UpdateOutcome.possiblyOutdated,
      candidate: _newest(newer),
      options: newer,
    );
  }
  // `_tsDateUpdated` and not `_tsDateModified`: the second is bumped by any
  // edit including cosmetic ones, and would flag a mod because its author fixed
  // a typo in the description. Only reached when no file date could answer —
  // a file with a date is the better signal because it can be *named*.
  final updated = remote.dateUpdated;
  if (updated != null && updated.isAfter(baseline)) {
    return result(UpdateOutcome.possiblyOutdated);
  }
  return result(UpdateOutcome.upToDate);
}

/// `exact` or `user`. Everything else is a guess we recorded and label as one.
///
/// Delegates to the enum rather than restating the test: the bulk resolution
/// pass asks the same question to decide which identities still want a human's
/// confirmation, and two copies of "which tiers count as established" is a
/// disagreement waiting to happen.
bool _isConfirmed(OriginConfidence confidence) => confidence.isConfirmed;

/// Newest upload first, undated entries last, ties broken by id so the order is
/// stable across runs — a list the user reads must not reshuffle itself.
List<GbFile> _newestFirst(List<GbFile> files) => [...files]..sort((a, b) {
      final aDate = a.dateAdded;
      final bDate = b.dateAdded;
      if (aDate == null && bDate == null) return a.idRow.compareTo(b.idRow);
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      final byDate = bDate.compareTo(aDate);
      return byDate != 0 ? byDate : a.idRow.compareTo(b.idRow);
    });

GbFile? _newest(List<GbFile> files) {
  GbFile? best;
  for (final file in files) {
    final date = file.dateAdded;
    if (date == null) continue;
    if (best == null || date.isAfter(best.dateAdded!)) best = file;
  }
  return best ?? (files.isEmpty ? null : files.first);
}

GbFile? _newestWithLabel(List<GbFile> files, String? label) {
  if (label == null) return null;
  return _newest([
    for (final file in files)
      if (_labelKey(file.description) == label) file,
  ]);
}

/// A declared version, normalised, or null when the author declared none.
///
/// Null-for-absent is the rule here as much as for labels: two files that both
/// omit `_sVersion` have not declared the same version, they have declared
/// nothing, and treating that as agreement would silence every unversioned mod
/// on the site.
String? _versionKey(String? value) {
  final key = value?.trim().toLowerCase();
  return key == null || key.isEmpty ? null : key;
}

/// Case- and whitespace-insensitive, and **null for an empty label**.
///
/// The nullness is the rule, not a guard: two files that both carry no variant
/// label are not thereby the same variant, and treating them as one would turn
/// "the author published something" into "the author replaced your file".
String? _labelKey(String? value) {
  if (value == null) return null;
  final key = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  return key.isEmpty ? null : key;
}
