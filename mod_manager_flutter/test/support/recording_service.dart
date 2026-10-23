import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/services/api_service.dart';
import 'package:mod_manager_flutter/services/mod_manager_service.dart';
import 'package:mod_manager_flutter/services/origin_write.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';
import 'package:path/path.dart' as p;

import 'temp_library.dart';

/// [TempLibrary]'s real service over the same folders, which also records whose keys were dropped and can hold a
/// mod being turned on or refuse origin writes.
///
/// Mount it with [overrides] after [install]: the flows reach it through `modManagerServiceProvider`, and a switch
/// press through `ApiService`.
class RecordingService extends ModManagerService {
  RecordingService(this.temp)
      : super(
          temp.config,
          shaderFixes: ShaderFixesService(recordPath: p.join(temp.root.path, 'shader_fixes.json')),
          snapshots: temp.snapshots,
        );

  final TempLibrary temp;

  /// Every mod whose cached keys were dropped, in order.
  final List<String> keysDropped = [];

  /// While set, turning a mod on waits for it.
  Completer<void>? holdActivation;

  /// Whether a write to a mod's origin throws, as a sidecar on a read-only disk does.
  bool failOriginWrites = false;

  /// While set, a write to a mod's origin waits for it.
  Completer<void>? holdOriginWrites;

  /// Puts this in `ApiService` in place of the library's own service.
  void install() => ApiService.useLibraryForTests(temp.config, service: this);

  List<Override> get overrides => [
        modManagerServiceProvider.overrideWith((ref) async => this),
        snapshotServiceProvider.overrideWithValue(temp.snapshots),
      ];

  @override
  void invalidateKeybinds(String modId) {
    keysDropped.add(modId);
    super.invalidateKeybinds(modId);
  }

  @override
  Future<bool> activateMod(String modName) async {
    await holdActivation?.future;
    return super.activateMod(modName);
  }

  @override
  Future<OriginWriteResult> updateModOrigin(String modName, ModOrigin? Function(ModOrigin? current) update) async {
    if (failOriginWrites) throw StateError('origin write refused');
    await holdOriginWrites?.future;
    return super.updateModOrigin(modName, update);
  }
}
