import '../../models/gamebanana/gamebanana.dart';
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
    this.tags = const [],
    this.characterId,
    this.imageUrls = const [],
  });

  /// [GbMod.text] converted from HTML to markdown, which is the only form this
  /// app's descriptions come in.
  final String? description;

  /// Author tags, flattened to `"title: value"` — minus the credit family, see
  /// [_creditTagTitle].
  final List<String> tags;

  /// The character this mod is filed under upstream, as a roster id.
  final String? characterId;

  /// Gallery images to import, cover first, capped at [maxImages].
  final List<Uri> imageUrls;

  /// Whether this page has nothing to contribute.
  ///
  /// True for a page with no description, tags, character or gallery, which
  /// says nothing about whether the mod is *known*: which mod it is was written
  /// by the install itself, into the origin block, and does not pass through
  /// here at all.
  bool get isEmpty =>
      description == null &&
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

  /// The roster id a GameBanana category name stands for, or null.
  ///
  /// The category, not the mod's name or tags. Upstream this is where the author
  /// actually files the mod, picked from a list, and it maps cleanly: all 60
  /// children of Character Skins resolve to a roster id, while none of the 4 root
  /// categories and none of the 22 Bangboo categories falsely match one.
  ///
  /// Only for a name known to be a Character Skins child: a mod's agent goes through [characterIdForMod].
  static String? characterIdForCategory(String? name) => storedCharacterId(detectCharacterId(name ?? ''));

  /// The roster id of the agent [mod] is filed under, or null.
  ///
  /// The type first: only a Character Skins mod is an agent's. A Bangboo, UI or Other/Misc child category whose name
  /// holds an agent's term is that type, never the agent, so it maps to nothing and installs under Unassigned, and so
  /// does a record that names no type.
  static String? characterIdForMod(GbMod mod) {
    if (mod.typeCategoryId != kCharacterSkinsCategoryId) return null;
    return characterIdForCategory(mod.displayCategory?.name);
  }

  /// Reads everything useful out of a mod profile.
  ///
  /// Deliberately tolerant: every field is optional upstream, so an absent one
  /// simply contributes nothing rather than blocking the rest.
  factory RemoteModMetadata.fromMod(GbMod mod) {
    final html = mod.text;
    final markdown = html == null ? null : htmlToMarkdown(html);

    return RemoteModMetadata(
      description: (markdown == null || markdown.isEmpty) ? null : markdown,
      tags: [
        for (final tag in mod.tags)
          if (!_isCreditTag(tag)) tag,
      ],
      characterId: characterIdForMod(mod),
      imageUrls: [
        for (final image in mod.images.take(maxImages))
          // Full size rather than a ladder rung. Measured: 112 of 132 captured
          // gallery images publish only `_sFile` and `_sFile100`, so
          // negotiating a size would shrink nothing but the *cover* — the one
          // image most likely to be opened full-screen from the details panel.
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
