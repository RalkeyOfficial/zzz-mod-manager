import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/services/download/download_exceptions.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_queue.dart';
import 'package:mod_manager_flutter/services/download/download_service.dart';

import '../support/fake_download_transport.dart';

/// The queue, end to end, against a scripted transport and a temp directory.
///
/// The service underneath is already covered by `download_service_test.dart`;
/// what is new here is everything *between* downloads — the cap, the handover to
/// the host, and the four ways a job can stop.
void main() {
  late Directory temp;
  late FakeDownloadTransport transport;
  late ProviderContainer container;

  final body = List<int>.generate(200, (i) => i % 256);

  Uri urlFor(int fileId) => Uri.parse('https://gamebanana.com/dl/$fileId');

  GbFile fileFor(int fileId) => GbFile(
        idRow: fileId,
        file: 'mod$fileId.rar',
        filesize: body.length,
        downloadUrl: urlFor(fileId).toString(),
      );

  DownloadQueue queue() => container.read(downloadQueueProvider.notifier);
  List<DownloadJob> jobs() => container.read(downloadQueueProvider);

  DownloadJob jobOf(int seq) => jobs().firstWhere((j) => j.seq == seq);

  /// Waits for a state the queue reaches on its own.
  ///
  /// Polled rather than pumped a fixed number of turns: the transport is
  /// in-memory but the service underneath does **real** file I/O, so "how many
  /// microtasks is a completed download" has no answer and a fixed pump is a
  /// flaky test waiting to happen.
  Future<void> waitUntil(bool Function() done, String because) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $because');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// A short fixed pump, for asserting that something has *not* happened.
  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Closing a `StreamController` nobody ever listened to never completes, and a
  /// queued job's response is exactly that — so these are dropped rather than
  /// awaited.
  void closeAll(Iterable<StreamController<List<int>>> controllers) {
    for (final c in controllers) {
      if (!c.isClosed) unawaited(c.close());
    }
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('download_queue_test_');
    transport = FakeDownloadTransport();
    container = ProviderContainer(
      overrides: [
        downloadServiceProvider.overrideWith(
          (ref) => DownloadService(
            transport: transport,
            directory: temp,
            progressInterval: const Duration(milliseconds: 10),
          ),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  DownloadJob enqueue(
    int fileId, {
    DownloadIntent intent = DownloadIntent.install,
  }) =>
      queue().enqueue(
        file: fileFor(fileId),
        subject: 'mod $fileId',
        intent: intent,
      );

  group('the cap', () {
    test('runs two and holds the third', () async {
      final controllers = [
        for (var i = 0; i < 3; i++) StreamController<List<int>>()
      ];
      for (var i = 0; i < 3; i++) {
        transport.enqueueControlled(urlFor(i + 1), controllers[i],
            contentLength: body.length);
      }

      for (var i = 1; i <= 3; i++) {
        enqueue(i);
      }
      await settle();

      expect(jobOf(1).state, DownloadJobState.running);
      expect(jobOf(2).state, DownloadJobState.running);
      expect(jobOf(3).state, DownloadJobState.queued);

      // Finishing one frees exactly one slot, and the queue starts the next
      // without anyone asking it to.
      controllers[0].add(body);
      unawaited(controllers[0].close());
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the first transfer to finish',
      );

      expect(jobOf(3).state, DownloadJobState.running);
      closeAll(controllers);
    });
  });

  group('asking twice', () {
    test('the same file is never fetched twice at once', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(urlFor(1), controller,
          contentLength: body.length);

      final first = enqueue(1);
      final second = enqueue(1);
      await settle();

      expect(second.seq, first.seq);
      expect(jobs(), hasLength(1));
      // One transfer, one `.part`, one resume record. Two would append two
      // streams into one plausible and corrupt archive.
      expect(transport.callCount, 1);
      closeAll([controller]);
    });

    test('but a finished one can be asked for again', () async {
      transport.enqueue(urlFor(1), body: body);
      enqueue(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the first attempt to finish',
      );
      queue().markDone(1);

      transport.enqueue(urlFor(1), body: body);
      final again = enqueue(1);
      expect(again.seq, isNot(1));
      await waitUntil(
        () => jobOf(again.seq).state == DownloadJobState.downloaded,
        'the second attempt to finish',
      );
    });
  });

  group('when the bytes land', () {
    test('an install job waits for the host, with its archive', () async {
      transport.enqueue(urlFor(1), body: body);
      enqueue(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the transfer to finish',
      );

      final job = jobOf(1);
      expect(job.archive, isNotNull);
      expect(job.archive!.readAsBytesSync(), body);
    });

    test('a caller-owned job is finished the moment they land', () async {
      transport.enqueue(urlFor(1), body: body);
      final job = enqueue(1, intent: DownloadIntent.callerHandles);
      final result = await queue().completionOf(job.seq);

      expect(result.file.readAsBytesSync(), body);
      // Never `downloaded`: the host is told to ignore these, so parking one
      // there would leave a row nothing ever comes for.
      expect(jobOf(1).state, DownloadJobState.done);
    });
  });

  group('the handover', () {
    test('claims one job and refuses to claim a second', () async {
      transport.enqueue(urlFor(1), body: body);
      transport.enqueue(urlFor(2), body: body);
      enqueue(1);
      enqueue(2);
      await waitUntil(
        () => jobs().every((j) => j.state == DownloadJobState.downloaded),
        'both transfers to finish',
      );

      final claimed = queue().claimNextForHost();
      expect(claimed?.seq, 1);
      expect(claimed?.state, DownloadJobState.installing);
      expect(queue().claimNextForHost(), isNull);

      queue().markDone(1);
      expect(queue().claimNextForHost()?.seq, 2);
    });
  });

  group('stopping', () {
    test('a queued job is cancelled without ever connecting', () async {
      final controllers = [
        for (var i = 0; i < 3; i++) StreamController<List<int>>()
      ];
      for (var i = 0; i < 3; i++) {
        transport.enqueueControlled(urlFor(i + 1), controllers[i],
            contentLength: body.length);
      }
      for (var i = 1; i <= 3; i++) {
        enqueue(i);
      }
      await settle();

      await queue().cancel(3);
      expect(jobOf(3).state, DownloadJobState.cancelled);
      expect(transport.callCount, 2);
      closeAll(controllers);
    });

    test('a running job stops and frees its slot', () async {
      final controllers = [
        for (var i = 0; i < 3; i++) StreamController<List<int>>()
      ];
      for (var i = 0; i < 3; i++) {
        transport.enqueueControlled(urlFor(i + 1), controllers[i],
            contentLength: body.length);
      }
      for (var i = 1; i <= 3; i++) {
        enqueue(i);
      }
      await settle();

      await queue().cancel(1);
      await waitUntil(
        () => jobOf(3).state == DownloadJobState.running,
        'the freed slot to be taken by the next job',
      );

      expect(jobOf(1).state, DownloadJobState.cancelled);
      closeAll(controllers);
    });

    test('a cancel leaves no error behind on the row', () async {
      // `error != null` has to mean "something went wrong" — the title-bar
      // button reads it to decide whether to turn red, and a cancel is the user
      // getting what they asked for. Both cancel paths must agree, so this
      // covers the running one and the queued one below it.
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(urlFor(1), controller,
          contentLength: body.length);
      enqueue(1);
      await settle();

      await queue().cancel(1);
      expect(jobOf(1).state, DownloadJobState.cancelled);
      expect(jobOf(1).error, isNull);
      closeAll([controller]);
    });

    test('and neither does one that never started', () async {
      final controllers = [
        for (var i = 0; i < 3; i++) StreamController<List<int>>()
      ];
      for (var i = 0; i < 3; i++) {
        transport.enqueueControlled(urlFor(i + 1), controllers[i],
            contentLength: body.length);
      }
      for (var i = 1; i <= 3; i++) {
        enqueue(i);
      }
      await settle();

      await queue().cancel(3);
      expect(jobOf(3).error, isNull);
      closeAll(controllers);
    });

    test('an installing job cannot be cancelled', () async {
      // The refusal lives here rather than only in the button that declines to
      // offer it: there is no safe stopping point between the unpack and the
      // import, and the archive delete below would pull the file out from under
      // a running extraction.
      transport.enqueue(urlFor(1), body: body);
      enqueue(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the transfer to finish',
      );
      final archive = jobOf(1).archive!;
      queue().claimNextForHost();
      expect(jobOf(1).state, DownloadJobState.installing);

      await queue().cancel(1);

      expect(jobOf(1).state, DownloadJobState.installing);
      expect(archive.existsSync(), isTrue);
    });

    test('cancelling after the bytes landed takes the archive with it',
        () async {
      // Nothing else will ever come for it — the install that would have
      // consumed it is what is being called off — so leaving it would be
      // several hundred megabytes in a folder the user does not manage.
      transport.enqueue(urlFor(1), body: body);
      enqueue(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the transfer to finish',
      );

      final archive = jobOf(1).archive!;
      expect(archive.existsSync(), isTrue);

      await queue().cancel(1);
      expect(jobOf(1).state, DownloadJobState.cancelled);
      expect(archive.existsSync(), isFalse);
    });
  });

  group('failure and retry', () {
    test('records the failure and offers the job back unchanged', () async {
      transport.enqueueError(urlFor(1), const SocketException('no route'));
      enqueue(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.failed,
        'the transfer to fail',
      );

      expect(jobOf(1).error, isA<DownloadNetworkException>());

      transport.enqueue(urlFor(1), body: body);
      queue().retry(1);
      await waitUntil(
        () => jobOf(1).state == DownloadJobState.downloaded,
        'the retry to finish',
      );

      // Same row, same place in the list — and the previous error is gone
      // rather than lingering under a job that has since succeeded.
      expect(jobs(), hasLength(1));
      expect(jobOf(1).state, DownloadJobState.downloaded);
      expect(jobOf(1).error, isNull);
    });

    test('a stale failed row cannot start a second transfer of the same file',
        () async {
      // The whole reason `enqueue` de-duplicates, reached around the back. Two
      // runs of one file write the same `.part` and the same resume record, and
      // append two streams into a corrupt archive that still looks plausible.
      //
      // Entirely reachable: the failed row stays in the panel by design, the
      // user presses Download on the same file again, and then presses Retry on
      // the older of the two rows now showing the same mod name.
      transport.enqueueError(urlFor(1), const SocketException('no route'));
      final first = enqueue(1);
      await waitUntil(
        () => jobOf(first.seq).state == DownloadJobState.failed,
        'the first attempt to fail',
      );

      final controller = StreamController<List<int>>();
      transport.enqueueControlled(urlFor(1), controller,
          contentLength: body.length);
      final second = enqueue(1);
      await settle();
      expect(jobOf(second.seq).state, DownloadJobState.running);

      final callsBefore = transport.callCount;
      queue().retry(first.seq);
      await settle();

      expect(jobOf(first.seq).state, DownloadJobState.failed,
          reason: 'the stale row must stay put rather than restart');
      expect(transport.callCount, callsBefore,
          reason: 'no second transfer of a file already in flight');
      closeAll([controller]);
    });

    test('a retried job can be awaited again', () async {
      transport.enqueueError(urlFor(1), const SocketException('no route'));
      final job = enqueue(1, intent: DownloadIntent.callerHandles);
      await expectLater(
        queue().completionOf(job.seq),
        throwsA(isA<DownloadNetworkException>()),
      );

      transport.enqueue(urlFor(1), body: body);
      queue().retry(job.seq);
      // A completer cannot be completed twice, so a retry has to replace it.
      // Without that the second attempt succeeds and nothing ever hears.
      final result = await queue().completionOf(job.seq);
      expect(result.file.readAsBytesSync(), body);
    });
  });

  group('clearing', () {
    test('takes the finished rows and leaves the rest', () async {
      final controller = StreamController<List<int>>();
      transport.enqueue(urlFor(1), body: body);
      transport.enqueueControlled(urlFor(2), controller,
          contentLength: body.length);

      final finished = enqueue(1, intent: DownloadIntent.callerHandles);
      enqueue(2);
      await queue().completionOf(finished.seq);

      queue().clearFinished();
      expect(jobs().map((j) => j.seq), [2]);
      closeAll([controller]);
    });

    test('a running job cannot be removed', () async {
      final controller = StreamController<List<int>>();
      transport.enqueueControlled(urlFor(1), controller,
          contentLength: body.length);
      enqueue(1);
      await settle();

      queue().remove(1);
      expect(jobs(), hasLength(1));
      closeAll([controller]);
    });
  });

  test('a url that will not parse arrives as a failed row, not silence',
      () async {
    // Both callers read a null return as "already reported", so an enqueue that
    // quietly refused turned pressing Download into nothing happening at all.
    final job = queue().enqueue(
      file: const GbFile(idRow: 1, downloadUrl: 'http://[oops'),
      subject: 'broken',
      intent: DownloadIntent.install,
    );
    expect(job.state, DownloadJobState.failed);
    expect(jobs(), hasLength(1));
    await expectLater(
      queue().completionOf(job.seq),
      throwsA(isA<DownloadNetworkException>()),
    );
  });
}
