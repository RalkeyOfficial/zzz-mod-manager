import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/zzz_characters.dart';

/// Keeps the roster and the bundled artwork honest against each other.
///
/// Modelled on `l10n_keys_test.dart`, and for the same reason: this pairing
/// fails *silently* in both directions. A roster entry with no file renders a
/// grey silhouette wherever that character appears — no exception, because
/// every call site passes an `errorBuilder`. A file no entry claims is dead
/// weight in the bundle that nobody notices. Neither shows up in
/// `flutter analyze`, because the filenames are built from strings.
void main() {
  final directory = Directory('assets/characters');

  late Set<String> filesOnDisk;

  setUpAll(() {
    expect(directory.existsSync(), isTrue, reason: 'missing ${directory.path}');
    filesOnDisk = {
      for (final entity in directory.listSync())
        if (entity is File && entity.path.endsWith('.png'))
          entity.uri.pathSegments.last.replaceAll('.png', ''),
    };
  });

  test('the directory actually has artwork in it', () {
    // Guards the test itself: an empty or moved directory would otherwise make
    // the orphan check below pass vacuously.
    expect(filesOnDisk.length, greaterThan(50));
  });

  test('every character in the roster has a portrait', () {
    // `assetName`, not `id` — the roster's `asset:` override is exactly what a
    // hand-built path loses (`billy` lives in `billy_herinkton.png`).
    final missing = [
      for (final character in zzzCharactersData)
        if (!filesOnDisk.contains(character.assetName))
          '${character.id} -> ${character.assetName}.png',
    ]..sort();
    expect(missing, isEmpty,
        reason: 'in the roster, no file in assets/characters/');
  });

  test('every portrait is claimed by a character', () {
    final claimed = {for (final c in zzzCharactersData) c.assetName};
    final orphans = filesOnDisk.difference(claimed).toList()..sort();
    expect(orphans, isEmpty,
        reason: 'file in assets/characters/, nothing in the roster uses it');
  });
}
