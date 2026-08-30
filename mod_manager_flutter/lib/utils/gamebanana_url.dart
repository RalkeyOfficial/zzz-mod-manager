/// Recovering a GameBanana **mod id** from a url.
///
/// Lives in `utils/` rather than inside the API client on purpose: the offline
/// metadata backfill parses each mod's stored `source_url` during an ordinary
/// folder scan, which runs on every launch and must never touch the network.
/// This is a pure string function with no client and no I/O.
///
/// It is deliberately strict. `source_url` is a free-form field a human typed,
/// so it may hold a collection link, a Drive link, a file link, or a different
/// mod entirely — and a wrong id silently binds a local folder to an unrelated
/// remote mod, after which an "update" would overwrite it with another mod's
/// files. Returning null costs nothing; a wrong answer is expensive.
library;

const Set<String> _gameBananaHosts = {
  'gamebanana.com',
  'www.gamebanana.com',
};

/// The value `ModOrigin.source` carries for a mod tracked on GameBanana.
///
/// Lives here rather than next to `ModOrigin` because `source` is a *service*
/// discriminator that future-proofs for other sources — the model stays
/// generic, and everything GameBanana-specific about identity is in this file,
/// where offline code can reach it without the API client.
///
/// **The only spelling of it.** Four write sites now — the backfill, the
/// resolve dialog, an install and an update — and a typo in any of them would
/// create a silent second, unqueryable service rather than an error.
const String gameBananaSource = 'gamebanana';

/// Extracts the mod id from a GameBanana **mod page** url, or null.
///
/// Accepted:
/// - `https://gamebanana.com/mods/531649` (plus trailing slash, `?query`,
///   `#fragment`, `http://`, `www.`, and a missing scheme)
/// - `https://gamebanana.com/mods/download/531649`
///
/// Rejected — each returns null:
/// - **`https://gamebanana.com/dl/1770600`** — that is a *file* id, not a mod
///   id. The two are different id spaces, and reading one as the other is the
///   exact mis-binding described above.
/// - `https://gamebanana.com/mods/cats/30305` — a category.
/// - `https://gamebanana.com/games/19567`, member pages, any other host, and
///   anything unparseable.
int? gameBananaModIdFromUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  // Tolerate a pasted url with no scheme ("gamebanana.com/mods/531649"),
  // which Uri would otherwise read as a bare path with no host.
  final normalized =
      trimmed.contains('://') ? trimmed : 'https://$trimmed';

  final Uri uri;
  try {
    uri = Uri.parse(normalized);
  } on FormatException {
    return null;
  }

  if (!_gameBananaHosts.contains(uri.host.toLowerCase())) return null;

  final segments =
      uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.length < 2 || segments.first.toLowerCase() != 'mods') {
    return null;
  }

  // /mods/<id> or /mods/download/<id> — and nothing else. In particular this
  // rejects /mods/cats/<id>, whose second segment is not a number.
  final candidate = switch (segments.length) {
    2 => segments[1],
    3 when segments[1].toLowerCase() == 'download' => segments[2],
    _ => null,
  };
  if (candidate == null) return null;

  final id = int.tryParse(candidate);
  return (id == null || id <= 0) ? null : id;
}

/// Extracts the **file** id from a GameBanana download link, or null.
///
/// Accepted: `https://gamebanana.com/dl/1701141` and the mod-manager form
/// `https://gamebanana.com/mmdl/1701141`, with the same scheme/host tolerance as
/// [gameBananaModIdFromUrl].
///
/// **This cannot be turned into a mod id.** Probed against the live API
/// (2026-08-08, re-confirmed on apiv13 2026-08-15): `File/<id>` returns the
/// file record — name, size, date,
/// md5, scan results, even its archive tree — and carries no owning mod
/// anywhere; `_sProfileUrl` on a File comes back as the broken
/// `https://gamebanana.com//<id>`, and the legacy Core API's `File` fields list
/// offers nothing better. So a `/dl/` link is only useful **once the mod is
/// already known**, where it picks a row out of that mod's file list. Never
/// write it to `source_url`, which stays mod-page-only.
int? gameBananaFileIdFromUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final normalized = trimmed.contains('://') ? trimmed : 'https://$trimmed';

  final Uri uri;
  try {
    uri = Uri.parse(normalized);
  } on FormatException {
    return null;
  }

  if (!_gameBananaHosts.contains(uri.host.toLowerCase())) return null;

  final segments =
      uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.length != 2) return null;
  final prefix = segments.first.toLowerCase();
  if (prefix != 'dl' && prefix != 'mmdl') return null;

  final id = int.tryParse(segments[1]);
  return (id == null || id <= 0) ? null : id;
}

/// Whether [url] points at GameBanana at all.
///
/// Useful for deciding whether a stored `source_url` is even worth trying to
/// resolve, without claiming it identifies a mod.
bool isGameBananaUrl(String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return false;
  final normalized = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  try {
    return _gameBananaHosts.contains(Uri.parse(normalized).host.toLowerCase());
  } on FormatException {
    return false;
  }
}

/// The canonical mod-page url for [modId].
///
/// `source_url` stays user-facing and mod-page-only — machine handles and
/// `/dl/<fileid>` links belong in the origin block, never here — so this is
/// what a resolved id normalises back to.
String gameBananaModUrl(int modId) => 'https://gamebanana.com/mods/$modId';
