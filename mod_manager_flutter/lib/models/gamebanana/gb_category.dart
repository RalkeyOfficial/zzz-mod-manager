import 'gb_coerce.dart';

/// A category as embedded **on a mod** — `_aCategory` on a profile, or
/// `_aRootCategory` / `_aSubCategory` on a listing record.
///
/// The two spellings do not carry the same fields: a profile's `_aCategory`
/// includes `_idRow`, but a listing's `_aRootCategory` is only
/// `{_sName, _sProfileUrl, _sIconUrl}` — **no id at all**. Since the id is what
/// the `Generic_Category` browse filter needs, [idRow] falls back to parsing it
/// out of `_sProfileUrl` (`https://gamebanana.com/mods/cats/29874`), which is
/// the only place a listing exposes it.
class GbCategoryRef {
  const GbCategoryRef({
    this.idRow,
    this.name,
    this.profileUrl,
    this.iconUrl,
    this.isObsolete = false,
  });

  /// `_idRow`, or the id recovered from [profileUrl]. Null when neither exists.
  final int? idRow;

  /// `_sName`, e.g. "Ellen Joe" or "Other/Misc".
  final String? name;

  /// `_sProfileUrl` — `https://gamebanana.com/mods/cats/<id>`.
  final String? profileUrl;

  /// `_sIconUrl`.
  final String? iconUrl;

  /// `_bIsObsolete`.
  final bool isObsolete;

  static final RegExp _catUrlId = RegExp(r'/mods/cats/(\d+)');

  /// Extracts a category id from a `…/mods/cats/<id>` url.
  static int? idFromUrl(String? url) {
    if (url == null) return null;
    final match = _catUrlId.firstMatch(url);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static GbCategoryRef? fromJson(Object? value) {
    final json = gbObject(value);
    if (json == null) return null;
    final profileUrl = gbString(json['_sProfileUrl']);
    return GbCategoryRef(
      idRow: gbInt(json['_idRow']) ?? idFromUrl(profileUrl),
      name: gbString(json['_sName']),
      profileUrl: profileUrl,
      iconUrl: gbString(json['_sIconUrl']),
      isObsolete: gbBool(json['_bIsObsolete']),
    );
  }
}

/// A node of the category tree, as returned by `Mod/Categories`.
///
/// Kept separate from [GbCategoryRef] rather than merged: this endpoint spells
/// the link `_sUrl` (not `_sProfileUrl`) and is the only source of the counts
/// below. Folding both into one class would force those counts nullable and
/// hide a real guarantee — here they are always present.
///
/// For ZZZ the roots are Character Skins (`30305`), Bangboo Skins (`30702`),
/// Other/Misc (`29874`) and UI (`30395`); the 60 children of Character Skins
/// are effectively the live character roster, which is what the browse screen's
/// character filter is built from.
class GbCategoryNode {
  const GbCategoryNode({
    required this.idRow,
    this.name,
    this.url,
    this.iconUrl,
    this.itemCount = 0,
    this.categoryCount = 0,
    this.isObsolete = false,
  });

  /// `_idRow` — the value to pass as the `Generic_Category` filter.
  final int idRow;

  /// `_sName`.
  final String? name;

  /// `_sUrl` — note the spelling; this endpoint does not use `_sProfileUrl`.
  final String? url;

  /// `_sIconUrl`.
  final String? iconUrl;

  /// `_nItemCount` — mods directly in this category.
  final int itemCount;

  /// `_nCategoryCount` — number of child categories.
  final int categoryCount;

  /// `_bIsObsolete`.
  final bool isObsolete;

  /// Whether this node has children worth fetching.
  bool get hasChildren => categoryCount > 0;

  static GbCategoryNode? fromJson(Map<String, dynamic> json) {
    final id = gbInt(json['_idRow']);
    if (id == null) return null;
    return GbCategoryNode(
      idRow: id,
      name: gbString(json['_sName']),
      url: gbString(json['_sUrl']),
      iconUrl: gbString(json['_sIconUrl']),
      itemCount: gbInt(json['_nItemCount']) ?? 0,
      categoryCount: gbInt(json['_nCategoryCount']) ?? 0,
      isObsolete: gbBool(json['_bIsObsolete']),
    );
  }
}
