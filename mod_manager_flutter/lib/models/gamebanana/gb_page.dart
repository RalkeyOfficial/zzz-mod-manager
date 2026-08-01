import 'dart:convert';

import 'gb_coerce.dart';
import 'gb_exceptions.dart';

/// One page of a paginated listing — the `_aMetadata` / `_aRecords` envelope.
class GbPage<T> {
  const GbPage({
    required this.records,
    this.recordCount,
    this.perPage,
    this.isComplete = false,
  });

  final List<T> records;

  /// `_nRecordCount` — total matches across all pages, the paging denominator.
  final int? recordCount;

  /// `_nPerpage` **as the server actually applied it**.
  ///
  /// Never assume the value you requested: `Util/Search/Results` silently caps
  /// at 15 with no error, so asking for 30 and getting 15 back is normal and
  /// only this field reveals it.
  final int? perPage;

  /// `_bIsComplete` — whether this page exhausts the result set.
  final bool isComplete;

  bool get isEmpty => records.isEmpty;

  /// Total pages, when the server told us enough to work it out.
  int? get pageCount {
    final total = recordCount;
    final size = perPage;
    if (total == null || size == null || size <= 0) return null;
    return (total / size).ceil();
  }
}

/// Decodes a response body, mapping any JSON failure to [GbFormatException].
///
/// A non-JSON body is a real scenario, not paranoia: a Cloudflare interstitial
/// or an empty response both arrive here as text, and a raw `FormatException`
/// escaping this layer would surface far from its cause.
Object? gbDecode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException catch (e) {
    throw GbFormatException(
      'Response was not valid JSON: ${e.message}',
      bodySnippet: _snippet(body),
    );
  }
}

/// Parses the `{_aMetadata, _aRecords}` envelope used by `Mod/Index`,
/// `Util/Search/Results`, `Subfeed` and `Updates`.
///
/// Throws [GbFormatException] when handed a bare array. That strictness is the
/// point: quietly tolerating the wrong shape would surface later as an
/// inexplicably empty results grid rather than as a parse error.
GbPage<T> parseEnvelope<T>(String body, T? Function(Map<String, dynamic>) item) {
  final decoded = gbDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw GbFormatException(
      'Expected a {_aMetadata, _aRecords} envelope but got '
      '${decoded.runtimeType}. Endpoints like Mod/Categories and Mod/Multi '
      'return a bare array — use parseBareList for those.',
      bodySnippet: _snippet(body),
    );
  }
  if (!decoded.containsKey('_aRecords')) {
    throw GbFormatException(
      'Envelope has no _aRecords key.',
      bodySnippet: _snippet(body),
    );
  }

  final metadata = gbObject(decoded['_aMetadata']) ?? const {};
  return GbPage<T>(
    records: <T>[
      for (final record in gbObjects(decoded['_aRecords']))
        if (item(record) case final parsed?) parsed,
    ],
    recordCount: gbInt(metadata['_nRecordCount']),
    perPage: gbInt(metadata['_nPerpage']),
    isComplete: gbBool(metadata['_bIsComplete']),
  );
}

/// Parses the **bare array** returned by `Mod/Categories` and `Mod/Multi`.
///
/// These two endpoints have no envelope at all, which is exactly why there is
/// no single generic parser here.
List<T> parseBareList<T>(String body, T? Function(Map<String, dynamic>) item) {
  final decoded = gbDecode(body);
  if (decoded is! List) {
    throw GbFormatException(
      'Expected a bare JSON array but got ${decoded.runtimeType}. '
      'Most endpoints wrap results in an _aRecords envelope — use '
      'parseEnvelope for those.',
      bodySnippet: _snippet(body),
    );
  }
  return <T>[
    for (final entry in decoded)
      if (entry is Map<String, dynamic>)
        if (item(entry) case final parsed?) parsed,
  ];
}

/// Parses a response whose top level is a single object, e.g. `ProfilePage`.
Map<String, dynamic> parseObject(String body) {
  final decoded = gbDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw GbFormatException(
      'Expected a JSON object but got ${decoded.runtimeType}.',
      bodySnippet: _snippet(body),
    );
  }
  return decoded;
}

String _snippet(String body) =>
    body.length <= 200 ? body : '${body.substring(0, 200)}…';
