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

/// What an **asset-only** download replaces, and in which mod.
class AssetPatchAssessment {
  const AssetPatchAssessment({
    this.targets = const <String>[],
    this.replaced = 0,
  });

  static const AssetPatchAssessment none = AssetPatchAssessment();

  /// Library mod folders holding **every** file this download brings, sorted.
  ///
  /// Several is an ordinary answer, not an error: two variants of one mod
  /// installed side by side both hold the file. They are all reported and none
  /// is chosen — guesses may inform, never drive.
  final List<String> targets;

  /// How many of the download's files are content that could be replaced —
  /// auxiliary files excluded.
  final int replaced;

  bool get looksLikePatch => replaced > 0 && targets.isNotEmpty;
}

/// Whether a download that ships **no `.ini`** is a patch rather than a broken
/// mod, and what it patches.
///
/// ## Why the reference rule cannot answer this
///
/// [assessPatchShape] asks what a download's `.ini` files reference and whether
/// it brought any of it. A patch that replaces one texture ships **no `.ini` at
/// all**, so there are no references, nothing to compare, and no threshold that
/// would help. Measured on a real pair: GameBanana **605460** is a 6.7 MB `.rar`
/// containing exactly one file, `PulchraBodyADiffuse.dds`, and it patches
/// **585282**, whose download ships 17 files including that one. Today the first
/// reads as "the mod may be incomplete", which points at the wrong fix and
/// records nothing.
///
/// ## The rule
///
/// **A download that brings nothing the library does not already have is
/// replacing rather than adding.** Concretely: no `.ini`, at least one
/// replaceable file, and some single mod folder already holds **every** one of
/// them.
///
/// "Every" rather than "any" is the whole of it, and it is the same shape as the
/// `.ini` rule's "brought no content at all". A mod shipping one familiar
/// texture beside its own new meshes is a mod; only a download with nothing new
/// in it is a replacement. "Any" would report every retexture that happens to
/// reuse a name.
///
/// Matching is on the **file name**, not the path: a patch author has no idea
/// what layout the folder ended up with, and requiring the same relative path
/// would miss every base mod keeping its textures in a subfolder.
///
/// [library] maps a mod folder's name to its contents in `FolderContents`
/// spelling. [exclude] is the folder being judged — the check runs after the
/// copy, so without it every no-`.ini` import matches itself perfectly and
/// reports itself as its own patch.
///
/// Pure: the caller walks the library.
AssetPatchAssessment assessAssetPatch({
  required Set<String> files,
  required bool hasIni,
  required Map<String, Set<String>> library,
  Set<String> exclude = const <String>{},
}) {
  // A download with an `.ini` is the reference rule's question. Two rules
  // answering for one folder is how they come to disagree about it.
  if (hasIni) return AssetPatchAssessment.none;

  final wanted = <String>{
    for (final path in files)
      if (_replaceableName(path) case final name?) name,
  };
  if (wanted.isEmpty) return AssetPatchAssessment.none;

  final targets = <String>[];
  for (final entry in library.entries) {
    if (exclude.contains(entry.key)) continue;
    final held = <String>{
      for (final path in entry.value) _basename(path),
    };
    if (wanted.every(held.contains)) targets.add(entry.key);
  }

  // Sorted, so what the user reads does not depend on the order the filesystem
  // happened to enumerate the library in.
  targets.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return AssetPatchAssessment(targets: targets, replaced: wanted.length);
}

/// A name worth matching on, or null for something that replaces nothing.
///
/// **Auxiliary files are excluded rather than counted.** Every mod in a library
/// has a `preview.png`, so counting them would let one shared name carry a whole
/// download — a screenshot pack would read as a patch of whatever it was
/// compared against. Excluding them also lets a real patch ship a screenshot
/// alongside its texture without that breaking the match.
String? _replaceableName(String path) {
  final name = _basename(path);
  if (name.isEmpty) return null;
  return _auxiliaryNames.contains(name) ? null : name;
}

String _basename(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}

/// Lower-cased, to match `FolderContents` spelling.
const Set<String> _auxiliaryNames = <String>{
  'preview.png',
  'thumbnail.png',
  'icon.png',
  'readme.txt',
  'readme.md',
};
