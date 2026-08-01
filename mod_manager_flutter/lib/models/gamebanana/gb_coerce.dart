/// Coercion helpers for GameBanana's `apiv11` wire format.
///
/// The API's field-prefix convention (`_s` string, `_n` number, `_b` bool,
/// `_ts` unix seconds, `_a` array/object) is a naming *habit*, not a guarantee:
/// `_nStatus` arrives as the string `"0"`, and a `_ts…` of `0` means "never"
/// rather than 1970. These helpers absorb those quirks once, so no DTO has to
/// remember them and no caller has to re-discover them.
///
/// Everything here is pure and null-tolerant: a field that is absent, null or
/// the wrong type is never an error at this layer. The API is undocumented and
/// shifts without notice, so a surprising value must degrade to "we don't know"
/// instead of throwing halfway through parsing a page of results.
library;

/// Reads an `_n…`/`_id…` field, tolerating the string form.
///
/// `_nStatus` is a documented string despite the `_n` prefix, so any numeric
/// field is treated as possibly-stringly-typed.
int? gbInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Reads a `_b…` field, tolerating `0`/`1` and `"0"`/`"1"`.
bool gbBool(Object? value, {bool orElse = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true' || '1':
        return true;
      case 'false' || '0' || '':
        return false;
    }
  }
  return orElse;
}

/// Reads a `_ts…` field as a UTC [DateTime].
///
/// **A value of `0` means "never" and yields null, not 1970-01-01.** Returning
/// the epoch would make every never-updated mod look ancient to the update
/// comparator, which is exactly the kind of silent wrongness that surfaces much
/// later as "why does it think everything has an update?".
DateTime? gbTimestamp(Object? value) {
  final seconds = gbInt(value);
  if (seconds == null || seconds == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Reads a `_s…` field, trimmed.
///
/// An empty string collapses to null: an empty `_sVersion` means "this file has
/// no version", not "its version is the empty string". Callers can then use a
/// plain null check instead of every one of them remembering to test `isEmpty`.
String? gbString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Reads an `_a…` array of objects, skipping any entry that isn't one.
List<Map<String, dynamic>> gbObjects(Object? value) {
  if (value is! List) return const [];
  return <Map<String, dynamic>>[
    for (final entry in value)
      if (entry is Map<String, dynamic>) entry,
  ];
}

/// Reads a single nested `_a…` object, or null when absent.
Map<String, dynamic>? gbObject(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// Reads an `_a…` array of plain strings, e.g. `_aTags`.
///
/// Tags come back as bare strings (`"cheongsam: ellen"`), not objects — unlike
/// most `_a…` fields, which is why this exists separately from [gbObjects].
List<String> gbStrings(Object? value) {
  if (value is! List) return const [];
  return <String>[
    for (final entry in value)
      if (gbString(entry) case final text?) text,
  ];
}

/// Reads a `code -> label` map, e.g. `_aContentRatings`
/// (`{"sa": "Skimpy Attire"}`).
///
/// The *codes* are the stable, translatable part; the labels are server English
/// and should not be shown to users verbatim in a localized UI.
Map<String, String> gbStringMap(Object? value) {
  if (value is! Map) return const {};
  final result = <String, String>{};
  value.forEach((key, label) {
    final code = gbString(key);
    final text = gbString(label);
    if (code != null && text != null) result[code] = text;
  });
  return result;
}
