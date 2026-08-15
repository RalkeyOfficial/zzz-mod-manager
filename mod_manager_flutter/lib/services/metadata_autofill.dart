import '../models/mod_metadata.dart';
import '../utils/zzz_characters.dart';
import 'gamebanana/remote_mod_metadata.dart';

/// What the autofill would write for one mod: only the fields it is allowed to
/// touch, with **null meaning "leave what is there alone"**.
///
/// Null rather than "the existing value" on purpose — the caller has to be able
/// to tell "fill this in" from "this already had a value", both to report what
/// it did and to skip fetching images nobody will store.
class MetadataAutofillPlan {
  const MetadataAutofillPlan({
    this.description,
    this.sourceUrl,
    this.tags,
    this.characterId,
    this.imageUrls = const [],
    this.shippedPreview,
  });

  final String? description;

  /// The mod page to link back to.
  ///
  /// A user-facing field, and the reason it is filled here rather than by the
  /// install: the origin block records *which* mod this is for the app's own
  /// use, while this is the link the user clicks. Both are kept — the two
  /// answer to different readers.
  final String? sourceUrl;

  final List<String>? tags;
  final String? characterId;

  /// Remote gallery images to fetch and store, in order. Empty when the mod
  /// already has a gallery.
  final List<Uri> imageUrls;

  /// An author-shipped preview to keep at the front of the gallery, as a path
  /// **relative to the mod folder** (`Preview.png`). Only ever set alongside a
  /// non-empty [imageUrls]: on its own it is not something to write, because the
  /// scan already falls back to it.
  final String? shippedPreview;

  bool get isEmpty =>
      description == null &&
      sourceUrl == null &&
      tags == null &&
      characterId == null &&
      imageUrls.isEmpty;
}

/// What the autofill actually managed to write across one install.
///
/// Aggregated rather than per-mod because that is how it is reported: one
/// archive usually becomes one mod, and when it becomes several they all get the
/// same page's metadata.
class RemoteMetadataFill {
  const RemoteMetadataFill({
    this.characterTags = const {},
    this.descriptions = 0,
    this.tagSets = 0,
    this.images = 0,
    this.unwritable = const [],
  });

  /// Mod folder -> character id, for characters this fill assigned. Same shape
  /// as the import path's auto-tag map so the two can be reported together.
  final Map<String, String> characterTags;

  final int descriptions;
  final int tagSets;

  /// Image **files** written, summed over every mod — so one 8-image gallery
  /// installed as two mods is 16.
  ///
  /// A diagnostic, not a gallery size, and deliberately not rendered as one: the
  /// install message says "preview images" without a number precisely because
  /// this figure would be read as the length of one gallery.
  final int images;

  /// Mods whose sidecar could not be written. Already surfaced by the origin
  /// write for the same folder, so this exists for logging rather than a second
  /// message.
  final List<String> unwritable;

  bool get isEmpty =>
      characterTags.isEmpty &&
      descriptions == 0 &&
      tagSets == 0 &&
      images == 0;
}

/// Decides what a mod page may fill in on a mod we just installed.
///
/// Documented in full in `docs/metadata-autofill.md`.
///
/// **One rule, applied per field: fill absence, never displace.** The reason is
/// not politeness — a mod folder can arrive carrying somebody else's sidecar.
/// `_copyDirectory` copies `.zzz-mod-manager/` wholesale, and
/// `docs/metadata-schema.md` §2 keeps the *user-facing* half of an inbound
/// sidecar deliberately (a shared description and gallery travelling with the
/// folder is the whole point of the format; only the `origin` block is dropped).
/// So "the field is already set" routinely means "the author wrote this", and
/// overwriting it with the mod page's copy would throw away the better text.
///
/// Two consequences worth stating, because they are what a reader will check:
///
/// - **Tags are all-or-nothing.** A non-empty local tag list is a curation — the
///   author's, or the user's after a first edit — and merging remote tags into it
///   would produce a set nobody chose.
/// - **A shipped `Preview.png` counts as presence**, but only for the cover
///   slot: the remote gallery is still imported, with the local preview kept
///   first. Nothing local is lost and nothing local is demoted.
MetadataAutofillPlan planMetadataAutofill({
  required ModMetadata existing,
  required RemoteModMetadata remote,
  String? shippedPreview,
}) {
  final description = (existing.description == null ||
          existing.description!.isEmpty)
      ? remote.description
      : null;

  // The same rule, and it earns it here more than anywhere: a url the user
  // typed, or one the archive's own sidecar carried, may point at a collection,
  // a mirror, or the author's page — all better than the canonical link we
  // would substitute, and all impossible to recover once overwritten.
  final sourceUrl =
      (existing.sourceUrl == null || existing.sourceUrl!.isEmpty)
          ? remote.sourceUrl
          : null;

  final tags = existing.tags.isEmpty && remote.tags.isNotEmpty
      ? List<String>.unmodifiable(remote.tags)
      : null;

  // The install path's own name-based detection has already run and written a
  // character when it found one, so this fills the case it could not: a folder
  // named "bikini" or "mod v2". `storedCharacterId` keeps the runtime "unknown"
  // placeholder from being read as a real assignment.
  final characterId = isUnassignedCharacterId(existing.characterId)
      ? remote.characterId
      : null;

  final wantsImages = existing.images.isEmpty && remote.imageUrls.isNotEmpty;

  return MetadataAutofillPlan(
    description: description,
    sourceUrl: sourceUrl,
    tags: tags,
    characterId: characterId,
    imageUrls: wantsImages ? List<Uri>.unmodifiable(remote.imageUrls) : const [],
    shippedPreview: wantsImages ? shippedPreview : null,
  );
}
