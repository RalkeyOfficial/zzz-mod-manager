import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/services/update_apply/sibling_group.dart';

/// **The other mods that came out of one archive.**
///
/// The load-bearing half of this is the refusals, not the matches. A group
/// drives a real write into folders the user did not name, so what it must never
/// mistake for a group matters more than what it recognises as one.
void main() {
  const archiveModId = 7100;
  const installedFileId = 900;
  const newerFileId = 901;

  /// A file published *after* the one being installed — what a member that has
  /// been updated on its own is sitting on.
  const laterFileId = 902;

  final released = DateTime.utc(2026, 3, 1);
  final laterStill = DateTime.utc(2026, 6, 1);

  ModInfo mod(
    String id, {
    String? group,
    List<String> folders = const [],
    int? modId = archiveModId,
    int? fileId = installedFileId,
    bool patchOnTop = false,
    DateTime? dismissedUntil,
  }) =>
      ModInfo(
        id: id,
        name: id,
        characterId: 'ellen',
        isActive: false,
        origin: ModOrigin(
          source: 'gamebanana',
          provenance: OriginProvenance.downloaded,
          ingest: ModIngest(folders: folders, siblingGroup: group),
          downloads: [
            ModDownload(
              modId: modId,
              modIdConfidence: OriginConfidence.exact,
              fileId: fileId,
              updatesDismissedUntil: dismissedUntil,
            ),
            if (patchOnTop)
              const ModDownload(
                role: DownloadRole.patch,
                modId: 5100,
                modIdConfidence: OriginConfidence.exact,
              ),
          ],
        ),
      );

  /// The file being installed.
  final target = GbFile(idRow: newerFileId, dateAdded: released);

  /// What the check surfaced as newer than what the primary holds — the only
  /// place a member's own file can be placed in time.
  final onThePage = [
    target,
    GbFile(idRow: laterFileId, dateAdded: laterStill),
  ];

  SiblingGroupPlan plan({
    required ModInfo primary,
    required List<ModInfo> library,
    List<String> incoming = const ['Ellen Red', 'Ellen Blue'],
    List<GbFile> published = const <GbFile>[],
  }) =>
      planSiblingUpdates(
        primary: primary,
        library: library,
        subjectModId: archiveModId,
        target: target,
        published: published,
        incomingFolders: incoming,
      );

  group('what counts as a group', () {
    test('no group id means nothing is offered', () {
      final primary = mod('Ellen Red', folders: ['Ellen Red']);
      final other = mod('Ellen Blue', folders: ['Ellen Blue']);

      expect(plan(primary: primary, library: [primary, other]).isEmpty, isTrue);
    });

    // The canary for `origin-tracking.md` §3: after the offline backfill, two
    // mods from one *page* share a mod id, which is common and expected. Reading
    // that as a group would write one mod's archive over the other's folder, so
    // this asserts the refusal rather than the feature.
    test('a shared mod id is not a group', () {
      final primary = mod('Ellen Red', folders: ['Ellen Red']);
      final samePage = mod('Ellen Blue', folders: ['Ellen Blue']);

      final result = plan(primary: primary, library: [primary, samePage]);

      expect(result.targets, isEmpty);
      expect(result.refused, isEmpty,
          reason: 'not even as a refusal — it was never a member');
    });

    test('a matching group id is', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final sibling =
          mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(primary: primary, library: [primary, sibling]);

      expect(result.targets.map((t) => t.mod.id), ['Ellen Blue']);
      expect(result.targets.single.source, 'Ellen Blue');
    });

    test('a different group id is not', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final stranger =
          mod('Ellen Blue', group: 'g2', folders: ['Ellen Blue']);

      expect(plan(primary: primary, library: [primary, stranger]).isEmpty,
          isTrue);
    });

    test('the primary is never one of its own siblings', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final sibling =
          mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(primary: primary, library: [primary, sibling]);

      expect(result.targets.map((t) => t.mod.id), isNot(contains('Ellen Red')));
    });

    // The mod's own folder name is renamed by users and is never consulted: the
    // match is the sidecar's archive-relative basename against the archive.
    test('a folder the user renamed is still found by what it recorded', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final renamed =
          mod('my blue one', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(primary: primary, library: [primary, renamed]);

      expect(result.targets.single.mod.id, 'my blue one');
      expect(result.targets.single.source, 'Ellen Blue');
    });
  });

  group('members that are not offered', () {
    test('one already holding the file this would install', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final current = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: newerFileId);

      final result = plan(primary: primary, library: [primary, current]);

      expect(result.targets, isEmpty);
      expect(result.refused.single.reason, SiblingRefusal.alreadyCurrent);
    });

    test('an unknown file id is a target, not already current', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final unknown = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: null);

      final result = plan(primary: primary, library: [primary, unknown]);

      expect(result.targets.single.mod.id, 'Ellen Blue');
    });

    test('one whose stack does not record this download at all', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final elsewhere = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], modId: 6000);

      final result = plan(primary: primary, library: [primary, elsewhere]);

      expect(result.targets, isEmpty);
      expect(result.refused.single.reason, SiblingRefusal.notBase);
    });

    test('one whose recorded folder is gone from the archive', () {
      final primary =
          mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final moved =
          mod('Ellen Blue', group: 'g1', folders: ['Ellen Green']);

      final result = plan(primary: primary, library: [primary, moved]);

      expect(result.targets, isEmpty);
      expect(result.refused.single.reason, SiblingRefusal.layoutChanged);
    });

    // `planUpdateLayout` absorbs a renamed upstream folder when there is only
    // one to pick, which is right for a lone mod and wrong for a group: every
    // member absorbs the *same* folder. The collision guard is what stops two
    // mods being written from one folder's contents.
    //
    // The absorption is not lost — a group whose other members have been
    // deleted has no members left to contest it, so the primary takes the
    // ordinary single-mod path and still absorbs the rename.
    test('an archive collapsed to one folder is refused, not shared out', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final sibling = mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(
        primary: primary,
        library: [primary, sibling],
        incoming: ['Ellen Everything v4'],
      );

      expect(result.targets, isEmpty);
      expect(result.refused.single.reason, SiblingRefusal.sourceCollision);
      expect(result.primaryRefused, SiblingRefusal.sourceCollision);
    });

    test('a group with no members left leaves the primary to update alone', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);

      expect(
        plan(
          primary: primary,
          library: [primary],
          incoming: ['Ellen Everything v4'],
        ).isEmpty,
        isTrue,
      );
    });
  });

  /// **Offered, but not pre-ticked.** Both of these are things the user may
  /// want and neither is a thing to do to them by default, so they are a middle
  /// state rather than a refusal — the archive is already downloaded, so
  /// offering costs nothing.
  group('members that are offered unticked', () {
    test('one holding a file published after this one', () {
      // The shape this feature makes routine: members diverge as soon as one is
      // updated alone, because updating them one at a time is what came before.
      // The user pressed Update while looking at *another* mod's file list.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final ahead = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: laterFileId);

      final result = plan(
        primary: primary,
        library: [primary, ahead],
        published: onThePage,
      );

      expect(result.targets.single.caution, SiblingCaution.holdsNewer);
    });

    test('one whose updates the user waved away', () {
      // `updates_dismissed_until` means "I have seen what this mod published up
      // to here and I don't want it". Taking it would also *erase* the
      // dismissal, since `updatedTo` clears it.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final ignored = mod('Ellen Blue',
          group: 'g1',
          folders: ['Ellen Blue'],
          dismissedUntil: laterStill);

      final result = plan(
        primary: primary,
        library: [primary, ignored],
        published: onThePage,
      );

      expect(result.targets.single.caution, SiblingCaution.dismissed);
    });

    test('a dismissal older than this file does not apply', () {
      // The author has published something since, which is exactly when the
      // mark comes back on its own.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final ignored = mod('Ellen Blue',
          group: 'g1',
          folders: ['Ellen Blue'],
          dismissedUntil: DateTime.utc(2025));

      final result = plan(
        primary: primary,
        library: [primary, ignored],
        published: onThePage,
      );

      expect(result.targets.single.caution, isNull);
    });

    test('a downgrade beats a dismissal when both apply', () {
      // Rolling the folder back is the larger surprise, and the one the user
      // could not have seen coming from the list they were looking at.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final both = mod('Ellen Blue',
          group: 'g1',
          folders: ['Ellen Blue'],
          fileId: laterFileId,
          dismissedUntil: laterStill);

      final result = plan(
        primary: primary,
        library: [primary, both],
        published: onThePage,
      );

      expect(result.targets.single.caution, SiblingCaution.holdsNewer);
    });

    test('an ordinary member behind this file is ticked', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final behind = mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(
        primary: primary,
        library: [primary, behind],
        published: onThePage,
      );

      expect(result.targets.single.caution, isNull);
    });

    test('a member whose file nothing can place is ticked', () {
      // Nothing offline can say where an unpublished file sits in time, and the
      // list is every file newer than what the primary holds — so anything
      // newer than the target is transitively in it. Erring toward offering
      // costs a tick; erring toward refusing hides a mod they want.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final gone = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: 55555);

      final result = plan(
        primary: primary,
        library: [primary, gone],
        published: onThePage,
      );

      expect(result.targets.single.caution, isNull);
    });

    test('with no published list at all, nothing is cautioned', () {
      // The degraded input the repair and patch paths hand in. It reduces to
      // the older "is it on this exact file?" question and loses nothing those
      // paths had.
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final ahead = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: laterFileId);

      final result = plan(primary: primary, library: [primary, ahead]);

      expect(result.targets.single.caution, isNull);
    });
  });

  group('two members claiming one folder', () {
    // Reachable only from recorded names differing in case, against a repack
    // that kept one of them. On its own each member matches, writes, and is
    // silently wrong — which is the thing grouping can see and a per-mod update
    // cannot.
    ModInfo primary() =>
        mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
    ModInfo shadow() =>
        mod('Ellen Red 2', group: 'g1', folders: ['ellen red']);

    test('both are refused rather than one guessed at', () {
      final result = plan(
        primary: primary(),
        library: [primary(), shadow()],
        incoming: ['Ellen Red', 'Ellen Blue'],
      );

      expect(result.targets, isEmpty);
      expect(result.refused.single.reason, SiblingRefusal.sourceCollision);
    });

    test('being the mod the user pressed the button on is not evidence', () {
      final result = plan(
        primary: primary(),
        library: [primary(), shadow()],
        incoming: ['Ellen Red', 'Ellen Blue'],
      );

      expect(result.primaryRefused, SiblingRefusal.sourceCollision);
    });

    test('an uncontested member in the same archive still proceeds', () {
      final blue = mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(
        primary: primary(),
        library: [primary(), shadow(), blue],
        incoming: ['Ellen Red', 'Ellen Blue'],
      );

      expect(result.targets.map((t) => t.mod.id), ['Ellen Blue']);
    });
  });

  group('folders no mod claims', () {
    test('are named, and a member\'s own is not among them', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final sibling = mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(
        primary: primary,
        library: [primary, sibling],
        incoming: ['Ellen Red', 'Ellen Blue', 'previews'],
      );

      expect(result.otherFolders, ['previews']);
    });

    test('include the folder of a member that is no longer in the library', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final sibling = mod('Ellen Blue', group: 'g1', folders: ['Ellen Blue']);

      final result = plan(
        primary: primary,
        library: [primary, sibling],
        incoming: ['Ellen Red', 'Ellen Blue', 'Ellen Green'],
      );

      expect(result.otherFolders, ['Ellen Green']);
    });

    test('include a refused member\'s folder, since nothing writes it', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final current = mod('Ellen Blue',
          group: 'g1', folders: ['Ellen Blue'], fileId: newerFileId);

      final result = plan(primary: primary, library: [primary, current]);

      expect(result.otherFolders, ['Ellen Blue']);
    });
  });

  group('a member that holds a patch over the mod', () {
    test('is a target, and carries the patch files to put back', () {
      final primary = mod('Ellen Red', group: 'g1', folders: ['Ellen Red']);
      final patched = ModInfo(
        id: 'Ellen Blue',
        name: 'Ellen Blue',
        characterId: 'ellen',
        isActive: false,
        origin: const ModOrigin(
          source: 'gamebanana',
          provenance: OriginProvenance.downloaded,
          ingest: ModIngest(
            folders: ['Ellen Blue'],
            siblingGroup: 'g1',
            patchFiles: ['Textures/Body.dds'],
          ),
          downloads: [
            ModDownload(
              modId: archiveModId,
              modIdConfidence: OriginConfidence.exact,
              fileId: installedFileId,
            ),
            ModDownload(
              role: DownloadRole.patch,
              modId: 5100,
              modIdConfidence: OriginConfidence.exact,
            ),
          ],
        ),
      );

      final result = plan(primary: primary, library: [primary, patched]);

      expect(result.targets.single.route.patchFiles, ['Textures/Body.dds']);
      expect(result.targets.single.route.patchModId, 5100);
    });
  });
}
