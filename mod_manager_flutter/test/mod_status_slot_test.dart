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

  testWidgets('both visible states are tappable', (tester) async {
    // The untracked one too: it is not an error, but it is the case a user may
    // want to fix, and the context menu should not be the only way in.
    for (final candidate in [origin(modId: 1), null]) {
      var taps = 0;
      await pumpLocalized(
        tester,
        ModStatusSlot(mod: mod(origin: candidate), onTap: () => taps++),
      );
      await tester.tap(find.byType(ModStatusSlot));
      expect(taps, 1);
    }
  });

  testWidgets('both states occupy the same footprint', (tester) async {
    // So resolving a mod doesn't reflow the artwork underneath the slot.
    await pumpLocalized(
      tester,
      Center(child: ModStatusSlot(mod: mod(), onTap: () {})),
    );
    final muted = tester.getSize(find.byType(InkWell));

    await pumpLocalized(
      tester,
      Center(
        child: ModStatusSlot(mod: mod(origin: origin(modId: 1)), onTap: () {}),
      ),
    );
    expect(tester.getSize(find.byType(InkWell)), muted);
  });
}
