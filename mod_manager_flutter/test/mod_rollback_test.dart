import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/services/backup/snapshot_service.dart';
import 'package:mod_manager_flutter/services/mod_rollback.dart';
import 'package:mod_manager_flutter/services/update_apply/update_applier.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/library_override.dart';
import 'support/recording_service.dart';
import 'support/temp_library.dart';

/// The library's service with no library folder set.
class _NoLibrary extends RecordingService {
  _NoLibrary(super.temp);

  @override
  String? get modsPath => null;
}

/// History's Restore without its question and cards (`writeSnapshotBack`).
void main() {
  test('with no library folder set, a restore writes nothing and reads nothing again', () async {
    final temp = await TempLibrary.create(prefix: 'zzz_mod_rollback_');
    final service = _NoLibrary(temp);
    final mod = ModInfo(id: 'Ellen', name: 'Ellen', characterId: 'ellen', isActive: false);
    final container = ProviderContainer(overrides: [
      ...service.overrides,
      libraryOf([mod]),
    ]);
    addTearDown(container.dispose);
    final snapshot = ModSnapshot(
      modName: 'Ellen',
      modUid: 'u1',
      id: 's1',
      takenAt: DateTime.utc(2026, 8, 12),
      sizeBytes: 1,
      directory: Directory('/nonexistent/s1'),
    );

    final result = await writeSnapshotBack(container, mod: mod, snapshot: snapshot);

    expect(result.failure, UpdateApplyFailure.modMissing);
    expect(container.read(libraryScansProvider), 0, reason: 'no library to read again');
    expect(container.read(modWritesStartedProvider), isEmpty, reason: 'nothing was marked as being written');
    expect(service.keysDropped, isEmpty);
  });
}
