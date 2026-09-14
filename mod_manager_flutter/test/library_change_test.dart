import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

import 'support/origin_shorthand.dart';

/// **What counts as the library having changed.**
///
/// `LibraryNotifier.rescan` keeps the list it already has when a scan comes back
/// equal to it, which is what stops the grid rebuilding after every toggle and
/// rename. The comparison is `listEquals` over [ModInfo]'s own value equality,
/// so everything below is about that equality being exhaustive: while it was a
/// hand-written field list it shipped the same silent bug twice — `origin`, then
/// `keybinds` — each time leaving a card rendering yesterday's answer until the
/// tab was switched away and back, with nothing thrown.
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

  /// The guard as `LibraryNotifier.rescan` applies it: a scan that comes back
  /// equal to the library already in hand is not a change, and a first scan
  /// always is one.
  bool libraryChanged(List<ModInfo>? previous, List<ModInfo> next) =>
      previous == null || !listEquals(previous, next);

  final untracked = originFixture(
    source: 'gamebanana',
    modId: 555,
    modIdConfidence: OriginConfidence.inferred,
    provenance: OriginProvenance.importedFolder,
  );

  test('a first scan always counts as a change', () {
    expect(libraryChanged(null, [mod('A')]), isTrue);
  });

  test('an identical rescan does not', () {
    // The whole reason the guard exists: a scan runs after every toggle and
    // rename, and rebuilding the grid each time is what it prevents.
    expect(
      libraryChanged([mod('A'), mod('B')], [mod('A'), mod('B')]),
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
        libraryChanged(
          [mod('A', keybinds: [bind('KeySwap', 'VK_F7')])],
          [mod('A', keybinds: [bind('KeySwap', 'VK_F9')])],
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
        libraryChanged(
          [
            mod('A', keybinds: [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')])
          ],
          [
            mod('A', keybinds: [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')])
          ],
        ),
        isFalse,
        reason: 'the guard fires on every scan and stops guarding anything',
      );
    });

    test('gaining or losing bindings counts', () {
      final one = [bind('KeySwap', 'VK_F7')];
      final two = [bind('KeySwap', 'VK_F7'), bind('KeyUp', 'VK_UP')];

      expect(libraryChanged([mod('A', keybinds: one)],
          [mod('A', keybinds: two)]), isTrue);
      expect(libraryChanged([mod('A', keybinds: two)],
          [mod('A', keybinds: one)]), isTrue);
    });

    test('a mod that never had any is not mistaken for one that lost them', () {
      // `null` (never parsed a binding) and `[]` (parsed, found none) are
      // different values, and both are stable across scans — what would be a
      // bug is either of them flickering into the other.
      expect(libraryChanged([mod('A')], [mod('A')]), isFalse);
      expect(
        libraryChanged([mod('A')], [mod('A', keybinds: const [])]),
        isTrue,
      );
    });
  });

  test('resolving a mod counts as a change', () {
    // The regression. Everything a user sees is identical except the origin
    // block, which is exactly what the status slot renders.
    final before = [mod('Ellen Swimsuit', origin: untracked)];
    final after = [
      mod(
        'Ellen Swimsuit',
        origin: untracked.copyBase(
          modIdConfidence: OriginConfidence.user,
          fileId: 900,
          version: '2.0',
          versionConfidence: OriginConfidence.user,
        ),
      ),
    ];

    expect(libraryChanged(before, after), isTrue);
  });

  test('every axis the status slot reads is caught on its own', () {
    // Each of these flips the badge by itself, so each has to be visible to the
    // guard by itself.
    final variants = <String, ModOrigin>{
      'gained an identity': untracked.copyBase(modId: 777),
      'gained a version': untracked.copyBase(
        versionConfidence: OriginConfidence.assumedLatest,
      ),
      'was declared local': untracked.copyWith(tracking: OriginTracking.off),
      'went missing upstream': untracked.copyBase(remoteMissing: true),
      // The stack itself is an axis now: a folder that gained a patch reads
      // differently, and the guard compares the whole block.
      'gained a patch': untracked.copyWith(
        downloads: [untracked.base!, patchFixture()],
      ),
    };

    for (final entry in variants.entries) {
      expect(
        libraryChanged(
          [mod('A', origin: untracked)],
          [mod('A', origin: entry.value)],
        ),
        isTrue,
        reason: 'a mod that ${entry.key} must refresh the grid',
      );
    }
  });

  test('gaining or losing a block entirely counts', () {
    expect(
      libraryChanged([mod('A')], [mod('A', origin: untracked)]),
      isTrue,
    );
    expect(
      libraryChanged([mod('A', origin: untracked)], [mod('A')]),
      isTrue,
    );
  });

  test('the ordinary changes still register', () {
    expect(
      libraryChanged([mod('A')], [mod('A', isActive: true)]),
      isTrue,
    );
    expect(libraryChanged([mod('A')], [mod('B')]), isTrue);
    expect(libraryChanged([mod('A')], []), isTrue);
    expect(libraryChanged([mod('A'), mod('B')], [mod('A')]), isTrue);
  });

  group('ModInfo value equality', () {
    // What replaced the hand-written field list. The list missed `origin` and
    // then `keybinds`, each time leaving a surface showing stale data with
    // nothing thrown; the guard now asks the model instead.
    ModInfo full({
      String id = 'A',
      String name = 'A',
      String characterId = 'ellen',
      bool isActive = false,
      String? imagePath = '/img/a.png',
      String? description = 'notes',
      List<String> tags = const ['x'],
      List<String> images = const ['/img/a.png'],
      bool isFavorite = false,
      List<KeybindInfo>? keybinds,
      ModOrigin? origin,
      String? uid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
    }) =>
        ModInfo(
          id: id,
          name: name,
          characterId: characterId,
          isActive: isActive,
          imagePath: imagePath,
          description: description,
          tags: tags,
          images: images,
          isFavorite: isFavorite,
          keybinds: keybinds ?? [bind('KeySwap', 'VK_F7')],
          origin: origin ?? untracked,
          uid: uid,
        );

    test('two mods built the same way are equal, and hash the same', () {
      expect(full(), full());
      expect(full().hashCode, full().hashCode);
    });

    test('a difference in any field breaks equality', () {
      final cases = <String, ModInfo>{
        'id': full(id: 'B'),
        'name': full(name: 'B'),
        'characterId': full(characterId: 'miyabi'),
        'isActive': full(isActive: true),
        'imagePath': full(imagePath: '/img/b.png'),
        'description': full(description: 'other'),
        'tags': full(tags: const ['y']),
        'images': full(images: const ['/img/b.png']),
        'isFavorite': full(isFavorite: true),
        'keybinds': full(keybinds: [bind('KeySwap', 'VK_F9')]),
        'origin': full(
          origin: originFixture(
            source: 'gamebanana',
            modId: 9,
            provenance: OriginProvenance.importedFolder,
          ),
        ),
        // A mod that has just been given an identity is a changed mod: the
        // "Restore a previous version…" entry is drawn from it, so a grid built
        // before the uid landed would go on hiding it.
        'uid': full(uid: null),
      };
      for (final entry in cases.entries) {
        expect(full(), isNot(entry.value), reason: '${entry.key} was ignored');
        expect(libraryChanged([full()], [entry.value]), isTrue,
            reason: entry.key);
      }
    });

    test('every constructor parameter is covered by one of those cases', () {
      // The assertion that makes this list self-maintaining rather than a
      // second hand-written one: adding a field to `ModInfo` without adding a
      // case above fails here.
      const compared = {
        'id', 'name', 'characterId', 'isActive', 'imagePath', 'description',
        'tags', 'images', 'isFavorite', 'keybinds', 'origin', 'uid',
      };
      final source = File('lib/models/character_info.dart').readAsStringSync();
      final body = source.substring(source.indexOf('class ModInfo'));
      final ctor = body.substring(
          body.indexOf('ModInfo({'), body.indexOf('ModInfo copyWith('));
      final fields = RegExp(r'this\.(\w+)')
          .allMatches(ctor)
          .map((m) => m.group(1)!)
          .toSet();

      expect(fields.difference(compared), isEmpty,
          reason: 'ModInfo gained a field with no equality case above');
      expect(compared.difference(fields), isEmpty,
          reason: 'a case above names a field ModInfo no longer has');
    });

    test('null and empty lists are different values', () {
      expect(full(keybinds: const []), isNot(full(keybinds: null)));
    });
  });

  group('ModOrigin value equality', () {
    test('two blocks built the same way are equal', () {
      // What makes the guard's `origin != origin` comparison meaningful at all —
      // each scan builds fresh instances off disk, so identity comparison would
      // report a change on every single scan and switch the guard off.
      expect(
        originFixture(
          provenance: OriginProvenance.downloaded,
          modId: 1,
          ingest: ModIngest(folders: ['A', 'B']),
          archiveMd5: 'abc',
        ),
        originFixture(
          provenance: OriginProvenance.downloaded,
          modId: 1,
          ingest: ModIngest(folders: ['A', 'B']),
          archiveMd5: 'abc',
        ),
      );
    });

    test('equal blocks hash the same', () {
      final a = originFixture(
        provenance: OriginProvenance.downloaded,
        ingest: const ModIngest(folders: ['A']),
      );
      final b = originFixture(
        provenance: OriginProvenance.downloaded,
        ingest: const ModIngest(folders: ['A']),
      );
      expect(a.hashCode, b.hashCode);
    });

    test('a difference in any field breaks equality', () {
      final base = originFixture(
        source: null,
        provenance: OriginProvenance.downloaded,
      );
      final variants = <ModOrigin>[
        // The folder's own five.
        base.copyWith(source: 'gamebanana'),
        base.copyWith(provenance: OriginProvenance.importedFolder),
        base.copyWith(ingest: const ModIngest(folders: ['A'])),
        base.copyWith(installedAt: DateTime.utc(2026)),
        base.copyWith(installedAtIsProxy: true),
        base.copyWith(tracking: OriginTracking.off),
        // The stack: a layer added, and each of a layer's own fields.
        base.copyWith(downloads: [base.base!, patchFixture()]),
        base.copyBase(modId: 1),
        base.copyBase(modIdConfidence: OriginConfidence.user),
        base.copyBase(fileId: 2),
        base.copyBase(version: '1'),
        base.copyBase(versionLabel: 'white hair ver'),
        base.copyBase(versionConfidence: OriginConfidence.user),
        base.copyBase(baselineRemoteDate: DateTime.utc(2026)),
        base.copyBase(archiveMd5: 'abc'),
        base.copyBase(remoteMissing: true),
        base.copyBase(updatesDismissedUntil: DateTime.utc(2026)),
        base.copyBase(files: const [InstalledFile(path: 'a.ini')]),
      ];
      for (final variant in variants) {
        expect(variant, isNot(base));
      }
      // One per field across both halves, so a field added to either model
      // without being added to `==` shows up here as a count mismatch rather
      // than as a silent hole.
      expect(variants, hasLength(18));
    });

    test('ingest is compared by value, not by identity', () {
      final withFolders = originFixture(
        provenance: OriginProvenance.downloaded,
        ingest: const ModIngest(folders: ['A']),
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
