import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/utils/mod_group_diff.dart';

/// The guard that decides whether a rescan is allowed to refresh the mods grid.
///
/// It had no tests while it was a private method on a 2000-line `State`, and it
/// shipped a silent bug: `ModInfo.origin` was never added to its field list, so
/// a mod resolved through the resolve dialog was written to disk correctly,
/// re-read correctly, judged "unchanged", and kept its amber "needs attention"
/// mark on screen until the tab was switched away and back.
void main() {
  ModInfo mod(
    String name, {
    ModOrigin? origin,
    bool isActive = false,
    List<KeybindInfo>? keybinds,
  }) =>
      ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: isActive,
        origin: origin,
        keybinds: keybinds,
      );

  /// A freshly built binding, as a scan would produce it — never the same
  /// instance twice, which is the condition the guard has to survive.
  KeybindInfo bind(String section, String key) =>
      KeybindInfo(section: section, keys: {'key': key});

  List<CharacterInfo> groups(List<ModInfo> mods) => [
        CharacterInfo(id: 'all', name: 'All', skins: mods),
      ];

  const untracked = ModOrigin(
    source: 'gamebanana',
    modId: 555,
    modIdConfidence: OriginConfidence.inferred,
    provenance: OriginProvenance.importedFolder,
  );

  test('a first scan always counts as a change', () {
    expect(modGroupsChanged(null, groups([mod('A')])), isTrue);
  });

  test('an identical rescan does not', () {
    // The whole reason the guard exists: a scan runs after every toggle and
    // rename, and rebuilding the grid each time is what it prevents.
    expect(
      modGroupsChanged(groups([mod('A'), mod('B')]), groups([mod('A'), mod('B')])),
      isFalse,
    );
  });

  group('keybinds', () {
    // The second instance of the guard's one failure mode. Keybinds were left
    // out of the field list on the grounds that comparing them would fire on
    // every scan — true while `KeybindInfo` had no value equality — with the
    // note that keybind edits refreshed "through their own dialog's callback".
    // That callback is `loadMods`, which runs this guard, so the edit was
    // written, re-parsed and then thrown away here.
    test('editing a hotkey counts as a change', () {
      expect(
        modGroupsChanged(
          groups([mod('A', keybinds: [bind('KeySwap', 'VK_F7')])]),
          groups([mod('A', keybinds: [bind('KeySwap', 'VK_F9')])]),
        ),
        isTrue,
        reason: 'the grid would keep showing the old hotkey',
      );
    });

    test('an unchanged rescan still does not, despite fresh instances', () {
      // The half that made the omission look necessary: every scan re-parses
      // the `.ini` into new objects. Comparing them by identity reported a
      // change every time, which would turn the guard off entirely.
      expect(
        modGroupsChanged(
          groups([
            mod('A', keybinds: [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')])
          ]),
          groups([
            mod('A', keybinds: [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')])
          ]),
        ),
        isFalse,
        reason: 'the guard fires on every scan and stops guarding anything',
      );
    });

    test('gaining or losing bindings counts', () {
      final one = [bind('KeySwap', 'VK_F7')];
      final two = [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')];

      expect(modGroupsChanged(groups([mod('A', keybinds: one)]),
          groups([mod('A', keybinds: two)])), isTrue);
      expect(modGroupsChanged(groups([mod('A', keybinds: two)]),
          groups([mod('A', keybinds: one)])), isTrue);
    });

    test('a mod that never had any is not mistaken for one that lost them', () {
      // `null` (never parsed a binding) and `[]` (parsed, found none) are
      // different values, and both are stable across scans — what would be a
      // bug is either of them flickering into the other.
      expect(modGroupsChanged(groups([mod('A')]), groups([mod('A')])), isFalse);
      expect(
        modGroupsChanged(
            groups([mod('A')]), groups([mod('A', keybinds: const [])])),
        isTrue,
      );
    });
  });

  test('resolving a mod counts as a change', () {
    // The regression. Everything a user sees is identical except the origin
    // block, which is exactly what the status slot renders.
    final before = groups([mod('Ellen Swimsuit', origin: untracked)]);
    final after = groups([
      mod(
        'Ellen Swimsuit',
        origin: untracked.copyWith(
          modIdConfidence: OriginConfidence.user,
          fileId: 900,
          version: '2.0',
          versionConfidence: OriginConfidence.user,
        ),
      ),
    ]);

    expect(modGroupsChanged(before, after), isTrue);
  });

  test('every axis the status slot reads is caught on its own', () {
    // Each of these flips the badge by itself, so each has to be visible to the
    // guard by itself.
    final variants = <String, ModOrigin>{
      'gained an identity': untracked.copyWith(modId: 777),
      'gained a version': untracked.copyWith(
        versionConfidence: OriginConfidence.assumedLatest,
      ),
      'was declared local': untracked.copyWith(tracking: OriginTracking.off),
      'went missing upstream': untracked.copyWith(remoteMissing: true),
    };

    for (final entry in variants.entries) {
      expect(
        modGroupsChanged(
          groups([mod('A', origin: untracked)]),
          groups([mod('A', origin: entry.value)]),
        ),
        isTrue,
        reason: 'a mod that ${entry.key} must refresh the grid',
      );
    }
  });

  test('gaining or losing a block entirely counts', () {
    expect(
      modGroupsChanged(groups([mod('A')]), groups([mod('A', origin: untracked)])),
      isTrue,
    );
    expect(
      modGroupsChanged(groups([mod('A', origin: untracked)]), groups([mod('A')])),
      isTrue,
    );
  });

  test('the ordinary changes still register', () {
    expect(
      modGroupsChanged(groups([mod('A')]), groups([mod('A', isActive: true)])),
      isTrue,
    );
    expect(modGroupsChanged(groups([mod('A')]), groups([mod('B')])), isTrue);
    expect(modGroupsChanged(groups([mod('A')]), groups([])), isTrue);
    expect(modGroupsChanged(groups([mod('A')]), []), isTrue);
  });

  group('ModOrigin value equality', () {
    test('two blocks built the same way are equal', () {
      // What makes the guard's `origin != origin` comparison meaningful at all —
      // each scan builds fresh instances off disk, so identity comparison would
      // report a change on every single scan and switch the guard off.
      expect(
        const ModOrigin(
          provenance: OriginProvenance.downloaded,
          modId: 1,
          ingest: ModIngest(folders: ['A', 'B']),
          archiveMd5: 'abc',
        ),
        const ModOrigin(
          provenance: OriginProvenance.downloaded,
          modId: 1,
          ingest: ModIngest(folders: ['A', 'B']),
          archiveMd5: 'abc',
        ),
      );
    });

    test('equal blocks hash the same', () {
      const a = ModOrigin(
        provenance: OriginProvenance.downloaded,
        ingest: ModIngest(folders: ['A']),
      );
      const b = ModOrigin(
        provenance: OriginProvenance.downloaded,
        ingest: ModIngest(folders: ['A']),
      );
      expect(a.hashCode, b.hashCode);
    });

    test('a difference in any field breaks equality', () {
      const base = ModOrigin(provenance: OriginProvenance.downloaded);
      final variants = <ModOrigin>[
        base.copyWith(source: 'gamebanana'),
        base.copyWith(modId: 1),
        base.copyWith(modIdConfidence: OriginConfidence.user),
        base.copyWith(fileId: 2),
        base.copyWith(version: '1'),
        base.copyWith(versionLabel: 'white hair ver'),
        base.copyWith(versionConfidence: OriginConfidence.user),
        base.copyWith(provenance: OriginProvenance.importedFolder),
        base.copyWith(ingest: const ModIngest(folders: ['A'])),
        base.copyWith(installedAt: DateTime.utc(2026)),
        base.copyWith(installedAtIsProxy: true),
        base.copyWith(baselineRemoteDate: DateTime.utc(2026)),
        base.copyWith(archiveMd5: 'abc'),
        base.copyWith(tracking: OriginTracking.off),
        base.copyWith(remoteMissing: true),
      ];
      for (final variant in variants) {
        expect(variant, isNot(base));
      }
      // One per field, so a field added to the model without being added to
      // `==` shows up here as a count mismatch rather than as a silent hole.
      expect(variants, hasLength(15));
    });

    test('ingest is compared by value, not by identity', () {
      const withFolders = ModOrigin(
        provenance: OriginProvenance.downloaded,
        ingest: ModIngest(folders: ['A']),
      );
      expect(
        withFolders,
        isNot(withFolders.copyWith(ingest: const ModIngest(folders: ['B']))),
      );
      expect(
        const ModIngest(folders: ['A'], siblingGroup: 'g'),
        const ModIngest(folders: ['A'], siblingGroup: 'g'),
      );
    });
  });
}
