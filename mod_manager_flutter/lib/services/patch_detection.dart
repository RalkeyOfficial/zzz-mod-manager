/// Whether a download can stand on its own, or expects a mod to already be
/// there.
///
/// A **patch mod** replaces rather than adds: its `.ini` is a full replacement
/// for the host mod's `.ini`, and it carries **no content of its own** — the
/// textures and meshes are expected to be in the folder already.
///
/// ## "References a file it does not ship" is not the test
///
/// That was the first rule, and it is empirically wrong for this game. Measured
/// over 29 real ZZZ archives it produced **one true positive and six false
/// ones**, and it did not flag the single archive in the corpus with "Patch" in
/// its name.
///
/// The reason is the dominant idiom. A ZZZ character is several components
/// (body, hair, wings, jets…), and the extraction tools emit an `.ini` covering
/// **all** of them. An author replacing only the wings ships the wings' buffers
/// and textures and nothing else, while the `.ini` still declares — and
/// references — every other component. `Remielle combat wings replaced`
/// (GameBanana 701954) is a complete, working, standalone mod that references 36
/// files and ships 8 of them. The unshipped references simply never load, and
/// the game's own data stays in place.
///
/// So "partial mod" is the normal case, and the old rule could not tell it from
/// a patch. Nor could a ratio: the false positives sit at 0%, 2%, 18%, 22%, 32%
/// and 92% of references present, which is the entire range.
///
/// ## The test that does work
///
/// **A patch ships no content.** Concretely: the download contains at least one
/// `.ini`, its `.ini` files reference resources that are absent, and **not one
/// referenced resource is present**. The one real patch in the corpus,
/// `Nicole Casual Wear (Updated Ini's 3.0)`, is 5.8 KB of five `.ini` files and
/// nothing else. Every false positive ships 5–20 of the resources it
/// references.
///
/// No threshold, no filename similarity, no date — and it separates the measured
/// corpus completely.
///
/// It has two uses, one implementation:
///
/// - **At install**, so the user is told up front rather than discovering it
///   when the game shows nothing.
/// - **Before an update**, where a patch-shaped *incoming* download proves the
///   folder being written into is mixed — it holds two downloads — so the user
///   can be told that only part of it is being replaced. This works on an
///   existing library with no recorded data and no extra request, because the
///   new archive is already in hand.
///
/// **The limit bounds the whole feature and is stated rather than papered
/// over:** this cannot see a mixed folder whose *tracked* download is the base
/// mod with a patch applied on top. Nothing is missing there, so nothing looks
/// wrong. That direction is accepted loss, and it is the milder one — the base
/// mod's own update usually carries the same fix.
///
/// The reference filter in `ini_resources.dart` — only a *referenced*
/// declaration counts — still matters here, but it is no longer what makes the
/// verdict safe. It keeps [PatchAssessment.missing] honest for the message, and
/// the stale-`.ini` rule depends on it.
///
/// Pure: it compares two sets. `services/ini_resources.dart` produces the first
/// and the caller walks the folder for the second.
library;

import 'ini_resources.dart';

/// What a folder's `.ini` files ask for versus what the folder holds.
class PatchAssessment {
  const PatchAssessment({
    this.missing = const <String>[],
    this.required = 0,
    this.presentResources = 0,
    this.unresolvable = 0,
    this.unreferenced = 0,
    this.hasIni = false,
  });

  static const PatchAssessment none = PatchAssessment();

  /// Referenced files that are genuinely absent, normalised and sorted so the
  /// message a user reads is stable between runs.
  final List<String> missing;

  /// How many distinct files the `.ini` files actually require — referenced
  /// declarations only. Zero with [hasIni] true is a real state (an `.ini`
  /// whose every path is a variable), and it is why [looksLikePatch] cannot
  /// simply ask whether [missing] is empty without knowing something was
  /// looked at.
  final int required;

  /// How many distinct **resource** files the download both references and
  /// carries. Includes are excluded on purpose: one `.ini` including another is
  /// a patch's own internal structure, not content.
  ///
  /// This is the whole verdict. Anything above zero means the download brought
  /// content of its own, which a patch by definition does not.
  final int presentResources;

  /// References that were not literal paths, so nothing could be concluded
  /// about them. See `ini_resources.dart`.
  final int unresolvable;

  /// Declarations dropped because nothing referenced them. See
  /// `ini_resources.dart` — a `[Resource…]` nobody asks for is never opened.
  final int unreferenced;

  final bool hasIni;

  /// A download is a patch when it carries `.ini` files that ask for content it
  /// does not have, and **no content at all of its own**.
  ///
  /// Requires `hasIni`, and that is a real limit rather than a guard: a patch
  /// that ships only the asset it replaces has no references to compare, and
  /// this rule cannot see it at any threshold. [assessAssetPatch] is the other
  /// half.
  ///
  /// The absence of a threshold is the point. "Most of it is missing" cannot
  /// work here — an ordinary partial mod can be missing 100% of what its
  /// template `.ini` references — while "it brought nothing" is a fact about
  /// the download rather than a proportion of one.
  bool get looksLikePatch =>
      hasIni && missing.isNotEmpty && presentResources == 0;
}

/// Compares what [references] asks for against what the folder contains.
///
/// [files] and [directories] are paths relative to the same root the references
/// were resolved against, in the spelling [normalizeIniPath] produces.
PatchAssessment assessPatchShape({
  required IniReferences references,
  required Set<String> files,
  required Set<String> directories,
  bool hasIni = true,
}) {
  // Distinct paths throughout: two sections pointing at the same texture are
  // one requirement and one piece of content, not two.
  final wanted = <String>{};
  final missing = <String>{};
  final presentResources = <String>{};

  for (final ref in references.references) {
    wanted.add(ref.path);
    final present = switch (ref.kind) {
      IniReferenceKind.includeDirectory => directories.contains(ref.path),
      _ => files.contains(ref.path),
    };
    if (!present) {
      missing.add(ref.path);
    } else if (ref.kind == IniReferenceKind.resource) {
      presentResources.add(ref.path);
    }
  }

  return PatchAssessment(
    missing: missing.toList()..sort(),
    required: wanted.length,
    presentResources: presentResources.length,
    unresolvable: references.unresolvable,
    unreferenced: references.unreferenced,
    hasIni: hasIni,
  );
}

/// What an **asset-only** download carries that is waiting for an `.ini`.
class AssetPatchAssessment {
  const AssetPatchAssessment({this.assets = 0});

  static const AssetPatchAssessment none = AssetPatchAssessment();

  /// How many of the download's files are game assets — things the loader can
  /// only reach through an `.ini`.
  final int assets;

  bool get looksLikePatch => assets > 0;
}

/// Whether a download that ships **no `.ini`** is a patch rather than a broken
/// mod.
///
/// ## Why the reference rule cannot answer this
///
/// [assessPatchShape] asks what a download's `.ini` files reference and whether
/// it brought any of it. A patch that replaces one texture ships **no `.ini` at
/// all**, so there are no references, nothing to compare, and no threshold that
/// would help. Measured on a real pair: GameBanana **605460** is a 6.7 MB `.rar`
/// containing exactly one file, `PulchraBodyADiffuse.dds`, and it patches
/// **585282**, whose download ships 17 files including that one.
///
/// ## The rule
///
/// **A download carrying game assets and no `.ini` to load them is waiting for
/// somebody else's `.ini`.** Nothing in the game reaches a `.dds` or a `.buf`
/// except through one, so an asset arriving without one is an asset meant to
/// land beside a mod that has one.
///
/// It is a judgement about **this download and nothing else**, which is what
/// makes it work in either order. Comparing against the library instead — "it
/// brought nothing you don't already have" — reads as *incomplete* whenever the
/// patch is downloaded before the mod it patches, and finding the patch first is
/// an ordinary way round. A comparison is also a full library walk per install
/// and a filename collision away from a wrong answer, and it can only ever
/// suggest a folder anyway: what gets recorded is a **mod page**, and only the
/// user can name that.
///
/// The residue is the reverse mistake: a folder that really is a broken download
/// of assets, reported as a patch. It is the milder one — the user is told the
/// download cannot work alone and asked what it belongs to, which is true either
/// way, and they can say nothing and move on.
AssetPatchAssessment assessAssetPatch({
  required Set<String> files,
  required bool hasIni,
}) {
  // A download with an `.ini` is the reference rule's question. Two rules
  // answering for one folder is how they come to disagree about it.
  if (hasIni) return AssetPatchAssessment.none;

  var assets = 0;
  for (final path in files) {
    if (_isGameAsset(path)) assets++;
  }
  return AssetPatchAssessment(assets: assets);
}

/// Whether the loader can only reach this file through an `.ini`.
///
/// The list is the resource kinds an `.ini` names on the right of a
/// `filename =` line (`ini_resources.dart`), which is exactly the question:
/// these are the files that do nothing at all on their own.
///
/// **Images are deliberately absent.** A `.png` or `.jpg` in a mod folder is
/// overwhelmingly a screenshot, and counting them would make a `previews`
/// folder installed as its own mod read as a patch — which is the one case the
/// "may be incomplete" warning is genuinely for.
bool _isGameAsset(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return _gameAssetExtensions.contains(path.substring(dot));
}

/// Lower-cased, to match `FolderContents` spelling.
const Set<String> _gameAssetExtensions = <String>{
  '.dds',
  '.buf',
  '.ib',
  '.vb',
};
