import 'download_transport.dart';

/// What to do with the bytes already on disk, given the response we just got.
enum ResumeAction {
  /// Keep the partial and append the incoming body to it.
  append,

  /// Discard the partial and write the incoming body from byte zero.
  restart,

  /// The file is already complete on disk; promote it without transferring.
  complete,

  /// Don't write anything; the caller should surface an error.
  fail,
}

/// The outcome of applying [ResumePolicy] to one response.
class ResumeDecision {
  const ResumeDecision(
    this.action, {
    this.startOffset = 0,
    this.totalSize,
    this.etag,
    this.reason = '',
    this.retryable = false,
  });

  final ResumeAction action;

  /// Where the incoming bytes belong in the file. Always 0 unless appending.
  final int startOffset;

  /// Full size of the resource once known, for the progress denominator.
  final int? totalSize;

  /// The validator to store for a future resume.
  final String? etag;

  /// Developer-facing explanation; not shown to users.
  final String reason;

  /// Whether a failure is worth trying again later (5xx) or is terminal (404).
  final bool retryable;
}

/// Decides how a response combines with whatever is already on disk.
///
/// Pure and separate from the service on purpose: these rules are where a
/// download quietly corrupts a file, and they are far easier to get right — and
/// to prove right — as a table of inputs than as branches tangled through
/// stream handling. The dangerous case in particular is a `200` answering a
/// ranged request: appending there would concatenate the whole file onto the
/// partial and produce a plausible-looking archive that is silently broken.
class ResumePolicy {
  const ResumePolicy();

  ResumeDecision decide({
    required int statusCode,
    required int bytesOnDisk,
    required int contentLength,
    ContentRange? contentRange,
    String? etag,
  }) {
    // 416: the range we asked for is past the end of the resource.
    if (statusCode == 416) {
      final total = contentRange?.total;
      if (total != null && total == bytesOnDisk) {
        return ResumeDecision(
          ResumeAction.complete,
          startOffset: bytesOnDisk,
          totalSize: total,
          etag: etag,
          reason: 'range unsatisfiable and disk matches total — already done',
        );
      }
      return ResumeDecision(
        ResumeAction.restart,
        totalSize: total,
        etag: etag,
        reason: 'range unsatisfiable and disk size disagrees with total',
      );
    }

    if (statusCode == 206) {
      final range = contentRange;
      if (range == null || range.start == null) {
        // A 206 has to say which bytes it is. Without that we cannot place
        // them, and guessing is how files get corrupted.
        return const ResumeDecision(
          ResumeAction.restart,
          reason: '206 without a usable Content-Range',
        );
      }
      if (range.start != bytesOnDisk) {
        // The server returned a different span than we asked for. Appending
        // would leave a hole or an overlap.
        return ResumeDecision(
          ResumeAction.restart,
          totalSize: range.total,
          etag: etag,
          reason: '206 starts at ${range.start}, disk has $bytesOnDisk',
        );
      }
      return ResumeDecision(
        ResumeAction.append,
        startOffset: bytesOnDisk,
        totalSize: range.total ?? _sum(bytesOnDisk, contentLength),
        etag: etag,
        reason: 'aligned 206 — resuming',
      );
    }

    if (statusCode == 200) {
      // Either a fresh download, or the server declined our range (the file
      // changed, or If-Range didn't match). Both mean: this body is the whole
      // resource, so anything already on disk is stale and must go.
      return ResumeDecision(
        ResumeAction.restart,
        totalSize: contentLength >= 0 ? contentLength : null,
        etag: etag,
        reason: bytesOnDisk > 0
            ? '200 answering a ranged request — upstream copy changed'
            : 'fresh download',
      );
    }

    if (statusCode >= 500 || statusCode == 429 || statusCode == 408) {
      return ResumeDecision(
        ResumeAction.fail,
        reason: 'HTTP $statusCode',
        retryable: true,
      );
    }

    return ResumeDecision(ResumeAction.fail, reason: 'HTTP $statusCode');
  }

  static int? _sum(int offset, int contentLength) =>
      contentLength >= 0 ? offset + contentLength : null;
}
