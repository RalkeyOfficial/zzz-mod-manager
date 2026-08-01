import 'gb_coerce.dart';

/// The author of a mod — `_aSubmitter`.
///
/// Only the handful of fields a card or detail header actually renders. The
/// real payload carries a dozen more (points, medals, signature urls, online
/// status); leaving them unmapped keeps the surface small, which matters for an
/// undocumented API that changes without notice.
class GbSubmitter {
  const GbSubmitter({
    required this.idRow,
    this.name,
    this.profileUrl,
    this.avatarUrl,
    this.userTitle,
  });

  /// `_idRow` — the member id. Doubles as the `Generic_Submitter` filter value
  /// for "more from this author".
  final int idRow;

  /// `_sName` — the display name.
  final String? name;

  /// `_sProfileUrl` — `https://gamebanana.com/members/<idRow>`.
  final String? profileUrl;

  /// `_sAvatarUrl`.
  final String? avatarUrl;

  /// `_sUserTitle` — the self-chosen flair, e.g. "Quaso Devotee".
  final String? userTitle;

  static GbSubmitter? fromJson(Object? value) {
    final json = gbObject(value);
    if (json == null) return null;
    final id = gbInt(json['_idRow']);
    if (id == null) return null;
    return GbSubmitter(
      idRow: id,
      name: gbString(json['_sName']),
      profileUrl: gbString(json['_sProfileUrl']),
      avatarUrl: gbString(json['_sAvatarUrl']),
      userTitle: gbString(json['_sUserTitle']),
    );
  }
}
