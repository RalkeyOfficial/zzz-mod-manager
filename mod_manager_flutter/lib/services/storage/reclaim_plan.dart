/// What "free up space" is allowed to delete, decided without touching a disk.
///
/// Pure, and deliberately the whole of the safety argument: a planner over a
/// list of records and a clock can be tested exhaustively, where the same rules
/// spread through the code that performs the deletes could only be tested by
/// arranging real races. [ReclaimService] does the listing and the deleting and
/// makes no decisions.
library;

import '../log/log_rotation.dart';

/// The five stores the sweep may touch. The library, the sidecars and
/// `<appData>/backups` are absent from this enum on purpose — the sweep has no
/// vocabulary for them, so no future edit here can reach them.
enum ReclaimTarget {
  /// Completed archives in `<appData>/downloads` whose install never ran.
  completedArchives,

  /// `.part` files and resume records that are orphaned or long abandoned.
  abandonedPartials,

  /// `zzz_archive_extract_*` directories a crash or a finished import left.
  tempExtracts,

  /// `<appData>/mod_images`, which nothing has written since 2.0.0.
  legacyImages,

  /// Log files beyond the ones worth keeping.
  oldLogs,
}

/// Why something was left alone. Every one of these is shown to the user —
/// a sweep that quietly does less than it says is worse than one that does
/// nothing.
enum ReclaimSkipReason {
  /// A transfer is queued, running, or has landed and not yet been installed.
  downloadsActive,

  /// An archive is being unpacked or imported right now.
  installInProgress,

  /// Written too recently to be sure it is finished with.
  tooRecent,

  /// The library could not be read, so what is reachable cannot be worked out.
  libraryUnreadable,

  /// Not a file this app wrote.
  notOurs,

  /// This run's own log.
  currentSession,

  /// Still reachable: the only copy of some mod's cover.
  stillReferenced,
}

/// One thing on disk the sweep might take. Plain data — no `File` objects, so
/// the planner cannot accidentally perform I/O.
class ReclaimCandidate {
  const ReclaimCandidate({
    required this.target,
    required this.path,
    required this.name,
    required this.bytes,
    required this.modified,
    this.isDirectory = false,
  });

  final ReclaimTarget target;
  final String path;

  /// The basename, which is what every naming rule here is written against.
  final String name;

  final int bytes;

  /// For a directory, the newest write **anywhere inside it** — see
  /// [ReclaimRules.tempGrace].
  final DateTime modified;

  final bool isDirectory;
}

/// A candidate and why it stays.
class ReclaimSkip {
  const ReclaimSkip(this.candidate, this.reason);

  final ReclaimCandidate candidate;
  final ReclaimSkipReason reason;
}

/// What the sweep will do.
class ReclaimPlan {
  const ReclaimPlan({required this.remove, required this.skip});

  final List<ReclaimCandidate> remove;
  final List<ReclaimSkip> skip;

  int get reclaimableBytes =>
      remove.fold<int>(0, (sum, candidate) => sum + candidate.bytes);

  bool get isEmpty => remove.isEmpty;

  Iterable<ReclaimCandidate> forTarget(ReclaimTarget target) =>
      remove.where((candidate) => candidate.target == target);

  /// The one reason a whole target was refused, if it was. Null when the target
  /// ran, whatever it individually skipped.
  ReclaimSkipReason? refusalFor(ReclaimTarget target) {
    if (remove.any((candidate) => candidate.target == target)) return null;
    for (final entry in skip) {
      if (entry.candidate.target == target &&
          (entry.reason == ReclaimSkipReason.downloadsActive ||
              entry.reason == ReclaimSkipReason.installInProgress ||
              entry.reason == ReclaimSkipReason.libraryUnreadable)) {
        return entry.reason;
      }
    }
    return null;
  }
}

/// The thresholds, in one place so the doc comments sit next to the numbers.
class ReclaimRules {
  const ReclaimRules({
    this.tempGrace = const Duration(hours: 1),
    this.keepLogs = 7,
  });

  /// How long an extraction directory must have been untouched.
  ///
  /// An hour rather than minutes because unpacking a multi-gigabyte archive
  /// genuinely runs that long, and because nothing locks `<appData>`: a second
  /// copy of the app shares this directory and cannot be asked what it is
  /// doing. The age is measured from the newest write **inside** the directory,
  /// never from the directory's own timestamp — a directory's mtime stops
  /// changing once its top-level entries exist, while a deep extraction is
  /// still writing megabytes underneath, so the outside looks idle exactly when
  /// the inside is busiest.
  final Duration tempGrace;

  /// How many of this app's log files survive, not counting the running one.
  final int keepLogs;
}

/// Decides the sweep.
///
/// ## The gate, and why it refuses a whole target rather than filtering files
///
/// `DownloadPaths.sweepCompleted` is documented as safe at launch and nowhere
/// else, because a completed archive sitting in `<appData>/downloads` is
/// indistinguishable from one an install is about to consume. On demand, the
/// only honest question is whether *anything* is in flight:
///
/// - [downloadsBusy] covers the queue. A job that has finished transferring but
///   has not been installed is still busy — its archive is under its final name
///   and is exactly what the sweep would take.
/// - [installBusy] covers what the queue cannot see. A drag-in or file-picker
///   install unpacks into a temp directory with no download job anywhere.
///
/// **Filtering to "only the files no job will claim" has no correct
/// implementation.** The final name of a download is chosen at the moment it
/// lands, by collision resolution — a job that will become `mod (2).rar` is
/// indistinguishable from one that will become `mod.rar` until it does. So when
/// the gate is closed the target is refused whole, and the user is told which
/// one and why.
///
/// The same gate covers the partials, which look safe and are not: a paused,
/// resumable `.part` can be exactly as old as the staleness rule allows and be
/// about to resume. If nothing is active, nothing can be resuming.
///
/// Logs and leftovers are not gated on downloads at all.
ReclaimPlan planReclaim(
  List<ReclaimCandidate> inventory, {
  required DateTime now,
  required bool downloadsBusy,
  required bool installBusy,
  required bool libraryReadable,
  required Set<String> reachableLegacyImages,

  /// The **basename** of this run's log file, which never goes.
  String? currentLogFile,
  ReclaimRules rules = const ReclaimRules(),
}) {
  final remove = <ReclaimCandidate>[];
  final skip = <ReclaimSkip>[];

  void refuse(ReclaimCandidate candidate, ReclaimSkipReason reason) =>
      skip.add(ReclaimSkip(candidate, reason));

  final logCandidates = [
    for (final candidate in inventory)
      if (candidate.target == ReclaimTarget.oldLogs) candidate,
  ];
  final logsToDrop = planLogReclaim(
    logCandidates.map((candidate) => candidate.name),
    current: currentLogFile,
    keep: rules.keepLogs,
  ).toSet();

  for (final candidate in inventory) {
    switch (candidate.target) {
      case ReclaimTarget.completedArchives:
      case ReclaimTarget.abandonedPartials:
        if (downloadsBusy) {
          refuse(candidate, ReclaimSkipReason.downloadsActive);
        } else if (installBusy) {
          refuse(candidate, ReclaimSkipReason.installInProgress);
        } else {
          remove.add(candidate);
        }

      case ReclaimTarget.tempExtracts:
        if (installBusy) {
          refuse(candidate, ReclaimSkipReason.installInProgress);
        } else if (now.difference(candidate.modified) < rules.tempGrace) {
          refuse(candidate, ReclaimSkipReason.tooRecent);
        } else {
          remove.add(candidate);
        }

      case ReclaimTarget.legacyImages:
        // **The sharpest edge in the feature.** A mod with no sidecar still
        // reaches its cover through this directory, and reachability is decided
        // against the library. An empty or unreadable library would make every
        // image look unreachable and take the lot — so it is not swept at all
        // rather than swept against a list that cannot be trusted.
        if (!libraryReadable) {
          refuse(candidate, ReclaimSkipReason.libraryUnreadable);
        } else if (reachableLegacyImages.contains(candidate.name)) {
          refuse(candidate, ReclaimSkipReason.stillReferenced);
        } else {
          remove.add(candidate);
        }

      case ReclaimTarget.oldLogs:
        if (candidate.name == currentLogFile) {
          refuse(candidate, ReclaimSkipReason.currentSession);
        } else if (!isLogFileName(candidate.name)) {
          refuse(candidate, ReclaimSkipReason.notOurs);
        } else if (!logsToDrop.contains(candidate.name)) {
          refuse(candidate, ReclaimSkipReason.tooRecent);
        } else {
          remove.add(candidate);
        }
    }
  }

  return ReclaimPlan(remove: remove, skip: skip);
}
