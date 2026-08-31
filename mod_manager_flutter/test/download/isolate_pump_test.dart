import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/archive_hash.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_paths.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';
import 'package:mod_manager_flutter/services/download/isolate_download_pump.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';
import 'package:path/path.dart' as path;

import '../support/loopback_file_server.dart';

/// What only the isolate arm can be asked, and the whole service on top of it.
///
/// The shared behaviour is in `pump_contract_test.dart`, which runs one body
/// against both pumps. This file covers the two things that are specific to
/// running the transfer somewhere else: that the worker actually goes away, and
/// that the stall timer still means "no bytes" now that the counter arrives on a
/// timer rather than per chunk.
void main() {
  late LoopbackFileServer server;
  late Directory temp;
  late DownloadPaths paths;

  setUp(() async {
    server = await LoopbackFileServer.start();
    temp = Directory.systemTemp.createTempSync('isolate_pump_');
    paths = DownloadPaths(temp);
  });

  tearDown(() async {
    await server.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  DownloadService build({
    Duration stallTimeout = const Duration(seconds: 30),
  }) =>
      DownloadService(
        pump: IsolateDownloadPump(),
        directory: temp,
        stallTimeout: stallTimeout,
        progressInterval: const Duration(milliseconds: 50),
      );

  group('the worker does not outlive its session', () {
    // A leaked worker is invisible until the fortieth download, and it holds an
    // `HttpClient` and a `ReceivePort` — either of which keeps an isolate alive
    // forever. `shutdown` waits for the exit notification and only kills after
    // five seconds, so "it came back promptly" *is* the assertion that the
    // worker terminated on its own. A coarse bound, not a cadence check.
    Future<void> expectPrompt(Future<void> work) async {
      final stopwatch = Stopwatch()..start();
      await work;
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'shutdown fell back to killing the isolate, which means the '
              'worker never exited by itself');
    }

    test('after a completed drain', () async {
      final pump = IsolateDownloadPump();
      final session = await pump.open(server.uri('/file.bin'));
      await session.drainTo('${temp.path}/out.bin',
          hashMd5: false, onBytes: (_) {}, onBodyEnded: () {});
      await expectPrompt(session.shutdown());
      await pump.close();
    });

    test('after a shutdown with no drain at all', () async {
      final pump = IsolateDownloadPump();
      final session = await pump.open(server.uri('/file.bin'));
      await expectPrompt(session.shutdown());
      await pump.close();
    });

    test('after an interrupted drain', () async {
      final pump = IsolateDownloadPump();
      final session = await pump.open(server.uri('/trickle.bin'));
      final drain = session.drainTo('${temp.path}/out.bin',
          hashMd5: false, onBytes: (_) {}, onBodyEnded: () {});
      await expectPrompt(session.shutdown());
      await drain;
      await pump.close();
    });
  });

  group('what the worker can say', () {
    test('its diagnostics reach the log on the main isolate', () async {
      // The worker shares no memory with us: it cannot reach `Log.router` and
      // must not open the rotating file itself. So its lines travel as data on
      // the port it already has, and are logged on arrival — which this is the
      // only test that can prove, because it runs a real isolate.
      final sink = MemoryLogSink();
      Log.install(LogRouter(sinks: [sink]));
      addTearDown(() => Log.install(LogRouter(sinks: [])));

      final service = build();
      await service
          .start(DownloadRequest(
            url: server.uri('/file.bin'),
            suggestedFilename: 'mod.rar',
          ))
          .done;
      service.close();

      final fromWorker =
          sink.lines.where((line) => line.contains('download.worker'));
      expect(fromWorker, isNotEmpty);
      expect(fromWorker.first, contains('connected'));
      expect(fromWorker.first, contains('status=200'));
      expect(fromWorker.first, contains('origin=worker'),
          reason: 'a reader can tell which isolate a line came from');
    });
  });

  group('the whole service over a spawned isolate', () {
    test('downloads, promotes and hashes in-stream', () async {
      final service = build();
      final result = await service
          .start(DownloadRequest(
            url: server.uri('/file.bin'),
            suggestedFilename: 'mod.rar',
          ))
          .done;

      expect(path.basename(result.file.path), 'mod.rar');
      expect(result.file.readAsBytesSync(), server.body);
      expect(result.totalBytes, server.body.length);
      expect(result.md5, await md5OfFile(result.file));
      expect(paths.partFile('mod.rar').existsSync(), isFalse);
      service.close();
    });

    test('resumes an interrupted transfer to a byte-identical file', () async {
      // One url throughout: the resume record is keyed on it, so a second url
      // would correctly be treated as an unrelated download and start over.
      final request = DownloadRequest(
        url: server.uri('/trickle.bin'),
        suggestedFilename: 'mod.rar',
      );

      final stalling = build(stallTimeout: const Duration(milliseconds: 1500));
      await expectLater(
        stalling.start(request).done,
        throwsA(isA<DownloadStalledException>()),
      );
      stalling.close();
      expect(paths.partFile('mod.rar').lengthSync(),
          LoopbackFileServer.trickleBytes);

      // The node recovers; the same url now serves the rest.
      server.stalling = false;
      final service = build();
      final result = await service.start(request).done;

      expect(result.resumed, isTrue);
      expect(result.file.readAsBytesSync(), server.body,
          reason: 'a resumed file must be byte-identical to an uninterrupted one');
      expect(result.md5, isNull,
          reason: 'the earlier bytes never passed through this process, so '
              'there is nothing honest to hash');
      service.close();
    });

    test('a transfer that goes quiet stalls, and keeps its bytes', () async {
      // The rule the isolate pump changes: the worker posts its counter every
      // 200 ms whether or not anything moved, so only an *increase* may reset
      // the stall timer. If a tick reset it, this download would hang forever.
      final service = build(stallTimeout: const Duration(milliseconds: 1500));
      final handle = service.start(DownloadRequest(
        url: server.uri('/trickle.bin'),
        suggestedFilename: 'mod.rar',
      ));

      await expectLater(handle.done, throwsA(isA<DownloadStalledException>()));
      expect(paths.partFile('mod.rar').lengthSync(),
          LoopbackFileServer.trickleBytes,
          reason: 'a stall must flush what it has — those bytes are what the '
              'next resume starts from');
      expect(paths.recordFile('mod.rar').existsSync(), isTrue);
      service.close();
    });

    test('cancelling mid-transfer can delete the partial', () async {
      final service = build();
      final handle = service.start(DownloadRequest(
        url: server.uri('/trickle.bin'),
        suggestedFilename: 'mod.rar',
      ));
      await handle.progress
          .firstWhere((progress) => progress.received > 0)
          .timeout(const Duration(seconds: 10));

      await handle.cancel(deletePartial: true);
      await expectLater(handle.done, throwsA(isA<DownloadCancelledException>()));

      expect(paths.partFile('mod.rar').existsSync(), isFalse);
      expect(paths.recordFile('mod.rar').existsSync(), isFalse);
      expect(paths.finalFile('mod.rar').existsSync(), isFalse,
          reason: 'a cancelled download must never leave an archive behind');
      service.close();
    });
  });
}
