import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/archive_hash.dart';
import 'package:mod_manager_flutter/services/download/download_pump.dart';
import 'package:mod_manager_flutter/services/download/inline_download_pump.dart';
import 'package:mod_manager_flutter/services/download/io_download_transport.dart';
import 'package:mod_manager_flutter/services/download/isolate_download_pump.dart';

import '../support/loopback_file_server.dart';

/// One body, run against **both** [DownloadPump] implementations.
///
/// The shared `pumpResponseToFile` only covers the write loop. Everything the
/// two pumps do differently — teardown, error reporting, how often progress is
/// reported, what `shutdown` means before a drain versus during one — lives
/// outside it, and that is precisely where they would drift apart. A shared
/// function is a hope; this is the mechanism.
///
/// Plain `test()`, never `testWidgets`: `testWidgets` installs `FakeAsync`, so
/// timers would be virtual while port messages arrive on real time, and any
/// pump-and-settle around an isolate await would deadlock.
void main() {
  runPumpContract('InlineDownloadPump', () => InlineDownloadPump(IoDownloadTransport()));
  runPumpContract('IsolateDownloadPump', IsolateDownloadPump.new);
}

void runPumpContract(String name, DownloadPump Function() make) {
  group(name, () {
    late LoopbackFileServer server;
    late Directory temp;
    late DownloadPump pump;
    late String out;

    setUp(() async {
      server = await LoopbackFileServer.start();
      temp = Directory.systemTemp.createTempSync('pump_contract_');
      out = '${temp.path}/out.bin';
      pump = make();
    });

    // A worker that outlives its test hangs the whole suite rather than failing
    // it, and the 30 s timeout message says nothing useful about why.
    tearDown(() async {
      await pump.close();
      await server.close();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('a fresh download writes every byte and hashes it in-stream', () async {
      final session = await pump.open(server.uri('/file.bin'));
      expect(session.statusCode, 200);
      expect(session.contentLength, server.body.length);
      expect(session.etag, LoopbackFileServer.etag);

      var lastReport = 0;
      var bodyEnded = false;
      final outcome = await session.drainTo(
        out,
        hashMd5: true,
        onBytes: (bytes) {
          expect(bytes, greaterThanOrEqualTo(lastReport),
              reason: 'the counter is cumulative and never goes backwards');
          lastReport = bytes;
        },
        onBodyEnded: () => bodyEnded = true,
      );
      await session.shutdown();

      expect(outcome.bytesWritten, server.body.length);
      expect(File(out).readAsBytesSync(), server.body);
      expect(outcome.md5, await md5OfFile(File(out)),
          reason: 'the in-stream hash must match the file it wrote — the '
              'archive is deleted after extraction, so there is no second '
              'chance to compute it');
      expect(bodyEnded, isTrue);
    });

    test('a Range resume appends onto what is already there', () async {
      const prefix = 1000;
      File(out).writeAsBytesSync(server.body.sublist(0, prefix));

      final session = await pump.open(
        server.uri('/file.bin'),
        headers: {'range': 'bytes=$prefix-', 'if-range': LoopbackFileServer.etag},
      );
      expect(session.statusCode, 206);
      expect(session.contentRange?.start, prefix);
      expect(session.contentRange?.total, server.body.length);

      final outcome = await session.drainTo(
        out,
        hashMd5: false,
        onBytes: (_) {},
        onBodyEnded: () {},
      );
      await session.shutdown();

      expect(outcome.bytesWritten, server.body.length - prefix);
      expect(File(out).readAsBytesSync(), server.body,
          reason: 'a resumed file must be byte-identical to an uninterrupted one');
    });

    test('shutdown mid-drain keeps a valid prefix, and it resumes', () async {
      final session = await pump.open(server.uri('/trickle.bin'));
      final started = Completer<void>();
      final drain = session.drainTo(
        out,
        hashMd5: false,
        onBytes: (bytes) {
          if (bytes > 0 && !started.isCompleted) started.complete();
        },
        onBodyEnded: () {},
      );
      await started.future;
      await session.shutdown();
      final outcome = await drain;

      final partial = File(out).readAsBytesSync();
      expect(partial, isNotEmpty);
      expect(outcome.bytesWritten, partial.length,
          reason: 'an interrupted drain still reports what it wrote');
      expect(partial, server.body.sublist(0, partial.length),
          reason: 'the sink only ever appends, so a partial is always a valid '
              'prefix — which is the whole reason a kill is survivable');

      // And the property that matters: those bytes are worth keeping.
      final resumed = await pump.open(
        server.uri('/file.bin'),
        headers: {'range': 'bytes=${partial.length}-'},
      );
      await resumed.drainTo(out,
          hashMd5: false, onBytes: (_) {}, onBodyEnded: () {});
      await resumed.shutdown();
      expect(File(out).readAsBytesSync(), server.body);
    });

    test('shutdown before any drain writes nothing and lets go', () async {
      final session = await pump.open(server.uri('/file.bin'));
      await session.shutdown();

      expect(File(out).existsSync(), isFalse);
      // Calling it twice is legitimate — cancel, a stall and the success path
      // all reach for it — and must not throw or hang.
      await session.shutdown();
    });

    test('a 404 comes back as a status, not as a throw', () async {
      final session = await pump.open(server.uri('/missing.bin'));
      expect(session.statusCode, 404);
      await session.shutdown();
    });

    test('an unreachable port throws rather than returning a session', () async {
      // Port 1 is privileged and unbound, so this fails to connect. The two
      // pumps throw different types on purpose — the inline one surfaces the
      // raw `SocketException` its transport threw, the isolate one cannot send
      // that object across a port and so maps it. `DownloadService._open` is
      // what normalises both into `DownloadNetworkException`.
      await expectLater(
        pump.open(
          Uri.parse('http://127.0.0.1:1/nope.bin'),
          connectTimeout: const Duration(seconds: 5),
        ),
        throwsA(anything),
      );
    });
  });
}
