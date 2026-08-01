import 'dart:convert';
import 'dart:io';

/// What has to survive an app restart for a half-finished download to resume.
///
/// Stored as one small JSON file beside its `.part`, rather than as entries in
/// `config.json`: that file is rewritten wholesale on every setting change, so a
/// record churning during a download could race with — and lose — the user's
/// settings. A sidecar per download also means there is no index to drift out of
/// sync with the directory, and cleanup is just "delete both files".
///
/// Note what is deliberately **absent: bytes-received.** `File.length()` on the
/// `.part` is authoritative, free, and cannot disagree with reality after a
/// crash; a stored counter can, and would need a write per chunk to be even
/// approximately right.
///
/// The resolved CDN url is absent for the same reason it is never needed:
/// `Range` survives both redirect hops, so a resume re-requests the original
/// `/dl/<id>` and lets the CDN route it again.
class PartialDownload {
  const PartialDownload({
    required this.url,
    required this.filename,
    this.fileId,
    this.expectedSize,
    this.etag,
    this.startedAt,
    this.updatedAt,
  });

  /// The **original** download url, not a resolved CDN address.
  final String url;

  /// Final filename this will be promoted to.
  final String filename;

  /// GameBanana file id, when the caller knew it.
  final int? fileId;

  /// Total size from the first response, for the progress denominator.
  final int? expectedSize;

  /// Validator sent back as `If-Range`. Stable across CDN nodes, so a resume
  /// landing on a different node won't spuriously restart.
  final String? etag;

  final DateTime? startedAt;
  final DateTime? updatedAt;

  static const int currentVersion = 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': currentVersion,
        'url': url,
        'filename': filename,
        if (fileId != null) 'file_id': fileId,
        if (expectedSize != null) 'expected_size': expectedSize,
        if (etag != null) 'etag': etag,
        if (startedAt != null) 'started_at': startedAt!.toUtc().toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
      };

  /// Parses a record, returning null for anything unusable.
  ///
  /// Never throws. A record we can't read is not a crash: the partial is simply
  /// discarded and the download starts over, which costs bandwidth but is always
  /// correct. Being strict here is cheap; being fragile is not.
  static PartialDownload? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    if (raw['version'] != currentVersion) return null;

    final url = raw['url'];
    final filename = raw['filename'];
    if (url is! String || url.isEmpty) return null;
    if (filename is! String || filename.isEmpty) return null;

    return PartialDownload(
      url: url,
      filename: filename,
      fileId: raw['file_id'] is int ? raw['file_id'] as int : null,
      expectedSize:
          raw['expected_size'] is int ? raw['expected_size'] as int : null,
      etag: raw['etag'] is String ? raw['etag'] as String : null,
      startedAt: _date(raw['started_at']),
      updatedAt: _date(raw['updated_at']),
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  PartialDownload copyWith({int? expectedSize, String? etag, DateTime? updatedAt}) =>
      PartialDownload(
        url: url,
        filename: filename,
        fileId: fileId,
        expectedSize: expectedSize ?? this.expectedSize,
        etag: etag ?? this.etag,
        startedAt: startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Reads a record from disk, or null when missing or unreadable.
  static Future<PartialDownload?> read(File file) async {
    try {
      if (!await file.exists()) return null;
      return fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// Writes a record. Returns false rather than throwing — a download that
  /// can't record itself should still proceed, it just won't be resumable.
  Future<bool> write(File file) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Nothing useful to do; the sweep will get it later.
    }
  }
}
