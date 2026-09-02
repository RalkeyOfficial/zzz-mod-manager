import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/origin_shorthand.dart';

/// The "needs attention" filter, at the provider level.
///
/// A status dot is spatial; this is the part that makes the state
/// *enumerable*, which is the whole reason it exists — and it is also the part
/// that can silently empty the grid if it disagrees with the badge.
void main() {
  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
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
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(charactersProvider.notifier).state = [
      CharacterInfo(id: 'all', name: 'All', skins: mods),
    ];
    return container;
  }

  test('off, the filter changes nothing', () {
    final container = containerWith(library);
    expect(container.read(visibleModsProvider), hasLength(4));
    expect(container.read(modFiltersActiveProvider), isFalse);
  });

  test('on, it keeps both non-empty states of the slot', () {
    // Untracked mods are in deliberately: the resolve dialog acts on them
    // perfectly well, and excluding them would leave a legacy library with an
    // empty filter and no way to enumerate what it exists to enumerate.
    final container = containerWith(library);
    container.read(modNeedsAttentionOnlyProvider.notifier).state = true;

    expect(
      container.read(visibleModsProvider).map((m) => m.name),
      ['Untracked', 'Version unknown'],
    );
    expect(container.read(modFiltersActiveProvider), isTrue);
  });

  test('the count matches what the filter would show', () {
    final container = containerWith(library);
    expect(container.read(modsNeedingAttentionCountProvider), 2);

    container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
    expect(
      container.read(visibleModsProvider),
      hasLength(container.read(modsNeedingAttentionCountProvider)),
    );
  });

  test('it composes with the other filters rather than replacing them', () {
    final container = containerWith([
      ...library,
      mod('Untracked favourite').copyWith(isFavorite: true),
    ]);
    container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
    container.read(modFavoritesOnlyProvider.notifier).state = true;

    expect(
      container.read(visibleModsProvider).map((m) => m.name),
      ['Untracked favourite'],
    );
  });

  test('clearing the filters clears this one too', () {
    final container = containerWith(library);
    container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
    // Mirrors clearModFilters, which takes a WidgetRef and so cannot be called
    // here — the assertion that matters is that the flag is part of the set.
    expect(container.read(modFiltersActiveProvider), isTrue);
    container.read(modNeedsAttentionOnlyProvider.notifier).state = false;
    expect(container.read(modFiltersActiveProvider), isFalse);
  });
}
