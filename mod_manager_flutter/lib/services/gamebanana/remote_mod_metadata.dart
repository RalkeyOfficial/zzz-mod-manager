import '../../models/gamebanana/gamebanana.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/zzz_characters.dart';

/// What a mod page can contribute to a freshly-installed mod's sidecar.
///
/// The translation **out of** the wire layer: nothing downstream of this touches
/// a `Gb*` object, and every judgement about what the remote data is worth is
/// made here rather than at a save site. Whether any of it is actually written
/// is a separate decision — see `services/metadata_autofill.dart`, which never
/// overwrites something the mod already carries.
///
/// Pure and offline. The one thing it cannot do itself is the images: those are
/// urls, and our `images` array holds paths inside the mod folder, so they have
/// to be fetched. Everything else here is free — it was already in the profile
/// response the detail screen fetched to show the file list.
class RemoteModMetadata {
  const RemoteModMetadata({
    this.description,
    this.sourceUrl,
    this.tags = const [],
    this.characterId,
    this.imageUrls = const [],
  });

  /// [GbMod.text] converted from HTML to markdown, which is the only form this
  /// app's descriptions come in.
  final String? description;

  /// The mod's page url, in canonical form.
  ///
  /// Derived from the **identity** rather than read off the page. `_sProfileUrl`
  /// says the same thing, but [gameBananaModUrl] is the form
  /// [gameBananaModIdFromUrl] parses back — and the offline origin backfill does
  /// exactly that parse. Agreeing with the origin block is what stops the two
  /// from arguing about which mod this is.
  final String? sourceUrl;

  /// Author tags, flattened to `"title: value"` — minus the credit family, see
  /// [_creditTagTitle].
  final List<String> tags;

  /// The character this mod is filed under upstream, as a roster id.
  final String? characterId;

  /// Gallery images to import, cover first, capped at [maxImages].
  final List<Uri> imageUrls;

  /// Whether this page has nothing to contribute.
  ///
  /// [sourceUrl] counts, which in practice makes this **false for every real
  /// mod page** — a page always has an id. That is the honest answer rather
  /// than an oversight: a link back to where a mod came from is worth writing a
  /// sidecar for on its own. Do not exclude it to restore the early-out; the
  /// cost is one metadata read per installed mod.
  bool get isEmpty =>
      description == null &&
      sourceUrl == null &&
      tags.isEmpty &&
      characterId == null &&
      imageUrls.isEmpty;

  /// How many gallery images are worth copying into a mod folder.
  ///
  /// Not a guard against an unaffordable download — measured, GameBanana's
  /// "full size" screenshots are already web-compressed at ~115–310 KB each, so
  /// two real galleries of 15 and 26 images came to 2.3 MB and 5.5 MB against a
  /// median mod archive of 21.9 MB. The cap is about what a gallery is *for*: in
  /// a real library the user's own hand-built galleries run 1–7 images (median
  /// 3), and copying a 26-shot marketing gallery into every mod folder is
  /// clutter rather than information. Ten covers the whole gallery for most mods
  /// and truncates the outliers.
  static const int maxImages = 10;

  /// Tag title naming the author's toolchain rather than the mod.
  ///
  /// Dropped because `tags` is *structural* here — it drives the filter chips in
  /// the mods toolbar — so noise in it has a UI cost that a noisy description
  /// does not. It is also not a marginal case: 3 of the 6 distinct tag values
  /// across the captured listings are this family ("Software Used: Blender",
  /// "…: Paint.NET"), so importing them verbatim would fill a real library's
  /// filter bar with facts about Blender.
  static const String _creditTagTitle = 'software used';

  /// Reads everything useful out of a mod profile.
  ///
  /// Deliberately tolerant: every field is optional upstream, so an absent one
  /// simply contributes nothing rather than blocking the rest.
  factory RemoteModMetadata.fromMod(GbMod mod) {
    final html = mod.text;
    final markdown = html == null ? null : htmlToMarkdown(html);

    return RemoteModMetadata(
      description: (markdown == null || markdown.isEmpty) ? null : markdown,
      sourceUrl: gameBananaModUrl(mod.idRow),
      tags: [
        for (final tag in mod.tags)
          if (!_isCreditTag(tag)) tag,
      ],
      // The category, not the name or the tags. Upstream this is where the
      // author actually files the mod, and it maps cleanly: all 60 children of
      // Character Skins resolve to a roster id, while none of the 4 root
      // categories and none of the 22 Bangboo categories falsely match one.
      // `displayCategory` is most-specific-first, so this works on a listing
      // record (`_aSubCategory`) as well as a profile (`_aCategory`).
      characterId: storedCharacterId(
        detectCharacterId(mod.displayCategory?.name ?? ''),
      ),
      imageUrls: [
        for (final image in mod.images.take(maxImages))
          // Full size rather than a ladder rung. Measured: 112 of 132 captured
          // gallery images publish only `_sFile` and `_sFile100`, so
          // negotiating a size would shrink nothing but the *cover* — the one
          // image most likely to be opened full-screen in the details dialog.
          if (_httpUri(image.fullUrl) case final url?) url,
      ],
    );
  }

  /// Whether a flattened tag's *title* half names the credit family.
  ///
  /// A tag with no colon is the whole title, not "no title": [gbTags] emits a
  /// bare title when `_sValue` is missing, so `{"_sTitle": "Software Used"}`
  /// arrives here as `"Software Used"` and has to be caught by the same rule.
  static bool _isCreditTag(String tag) {
    final separator = tag.indexOf(':');
    final title = separator < 0 ? tag : tag.substring(0, separator);
    return title.trim().toLowerCase() == _creditTagTitle;
  }

  /// A parsed absolute http(s) url, or null.
  ///
  /// A [GbImage] with no `_sBaseUrl` yields a bare filename, which parses fine
  /// as a relative [Uri] and would then be fetched as garbage.
  static Uri? _httpUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isAbsolute) return null;
    return (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
  }
}
