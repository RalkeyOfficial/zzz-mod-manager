import 'gb_coerce.dart';

/// One entry of a mod's update feed — an author's "here's what changed" post,
/// and **the files that shipped with it**.
///
/// The file list is why this type exists at all. `_aFileRowIds` names the files
/// released *together as one release*, which is the only authoritative answer
/// GameBanana gives to a question no amount of guessing at `_sVersion` and
/// `_sDescription` can settle: are these two files a new version and an old
/// one, or two variants of the same version? The author already grouped them.
///
/// Lenient like every wire DTO here, and it has to be: the records genuinely
/// differ field-for-field between mods. One captured feed carries `_aChangeLog`
/// and no `_sVersion`, another carries `_sVersion` and no `_aChangeLog`.
class GbUpdate {
  const GbUpdate({
    required this.idRow,
    this.name,
    this.version,
    this.dateAdded,
    this.fileRowIds = const {},
    this.isSignificant = false,
  });

  /// `_idRow` — the update post's id (`gamebanana.com/updates/<id>`).
  final int idRow;

  /// `_sName` — the author's title for the release, e.g. `Version 1.5`.
  /// Frequently the closest thing to a real version number a mod page has.
  final String? name;

  /// `_sVersion` — present on some feeds and absent on others.
  final String? version;

  /// `_tsDateAdded` — when the update was posted.
  final DateTime? dateAdded;

  /// `_aFileRowIds` — **the file ids released together in this update.**
  ///
  /// A set because the only question ever asked of it is membership.
  final Set<int> fileRowIds;

  /// `_bIsSignificant` — the author marked this a real change rather than a
  /// touch-up. Not currently read; recorded because it is the field that would
  /// separate a re-upload from a release if that is ever needed.
  final bool isSignificant;

  static GbUpdate? fromJson(Map<String, dynamic> json) {
    final id = gbInt(json['_idRow']);
    if (id == null) return null;
    return GbUpdate(
      idRow: id,
      name: gbString(json['_sName']),
      version: gbString(json['_sVersion']),
      dateAdded: gbTimestamp(json['_tsDateAdded']),
      fileRowIds: <int>{
        if (json['_aFileRowIds'] case final List<Object?> raw)
          for (final entry in raw)
            if (gbInt(entry) case final fileId?) fileId,
      },
      isSignificant: gbBool(json['_bIsSignificant']),
    );
  }
}
