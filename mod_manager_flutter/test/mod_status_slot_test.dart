import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_status_slot.dart';
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
  bool remoteMissing = false,
}) =>
    originFixture(
      modId: modId,
      modIdConfidence:
          modId == null ? OriginConfidence.unknown : OriginConfidence.inferred,
      versionConfidence: versionConfidence,
      provenance: OriginProvenance.importedFolder,
      tracking: tracking,
      remoteMissing: remoteMissing,
    );

void main() {
  testWidgets('the actionable state is the loud one', (tester) async {
    await pumpLocalized(
      tester,
      ModStatusSlot(mod: mod(origin: origin(modId: 1)), onTap: () {}),
    );
    expectBuilt(ModStatusSlot);
    expect(find.byIcon(Icons.priority_high), findsOneWidget);
  });

  testWidgets('untracked is a muted dot, not the amber mark', (tester) async {
    // Most of a legacy library is untracked. Badging all of it loudly is how a
    // status slot stops being read at all.
    await pumpLocalized(tester, ModStatusSlot(mod: mod(), onTap: () {}));
    expect(find.byIcon(Icons.priority_high), findsNothing);
    expect(find.byIcon(Icons.circle), findsOneWidget);
  });

  testWidgets('a recorded guess is a muted clock, not amber and not silent',
      (tester) async {
    // The gap this closes: a mod waved through by the bulk "assume current"
    // action used to render exactly like one whose file the user had picked, so
    // a library of seventeen could not be told apart without opening seventeen
    // dialogs. It is quiet rather than amber because nothing is wrong — settling
    // for a date is a legitimate answer — but it is not nothing either.
    await pumpLocalized(
      tester,
      ModStatusSlot(
        mod: mod(
          origin: origin(
            modId: 1,
            versionConfidence: OriginConfidence.assumedLatest,
          ),
        ),
        onTap: () {},
      ),
    );
    expectBuilt(ModStatusSlot);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.priority_high), findsNothing);
    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('the two quiet states differ by shape, not by colour',
      (tester) async {
    // Two muted colours at this size would be indistinguishable, and would stay
    // indistinguishable for anyone colourblind. So the dot and the clock share
    // one colour and carry the meaning in the glyph.
    Color colourOf(IconData icon) =>
        tester.widget<Icon>(find.byIcon(icon)).color!;

    await pumpLocalized(tester, ModStatusSlot(mod: mod(), onTap: () {}));
    final dot = colourOf(Icons.circle);

    await pumpLocalized(
      tester,
      ModStatusSlot(
        mod: mod(
          origin: origin(
            modId: 1,
            versionConfidence: OriginConfidence.assumedLatest,
          ),
        ),
        onTap: () {},
      ),
    );
    expect(colourOf(Icons.schedule), dot);
  });

  testWidgets('a gone source is a broken link, not amber and not silence',
      (tester) async {
    // Amber's whole offer is "click to set the version", which means reading a
    // page that is private, trashed or withheld. Silence was correct only while
    // nothing wrote the flag; the bulk resolution pass writes it now, so a mod
    // that quietly stopped being watched needed something to say why.
    await pumpLocalized(
      tester,
      ModStatusSlot(
        mod: mod(origin: origin(modId: 1, remoteMissing: true)),
        onTap: () {},
      ),
    );
    expectBuilt(ModStatusSlot);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.byIcon(Icons.priority_high), findsNothing);
  });

  testWidgets('a resolved mod renders nothing at all', (tester) async {
    await pumpLocalized(
      tester,
      ModStatusSlot(
        mod: mod(
          origin: origin(modId: 1, versionConfidence: OriginConfidence.exact),
        ),
        onTap: () {},
      ),
    );
    expect(find.byIcon(Icons.priority_high), findsNothing);
    expect(find.byIcon(Icons.circle), findsNothing);
    expect(find.byIcon(Icons.schedule), findsNothing);
  });

  testWidgets('a mod the user declared their own stays silent', (tester) async {
    await pumpLocalized(
      tester,
      ModStatusSlot(
        mod: mod(origin: origin(modId: 1, tracking: OriginTracking.off)),
        onTap: () {},
      ),
    );
    expect(find.byIcon(Icons.priority_high), findsNothing);
    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('every visible state is tappable', (tester) async {
    // The quiet ones too: neither is an error, but each is a case a user may
    // want to change, and the context menu should not be the only way in.
    for (final candidate in [
      origin(modId: 1),
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
      null,
    ]) {
      var taps = 0;
      await pumpLocalized(
        tester,
        ModStatusSlot(mod: mod(origin: candidate), onTap: () => taps++),
      );
      await tester.tap(find.byType(ModStatusSlot));
      expect(taps, 1);
    }
  });

  testWidgets('every state occupies the same footprint', (tester) async {
    // So resolving a mod doesn't reflow the artwork underneath the slot — and
    // the clock is a larger glyph than the dot, which is exactly the kind of
    // thing that would have shifted it.
    Size sizeOf(ModOrigin? candidate) => tester.getSize(find.byType(InkWell));

    await pumpLocalized(
      tester,
      Center(child: ModStatusSlot(mod: mod(), onTap: () {})),
    );
    final muted = sizeOf(null);

    for (final candidate in [
      origin(modId: 1),
      origin(modId: 1, versionConfidence: OriginConfidence.assumedLatest),
    ]) {
      await pumpLocalized(
        tester,
        Center(child: ModStatusSlot(mod: mod(origin: candidate), onTap: () {})),
      );
      expect(sizeOf(candidate), muted);
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
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
    });

    testWidgets('replaces the amber and the quiet marks rather than stacking',
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
        expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
        expect(find.byIcon(Icons.priority_high), findsNothing);
        expect(find.byIcon(Icons.schedule), findsNothing);
        expect(find.byIcon(Icons.circle), findsNothing);
      }
    });

    testWidgets('stays silent for a mod the user declared their own',
        (tester) async {
      // `checkForUpdate` cannot produce a verdict for one, so this is belt and
      // braces — but the promise attached to "not from GameBanana" is
      // permanence, and a badge appearing on such a card would break it.
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1, tracking: OriginTracking.off),
      );
      expect(find.byIcon(Icons.arrow_circle_up), findsNothing);
    });

    testWidgets('a clean verdict shows nothing new', (tester) async {
      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.upToDate),
        modOrigin: origin(modId: 1),
      );
      // Still amber: the *version* is unrecorded, which the check happens not
      // to have changed. The slot reports the origin state it always did.
      expect(find.byIcon(Icons.arrow_circle_up), findsNothing);
      expect(find.byIcon(Icons.priority_high), findsOneWidget);
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
      // `isGuess` and `possiblyOutdated` are **not** the same condition, and
      // keying the wording on the first overclaimed: a mod recorded at
      // exact/exact whose author published a newer file under a *different
      // label* is possibly-outdated with `isGuess == false`, and the card then
      // asserted "an update is published" while the dialog for the same mod
      // said "possibly outdated". The badge is the only place that distinction
      // can be read without opening anything.
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
        // Confirmed evidence on both axes, softer verdict.
        const UpdateCheck(
          outcome: UpdateOutcome.possiblyOutdated,
          isGuess: false,
        ),
        modOrigin: origin(modId: 1),
      );
      expect(tooltip(), isNot(confirmed));
    });

    testWidgets('the blue state opens the update dialog, not the resolve one',
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

    testWidgets('and keeps the slot the same size', (tester) async {
      await pumpWithCheck(tester, null);
      final muted = tester.getSize(find.byType(InkWell));

      await pumpWithCheck(
        tester,
        const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
        modOrigin: origin(modId: 1),
      );
      expect(tester.getSize(find.byType(InkWell)), muted);
    });
  });
}
