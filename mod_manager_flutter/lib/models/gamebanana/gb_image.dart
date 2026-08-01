import 'gb_coerce.dart';

/// One entry of `_aPreviewMedia._aImages`.
///
/// GameBanana stores a base url plus a family of pre-scaled filenames:
///
/// ```json
/// { "_sBaseUrl": "https://images.gamebanana.com/img/ss/mods",
///   "_sFile":    "6693f0120d40f.jpg",
///   "_sFile100": "100-_6693f0120d40f.jpg",  "_wFile100": 100, "_hFile100": 56,
///   "_sFile220": "220-90_6693f0120d40f.jpg", … }
/// ```
///
/// **Only `_sFile` and `_sFile100` are guaranteed**; any larger variant may be
/// missing on any given image. Variants are therefore discovered by scanning
/// the keys rather than assuming the usual 100/220/530/800 ladder — a size the
/// server stops emitting is then naturally absent instead of being turned into
/// a fabricated filename that 404s, and a new size costs no code change.
class GbImage {
  const GbImage({
    required this.baseUrl,
    required this.file,
    this.variants = const {},
    this.dimensions = const {},
    this.type,
  });

  /// `_sBaseUrl`, with no trailing slash.
  final String baseUrl;

  /// `_sFile` — the full-size filename. Always present.
  final String file;

  /// Width -> filename, parsed from every `_sFileNNN` key.
  final Map<int, String> variants;

  /// Width -> `(width, height)`, where `_wFileNNN`/`_hFileNNN` were supplied.
  final Map<int, ({int width, int height})> dimensions;

  /// `_sType`, e.g. `screenshot`.
  final String? type;

  static final RegExp _variantKey = RegExp(r'^_sFile(\d+)$');

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
      final w = gbInt(json['_wFile$width']);
      final h = gbInt(json['_hFile$width']);
      if (w != null && h != null) dimensions[width] = (width: w, height: h);
    }

    return GbImage(
      baseUrl: (gbString(json['_sBaseUrl']) ?? '').replaceAll(RegExp(r'/+$'), ''),
      file: file,
      variants: Map.unmodifiable(variants),
      dimensions: Map.unmodifiable(dimensions),
      type: gbString(json['_sType']),
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
