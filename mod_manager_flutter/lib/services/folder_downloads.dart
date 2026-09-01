/// **Everything a mod folder holds, as peers.**
///
/// A folder is frequently two downloads: a mod and a patch applied into it. The
/// sidecar stores one of them in `origin`'s own fields and the rest in
/// `origin.companions` — and **which one lands where is install order, not
/// rank.** Install the patch first and the patch is the primary; install the mod
/// first and it is. The block is identical in substance either way.
///
/// So every surface that reads the block straight renders one download as the
/// subject and the other as an afterthought, and does it *inconsistently*: the
/// same pair of mods swaps places depending on the order somebody happened to
/// install them in. This flattens that away. What comes out is one list, each
/// entry carrying the role it actually plays, and nothing in it distinguishes
/// the entry the sidecar happened to store first.
///
/// Pure, and separate from the widget for the usual reason: what is easy to get
/// wrong is not the layout but the **role derivation**, which is a small piece
/// of logic with two inputs and no obvious right answer to eyeball.
library;

import '../models/mod_companion.dart';
import '../models/mod_origin.dart';
import 'origin_summary.dart';

/// What a download in the folder *is*, absolutely rather than relative to
/// another entry.
///
/// `ModCompanion.role` is relative — it names the companion's relationship to
/// the primary — so `base` on a companion and `patch` on a companion describe
/// opposite folders. These two do not move.
enum FolderDownloadRole {
  /// The mod itself. What a patch in the same folder patches.
  mod,

  /// A patch: files that replace some of the mod's.
  patch,
}

/// One download in the folder.
class FolderDownload {
  const FolderDownload({
    required this.role,
    required this.modId,
    required this.isFolderOwn,
    required this.summary,
    required this.remoteMissing,
  });

  final FolderDownloadRole role;

  /// The remote mod id, or null for a folder tracked with no identity at all.
  final int? modId;

  /// Whether this is the entry stored in `origin`'s own fields.
  ///
  /// **Not for ranking it** — it exists because the two are named from
  /// different places (this one can fall back to the folder name) and because
  /// the update dialog's facts and its Update button act on one identity, which
  /// a caller may want to point at. Nothing here orders by it.
  final bool isFolderOwn;

  /// What the block claims about this download — the same fold the resolve
  /// surfaces show, so "on record" cannot come to mean two things.
  final OriginSummary summary;

  /// This download's page has gone upstream.
  final bool remoteMissing;
}

/// The folder's contents, mod first and patches after.
///
/// **Ordered by role, never by which entry the sidecar stored first.** Base
/// before patch is the order the files themselves go on disk
/// (`applying-updates.md` §6), and it is the one ordering that reads the same
/// for both install orders — which is the whole point.
///
/// Returns a single entry for an ordinary mod and an empty list for a folder
/// with no origin block at all. A caller that only wants to say something about
/// *mixed* folders tests the length; this does not decide that for it.
List<FolderDownload> folderDownloads(ModOrigin? origin) {
  if (origin == null) return const <FolderDownload>[];

  // **The primary is a patch when something says so**, and two things can:
  // `ingest.patch_shaped`, captured at install because that is the only moment
  // a patch folder is legible; or a companion recorded as the `base`, which is
  // the user having answered *what does this patch patch*. Either alone is
  // enough — the first exists before anyone has answered, and the second
  // survives a sidecar that never carried an ingest block.
  final ownIsPatch = (origin.ingest?.patchShaped ?? false) ||
      origin.companions.any((c) => c.role == CompanionRole.base);

  final own = FolderDownload(
    role: ownIsPatch ? FolderDownloadRole.patch : FolderDownloadRole.mod,
    modId: origin.modId,
    isFolderOwn: true,
    summary: summarizeOrigin(origin),
    remoteMissing: origin.remoteMissing,
  );
  final companions = [
    for (final companion in origin.companions)
      FolderDownload(
        role: switch (companion.role) {
          CompanionRole.base => FolderDownloadRole.mod,
          CompanionRole.patch => FolderDownloadRole.patch,
        },
        modId: companion.modId,
        isFolderOwn: false,
        summary: summarizeCompanion(companion),
        remoteMissing: companion.remoteMissing,
      ),
  ];

  // Partitioned rather than sorted: `List.sort` is not stable in Dart, and
  // entries of one role must keep the order the block lists them in — peers
  // that reshuffled on a rewrite would make a sidecar edit look like a change
  // to the folder.
  final all = [own, ...companions];
  return [
    for (final download in all)
      if (download.role == FolderDownloadRole.mod) download,
    for (final download in all)
      if (download.role == FolderDownloadRole.patch) download,
  ];
}
