import 'dart:math';

import 'package:path/path.dart' as path;

import '../models/mod_ingest.dart';
import '../models/mod_origin.dart';
import '../models/mod_origin_seed.dart';
import '../models/origin_enums.dart';

/// Turns what the caller knew at ingest time into the origin block that gets
/// written.
///
/// Pure, and separate from `ModManagerService` for a practical reason: that
/// class needs a configured library, a `ProviderContainer` and the platform
/// service to instantiate, so it has no test file at all. Keeping the decisions
/// here — group membership, ingest shape, timestamps — is what makes them
/// testable, and leaves the import methods holding only plumbing.
class IngestOriginBuilder {
  IngestOriginBuilder({
    DateTime Function()? now,
    String Function()? newId,
  })  : _now = now ?? DateTime.now,
        _newId = newId ?? defaultIdGenerator;

  final DateTime Function() _now;
  final String Function() _newId;

  static final Random _random = Random();

  /// 12 hex characters.
  ///
  /// Not `Random.secure()` — there is no security property here and it can
  /// block on some platforms. Not a timestamp, which is already recorded in
  /// `installed_at` and would invite someone to parse meaning out of the id.
  /// Not a UUID: no dependency provides one, and 48 bits is already far beyond
  /// what is needed for ids only ever compared for equality among siblings in
  /// one library.
  static String defaultIdGenerator() {
    final buffer = StringBuffer();
    for (var i = 0; i < 3; i++) {
      buffer.write(_random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'));
    }
    return buffer.toString();
  }

  /// A group id, or null when this ingest produced a single mod.
  ///
  /// Null for one mod on purpose: a "group" of one is noise, and it invites
  /// code to read "has a group" as "is part of a group".
  String? siblingGroupFor(int installedCount) =>
      installedCount > 1 ? _newId() : null;

  /// Builds the origin block for one mod installed as its own folder.
  ///
  /// [sourceFolder] is the folder the archive yielded, whose basename is what
  /// gets recorded — see [ModIngest.folders] for why it is not the mod's own
  /// name and not an absolute path.
  ModOrigin separate({
    required ModOriginSeed seed,
    required String sourceFolder,
    String? siblingGroup,
  }) =>
      _build(
        seed: seed,
        ingest: ModIngest(
          mode: IngestMode.separate,
          folders: [path.basename(sourceFolder)],
          siblingGroup: siblingGroup,
        ),
      );

  /// Builds the origin block for several folders merged into one mod.
  ///
  /// Never carries a sibling group: combined is precisely the case where one
  /// archive produced exactly one mod.
  ModOrigin combined({
    required ModOriginSeed seed,
    required List<String> sourceFolders,
  }) =>
      _build(
        seed: seed,
        ingest: ModIngest(
          mode: IngestMode.combined,
          folders: sourceFolders.map(path.basename).toList(),
        ),
      );

  ModOrigin _build({required ModOriginSeed seed, required ModIngest ingest}) =>
      ModOrigin(
        source: seed.source,
        modId: seed.modId,
        modIdConfidence: seed.modIdConfidence,
        fileId: seed.fileId,
        version: seed.version,
        versionLabel: seed.versionLabel,
        versionConfidence: seed.versionConfidence,
        provenance: seed.provenance,
        ingest: ingest,
        // Observed, not derived from file timestamps — so no proxy flag. This
        // is also the first genuinely reliable install date the library has.
        installedAt: _now().toUtc(),
        archiveMd5: seed.archiveMd5,
      );

  /// Reduces several per-folder seeds to the one describing a combined mod.
  ///
  /// Rule: an archive hash may only be claimed when **every** folder came from
  /// the same archive. Merging a folder unpacked from a zip with one the user
  /// dragged in produces a mod that is only partly from that archive, and the
  /// least-trusted honest answer is the correct one — a hash that matches a
  /// published file would otherwise imply the whole folder matches it.
  static ModOriginSeed combineSeeds(Iterable<ModOriginSeed?> seeds) {
    final present = seeds.whereType<ModOriginSeed>().toList();
    if (present.isEmpty) return ModOriginSeed.importedFolder;

    final first = present.first;
    final uniform = present.every(
      (seed) =>
          seed.provenance == first.provenance &&
          seed.archiveMd5 != null &&
          seed.archiveMd5 == first.archiveMd5,
    );
    return uniform ? first : ModOriginSeed.importedFolder;
  }
}
