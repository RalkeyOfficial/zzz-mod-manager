import 'gb_category.dart';
import 'gb_coerce.dart';
import 'gb_enums.dart';
import 'gb_file.dart';
import 'gb_image.dart';
import 'gb_submitter.dart';

/// A GameBanana mod record.
///
/// **One lenient type covers all three response shapes**, deliberately:
/// `Mod/Index` and `Util/Search/Results` return a compact subset,
/// `Mod/<id>/ProfilePage` returns everything, and `Mod/Multi` returns exactly
/// whichever fields `_csvProperties` asked for. Modelling those as three
/// classes would triple the parsing surface for one underlying object, and
/// would have to be reshaped again the first time a `_csvProperties` list
/// changed.
///
/// The rule that makes that safe: **[idRow] is the only required field, and a
/// null anywhere else means "not present in this response" — never "zero" and
/// never "empty".** Two consequences worth stating outright, because getting
/// them wrong is silent:
///
/// - [likeCount] etc. are `int?`. A `Multi` record that never requested likes
///   must not render as "0 likes".
/// - [files] is `List<GbFile>?` where **null means "not requested" and `[]`
///   means "genuinely none"**. An update check must never conclude a mod has no
///   files from a response it didn't ask files from.
class GbMod {
  const GbMod({
    required this.idRow,
    this.name,
    this.version,
    this.text,
    this.profileUrl,
    this.downloadUrl,
    this.dateAdded,
    this.dateModified,
    this.dateUpdated,
    this.likeCount,
    this.viewCount,
    this.downloadCount,
    this.postCount,
    this.submitter,
    this.category,
    this.subCategory,
    this.rootCategory,
    this.tags = const [],
    this.images = const [],
    this.files,
    this.archivedFiles,
    this.visibility,
    this.contentRatings = const {},
    this.hasContentRatings = false,
    this.isObsolete = false,
    this.isPrivate = false,
    this.isTrashed = false,
    this.isWithheld = false,
    this.hasFiles,
  });

  /// `_idRow` — the mod id, and the stable handle to re-query. Far more
  /// reliable than a stored url.
  final int idRow;

  /// `_sName`.
  final String? name;

  /// `_sVersion` — the mod-level version. A free-form author string, **not**
  /// semver, and often absent. Distinct from `GbFile.version`.
  final String? version;

  /// `_sText` — the description, **as HTML**. Profile responses only.
  ///
  /// Our own descriptions are markdown, so this needs converting before it goes
  /// anywhere near a markdown widget.
  final String? text;

  /// `_sProfileUrl` — `https://gamebanana.com/mods/<idRow>`.
  final String? profileUrl;

  /// `_sDownloadUrl` — the mod's download page, not a direct file link.
  final String? downloadUrl;

  /// `_tsDateAdded` — first published.
  final DateTime? dateAdded;

  /// `_tsDateModified` — any edit, including cosmetic ones. Noisy.
  final DateTime? dateModified;

  /// `_tsDateUpdated` — a real content update. The comparator for update checks.
  final DateTime? dateUpdated;

  final int? likeCount;
  final int? viewCount;
  final int? downloadCount;
  final int? postCount;

  /// `_aSubmitter`.
  final GbSubmitter? submitter;

  /// `_aCategory` — the mod's own (often sub-) category. Profile responses.
  final GbCategoryRef? category;

  /// `_aSubCategory` — the specific category on **listing** responses, and the
  /// only place a listing names it.
  ///
  /// Worth parsing because for ZZZ this is usually the *character* ("Ellen Joe")
  /// while [rootCategory] is only ever the bland parent ("Character Skins").
  /// Absent on mods filed directly under a root category, so it is not a
  /// replacement for [rootCategory] — see [displayCategory].
  final GbCategoryRef? subCategory;

  /// `_aRootCategory` — the top-level category. Listing responses.
  final GbCategoryRef? rootCategory;

  /// `_aTags`, normalised to one flat `"title: value"` string per tag.
  ///
  /// Frequently empty (4 of 20 captured records carry any), and too unreliable
  /// for character detection on its own — the category is what says which
  /// character a mod is for. The wire shape differs between listing and profile
  /// responses; [gbTags] absorbs that.
  final List<String> tags;

  /// `_aPreviewMedia._aImages` — the gallery. First entry is the cover.
  final List<GbImage> images;

  /// `_aFiles`. **Null = not requested; `[]` = none published.**
  final List<GbFile>? files;

  /// `_aArchivedFiles` — superseded but still downloadable. Same null rule.
  ///
  /// Worth matching against as well as [files]: an old local install matches a
  /// superseded file more often than the current one.
  final List<GbFile>? archivedFiles;

  /// `_sInitialVisibility`. Null when the response omitted the field entirely —
  /// use [effectiveVisibility] for rendering decisions.
  final GbVisibility? visibility;

  /// `_aContentRatings` — `code -> server-English label`, e.g.
  /// `{"sa": "Skimpy Attire"}`. Empty on unrated mods.
  final Map<String, String> contentRatings;

  /// `_bHasContentRatings` — present on listing records, which don't carry the
  /// ratings map itself.
  final bool hasContentRatings;

  /// `_bIsObsolete` — the author flagged this superseded. **Not** the same as
  /// the mod being gone; it still exists and still downloads.
  final bool isObsolete;

  final bool isPrivate;
  final bool isTrashed;
  final bool isWithheld;

  /// `_bHasFiles` — listing records only.
  final bool? hasFiles;

  /// Whether the mod is no longer publicly retrievable upstream.
  ///
  /// Read from the explicit flags rather than inferred from a 404, which is
  /// only the crudest case. Distinct from [isObsolete].
  bool get isRemoteMissing => isPrivate || isTrashed || isWithheld;

  /// The visibility to render by, **failing closed**: an absent field is
  /// treated as [GbVisibility.warn] rather than assumed safe.
  GbVisibility get effectiveVisibility => visibility ?? GbVisibility.warn;

  /// The category to display, most specific first.
  ///
  /// The three spellings are populated by different responses — [category] by a
  /// profile, [subCategory] by a listing — so this is what lets one card widget
  /// render a record from either without knowing where it came from.
  GbCategoryRef? get displayCategory => category ?? subCategory ?? rootCategory;

  /// The cover image, if the response carried a gallery.
  GbImage? get coverImage => images.isEmpty ? null : images.first;

  /// Every file we know about, current and archived, for hash/id matching.
  /// Null only when neither list was requested.
  List<GbFile>? get allFiles {
    if (files == null && archivedFiles == null) return null;
    return [...?files, ...?archivedFiles];
  }

  static GbMod? fromJson(Map<String, dynamic> json) {
    final id = gbInt(json['_idRow']);
    if (id == null) return null;

    final preview = gbObject(json['_aPreviewMedia']);
    return GbMod(
      idRow: id,
      name: gbString(json['_sName']),
      version: gbString(json['_sVersion']),
      text: gbString(json['_sText']),
      profileUrl: gbString(json['_sProfileUrl']),
      downloadUrl: gbString(json['_sDownloadUrl']),
      dateAdded: gbTimestamp(json['_tsDateAdded']),
      dateModified: gbTimestamp(json['_tsDateModified']),
      dateUpdated: gbTimestamp(json['_tsDateUpdated']),
      likeCount: gbInt(json['_nLikeCount']),
      viewCount: gbInt(json['_nViewCount']),
      downloadCount: gbInt(json['_nDownloadCount']),
      postCount: gbInt(json['_nPostCount']),
      submitter: GbSubmitter.fromJson(json['_aSubmitter']),
      category: GbCategoryRef.fromJson(json['_aCategory']),
      subCategory: GbCategoryRef.fromJson(json['_aSubCategory']),
      rootCategory: GbCategoryRef.fromJson(json['_aRootCategory']),
      tags: gbTags(json['_aTags']),
      images: preview == null
          ? const []
          : <GbImage>[
              for (final image in gbObjects(preview['_aImages']))
                if (GbImage.fromJson(image) case final parsed?) parsed,
            ],
      // Absent key -> null (not requested); present key -> a list, even empty.
      files: json.containsKey('_aFiles') ? GbFile.listFrom(json['_aFiles']) : null,
      archivedFiles: json.containsKey('_aArchivedFiles')
          ? GbFile.listFrom(json['_aArchivedFiles'])
          : null,
      visibility: json.containsKey('_sInitialVisibility')
          ? GbVisibility.parse(json['_sInitialVisibility'])
          : null,
      contentRatings: gbStringMap(json['_aContentRatings']),
      hasContentRatings: gbBool(
        json['_bHasContentRatings'],
        orElse: gbStringMap(json['_aContentRatings']).isNotEmpty,
      ),
      isObsolete: gbBool(json['_bIsObsolete']),
      isPrivate: gbBool(json['_bIsPrivate']),
      isTrashed: gbBool(json['_bIsTrashed']),
      isWithheld: gbBool(json['_bIsWithheld']),
      hasFiles: json.containsKey('_bHasFiles') ? gbBool(json['_bHasFiles']) : null,
    );
  }
}
