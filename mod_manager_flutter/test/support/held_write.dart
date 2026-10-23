import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

/// A mod folder held as being written, the way an update or a restore holds one: through `whileWritingMod`, until
/// [release].
///
/// Never set `modWritesInProgressProvider` by hand to fake this. `whileWritingMod` writes that set from its own
/// counts, so the first wrapped write anywhere in the flow under test, on any mod, replaces the faked set and the
/// test goes on passing without the folder being held.
class HeldWrite {
  HeldWrite._(this._done, this._write);

  final Completer<void> _done;
  final Future<void> _write;

  /// Ends the write, and returns once `whileWritingMod` has let go of the folder.
  Future<void> release() async {
    if (!_done.isCompleted) _done.complete();
    await _write;
  }
}

/// Starts holding [modId]'s folder in [container] as being written. The hold is in place when this returns.
///
/// In a `testWidgets` body whose release has to resume code waiting on the real event loop, start and release it
/// inside `tester.runAsync`.
HeldWrite holdWrite(ProviderContainer container, String modId) {
  final done = Completer<void>();
  final write = whileWritingMod(container, modId, () => done.future);
  return HeldWrite._(done, write);
}
