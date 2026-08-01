import 'dart:async';
import 'dart:io';

import 'download_progress.dart';

/// What a completed download produced.
class DownloadResult {
  const DownloadResult({
    required this.file,
    required this.totalBytes,
    this.etag,
    this.md5,
    this.resumed = false,
  });

  /// The archive at its final name.
  final File file;

  final int totalBytes;

  final String? etag;

  /// md5 computed while the bytes streamed past.
  ///
  /// Free here and **unrecoverable later**: the archive is deleted once
  /// extracted, and a zip cannot be reproduced byte-for-byte from its extracted
  /// contents. If it isn't captured on the way through, it is gone.
  ///
  /// Null when the download resumed across a restart, since the earlier bytes
  /// never passed through this process.
  final String? md5;

  /// Whether this download picked up from bytes already on disk.
  final bool resumed;
}

/// A running download, from the caller's side.
class DownloadHandle {
  DownloadHandle({
    required Stream<DownloadProgress> progress,
    required Future<DownloadResult> done,
    required Future<void> Function({bool deletePartial}) onCancel,
  })  : _progress = progress,
        _done = done,
        _onCancel = onCancel;

  final Stream<DownloadProgress> _progress;
  final Future<DownloadResult> _done;
  final Future<void> Function({bool deletePartial}) _onCancel;

  /// Progress updates. Broadcast, so a dialog and a list row can both listen.
  Stream<DownloadProgress> get progress => _progress;

  /// Completes with the result, or throws a `DownloadException`.
  Future<DownloadResult> get done => _done;

  /// Stops the download.
  ///
  /// By default the partial and its record are **kept**, so the transfer can be
  /// picked up later — that is the right behaviour for "the app is closing" or
  /// "the network went away". Pass [deletePartial] for an explicit user cancel,
  /// where leaving several hundred MB of junk behind would be surprising.
  Future<void> cancel({bool deletePartial = false}) =>
      _onCancel(deletePartial: deletePartial);
}
