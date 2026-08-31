import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/patch_placement.dart';

/// Where each file of a patch lands inside the mod it is being installed into.
///
/// The rule this pins is one sentence — **a file goes where the target already
/// keeps that name** — and the reason it needs pinning is that getting it wrong
/// is silent. Written at the root when the base mod keeps its textures in a
/// subfolder, the file lands *beside* the mod rather than over it: every
/// reference in the `.ini` still resolves to the original, the folder gains a
/// file nothing reads, and nothing changes in the game with no error anywhere.
///
/// Every path here is in `FolderContents` spelling — relative to the mod folder
/// root, `/`-separated, lower-cased — which is also why matching is
/// case-insensitive without this file doing anything about it.
void main() {
  /// A base mod that keeps its textures in a subfolder, which is the layout the
  /// naive "write it at the root" answer breaks on.
  const nested = <String>{
    'chara.ini',
    'textures/charabodyadiffuse.dds',
    'textures/charabodyanormalmap.dds',
    'charabodya.ib',
  };

  group('one candidate', () {
    test('a bare file lands where the target keeps that name', () {
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyadiffuse.dds'},
        target: nested,
      );

      expect(placement.mapping,
          {'charabodyadiffuse.dds': 'textures/charabodyadiffuse.dds'});
      expect(placement.unmatched, isEmpty);
      expect(placement.needsChoice, isFalse);
    });

    test('a file the target keeps at its root stays at the root', () {
      final placement = resolvePatchPlacement(
        incoming: const {'charabodya.ib'},
        target: nested,
      );
      expect(placement.mapping, {'charabodya.ib': 'charabodya.ib'});
    });

    test('the target\'s layout wins over the patch\'s own', () {
      // The patch author shipped it in a folder of their own choosing. Where it
      // has to *land* is decided by the mod being patched, not by them.
      final placement = resolvePatchPlacement(
        incoming: const {'assets/charabodya.ib'},
        target: nested,
      );
      expect(placement.mapping, {'assets/charabodya.ib': 'charabodya.ib'});
    });

    test('an .ini of the same name is replaced in place', () {
      // The ordinary case for a patch that ships its own `.ini`: same name,
      // overwritten rather than orphaned. The orphaned-`.ini` rule is what
      // covers the renamed case, and it is not this file's business.
      final placement = resolvePatchPlacement(
        incoming: const {'chara.ini'},
        target: nested,
      );
      expect(placement.mapping, {'chara.ini': 'chara.ini'});
    });
  });

  group('no candidate', () {
    test('a new file keeps its own relative path, and is reported', () {
      // A patch may legitimately add a texture the base never had. It is not an
      // error — but it is the one thing the user cannot verify by looking, so
      // it is said rather than done quietly.
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyaglowmap.dds'},
        target: nested,
      );
      expect(placement.mapping,
          {'charabodyaglowmap.dds': 'charabodyaglowmap.dds'});
      expect(placement.unmatched, ['charabodyaglowmap.dds']);
    });

    test('a new file inside a folder of its own keeps that folder', () {
      // Nothing in the target says otherwise, so the author's own structure is
      // the only information there is.
      final placement = resolvePatchPlacement(
        incoming: const {'extra/newthing.dds'},
        target: nested,
      );
      expect(placement.mapping, {'extra/newthing.dds': 'extra/newthing.dds'});
      expect(placement.unmatched, ['extra/newthing.dds']);
    });

    test('nothing matching anything is the wrong-target signal', () {
      // **Said before the write, not discovered after it.** Every file being new
      // to the target means this patch is almost certainly for a different mod,
      // and the snapshot is not a reason to find out the expensive way.
      final placement = resolvePatchPlacement(
        incoming: const {'otherchardiffuse.dds', 'otherchara.ib'},
        target: nested,
      );
      expect(placement.matchedNothing, isTrue);
      expect(placement.unmatched, hasLength(2));
    });

    test('one match is enough to stop being the wrong-target signal', () {
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyadiffuse.dds', 'brandnew.dds'},
        target: nested,
      );
      expect(placement.matchedNothing, isFalse);
      expect(placement.unmatched, ['brandnew.dds']);
    });

    test('an empty download is not the wrong-target signal either', () {
      // There is nothing to have failed to match.
      final placement =
          resolvePatchPlacement(incoming: const {}, target: nested);
      expect(placement.matchedNothing, isFalse);
      expect(placement.mapping, isEmpty);
    });
  });

  group('several candidates', () {
    /// One mod installed as two variant subfolders — an ordinary layout, and
    /// the one where the name alone cannot decide.
    const twoVariants = <String>{
      'sfw/charabodyadiffuse.dds',
      'sfw/chara.ini',
      'nsfw/charabodyadiffuse.dds',
      'nsfw/chara.ini',
    };

    test('the file is left unsettled and the candidates are offered', () {
      // Picking would be a guess about which variant the user actually runs,
      // and the guess is invisible once written. Same discipline the update
      // path already holds: a set of mappings, or a stop-and-ask, and no third
      // outcome where it picks something plausible.
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyadiffuse.dds'},
        target: twoVariants,
      );

      expect(placement.needsChoice, isTrue);
      expect(placement.mapping, isEmpty,
          reason: 'nothing is settled for a file whose destination is a guess');
      expect(placement.choices.single.incoming, 'charabodyadiffuse.dds');
      expect(
        placement.choices.single.candidates,
        ['nsfw/charabodyadiffuse.dds', 'sfw/charabodyadiffuse.dds'],
        reason: 'sorted, so what the user reads does not depend on the order '
            'the filesystem enumerated the folder in',
      );
    });

    test('there is no way to answer it and carry on', () {
      // Not an oversight. The only thing that produces this is a mod folder
      // holding two copies of its own files, and **no install path creates
      // that** — the import picker settles separate-or-combined before
      // anything is copied. So it is a folder assembled by hand outside the
      // flow, and a patch written blind into a folder that is already wrong
      // makes it worse. The caller refuses; nothing negotiates.
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyadiffuse.dds'},
        target: twoVariants,
      );
      expect(placement.needsChoice, isTrue);
      expect(placement.mapping, isEmpty);
    });

    test('the candidates are named, so the refusal can say where they are', () {
      // The refusal has to be explicable — "that folder keeps two copies of
      // these files" is only useful if it can point at them.
      final placement = resolvePatchPlacement(
        incoming: const {'charabodyadiffuse.dds', 'chara.ini'},
        target: {...twoVariants, 'charabodyadiffuse.dds'},
      );

      expect(placement.choices, hasLength(2),
          reason: 'both names appear more than once in this target');
      final texture = placement.choices
          .firstWhere((c) => c.incoming == 'charabodyadiffuse.dds');
      expect(texture.candidates, [
        'charabodyadiffuse.dds',
        'nsfw/charabodyadiffuse.dds',
        'sfw/charabodyadiffuse.dds',
      ]);
    });
  });

  test('every incoming file gets exactly one destination', () {
    // The invariant the copy depends on. Two incoming files landing on one
    // target path would have one silently overwrite the other, and a file with
    // no destination would be dropped.
    final placement = resolvePatchPlacement(
      incoming: const {
        'charabodyadiffuse.dds',
        'charabodya.ib',
        'brandnew.dds',
        'chara.ini',
      },
      target: nested,
    );

    expect(placement.mapping, hasLength(4));
    expect(placement.mapping.values.toSet(), hasLength(4));
    expect(placement.needsChoice, isFalse);
  });
}
