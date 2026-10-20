import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/palette.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_status_slot.dart';
import 'package:mod_manager_flutter/screens/components/zenith_controls.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';
import 'support/origin_shorthand.dart';

ModInfo mod({ModOrigin? origin}) => ModInfo(
      id: 'Ellen Swimsuit',
      name: 'Ellen Swimsuit',
      characterId: 'ellen',
      isActive: false,
      origin: origin,
    );

ModOrigin origin({
  int? modId,
  OriginConfidence versionConfidence = OriginConfidence.unknown,
  OriginTracking tracking = OriginTracking.auto,
  bool patchShaped = false,
}) =>
    originFixture(
      modId: modId,
      modIdConfidence:
          modId == null ? OriginConfidence.unknown : OriginConfidence.inferred,
      versionConfidence: versionConfidence,
      provenance: OriginProvenance.importedFolder,
      tracking: tracking,
      ingest: patchShaped ? const ModIngest(patchShaped: true) : null,
    );

/// Every label the badge can show, to assert that exactly one is on screen.
const _labels = [
  'Newer file',
  'Maybe newer',
  'Which file?',
  'Base unknown',
  'Dated only',
  'Not tracked',
  'Local',
];

/// Asserts the badge reads [label] and no other state's label is on screen, or
/// that there is no badge at all when [label] is null.
void expectBadge(String? label) {
  for (final other in _labels) {
    expect(find.text(other), other == label ? findsOneWidget : findsNothing,
        reason: 'expected the badge to read ${label ?? 'nothing'}');
  }
  expect(find.byType(ZenithBadge), label == null ? findsNothing : findsOneWidget);
}

void main() {
  Future<void> pumpSlot(WidgetTester tester, ModOrigin? candidate, {VoidCallback? onTap}) async {
    await tester.pumpWidget(const SizedBox());
    await pumpLocalized(
      tester,
      Center(child: ModStatusSlot(mod: mod(origin: candidate), onTap: onTap ?? () {})),
    );
    expectBuilt(ModStatusSlot);
  }

  TonePair toneOf(WidgetTester tester) => tester.widget<ZenithBadge>(find.byType(ZenithBadge)).tone;

  testWidgets('a known mod with an unknown file asks which file', (tester) async {
    await pumpSlot(tester, origin(modId: 1));
    expectBadge('Which file?');
  });

  testWidgets('a patch with no base named asks for the base', (tester) async {
    await pumpSlot(
      tester,
      origin(modId: 222, versionConfidence: OriginConfidence.exact, patchShaped: true),
    );
    expectBadge('Base unknown');
  });

  testWidgets('untracked is a grey fact, not a question', (tester) async {
    // Most of a legacy library is untracked. Badging all of it loudly is how a
    // status badge stops being read at all.
    await pumpSlot(tester, null);
    expectBadge('Not tracked');
  });

  String tooltipOf(WidgetTester tester) => tester.widget<Tooltip>(find.byType(Tooltip)).message!;

  testWidgets('a version on record by date only is grey, not blue and not silent',
      (tester) async {
    // A mod waved through by the bulk "assume current" action must not render
    // exactly like one whose file the user picked. It is quiet because nothing
    // is wrong — settling for a date is a legitimate answer — but it is not
    // nothing either.
    await pumpSlot(
      tester,
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
    );
    expectBadge('Dated only');
    expect(tooltipOf(tester), 'Tracked by date only — no file recorded. Click to say which file you have.');
  });

  testWidgets('a worked-out file has no badge, like a confirmed one', (tester) async {
    // The user accepted it in the tracking screen, so it is their file.
    await pumpSlot(
      tester,
      origin(modId: 1, versionConfidence: OriginConfidence.inferred),
    );
    expectBadge(null);
  });

  testWidgets("a patch dated only does not make the base's worked-out file Dated only", (tester) async {
    // The base was worked out; the patch on top was marked current by date. The badge describes the base.
    await pumpSlot(
      tester,
      originFixture(
        modId: 1,
        modIdConfidence: OriginConfidence.inferred,
        fileId: 10,
        versionConfidence: OriginConfidence.inferred,
        patches: [
          const ModDownload(
            modId: 2,
            modIdConfidence: OriginConfidence.inferred,
            versionConfidence: OriginConfidence.assumedLatest,
          ),
        ],
      ),
    );
    expectBadge(null);
  });

  group('a pressable badge', () {
    Border? ring(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(ZenithBadge),
        matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.position == DecorationPosition.foreground),
      ));
      return (box.decoration as BoxDecoration).border as Border?;
    }

    testWidgets('shows a focus ring when Tab reaches it, and none otherwise', (tester) async {
      await pumpSlot(tester, origin(modId: 1));
      expect(ring(tester), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = ring(tester);
      expect(focused, isNotNull);
      expect(focused!.top.width, 2);

      // A pointer press is not keyboard use, so the ring goes.
      await tester.tap(find.byType(ZenithBadge));
      await tester.pumpAndSettle();
      expect(ring(tester), isNull);
    });
  });

  testWidgets('the asking states and the grey states differ in tone', (tester) async {
    await pumpSlot(tester, origin(modId: 1));
    final asking = toneOf(tester);

    await pumpSlot(tester, null);
    final untracked = toneOf(tester);

    await pumpSlot(
      tester,
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
    );
    final guessed = toneOf(tester);

    // The two quiet states share a tone and carry their meaning in the words.
    expect(guessed.background, untracked.background);
    expect(guessed.foreground, untracked.foreground);
    expect(asking.background, isNot(untracked.background));
  });

  testWidgets('a resolved mod renders nothing at all', (tester) async {
    await pumpSlot(tester, origin(modId: 1, versionConfidence: OriginConfidence.exact));
    expectBadge(null);
  });

  testWidgets('a mod the user declared their own reads Local, and opens nothing',
      (tester) async {
    var taps = 0;
    await pumpSlot(
      tester,
      origin(modId: 1, tracking: OriginTracking.off),
      onTap: () => taps++,
    );
    expectBadge('Local');

    await tester.tap(find.byType(ModStatusSlot));
    expect(taps, 0);
  });

  testWidgets('every other visible state is tappable', (tester) async {
    // The quiet ones too: neither is an error, but each is a case a user may
    // want to change, and the context menu should not be the only way in.
    for (final candidate in [
      origin(modId: 1),
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
      origin(modId: 222, versionConfidence: OriginConfidence.exact, patchShaped: true),
      null,
    ]) {
      var taps = 0;
      await pumpSlot(tester, candidate, onTap: () => taps++);
      await tester.tap(find.byType(ModStatusSlot));
      expect(taps, 1);
    }
  });

  testWidgets('every state is the same height', (tester) async {
    // So resolving a mod doesn't reflow the badges' row on the cover.
    await pumpSlot(tester, null);
    final height = tester.getSize(find.byType(ZenithBadge)).height;

    for (final candidate in [
      origin(modId: 1),
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
      origin(modId: 1, tracking: OriginTracking.off),
    ]) {
      await pumpSlot(tester, candidate);
      expect(tester.getSize(find.byType(ZenithBadge)).height, height);
    }
  });

  group('an update was found', () {
    /// Seeds the session results map, which is where an update verdict lives —
    /// it is not part of the origin block and never reaches the sidecar.
    Future<void> pumpWithCheck(
      WidgetTester tester,
      UpdateCheck? check, {
      ModOrigin? modOrigin,
      VoidCallback? onShowUpdate,
      VoidCallback? onTap,
    }) async {
      // Tear the whole tree down first. `ProviderScope` *updates* its overrides
      // rather than re-running them when it is re-pumped in place, so a second
      // call would silently keep the first call's state — and every assertion
      // after it would describe the previous case while looking like it
      // described the new one.
      await tester.pumpWidget(const SizedBox());
      await pumpLocalized(
        tester,
        Center(
          child: ModStatusSlot(
            mod: mod(origin: modOrigin),
            onTap: onTap ?? () {},
            onShowUpdate: onShowUpdate,
          ),
        ),
        overrides: [
          modUpdateChecksProvider.overrideWith(
            (ref) => check == null ? {} : {'Ellen Swimsuit': check},
          ),
        ],
      );
    }

    testWidgets('beats every origin state, including a fully resolved one',
        (tester) async {
      // The case a naive "is the origin slot empty?" short-circuit gets wrong:
      // a mod whose file is recorded at `exact` renders nothing from its origin
      // block, and is exactly the mod best placed to have a *confirmed* update.
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1, versionConfidence: OriginConfidence.exact),
      );
      expectBadge('Newer file');
    });

    testWidgets('replaces the origin states rather than stacking',
        (tester) async {
      for (final candidate in [
        null,
        origin(modId: 1),
        origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
      ]) {
        await pumpWithCheck(
          tester,
          const UpdateCheck(outcome: UpdateOutcome.possiblyOutdated),
          modOrigin: candidate,
        );
        expectBadge('Maybe newer');
      }
    });

    testWidgets('a mod the user declared their own still reads Local',
        (tester) async {
      // `checkForUpdate` cannot produce a verdict for one, so this is belt and
      // braces — but the promise attached to "not from GameBanana" is
      // permanence, and an update badge on such a card would break it.
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1, tracking: OriginTracking.off),
      );
      expectBadge('Local');
    });

    testWidgets('a clean verdict shows nothing new', (tester) async {
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.upToDate),
        modOrigin: origin(modId: 1),
      );
      // The *version* is unrecorded, which the check happens not to have
      // changed. The badge reports the origin state it always did.
      expectBadge('Which file?');
    });

    testWidgets('the guess and the confirmed finding say different things',
        (tester) async {
      String tooltip() =>
          tester.widget<Tooltip>(find.byType(Tooltip)).message!;

      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1),
      );
      final confirmed = tooltip();

      await pumpWithCheck(
        tester,
        const UpdateCheck(
          outcome: UpdateOutcome.possiblyOutdated,
          isGuess: true,
        ),
        modOrigin: origin(modId: 1),
      );
      expect(tooltip(), isNot(confirmed));
    });

    testWidgets('a "possibly" finding never reads as a confirmed one',
        (tester) async {
      // `isGuess` and `possiblyOutdated` are **not** the same condition: a mod
      // recorded at exact/exact whose author published a newer file under a
      // *different label* is possibly-outdated with `isGuess == false`. Keyed
      // on `isGuess`, the card would say "an update is published" while the
      // dialog for the same mod says "possibly outdated". The badge is the only
      // place that distinction can be read without opening anything.
      await pumpWithCheck(
        tester,
        // Confirmed evidence on both axes, softer verdict.
        const UpdateCheck(
          outcome: UpdateOutcome.possiblyOutdated,
          isGuess: false,
        ),
        modOrigin: origin(modId: 1, versionConfidence: OriginConfidence.exact),
      );
      expectBadge('Maybe newer');
    });

    testWidgets('the update badge opens the update dialog, not the resolve one',
        (tester) async {
      var resolves = 0;
      var updates = 0;
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1),
        onTap: () => resolves++,
        onShowUpdate: () => updates++,
      );
      await tester.tap(find.byType(ModStatusSlot));
      expect((updates, resolves), (1, 0));
    });

    testWidgets('and it falls back rather than being inert', (tester) async {
      // The drag-feedback copy of the card passes no update callback.
      var resolves = 0;
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1),
        onTap: () => resolves++,
      );
      await tester.tap(find.byType(ModStatusSlot));
      expect(resolves, 1);
    });

    testWidgets('and keeps the badge the same height', (tester) async {
      await pumpWithCheck(tester, null);
      final height = tester.getSize(find.byType(ZenithBadge)).height;

      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1),
      );
      expect(tester.getSize(find.byType(ZenithBadge)).height, height);
    });
  });
}
