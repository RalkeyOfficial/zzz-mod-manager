import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/download/download_transport.dart';
import 'package:mod_manager_flutter/services/download/resume_policy.dart';

/// The rules that decide whether bytes already on disk are kept or thrown away.
/// Getting one of these wrong produces a corrupt archive that still extracts —
/// which is why they live in a pure function with a table of cases.
void main() {
  const policy = ResumePolicy();

  ResumeDecision decide({
    required int status,
    int onDisk = 0,
    int contentLength = -1,
    String? range,
    String? etag,
  }) =>
      policy.decide(
        statusCode: status,
        bytesOnDisk: onDisk,
        contentLength: contentLength,
        contentRange: ContentRange.parse(range),
        etag: etag,
      );

  group('ContentRange.parse', () {
    test('reads the satisfied form', () {
      final range = ContentRange.parse('bytes 100-999/1000')!;
      expect(range.start, 100);
      expect(range.end, 999);
      expect(range.total, 1000);
      expect(range.isUnsatisfiedForm, isFalse);
    });

    test('reads the unsatisfied form a 416 carries', () {
      final range = ContentRange.parse('bytes */655792108')!;
      expect(range.start, isNull);
      expect(range.total, 655792108);
      expect(range.isUnsatisfiedForm, isTrue);
    });

    test('tolerates an unknown total', () {
      expect(ContentRange.parse('bytes 0-99/*')!.total, isNull);
    });

    test('returns null rather than throwing on junk', () {
      expect(ContentRange.parse(null), isNull);
      expect(ContentRange.parse(''), isNull);
      expect(ContentRange.parse('nonsense'), isNull);
      expect(ContentRange.parse('items 0-99/100'), isNull);
    });
  });

  group('200', () {
    test('a fresh download just writes', () {
      final d = decide(status: 200, contentLength: 1000);
      expect(d.action, ResumeAction.restart);
      expect(d.startOffset, 0);
      expect(d.totalSize, 1000);
    });

    test('answering a ranged request means the upstream copy changed', () {
      // THE dangerous case. The body is the whole file; appending it to a
      // partial would concatenate two copies into a corrupt archive that still
      // looks plausible on disk.
      final d = decide(status: 200, onDisk: 500, contentLength: 1000);
      expect(d.action, ResumeAction.restart);
      expect(d.startOffset, 0);
      expect(d.reason, contains('changed'));
    });

    test('carries the new etag forward', () {
      expect(decide(status: 200, etag: '"abc"').etag, '"abc"');
    });

    test('an unknown content length leaves the total unknown', () {
      expect(decide(status: 200, contentLength: -1).totalSize, isNull);
    });
  });

  group('206', () {
    test('an aligned partial appends at the offset', () {
      final d = decide(
        status: 206,
        onDisk: 500,
        contentLength: 500,
        range: 'bytes 500-999/1000',
        etag: '"6a6d2f6d-271697ec"',
      );
      expect(d.action, ResumeAction.append);
      expect(d.startOffset, 500);
      expect(d.totalSize, 1000);
      expect(d.etag, '"6a6d2f6d-271697ec"');
    });

    test('a misaligned start restarts instead of leaving a hole', () {
      final d = decide(
        status: 206,
        onDisk: 500,
        range: 'bytes 300-999/1000',
      );
      expect(d.action, ResumeAction.restart);
      expect(d.reason, contains('300'));
    });

    test('a 206 with no Content-Range restarts rather than guessing', () {
      final d = decide(status: 206, onDisk: 500);
      expect(d.action, ResumeAction.restart);
    });

    test('derives the total from offset + length when the range omits it', () {
      final d = decide(
        status: 206,
        onDisk: 500,
        contentLength: 500,
        range: 'bytes 500-999/*',
      );
      expect(d.action, ResumeAction.append);
      expect(d.totalSize, 1000);
    });
  });

  group('416', () {
    test('disk size matching the total means we already have the file', () {
      final d = decide(status: 416, onDisk: 1000, range: 'bytes */1000');
      expect(d.action, ResumeAction.complete);
      expect(d.totalSize, 1000);
    });

    test('a disagreeing disk size restarts', () {
      final d = decide(status: 416, onDisk: 900, range: 'bytes */1000');
      expect(d.action, ResumeAction.restart);
    });

    test('no Content-Range restarts', () {
      expect(decide(status: 416, onDisk: 900).action, ResumeAction.restart);
    });
  });

  group('failures', () {
    test('404 is terminal', () {
      final d = decide(status: 404);
      expect(d.action, ResumeAction.fail);
      expect(d.retryable, isFalse);
    });

    test('403 is terminal', () {
      expect(decide(status: 403).retryable, isFalse);
    });

    test('503, 500, 429 and 408 are worth another go later', () {
      for (final status in [500, 503, 429, 408]) {
        final d = decide(status: status);
        expect(d.action, ResumeAction.fail, reason: 'status $status');
        expect(d.retryable, isTrue, reason: 'status $status');
      }
    });
  });
}
