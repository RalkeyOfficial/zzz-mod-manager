import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/archive_hash.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_paths.dart';
import 'package:mod_manager_flutter/services/download/download_progress.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';
import 'package:path/path.dart' as path;

import '../support/fake_download_transport.dart';

/// The download service, end to end, with no network anywhere.
void main() {
  late Directory temp;
  late FakeDownloadTransport transport;
  late DownloadPaths paths;

  final url = Uri.parse('https://gamebanana.com/dl/1770600');
  final body = List<int>.generate(200, (i) => i % 256);

  DownloadService build({
    Duration stallTimeout = const Duration(seconds: 30),
    IOSink Function(File, FileMode)? openSink,
  }) =>
      DownloadService(
        transport: transport,
        directory: temp,
        stallTimeout: stallTimeout,
        progressInterval: const Duration(milliseconds: 10),
        openSink: openSink,
      );

  DownloadRequest request({String name = 'mod.rar'}) =>
      DownloadRequest(url: url, suggestedFilename: name, fileId: 1770600);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('download_service_test_');
    transport = FakeDownloadTransport();
    paths = DownloadPaths(temp);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('a fresh download', () {
    test('writes the bytes and promotes to the final name', () async {
      transport.enqueue(url, body: body, headers: {'etag': '"abc"'});

      final result = await build().start(request()).done;

      expect(path.basename(result.file.path), 'mod.rar');
      expect(result.file.readAsBytesSync(), body);
      expect(result.totalBytes, body.length);
      expect(result.resumed, isFalse);
    });

    test('sends no range header', () async {
      transport.enqueue(url, body: body);
      await build().start(request()).done;

      expect(transport.lastHeaders.containsKey('range'), isFalse);
      expect(transport.lastHeaders.containsKey('if-range'), isFalse);
    });

    test('leaves no .part or record behind', () async {
      transport.enqueue(url, body: body);
      await build().start(request()).done;

      expect(paths.partFile('mod.rar').existsSync(), isFalse);
      expect(paths.recordFile('mod.rar').existsSync(), isFalse);
    });

    test('computes the md5 in-stream, matching the file on disk', () async {
      transport.enqueue(url, body: body);
      final result = await build().start(request()).done;

      expect(result.md5, isNotNull);
      expect(result.md5, await md5OfFile(result.file));
    });

    test('reports progress ending in completed', () async {
      transport.enqueue(url, body: body, chunkSize: 20);
      final handle = build().start(request());
      final seen = <DownloadProgress>[];
      final sub = handle.progress.listen(seen.add);

      await handle.done;
      await sub.cancel();

      expect(seen, isNotEmpty);
      expect(seen.last.state, DownloadState.completed);
      expect(seen.last.received, body.length);
    });

    test('never overwrites an existing archive', () async {
      paths.finalFile('mod.rar').writeAsStringSync('previous');
      transport.enqueue(url, body: body);

      final result = await build().start(request()).done;

      expect(path.basename(result.file.path), 'mod (2).rar');
      expect(paths.finalFile('mod.rar').readAsStringSync(), 'previous');
    });
  });

  group('interruption and resume', () {
    Future<void> interrupt() async {
      transport.enqueue(url,
          body: body,
          failAfter: 80,
          chunkSize: 20,
          headers: {'etag': '"abc"'});
      await expectLater(build().start(request()).done, throwsA(isA<Object>()));
    }

    test('an interrupted transfer keeps its bytes and its record', () async {
      await interrupt();

      expect(paths.partFile('mod.rar').existsSync(), isTrue);
      expect(paths.partFile('mod.rar').lengthSync(), 80);
      expect(paths.recordFile('mod.rar').existsSync(), isTrue);
      expect(paths.finalFile('mod.rar').existsSync(), isFalse,
          reason: 'a partial file must never take the final name');
    });

    test('resuming sends range AND if-range, then appends', () async {
      await interrupt();

      transport.enqueue(
        url,
        body: body.sublist(80),
        statusCode: 206,
        headers: {
          'etag': '"abc"',
          'content-range': 'bytes 80-199/200',
        },
      );
      final result = await build().start(request()).done;

      expect(transport.lastHeaders['range'], 'bytes=80-');
      expect(transport.lastHeaders['if-range'], '"abc"');
      expect(result.resumed, isTrue);
      expect(result.file.readAsBytesSync(), body,
          reason: 'the resumed file must be byte-identical to an uninterrupted one');
    });

    test('a 200 answering a ranged request replaces, never concatenates',
        () async {
      // The corruption case: appending a full body onto a partial produces a
      // file that looks plausible and is silently broken.
      await interrupt();

      final replacement = List<int>.generate(150, (i) => (i + 7) % 256);
      transport.enqueue(url, body: replacement, statusCode: 200);

      final result = await build().start(request()).done;

      expect(result.file.readAsBytesSync(), replacement);
      expect(result.file.lengthSync(), 150);
      expect(result.resumed, isFalse);
    });

    test('a 416 whose total matches the disk completes without transferring',
        () async {
      await interrupt();
      // Pretend the 80 bytes we hold are the whole file.
      transport.enqueue(url,
          statusCode: 416, headers: {'content-range': 'bytes */80'});

      final result = await build().start(request()).done;

      expect(result.totalBytes, 80);
      expect(result.file.lengthSync(), 80);
      expect(path.basename(result.file.path), 'mod.rar');
      expect(transport.discarded, contains(url),
          reason: 'the body must be released, not read');
    });

    test('a 416 whose total disagrees re-requests without a range', () async {
      await interrupt();
      transport.enqueue(url,
          statusCode: 416, headers: {'content-range': 'bytes */999'});
      transport.enqueue(url, body: body, statusCode: 200);

      final result = await build().start(request()).done;

      // A 416 carries no body, so "restart" cannot mean "write this response" —
      // promoting it would yield a zero-byte archive. One clean retry instead.
      expect(result.file.readAsBytesSync(), body);
      expect(transport.sentHeaders.last.containsKey('range'), isFalse);
      expect(transport.callCount, 3, reason: 'interrupt, 416, then clean retry');
    });

    test('a brand-new service instance resumes the same directory', () async {
      // Proves nothing needed for resume lives in memory — this is what makes
      // a resume survive the app being closed and reopened.
      await interrupt();

      transport.enqueue(
        url,
        body: body.sublist(80),
        statusCode: 206,
        headers: {'etag': '"abc"', 'content-range': 'bytes 80-199/200'},
      );
      final freshService = build();
      final result = await freshService.start(request()).done;

      expect(result.resumed, isTrue);
      expect(result.file.readAsBytesSync(), body);
    });

    test('a record for a different url is discarded, not resumed onto',
        () async {
      await interrupt();

      final otherUrl = Uri.parse('https://gamebanana.com/dl/999');
      transport.enqueue(otherUrl, body: body, statusCode: 200);

      final result = await build()
          .start(DownloadRequest(url: otherUrl, suggestedFilename: 'mod.rar'))
          .done;

      expect(transport.sentHeaders.last.containsKey('range'), isFalse);
      expect(result.file.readAsBytesSync(), body);
    });
  });

  group('stall timeout', () {
    test('aborts when no bytes arrive at all', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(url, controller);

      final service = build(stallTimeout: const Duration(milliseconds: 50));
      await expectLater(
        service.start(request()).done,
        throwsA(isA<DownloadStalledException>()),
      );
      await controller.close();
    });

    test('a slow but moving transfer is NOT aborted', () async {
      // The guard against anyone reintroducing a total-duration timeout: this
      // download runs far longer than the stall window, but never pauses.
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(url, controller, contentLength: 10);

      final service = build(stallTimeout: const Duration(milliseconds: 60));
      final handle = service.start(request());

      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        controller.add([i]);
      }
      await controller.close();

      final result = await handle.done;
      expect(result.totalBytes, 10);
      expect(result.file.lengthSync(), 10);
    });

    test('the partial survives a stall so it can be resumed', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(url, controller);
      final service = build(stallTimeout: const Duration(milliseconds: 50));
      final handle = service.start(request());

      controller.add([1, 2, 3]);
      await expectLater(handle.done, throwsA(isA<DownloadStalledException>()));
      await controller.close();

      expect(paths.partFile('mod.rar').existsSync(), isTrue);
      expect(paths.recordFile('mod.rar').existsSync(), isTrue);
    });
  });

  group('cancellation', () {
    test('keeps the partial by default so it can be resumed', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(url, controller);
      final handle = build().start(request());

      controller.add([1, 2, 3, 4]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await handle.cancel();

      await expectLater(handle.done, throwsA(isA<DownloadCancelledException>()));
      expect(paths.partFile('mod.rar').existsSync(), isTrue);
      await controller.close();
    });

    test('deletePartial removes both files', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(url, controller);
      final handle = build().start(request());

      controller.add([1, 2, 3, 4]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await handle.cancel(deletePartial: true);

      await expectLater(handle.done, throwsA(isA<DownloadCancelledException>()));
      expect(paths.partFile('mod.rar').existsSync(), isFalse);
      expect(paths.recordFile('mod.rar').existsSync(), isFalse);
      expect(paths.finalFile('mod.rar').existsSync(), isFalse);
      await controller.close();
    });
  });

  group('failures', () {
    test('a 404 throws and leaves no zero-byte file', () async {
      transport.enqueue(url, statusCode: 404);

      await expectLater(
        build().start(request()).done,
        throwsA(isA<DownloadHttpException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.retryable, 'retryable', isFalse)),
      );

      expect(paths.finalFile('mod.rar').existsSync(), isFalse);
      expect(paths.partFile('mod.rar').existsSync(), isFalse);
      expect(transport.discarded, contains(url),
          reason: 'the connection must be released, not leaked');
    });

    test('a 503 is reported as retryable', () async {
      transport.enqueue(url, statusCode: 503);

      await expectLater(
        build().start(request()).done,
        throwsA(isA<DownloadHttpException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
    });

    test('a transport failure becomes DownloadNetworkException', () async {
      transport.enqueueError(url, const SocketExceptionStub());

      await expectLater(
        build().start(request()).done,
        throwsA(isA<DownloadNetworkException>()),
      );
    });
  });

  group('housekeeping', () {
    test('sweeps orphaned partials on first use', () async {
      paths.partFile('orphan.rar').writeAsStringSync('junk');
      transport.enqueue(url, body: body);

      await build().start(request()).done;

      expect(paths.partFile('orphan.rar').existsSync(), isFalse);
    });

    test('an untrusted filename cannot escape the directory', () async {
      transport.enqueue(url, body: body);

      final result = await build()
          .start(DownloadRequest(url: url, suggestedFilename: '../../evil.rar'))
          .done;

      expect(result.file.parent.path, temp.path);
      expect(path.basename(result.file.path), 'evil.rar');
    });
  });
}
