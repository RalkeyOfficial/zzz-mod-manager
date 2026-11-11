import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';

import 'fake_download_transport.dart';

/// The real download queue over a scripted transport and a temp directory, for the queue's tests.
///
/// The service does real file I/O underneath, so how many turns a finished transfer takes has no answer:
/// wait for a state with [waitUntil], and use [settle] only to say something has *not* happened.
class DownloadQueueRig {
  DownloadQueueRig() : temp = Directory.systemTemp.createTempSync('download_queue_rig_');

  final Directory temp;
  final FakeDownloadTransport transport = FakeDownloadTransport();
  final List<StreamController<List<int>>> _controllers = [];

  /// What the space preflight reads, room for anything by default; read at each transfer's start.
  int freeSpace = 1 << 40;

  /// Read when the service is first built, so set it before the first transfer.
  Duration stallTimeout = const Duration(seconds: 60);

  static Uri urlFor(int fileId) => Uri.parse('https://gamebanana.com/dl/$fileId');

  /// A container whose download service is this rig's, with [overrides] after it.
  ProviderContainer container([List<Override> overrides = const []]) => ProviderContainer(
        overrides: [
          downloadServiceProvider.overrideWith(
            (ref) => DownloadService(
              transport: transport,
              directory: temp,
              progressInterval: const Duration(milliseconds: 10),
              stallTimeout: stallTimeout,
              // No `df` spawned per download: the preflight has its own tests.
              freeSpace: (_) async => freeSpace,
            ),
          ),
          ...overrides,
        ],
      );

  /// A transfer of [fileId] whose body the test sends when it likes. Closed by [dispose] if the test does not.
  StreamController<List<int>> controlled(int fileId, {int contentLength = -1}) {
    final controller = StreamController<List<int>>();
    _controllers.add(controller);
    transport.enqueueControlled(urlFor(fileId), controller, contentLength: contentLength);
    return controller;
  }

  /// Closing a `StreamController` nobody listened to never completes, and a queued job's response is exactly that,
  /// so these are dropped rather than awaited.
  void dispose() {
    for (final controller in _controllers) {
      if (!controller.isClosed) unawaited(controller.close());
    }
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

/// Waits for a state the queue reaches on its own, polled rather than pumped a fixed number of turns.
Future<void> waitUntil(bool Function() done, String because) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $because');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A short fixed wait, for asserting that something has *not* happened.
Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
