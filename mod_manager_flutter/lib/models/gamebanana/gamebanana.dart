/// GameBanana wire types.
///
/// Everything here is prefixed **`Gb`** to mark it as a *remote DTO* — the
/// shape GameBanana's undocumented `apiv13` happens to return today. They are
/// not domain models: `ModInfo` and `ModMetadata` are ours, they outlive any
/// API change, and nothing outside the GameBanana layer should be storing a
/// `Gb*` object.
///
/// The protocol these map onto is documented in `docs/gamebanana-api.md`, which
/// is the authoritative reference — its surface is undocumented upstream, so
/// guessing costs more than looking.
library;

export 'gb_category.dart';
export 'gb_coerce.dart';
export 'gb_enums.dart';
export 'gb_exceptions.dart';
export 'gb_file.dart';
export 'gb_image.dart';
export 'gb_mod.dart';
export 'gb_page.dart';
export 'gb_submitter.dart';
export 'gb_top_sub.dart';
export 'gb_update.dart';
