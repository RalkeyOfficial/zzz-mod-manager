import '../../models/gamebanana/gb_enums.dart';

/// What the user asked us to do with mods GameBanana flags as adult.
///
/// The filter is **ours to implement**: the API applies none of its own. Adult
/// mods are returned to anonymous callers like any other and their files
/// download without a session; GameBanana ships a rendering hint
/// (`_sInitialVisibility`) and trusts the client to honour it
/// (`docs/gamebanana-api.md` §7). So this setting is not a permission — it is
/// purely how we present what we were already given.
///
/// Not an edge case for ZZZ: 4 of the 5 records in a captured `Mod/Index` page
/// carry `hide`, and 25 of 45 recent submissions carried content ratings. The
/// default therefore has to be usable rather than merely safe, which is why
/// [blur] reveals on click instead of hiding.
enum ContentFilterMode {
  /// Honour the hint: blur flagged mods, reveal on click. What the site itself
  /// does, and the default.
  blur('blur'),

  /// Show everything unblurred. The user has opted in explicitly.
  show('show'),

  /// Omit flagged mods from listings entirely.
  hide('hide');

  const ContentFilterMode(this.wire);

  /// The value stored in `config.json`.
  final String wire;

  /// Parses the stored value, **failing to [blur]**.
  ///
  /// Load-bearing rather than defensive habit: an unreadable or hand-edited
  /// setting must not un-blur adult content, and it must not silently empty the
  /// grid either. [blur] is the only value that is wrong in neither direction.
  static ContentFilterMode parse(Object? value) {
    if (value is! String) return ContentFilterMode.blur;
    for (final mode in ContentFilterMode.values) {
      if (mode.wire == value) return mode;
    }
    return ContentFilterMode.blur;
  }
}

/// How one mod should be rendered, once the hint and the setting are combined.
enum ContentTreatment {
  /// Render normally.
  show,

  /// Render behind a blur with a reveal affordance.
  blur,

  /// Do not render at all — drop it from the list.
  omit,
}

/// Combines GameBanana's per-mod hint with the user's setting.
///
/// Pure and total, so the whole matrix is a unit test rather than something
/// spread across widget build methods where the `hide`-under-`show` corner would
/// never be exercised.
///
/// Note [ContentFilterMode.show] overrides the hint completely, including
/// `hide` — an explicit "show me everything" that still hid a subset would be a
/// setting that lies. Conversely nothing here can *promote* a mod GameBanana
/// called `show` into being blurred: we have no other signal to justify it.
ContentTreatment contentTreatment(
  GbVisibility visibility,
  ContentFilterMode mode,
) {
  if (!visibility.needsContentWarning) return ContentTreatment.show;
  return switch (mode) {
    ContentFilterMode.show => ContentTreatment.show,
    ContentFilterMode.blur => ContentTreatment.blur,
    ContentFilterMode.hide => ContentTreatment.omit,
  };
}
