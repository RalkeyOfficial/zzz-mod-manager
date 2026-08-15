import 'gb_coerce.dart';

/// One entry of `_aPreviewContent` — see [listFromPreviewContent] for the two
/// container spellings it arrives under.
///
/// GameBanana stores a base url plus a family of pre-scaled filenames:
///
/// ```json
/// { "_sBaseUrl": "https://images.gamebanana.com/img/ss/mods",
///   "_sFile":    "6a6d7bb20324f.jpg",
///   "_sFile220": "sgi_common_thumbs_6a6d7bb20324f_220.webp", "_hFile220": 137,
///   "_sFile530": "sgi_common_thumbs_6a6d7bb20324f_530.webp", "_hFile530": 331 }
/// ```
///
/// **The ladder is not uniform**, so variants are discovered by scanning the
/// keys rather than assuming a fixed 100/220/530/800 set: measured on apiv13, a
/// cover publishes 220 and 530 while the gallery images behind it publish only
/// 100. Scanning means a size the server stops emitting is naturally absent
/// instead of being turned into a fabricated filename that 404s, and a new size
/// costs no code change.
///
/// Two apiv13 details worth knowing before reading a raw response:
///
/// - `_sFile` is still the original jpeg, while every *variant* is webp under a
///   shared `sgi_common_thumbs_<hash>_<size>` name. Nothing here parses those
///   names — they are opaque strings joined to [baseUrl].
/// - **`_sFileNNNSfw` keys are ignored on purpose.** apiv13 publishes a
///   server-pixelated copy (only at 220, and only for `warn`/`hide` mods); this
///   app applies its own blur in `GbThumbnail` instead, so their absence here is
///   a decision rather than an oversight. See `docs/gamebanana-api.md` §7.
class GbImage {
  const GbImage({
    required this.baseUrl,
    required this.file,
    this.variants = const {},
    this.dimensions = const {},
  });

  /// `_sBaseUrl`, with no trailing slash.
  final String baseUrl;

  /// `_sFile` — the full-size filename. Always present.
  final String file;

  /// Width -> filename, parsed from every `_sFileNNN` key.
  final Map<int, String> variants;

  /// Width -> `(width, height)`, for every variant whose height was supplied.
  final Map<int, ({int width, int height})> dimensions;

  static final RegExp _variantKey = RegExp(r'^_sFile(\d+)$');

  /// Every image in an `_aPreviewContent` object, cover first.
  ///
  /// Handles **both container spellings**, which is the one apiv13 quirk that
  /// has to live somewhere: a profile sends `screenshots` — the full gallery, as
  /// an array — while `Mod/Index`, `Util/Search/Results`, `Subfeed` and
  /// `TopSubs` send a single `screenshot` **object** holding only the cover.
  /// Reading just one of the two keys therefore fails silently, with a gallery
  /// that is empty rather than an error.
  static List<GbImage> listFromPreviewContent(Object? raw) {
    final content = gbObject(raw);
    if (content == null) return const [];
    return <GbImage>[
      for (final entry in gbObjects(content['screenshots']))
        if (GbImage.fromJson(entry) case final parsed?) parsed,
      if (gbObject(content['screenshot']) case final single?)
        if (GbImage.fromJson(single) case final parsed?) parsed,
    ];
  }

  static GbImage? fromJson(Map<String, dynamic> json) {
    final file = gbString(json['_sFile']);
    if (file == null) return null;

    final variants = <int, String>{};
    final dimensions = <int, ({int width, int height})>{};
    for (final entry in json.entries) {
      final match = _variantKey.firstMatch(entry.key);
      if (match == null) continue;
      final width = int.parse(match.group(1)!);
      final name = gbString(entry.value);
      if (name == null) continue;
      variants[width] = name;
      // apiv13 stopped sending `_wFileNNN`, so the width comes from the rung
      // itself — which is what it always was: `_wFileNNN == NNN` held on every
      // apiv11 sample measured. The explicit value still wins where one is sent,
      // so this reads an older response identically.
      final h = gbInt(json['_hFile$width']);
      if (h != null) {
        dimensions[width] = (
          width: gbInt(json['_wFile$width']) ?? width,
          height: h,
        );
      }
    }

    return GbImage(
      baseUrl: (gbString(json['_sBaseUrl']) ?? '').replaceAll(RegExp(r'/+$'), ''),
      file: file,
      variants: Map.unmodifiable(variants),
      dimensions: Map.unmodifiable(dimensions),
    );
  }

  String _url(String name) => baseUrl.isEmpty ? name : '$baseUrl/$name';

  /// The full-size image. Always resolvable — this is the ladder's floor.
  String get fullUrl => _url(file);

  /// The smallest variant at least [minWidth] wide, falling back to [fullUrl].
  ///
  /// Never invents a filename: if nothing that large was published, the caller
  /// gets the original rather than a url that 404s.
  String urlAtLeast(int minWidth) {
    final widths = variants.keys.where((w) => w >= minWidth).toList()..sort();
    return widths.isEmpty ? fullUrl : _url(variants[widths.first]!);
  }

  /// The largest variant no wider than [maxWidth], falling back to [fullUrl].
  String urlAtMost(int maxWidth) {
    final widths = variants.keys.where((w) => w <= maxWidth).toList()..sort();
    return widths.isEmpty ? fullUrl : _url(variants[widths.last]!);
  }

  /// A grid-card thumbnail.
  String get thumbnailUrl => urlAtMost(220);
}
