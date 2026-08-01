import 'origin_enums.dart';

/// What the caller knows about a mod at the moment it is ingested.
///
/// Separate from `ModOrigin` because the two are known at different points: a
/// seed is what the *UI* has when it hands folders to the importer, while the
/// finished origin block also needs facts only the importer learns — how many
/// mods the archive actually produced, which folders survived a duplicate skip,
/// and when the install completed.
///
/// Keeping it a distinct type is also what lets the marketplace fill in remote
/// identity later without changing a single service signature.
class ModOriginSeed {
  const ModOriginSeed({
    required this.provenance,
    this.archiveMd5,
    this.source,
    this.modId,
    this.modIdConfidence = OriginConfidence.unknown,
    this.fileId,
    this.version,
    this.versionLabel,
    this.versionConfidence = OriginConfidence.unknown,
  });

  final OriginProvenance provenance;

  /// md5 of the archive this came from, when there was one.
  ///
  /// Null for a folder the user dragged in directly — there is no archive, and
  /// inventing a hash of the folder contents would be a different claim
  /// entirely (it would never match anything the remote publishes).
  final String? archiveMd5;

  /// Remote identity, when the caller had it.
  ///
  /// All null today: the marketplace is still a webview, which intercepts a CDN
  /// url and knows nothing else about the file. The native browser will supply
  /// these, and nothing downstream changes when it does.
  final String? source;
  final int? modId;
  final OriginConfidence modIdConfidence;
  final int? fileId;
  final String? version;
  final String? versionLabel;
  final OriginConfidence versionConfidence;

  /// A seed for an archive the user supplied by hand.
  factory ModOriginSeed.importedArchive({String? archiveMd5}) =>
      ModOriginSeed(
        provenance: OriginProvenance.importedArchive,
        archiveMd5: archiveMd5,
      );

  /// A seed for a folder dragged in directly.
  static const ModOriginSeed importedFolder =
      ModOriginSeed(provenance: OriginProvenance.importedFolder);
}
