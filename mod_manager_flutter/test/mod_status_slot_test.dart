import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mod_status_slot.dart';

import 'support/localized_harness.dart';

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
}) =>
    ModOrigin(
      modId: modId,
      modIdConfidence:
          modId == null ? OriginConfidence.unknown : OriginConfidence.inferred,
      versionConfidence: versionConfidence,
      provenance: OriginProvenance.importedFolder,
      tracking: tracking,
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
}
