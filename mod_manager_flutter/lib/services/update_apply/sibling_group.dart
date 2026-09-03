/// **The other mods that came out of this archive**, and which folder of it is
/// which.
///
/// One archive does not map to one mod: the import dialog offers "install
/// separately", and each top-level folder becomes its own mod folder with its
/// own origin block. Updating them one at a time re-downloads the same file per
/// member, and archives reach 1.24 GB
/// ([`gamebanana-api.md`](../../../../docs/gamebanana-api.md) §8) — so one
/// download feeding every member is the whole point of this.
///
/// ## Two identifiers, and neither of them is a folder name
///
/// **Which mods came from one archive** is `ingest.sibling_group`, an id stamped
/// on every folder one import produced. Never `mod_id` + `file_id`: two mods
/// from the same *page*, installed separately at different times, carry the same
/// pair, and the offline backfill produces exactly that by accident — common and
/// expected, observed twice in a 23-mod library
/// ([`origin-tracking.md`](../../../../docs/origin-tracking.md) §3). Reading a
/// shared id as a group would write one mod's archive over another's folder.
///
/// **Which folder of the archive belongs to which mod** is `ingest.folders`, the
/// archive-relative basename. That is why it is recorded rather than derived
/// from the mod's own folder name: the user renames their folders, and the
/// sidecar survives it.
///
/// ## Why a record may drive a write where a guess may not
///
/// Everything else this app infers about a folder may inform and never drive.
/// The difference is that a sibling group is not an inference: the app watched
/// one archive become these folders and wrote it down, which is the same grounds
/// on which the write it is about to do is `exact`.
///
/// **Consequence:** a backfilled library has no groups and never will — nothing
/// on disk records that two folders came from one archive — so this only ever
/// fires for an archive installed through the app.
///
/// Pure: no filesystem, no dialogs, no network. It composes [updateWriteRoute]
/// and [planUpdateLayout], which are pure for the same reason.
library;

import '../../models/character_info.dart';
import '../../models/gamebanana/gb_file.dart';
import '../../models/mod_download.dart';
import 'update_layout.dart';
import 'update_write_route.dart';

/// Why a member of the group is not offered.
enum SiblingRefusal {
  /// Its stack does not put this download at the bottom, so this write would
  /// not be that folder's base — or it does not record this download at all.
  notBase,

  /// It already holds the file this would install. Offline and exact: the
  /// recorded file id, never a check.
  alreadyCurrent,

  /// Its recorded folder is not in this archive under any name, and there is
  /// more than one folder to pick from.
  layoutChanged,

  /// Two members claim the same folder of the archive, so which is which cannot
  /// be known.
  sourceCollision,
}

/// A member that is offered but **not pre-ticked**.
///
/// The middle state between writing a folder and refusing to, and it exists
/// because both of these are things the user may well want and neither is
/// something to do to them by default. The archive is already downloaded, so
/// offering costs nothing; the row is named, noted and one tap from being taken.
enum SiblingCaution {
  /// It holds a file published **after** the one being installed, so writing it
  /// is a downgrade.
  ///
  /// Routine, because updating members one at a time is the status quo this
  /// feature replaces: two mods from one archive diverge as soon as one of them
  /// is updated alone. The user pressed Update while looking at *another* mod's
  /// file list, and nothing on that screen said what this one was on.
  holdsNewer,

  /// The user waved this mod's updates away, and this file is not past the point
  /// they waved away up to.
  ///
  /// `ModDownload.updatesDismissedUntil` means "I have seen what this mod
  /// published up to here and I don't want it". Pre-ticking against a standing
  /// instruction is bad enough on its own; `ModDownload.updatedTo` then *clears*
  /// the dismissal, so taking it would also erase the instruction with nothing
  /// on screen saying so.
  dismissed,
}

/// One mod the archive can be written into, and how.
class SiblingTarget {
  const SiblingTarget({
    required this.mod,
    required this.route,
    required this.source,
    this.caution,
  });

  final ModInfo mod;

  /// How this folder takes the write — always [UpdateWriteKind.base] here.
  final UpdateWriteRoute route;

  /// The top-level folder of the archive this member's files come from, as a
  /// basename.
  final String source;

  /// Why this row is offered unticked, or null to offer it ticked.
  final SiblingCaution? caution;
}

/// A member that is not offered, and the reason to say out loud.
class SiblingRefused {
  const SiblingRefused({required this.mod, required this.reason});

  final ModInfo mod;
  final SiblingRefusal reason;
}

class SiblingGroupPlan {
  const SiblingGroupPlan({
    this.targets = const <SiblingTarget>[],
    this.refused = const <SiblingRefused>[],
    this.otherFolders = const <String>[],
    this.primaryRefused,
  });

  static const SiblingGroupPlan none = SiblingGroupPlan();

  /// The **other** members this archive can be written into. Never the mod the
  /// user pressed Update on — the caller already has that one and prepends it.
  final List<SiblingTarget> targets;

  final List<SiblingRefused> refused;

  /// Top-level folders of the archive that **nothing this write touches** — a
  /// `previews/` folder, a mod that is not in the library, and the folder of any
  /// member that was refused.
  ///
  /// It is deliberately *not* "belongs to no mod of yours": a refused member's
  /// folder does belong to one of their mods, and the same screen says so two
  /// sections above. What this list means is which of the download's bytes go
  /// unused, which is the useful half and the one the wording states.
  ///
  /// Named rather than dropped: a user watching two thirds of a download go
  /// unused deserves to be told why.
  final List<String> otherFolders;

  /// Set when the **primary** collides with a sibling over one folder, which is
  /// the one refusal that can reach the mod the user chose.
  final SiblingRefusal? primaryRefused;

  bool get isEmpty =>
      targets.isEmpty && refused.isEmpty && primaryRefused == null;
}

/// The other mods of [primary]'s archive, split into what can be written and
/// what cannot.
///
/// [subjectModId] is the download being updated and [target] the file that would
/// be installed. [incomingFolders] are the archive's top-level folder
/// **basenames**. [published] is what the check surfaced as newer than what the
/// primary holds — used only to place a member's own recorded file against
/// [target], which is the difference between updating it and rolling it back.
SiblingGroupPlan planSiblingUpdates({
  required ModInfo primary,
  required Iterable<ModInfo> library,
  required int subjectModId,
  required GbFile target,
  required List<String> incomingFolders,
  List<GbFile> published = const <GbFile>[],
}) {
  final screened = _screenMembers(
    primary: primary,
    library: library,
    subjectModId: subjectModId,
    target: target,
    published: published,
  );
  if (screened.kept.isEmpty && screened.refused.isEmpty) {
    return SiblingGroupPlan.none;
  }

  final targets = <SiblingTarget>[];
  final refused = [...screened.refused];

  for (final candidate in screened.kept) {
    final member = candidate.mod;
    final route = candidate.route;

    final layout = planUpdateLayout(
      ingest: member.origin?.ingest,
      incomingFolders: incomingFolders,
    );
    // `separate` is the only mode a group is ever written for — `combined` is
    // precisely the case where one archive produced one mod — so a proceeding
    // layout here is always a single mapping.
    if (!layout.canProceed || layout.mappings.length != 1) {
      refused.add(
        SiblingRefused(mod: member, reason: SiblingRefusal.layoutChanged),
      );
      continue;
    }

    targets.add(SiblingTarget(
      mod: member,
      route: route,
      source: layout.mappings.single.source,
      caution: candidate.caution,
    ));
  }

  final primarySource = _sourceFor(primary, incomingFolders);

  // **The collision guard**, and the one thing grouping can see that a per-mod
  // update structurally cannot: on its own each member matches its recorded
  // folder, writes, and is silently wrong. Two recorded names differing only in
  // case reach it, against a repack that kept one of them.
  //
  // Every claimant is refused, the primary included. Guessing which of two mods
  // a folder became is the thing `layoutChanged` already refuses to do, and
  // being the mod the user pressed the button on is not evidence.
  //
  // It also catches the commoner shape: [planUpdateLayout] absorbs a renamed
  // upstream folder when there is **only one** to pick, which is right for a
  // lone mod and wrong for a group — every member absorbs the same folder. An
  // archive that collapsed several folders into one is therefore refused rather
  // than written into every member. The absorption is not lost: a group whose
  // other members are deleted has nothing left to contest it, and the primary
  // takes the ordinary single-mod path.
  final claims = <String, int>{};
  for (final source in [
    if (primarySource != null) primarySource,
    for (final target in targets) target.source,
  ]) {
    final key = source.toLowerCase();
    claims[key] = (claims[key] ?? 0) + 1;
  }
  bool contested(String source) => (claims[source.toLowerCase()] ?? 0) > 1;

  final kept = <SiblingTarget>[];
  for (final target in targets) {
    if (contested(target.source)) {
      refused.add(
        SiblingRefused(mod: target.mod, reason: SiblingRefusal.sourceCollision),
      );
      continue;
    }
    kept.add(target);
  }

  final claimed = <String>{
    if (primarySource != null) primarySource.toLowerCase(),
    for (final target in kept) target.source.toLowerCase(),
  };

  return SiblingGroupPlan(
    targets: kept,
    refused: refused,
    otherFolders: [
      for (final folder in incomingFolders)
        if (!claimed.contains(folder.toLowerCase())) folder,
    ]..sort(),
    primaryRefused: primarySource != null && contested(primarySource)
        ? SiblingRefusal.sourceCollision
        : null,
  );
}

/// The archive's other mods that this file would actually change.
///
/// **What can be answered before the download**, and the reason this is separate
/// from [planSiblingUpdates]: membership and the recorded file id are on record,
/// where which folder each member takes needs the archive in hand. So the update
/// dialog can say "2 other mods came from this archive" while the confirmation
/// is the first screen that can promise anything about them.
///
/// Cautioned members are counted, because the hint promises they will be
/// *offered* rather than written.
List<ModInfo> siblingsAwaiting({
  required ModInfo primary,
  required Iterable<ModInfo> library,
  required int subjectModId,
  required GbFile target,
  List<GbFile> published = const <GbFile>[],
}) =>
    [
      for (final candidate in _screenMembers(
        primary: primary,
        library: library,
        subjectModId: subjectModId,
        target: target,
        published: published,
      ).kept)
        candidate.mod,
    ];

/// One member of the group that this write could reach, with how it would land.
class _Candidate {
  const _Candidate(this.mod, this.route, this.caution);

  final ModInfo mod;
  final UpdateWriteRoute route;
  final SiblingCaution? caution;
}

/// Membership, the two refusals that need no archive, and the two cautions.
///
/// Shared so the pre-download count and the confirmation cannot come to
/// disagree about who is in the group: a mod named in the hint and then missing
/// from the list reads as the app having lost it.
({List<_Candidate> kept, List<SiblingRefused> refused}) _screenMembers({
  required ModInfo primary,
  required Iterable<ModInfo> library,
  required int subjectModId,
  required GbFile target,
  required List<GbFile> published,
}) {
  final group = primary.origin?.ingest?.siblingGroup;
  // The fast exit, and it is the case for essentially every mod in a real
  // library. Answered from data already in hand, so nothing is scanned.
  if (group == null) {
    return (kept: const <_Candidate>[], refused: const <SiblingRefused>[]);
  }

  final kept = <_Candidate>[];
  final refused = <SiblingRefused>[];

  // When each file the check surfaced was published, so a member's own recorded
  // file can be placed against the one being installed.
  final publishedAt = <int, DateTime>{
    for (final file in published)
      if (file.dateAdded case final date?) file.idRow: date,
  };

  for (final member in library) {
    if (member.id == primary.id) continue;
    if (member.origin?.ingest?.siblingGroup != group) continue;

    final route = updateWriteRoute(
      origin: member.origin,
      subjectModId: subjectModId,
    );
    if (route.kind != UpdateWriteKind.base) {
      refused.add(SiblingRefused(mod: member, reason: SiblingRefusal.notBase));
      continue;
    }

    final layer = member.origin?.base;

    // Unknown is not a match: a folder with no recorded file id is a target, not
    // something already holding this version.
    if (layer?.fileId == target.idRow) {
      refused.add(
        SiblingRefused(mod: member, reason: SiblingRefusal.alreadyCurrent),
      );
      continue;
    }

    kept.add(_Candidate(
      member,
      route,
      _cautionFor(
        layer: layer,
        target: target,
        publishedAt: publishedAt,
      ),
    ));
  }

  return (kept: kept, refused: refused);
}

/// Whether this member is offered unticked, and why.
///
/// **A downgrade beats a dismissal** when both apply: rolling the folder back is
/// the larger surprise, and it is the one the user could not have seen coming
/// from the file list they were looking at.
///
/// **A member whose recorded file is not among [publishedAt] gets no caution,
/// and that is a real hole rather than an impossibility.** [published] is the
/// check's own candidate pool, which has already had removed from it: files the
/// author **archived**, release-group siblings of the *primary's* installed
/// file, and anything stamped with the primary's version. So a member holding an
/// archived newer file cannot be placed and is offered ticked — authors archive
/// superseded files routinely.
///
/// Erring toward offering is still the right side to err on: a wrong caution
/// costs a tick, where refusing hides a mod the user wants. Closing it properly
/// needs the archived list (`GbMod.allFiles`) rather than the check's pool,
/// which is a second request on this path — filed in
/// `docs/applying-updates.md` §7 rather than done here.
SiblingCaution? _cautionFor({
  required ModDownload? layer,
  required GbFile target,
  required Map<int, DateTime> publishedAt,
}) {
  if (layer == null) return null;

  final held = layer.fileId == null ? null : publishedAt[layer.fileId];
  final incoming = target.dateAdded;
  if (held != null && incoming != null && held.isAfter(incoming)) {
    return SiblingCaution.holdsNewer;
  }

  // The same comparison `_withDismissal` makes: a finding with no date cannot be
  // shown to be covered, so it is not, and the caution does not apply.
  final until = layer.updatesDismissedUntil;
  if (until != null && incoming != null && !incoming.isAfter(until)) {
    return SiblingCaution.dismissed;
  }
  return null;
}

/// Which folder of the archive the primary takes, or null when its own layout
/// cannot be replayed — in which case it claims nothing and cannot be contested.
String? _sourceFor(ModInfo mod, List<String> incomingFolders) {
  final layout = planUpdateLayout(
    ingest: mod.origin?.ingest,
    incomingFolders: incomingFolders,
  );
  if (!layout.canProceed || layout.mappings.length != 1) return null;
  return layout.mappings.single.source;
}
