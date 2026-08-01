import 'gb_coerce.dart';

/// How GameBanana asks a client to present a mod on first view
/// (`_sInitialVisibility`).
///
/// The API applies **no** content filtering of its own: adult mods are returned
/// to anonymous callers like any other and their files download without a
/// session. GameBanana ships this rendering hint instead and trusts the client
/// to honour it, which makes the filter ours to implement.
enum GbVisibility {
  /// Render normally.
  show,

  /// Render behind a blur / reveal-on-click, which is what the site itself does.
  warn,

  /// Hide by default; only reveal on an explicit user action.
  hide;

  /// Parses `_sInitialVisibility`, **failing closed**.
  ///
  /// A value we don't recognise maps to [warn] rather than [show]: a new hint
  /// string appearing upstream must not silently un-blur adult content. Note
  /// this is for a *present but unrecognised* value — an entirely absent field
  /// is modelled as null by the caller, see `GbMod.effectiveVisibility`.
  static GbVisibility parse(Object? value) {
    return switch (gbString(value)?.toLowerCase()) {
      'show' => GbVisibility.show,
      'hide' => GbVisibility.hide,
      _ => GbVisibility.warn,
    };
  }

  /// Whether this mod needs any content treatment at all.
  bool get needsContentWarning => this != GbVisibility.show;
}

/// The `_sSort` vocabulary accepted by `Mod/Index`.
///
/// Modelled as an enum because the API's error responses never enumerate the
/// valid values — a typo'd sort string is a runtime 400 with no hint about what
/// would have worked. Every alias here has been verified against the live API;
/// plausible-looking ones that do *not* exist (`Generic_LatestAdded`,
/// `Generic_Alphabetical`, `Generic_Featured`, `Generic_Random`) are rejected.
enum GbModSort {
  newest('Generic_Newest'),
  oldest('Generic_Oldest'),
  mostLiked('Generic_MostLiked'),
  mostDownloaded('Generic_MostDownloaded'),
  mostViewed('Generic_MostViewed'),
  latestModified('Generic_LatestModified'),
  latestComment('Generic_LatestComment');

  const GbModSort(this.wireValue);

  /// The literal string sent as `_sSort`.
  final String wireValue;
}

/// The `_sSort` vocabulary accepted by `Mod/Categories`.
///
/// Deliberately a **separate** enum from [GbModSort]: the two vocabularies do
/// not overlap at all, and passing a `Generic_*` alias here is an error. This
/// endpoint also *requires* `_sSort` — its own internal default (`most_items`)
/// is not a value it accepts — so the client always sends one.
enum GbCategorySort {
  aToZ('a_to_z'),
  count('count');

  const GbCategorySort(this.wireValue);

  /// The literal string sent as `_sSort`.
  final String wireValue;
}
