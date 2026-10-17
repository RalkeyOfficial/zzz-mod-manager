import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'support/temp_library.dart';

/// The sidebar's "ZZMI connected" reads the disk, so it has to look again when Settings saves.
void main() {
  test('saving the same ZZMI folder looks at the disk again', () async {
    final library = await TempLibrary.create();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await ApiService.initialize(container: container);
    expect(await container.read(zzmiFoundProvider.future), isFalse);

    File(p.join(library.root.path, 'd3dx.ini')).writeAsStringSync('');
    await ApiService.updateConfig(modsPath: library.mods.path, zzmiPath: library.root.path);

    expect(await container.read(zzmiFoundProvider.future), isTrue);
  });
}
