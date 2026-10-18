@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

/// How Settings reads the folder chosen as the Wine prefix, checked on real folders.
void main() {
  late Directory prefix;

  setUp(() {
    prefix = Directory.systemTemp.createTempSync('zzz_prefix_');
    addTearDown(() => prefix.deleteSync(recursive: true));
  });

  Future<WinePrefixLayout> layoutOf(String folder) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(winePrefixProvider.notifier).state = folder;
    // Listened to so the auto-disposed provider stays alive until its answer arrives.
    container.listen(winePrefixLayoutProvider, (_, _) {});
    return container.read(winePrefixLayoutProvider.future);
  }

  test('drive_c only under a real pfx folder is a Proton prefix folder, as Steam makes it', () async {
    Directory(p.join(prefix.path, 'pfx', 'drive_c')).createSync(recursive: true);
    expect(await layoutOf(prefix.path), WinePrefixLayout.protonOnly);
  });

  test('drive_c with a pfx link back to the folder, as umu makes it, works for every runner', () async {
    Directory(p.join(prefix.path, 'drive_c')).createSync();
    Link(p.join(prefix.path, 'pfx')).createSync('.');
    expect(await layoutOf(prefix.path), WinePrefixLayout.compatData);
  });

  test('drive_c and no pfx is a plain prefix', () async {
    Directory(p.join(prefix.path, 'drive_c')).createSync();
    expect(await layoutOf(prefix.path), WinePrefixLayout.plain);
  });

  test('a folder without drive_c is not a prefix', () async {
    expect(await layoutOf(prefix.path), WinePrefixLayout.missing);
  });

  test('no prefix chosen is the runner default', () async {
    expect(await layoutOf(''), WinePrefixLayout.unset);
  });
}
