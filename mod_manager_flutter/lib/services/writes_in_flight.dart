/// The writes into mod folders running right now, so closing the app can wait for them.
///
/// A write killed part-way loses a folder: an update between its wipe and its copy, a restore, an import half copied.
/// A download killed part-way loses only bytes that resume, and a question waiting loses only itself, so neither is counted here and closing never waits for them (`docs/downloads.md` §10).
///
/// `whileWritingMod` feeds [WritesInFlight.shared] for every write it marks, and the library's imports join it directly.
/// A plain static rather than a provider, since an import runs in `ModManagerService`, which has no `ref`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log/logger.dart';

final Logger _log = Logger('app');

/// How long closing the window waits for writes in flight before the app exits anyway.
///
/// Long enough for an ordinary update's copy to finish; bounded, since a hung volume must not keep the app from closing.
const Duration kCloseWaitForWrites = Duration(seconds: 30);

class WritesInFlight {
  /// The one every writer registers with.
  static final WritesInFlight shared = WritesInFlight();

  /// Marks the zone a tracked write runs in, so the steps of a write already running are never held back.
  static final Object _insideWrite = Object();

  int _count = 0;
  bool _closing = false;
  Completer<void>? _idle;

  int get count => _count;

  /// Whether closing has begun: [track] starts no new write from then on, and a queue can read this to stop admitting work.
  bool get closing => _closing;

  /// Begins closing. A write started from here on, other than a step of a write already running, never starts and its future never completes, since the app is about to exit.
  void close() => _closing = true;

  /// For tests, which must not inherit a closing app from a test before them.
  @visibleForTesting
  void reopenForTests() => _closing = false;

  /// Runs [write] counted as a write in flight until it ends, however it ends.
  Future<T> track<T>(Future<T> Function() write) async {
    if (_closing && Zone.current[_insideWrite] != true) {
      _log.info('a write was not started because the app is closing');
      return Completer<T>().future;
    }
    _count++;
    try {
      return await runZoned(write, zoneValues: {_insideWrite: true});
    } finally {
      _count--;
      if (_count == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Completes the next time no write is running, at once when none is.
  Future<void> get idle => _count == 0 ? Future.value() : (_idle ??= Completer<void>()).future;

  /// Waits until no write is running, for at most [bound] in all. True when none was left running, false when the bound ran out first.
  ///
  /// A write that starts while this waits, such as a step of a running one, is waited for too, inside the same bound.
  Future<bool> settle(Duration bound) async {
    final clock = Stopwatch()..start();
    while (_count > 0) {
      final left = bound - clock.elapsed;
      if (left <= Duration.zero) return false;
      try {
        await idle.timeout(left);
      } on TimeoutException {
        return false;
      }
    }
    return true;
  }
}
