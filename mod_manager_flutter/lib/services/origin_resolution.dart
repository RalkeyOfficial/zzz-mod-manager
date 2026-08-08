/// Binding one library folder to one remote mod and file — the decisions, with
/// no dialog, no network and no filesystem around them.
///
/// The resolve dialog is mostly plumbing: fetch a profile, show a list, write
/// what came back. What is actually easy to get wrong is *what each answer is
/// allowed to claim*, and that is all here so it can be tested against real
/// captured profiles instead of clicked through.
///
/// Two rules from the plan's locked decisions govern every function below:
///
/// - **Destructive paths require exact knowledge; guesses may only inform.** So
///   a suggestion carries a stated [FileMatchReason] and is never preselected —
///   the only two things that preselect are a banked-hash match (which is
///   exact) and a mod that publishes exactly one file (where there is nothing to
///   guess between).
/// - **Never-confirmed is not safe.** An `inferred` identity came from a
///   free-form text field a human typed, so confirming it here raises it to
///   [OriginConfidence.user] rather than leaving it where the backfill left it.
library;

import '../models/gamebanana/gb_file.dart';
import '../models/mod_origin.dart';
import '../models/origin_enums.dart';
import '../utils/gamebanana_url.dart';
import 'installed_mods_index.dart';

/// Why one file is being offered as the likely installed one.
///
/// The dialog shows this verbatim next to the row. "No silent magic" is the
/// point: a ranked list with no visible reason is indistinguishable from a
/// ranked list with a wrong reason.
enum FileMatchReason {
  /// The archive we unpacked is byte-identical to this published file. The one
  /// **exact** answer available offline — and a matching key only, never an
  /// integrity or authenticity claim.
  archiveHash,

  /// The mod folder's name matches this file's archive name.
  folderName,

  /// The newest file uploaded at or before the mod was installed. A file
  /// uploaded *after* the install cannot be the one that is installed, so the
  /// candidate is picked from the ones that could be rather than by absolute
  /// distance.
  installDate,

  /// The mod publishes exactly one file, so there is nothing to choose between.
  onlyFile,

  /// Nothing local points at this file. Still listed — the user may simply know.
  none,
}

/// One row of the resolve dialog's file list.
class ResolveCandidate {
  const ResolveCandidate(this.file, this.reason);

  final GbFile file;
  final FileMatchReason reason;

  /// Whether picking this row may be recorded at [OriginConfidence.exact].
  ///
  /// Only the hash match qualifies. Everything else is the user telling us,
  /// which is [OriginConfidence.user] — trusted, but not the tier that gates
  /// unattended overwrites.
  bool get isExact => reason == FileMatchReason.archiveHash;
}

/// The ranked file list plus what, if anything, may start out selected.
class FileResolution {
  const FileResolution({
    required this.candidates,
    this.preselected,
  });

  static const FileResolution empty =
      FileResolution(candidates: <ResolveCandidate>[]);

  /// Every published file, current and archived, best guess first.
  final List<ResolveCandidate> candidates;

  /// The row to start on, or null when the user must choose unaided.
  final ResolveCandidate? preselected;

  /// Whether the answer is already settled and the picker can be skipped
  /// entirely — a banked hash matched a published checksum.
  bool get isSettled => preselected?.isExact ?? false;

  bool get isEmpty => candidates.isEmpty;
}

/// Ranks a mod's published files against what is known about the local folder.
///
/// [files] and [archivedFiles] are `_aFiles` and `_aArchivedFiles`; **both are
/// searched**, and that is not a nicety — an old local install matches a
/// superseded file far more often than the current one, so ignoring the
/// archived list throws away the best chance of identifying what the user
/// actually has.
///
/// Null for either list means "the response never carried it", which is
/// different from `[]` ("none published"); both are simply treated as nothing to
/// rank here, since neither yields a candidate.
FileResolution rankResolveCandidates({
  required List<GbFile>? files,
  required List<GbFile>? archivedFiles,
  required String folderName,
  DateTime? installedAt,
  String? archiveMd5,
}) {
  final all = <GbFile>[...?files, ...?archivedFiles];
  if (all.isEmpty) return FileResolution.empty;

  final reasons = <int, FileMatchReason>{};

  // 1. The exact one, if it is there. Checked first and alone: once bytes match
  //    a published checksum, nothing weaker can improve on it.
  final banked = InstalledModsIndex.normalizeArchiveMd5(archiveMd5);
  if (banked != null) {
    for (final file in all) {
      if (InstalledModsIndex.normalizeArchiveMd5(file.md5Checksum) == banked) {
        reasons[file.idRow] = FileMatchReason.archiveHash;
        break;
      }
    }
  }

  // 2. Folder name ↔ archive name. Compared with extensions and separators
  //    stripped, because the folder is what the archive *unpacked to* rather
  //    than a copy of its name: `Ellen Swimsuit` vs `ellen_swimsuit.zip`.
  if (reasons.isEmpty) {
    final needle = _nameKey(folderName);
    if (needle.isNotEmpty) {
      for (final file in all) {
        if (_nameKey(_withoutExtension(file.file)) == needle) {
          reasons[file.idRow] = FileMatchReason.folderName;
          break;
        }
      }
    }
  }

  // 3. The newest file that already existed when the mod was installed.
  if (reasons.isEmpty && installedAt != null) {
    GbFile? best;
    for (final file in all) {
      final added = file.dateAdded;
      if (added == null || added.isAfter(installedAt)) continue;
      if (best == null || added.isAfter(best.dateAdded!)) best = file;
    }
    if (best != null) reasons[best.idRow] = FileMatchReason.installDate;
  }

  // 4. Nothing to choose between.
  //
  // **A property of the list, not a reason on a row.** The reason map is about
  // evidence and the strongest wins, so `putIfAbsent` correctly leaves a
  // hash/name/date match in place on the one file — but "there is only one file"
  // is a statement about *ambiguity*, and it stays true whatever else matched.
  // Deciding the preselect off `top.reason` alone got this exactly backwards:
  // a single-file mod was preselected only while nothing local pointed at it,
  // and stopped being preselected the moment the evidence got stronger.
  final unambiguous = all.length == 1;
  if (unambiguous) {
    reasons.putIfAbsent(all.first.idRow, () => FileMatchReason.onlyFile);
  }

  final ranked = [
    for (final file in all)
      ResolveCandidate(file, reasons[file.idRow] ?? FileMatchReason.none),
  ]..sort(_byRank);

  final top = ranked.first;
  return FileResolution(
    candidates: ranked,
    // A stated reason is a suggestion; only certainty and unambiguity preselect.
    preselected: top.reason == FileMatchReason.archiveHash || unambiguous
        ? top
        : null,
  );
}

/// Best guess first, then current files before superseded ones, then newest
/// upload first. The last two keys only order the rows nobody suggested, so the
/// list reads the way the mod page does when we know nothing.
int _byRank(ResolveCandidate a, ResolveCandidate b) {
  final byReason = a.reason.index.compareTo(b.reason.index);
  if (byReason != 0) return byReason;
  final byArchived = (a.file.isArchived ? 1 : 0) - (b.file.isArchived ? 1 : 0);
  if (byArchived != 0) return byArchived;
  final aDate = a.file.dateAdded;
  final bDate = b.file.dateAdded;
  if (aDate != null && bDate != null && aDate != bDate) {
    return bDate.compareTo(aDate);
  }
  return a.file.idRow.compareTo(b.file.idRow);
}

String _withoutExtension(String? filename) {
  if (filename == null) return '';
  final dot = filename.lastIndexOf('.');
  return dot <= 0 ? filename : filename.substring(0, dot);
}

/// Lower-cased with everything that isn't a letter or digit removed.
///
/// Deliberately not a fuzzy score. A near-match would have to be rendered as a
/// suggestion the user then rubber-stamps, and folder names in the wild
/// (`Ellen final FIXED v2`, `bikini`, `mod`) are exactly where that goes wrong.
/// Equal-after-normalising is a fact; "78% similar" is a guess wearing a number.
String _nameKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The pure transforms the resolve dialog writes through.
///
/// Every one takes the block currently on disk and returns the block to write,
/// or **null meaning "don't write"** — the write path re-reads the sidecar
/// before applying these, so a decision that no longer makes sense against what
/// came back has to be able to abandon rather than clobber.
class OriginResolution {
  const OriginResolution._();

  /// Binds the folder to remote mod [modId] because the user said so.
  ///
  /// [OriginConfidence.user] and never higher: the user picking a mod page is
  /// trusted enough for a confirmed update, but it is not the same as having
  /// downloaded the file or matched its checksum, which is what `exact` means.
  static ModOrigin bind(ModOrigin? existing, int modId) {
    final base = existing ??
        // Genuinely unknown for a mod that never had a block: it may have been
        // hand-copied, imported, or downloaded by an older build. The
        // least-privileged answer costs nothing, since provenance is not the
        // auto-update gate — confidence is.
        const ModOrigin(provenance: OriginProvenance.importedFolder);
    return base.boundTo(
      modId: modId,
      confidence: OriginConfidence.user,
      source: gameBananaSource,
    );
  }

  /// Records which file of the bound mod is installed.
  ///
  /// Returns null when the block is no longer bound to [modId] — the sidecar was
  /// rewritten while the dialog was open, and a `file_id` written against the
  /// wrong mod is precisely the corruption the re-read exists to prevent.
  ///
  /// `version` and `versionLabel` come from the two GameBanana strings that must
  /// never be conflated: `_sVersion` is a per-file version, `_sDescription` is
  /// the author's variant label ("white hair ver"). Collapsing them would make
  /// two variants of one release look like two releases.
  static ModOrigin? pickFile(
    ModOrigin? existing, {
    required int modId,
    required GbFile file,
    required bool exact,
  }) {
    if (existing == null || existing.modId != modId) return null;
    return existing.copyWith(
      fileId: file.idRow,
      version: file.version,
      versionLabel: file.description,
      versionConfidence:
          exact ? OriginConfidence.exact : OriginConfidence.user,
    );
  }

  /// "I don't know which file — I got it around then."
  ///
  /// Records no file and no version, only a date to compare against, so the mod
  /// is flagged for anything published *after* it arrived and stays quiet about
  /// everything before. Requires zero knowledge from the user, which is what
  /// makes it the highest value-per-line answer in the dialog.
  ///
  /// [remoteCreatedAt] clamps the baseline, and the clamp is load-bearing rather
  /// than tidy. `installed_at` is frequently a **proxy** derived from the oldest
  /// file in the folder, and for a library placed on disk by hand (`cp -p`, the
  /// user's own 7-Zip run, a synced folder) the author's build timestamps
  /// survive and that proxy can read *years* early. Left unclamped, a baseline
  /// before the mod even existed flags every file it has ever published.
  ///
  /// Returns null when no baseline can be derived at all; the caller must not
  /// offer the action in that state, since `assumed_latest` without a date is a
  /// tier that compares against nothing.
  static ModOrigin? assumeCurrent(
    ModOrigin? existing, {
    DateTime? installedAt,
    DateTime? remoteCreatedAt,
  }) {
    if (existing == null) return null;
    final observed = installedAt ?? existing.installedAt;
    final baseline = _latest(observed, remoteCreatedAt);
    if (baseline == null) return null;
    return existing.copyWith(
      installedAt: existing.installedAt ?? observed,
      // Only claim a proxy when one was actually supplied. A baseline derived
      // from the mod's own creation date leaves the install date unknown, and
      // flagging that as "derived from file timestamps" would describe a value
      // that isn't there.
      installedAtIsProxy: existing.installedAt == null && observed != null
          ? true
          : existing.installedAtIsProxy,
      versionConfidence: OriginConfidence.assumedLatest,
      baselineRemoteDate: baseline,
    );
  }

  /// "Not from GameBanana / it's my own" — the status slot goes quiet
  /// permanently.
  ///
  /// Deliberately the one thing that *writes* a block for a mod that had none:
  /// the don't-litter rule says an untracked mod gets no sidecar, but this is an
  /// explicit user decision and absence cannot express it — absence means "not
  /// looked at yet", which is exactly what the user is trying to stop.
  ///
  /// The remote identity is left in place rather than erased. It costs nothing
  /// (nothing reads it while tracking is off, including the installed-mods
  /// index), and it is what makes [resumeTracking] a real undo instead of a
  /// second trip through the dialog.
  static ModOrigin stopTracking(ModOrigin? existing) =>
      (existing ??
              const ModOrigin(provenance: OriginProvenance.importedFolder))
          .copyWith(tracking: OriginTracking.off);

  /// Undoes [stopTracking].
  static ModOrigin resumeTracking(ModOrigin existing) =>
      existing.copyWith(tracking: OriginTracking.auto);

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}
