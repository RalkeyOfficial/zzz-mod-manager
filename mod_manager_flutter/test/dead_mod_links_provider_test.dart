import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/library_override.dart';

/// The Folder missing rows follow the links folder on every scan, not only on one that changed the library: a drive
/// unplugged or plugged back in changes only the links.
void main() {
  late Directory links;
  late ProviderContainer container;

  setUp(() {
    links = Directory.systemTemp.createTempSync('zzz_dead_links_provider_');
    container = ProviderContainer(overrides: [
      libraryOf(const []),
      linksFolderProvider.overrideWithValue(links.path),
    ]);
  });

  tearDown(() {
    container.dispose();
    links.deleteSync(recursive: true);
  });

  Future<List<String>> missing() async => [for (final link in await container.read(deadModLinksProvider.future)) link.name];

  test('a rescan that finds the library unchanged reads the links again', () async {
    expect(await missing(), isEmpty);

    Link(p.join(links.path, 'Unplugged')).createSync('/media/drive/Unplugged');
    await container.read(libraryProvider.notifier).rescan();
    expect(await missing(), ['Unplugged']);

    Link(p.join(links.path, 'Unplugged')).deleteSync();
    await container.read(libraryProvider.notifier).rescan();
    expect(await missing(), isEmpty);
  });
}
