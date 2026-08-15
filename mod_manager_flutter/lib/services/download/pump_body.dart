/// The socket→disk write loop, shared by **both** [DownloadPump]
/// implementations.
///
/// `InlineDownloadPump` calls it directly; the spawned worker behind
/// `IsolateDownloadPump` calls the very same function. That is deliberate — the
/// resume rules above this are where the subtle bugs live, and two hand-written
/// copies of the write loop is exactly how the inline path and the isolate path
/// would come to disagree about them.
///
/// It is not the whole anti-divergence story, though, and it would be a mistake
/// to treat it as such: teardown semantics, error fidelity and report cadence
/// all live *outside* this function. Those are covered by the shared contract
/// test (`test/download/pump_contract_test.dart`), which runs one body against
/// both pumps.
library;

import 'dart:async';
import 'dart:io';

import '../archive_hash.dart';
import 'download_exceptions.dart';
import 'download_pump.dart';
import 'download_transport.dart';

/// A one-shot "stop early" signal handed to [pumpResponseToFile].
///
/// The drain stops **gracefully**: the sink is still flushed and closed, and the
/// bytes written so far are still reported. That is not politeness either — the
/// partial file is what a later resume picks up from, so throwing the tail away
/// would turn every cancel into a restart.
class PumpInterrupt {
  final Completer<void> _completer = Completer<void>();

  bool get isSet => _completer.isCompleted;

  Future<void> get signal => _completer.future;

  void set() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

IOSink _defaultOpenSink(File file, FileMode mode) => file.openWrite(mode: mode);

/// Writes [response]'s body onto the **end** of the file at [partPath].
///
/// Always appends — see [PumpSession.drainTo] for why there is no truncate mode.
///
/// [onBytes] is called per chunk with the running total for *this* drain. That
/// is cheap where this function runs; throttling it down to something worth
/// sending across an isolate boundary is the caller's job.
///
/// [onBodyEnded] fires the moment the socket is done, **before** the flush and
/// close. Flushing a gigabyte can take seconds on contended storage, and the
/// caller's stall timer must not be running through it.
Future<PumpOutcome> pumpResponseToFile(
  DownloadResponse response,
  String partPath, {
  required bool hashMd5,
  required void Function(int bytesWritten) onBytes,
  required void Function() onBodyEnded,
  required PumpInterrupt interrupt,
  IOSink Function(File file, FileMode mode)? openSink,
}) async {
  final IOSink sink;
  try {
    sink = (openSink ?? _defaultOpenSink)(File(partPath), FileMode.append);
  } catch (error) {
    throw DownloadWriteException('Could not open $partPath', cause: error);
  }

  final digest = hashMd5 ? Md5Accumulator() : null;
  final finished = Completer<void>();
  var written = 0;
  var ended = false;

  /// The backpressure flush currently in flight, settled and never throwing.
  ///
  /// An `IOSink` refuses a second `flush()` while one is outstanding — it marks
  /// itself bound and raises a `StateError` — so the teardown has to wait for
  /// this one before it can flush and close. Interrupting mid-chunk is exactly
  /// when there is one outstanding.
  Future<void>? pendingFlush;

  void endBody() {
    if (ended) return;
    ended = true;
    onBodyEnded();
  }

  late final StreamSubscription<List<int>> sub;
  sub = response.body.listen(
    (chunk) {
      if (finished.isCompleted) return;
      try {
        sink.add(chunk);
      } catch (error) {
        if (!finished.isCompleted) {
          finished.completeError(
            DownloadWriteException('Write failed', cause: error),
          );
        }
        return;
      }
      digest?.add(chunk);
      written += chunk.length;
      onBytes(written);
      // Backpressure. Without this the socket keeps delivering while the disk
      // falls behind and the difference buffers in memory. `sink.add` is not
      // awaitable, so pausing on the flush is what applies the brake. Measured
      // at +57 MB against a slow consumer, on files that reach 1.24 GB.
      final flushed = sink.flush();
      pendingFlush = flushed.then<void>((_) {}, onError: (Object _) {});
      sub.pause(flushed);
    },
    onError: (Object error, StackTrace stack) {
      if (!finished.isCompleted) finished.completeError(error);
    },
    onDone: () {
      if (!finished.isCompleted) finished.complete();
    },
    cancelOnError: true,
  );

  // An interrupt ends the drain the same way the stream ending does, so there
  // is one path out of here rather than two.
  unawaited(interrupt.signal.then((_) {
    if (!finished.isCompleted) finished.complete();
  }));

  var failing = false;
  try {
    await finished.future;
  } catch (_) {
    failing = true;
    rethrow;
  } finally {
    endBody();
    await sub.cancel();
    await pendingFlush;
    // Always close the sink, on every path. The old inline downloader leaked it
    // on every error, which is how partial writes stayed unflushed.
    try {
      await sink.flush();
      await sink.close();
    } catch (error) {
      // While already failing the original error is the one worth reporting.
      // On the success path it is not: a flush that fails there means the tail
      // of the archive never reached the disk, and reporting success would hand
      // back a short file that looks whole.
      if (!failing) {
        throw DownloadWriteException('Could not flush $partPath', cause: error);
      }
    }
  }

  return PumpOutcome(bytesWritten: written, md5: digest?.close());
}
