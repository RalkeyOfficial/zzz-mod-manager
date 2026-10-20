import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/origin_shorthand.dart';

/// The "needs attention" filter, at the provider level.
///
/// A status dot is spatial; this is the part that makes the state
/// *enumerable*, which is the whole reason it exists — and it is also the part
/// that can silently empty the grid if it disagrees with the badge.
void main() {
  ModInfo mod(String name, {ModOrigin? origin, String characterId = 'ellen'}) => ModInfo(
        id: name,
        name: name,
        characterId: characterId,
        isActive: false,
        origin: origin,
      );

  ModOrigin origin({
    int? modId,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    OriginTracking tracking = OriginTracking.auto,
  }) =>
      originFixture(
        modId: modId,
        versionConfidence: versionConfidence,
        provenance: OriginProvenance.importedFolder,
        tracking: tracking,
      );

  final library = [
    mod('Untracked'),
    mod('Version unknown', origin: origin(modId: 1)),
    mod('Fully known',
        origin: origin(modId: 2, versionConfidence: OriginConfidence.exact)),
    mod('My own', origin: origin(modId: 3, tracking: OriginTracking.off)),
  ];

  ProviderContainer containerWith(List<ModInfo> mods) {
    final container = ProviderContainer(overrides: [libraryOf(mods)]);
    addTearDown(container.dispose);
    return container;
  }

  test('off, the filter changes nothing', () {
    final container = containerWith(library);
    expect(container.read(modGridFilterProvider), ModGridFilter.all);
    expect(container.read(visibleModsProvider), hasLength(4));
  });

  test('on, it keeps both non-empty states of the slot', () {
    // Untracked mods are in deliberately: the resolve dialog acts on them
    // perfectly well, and excluding them would leave a legacy library with an
    // empty filter and no way to enumerate what it exists to enumerate.
    final container = containerWith(library);
    container.read(modGridFilterProvider.notifier).state = ModGridFilter.needsAttention;

    expect(
      container.read(visibleModsProvider).map((m) => m.name),
      ['Untracked', 'Version unknown'],
    );
  });

  test('the count matches what the filter would show', () {
    final container = containerWith(library);
    expect(container.read(modsNeedingAttentionCountProvider), 2);

    container.read(modGridFilterProvider.notifier).state = ModGridFilter.needsAttention;
    expect(
      container.read(visibleModsProvider),
      hasLength(container.read(modsNeedingAttentionCountProvider)),
    );
  });

  test('the count and the filter cover the character on screen only', () {
    // Both describe what pressing the chip leaves on screen, so another
    // character's mods are in neither.
    final container = containerWith([
      ...library,
      mod('Miyabi untracked', characterId: 'miyabi'),
    ]);
    container.read(selectedCharacterIdProvider.notifier).state = 'ellen';
    container.read(modGridFilterProvider.notifier).state = ModGridFilter.needsAttention;

    expect(container.read(modsNeedingAttentionCountProvider), 2);
    expect(
      container.read(visibleModsProvider).map((m) => m.name),
      isNot(contains('Miyabi untracked')),
    );
  });
}
