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
    this.text,
    this.changeLog = const <GbChangeLogEntry>[],
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

  /// `_sText` — the author's prose for the release, as **HTML**.
  ///
  /// Every description this app renders is markdown, so a caller has to run it
  /// through `utils/html_to_markdown.dart` exactly like a mod page's `_sText`.
  /// Kept raw here because a wire DTO converts nothing.
  final String? text;

  /// `_aChangeLog` — the author's structured bullet list, when they filled one
  /// in.
  ///
  /// **Complementary to [text], not an alternative spelling of it.** The two
  /// carry different content and each appears without the other: one captured
  /// feed has five categorised bullets and no prose worth reading, another has
  /// two paragraphs of prose and no bullets at all.
  final List<GbChangeLogEntry> changeLog;

  /// Whether this post says anything a user could read before updating.
  bool get hasNotes =>
      changeLog.isNotEmpty || (text?.trim().isNotEmpty ?? false);

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
      text: gbString(json['_sText']),
      changeLog: <GbChangeLogEntry>[
        if (json['_aChangeLog'] case final List<Object?> raw)
          for (final entry in raw)
            if (GbChangeLogEntry.fromJson(entry) case final parsed?) parsed,
      ],
    );
  }
}

/// One line of an author's changelog.
///
/// **The only object in this API whose keys are not Hungarian-prefixed.**
/// Everything else on the wire is `_sName` / `_idRow` / `_aFiles`; these are
/// bare `text` and `cat`. Recorded because it looks like a typo in the parser
/// and is not — reading them as `_sText` / `_sCat` silently yields an empty
/// changelog for every mod, which is exactly how `_aTags` went unnoticed.
class GbChangeLogEntry {
  const GbChangeLogEntry({required this.text, this.category});

  final String text;

  /// `cat` — the author's own bucket: `Addition`, `Adjustment`, `Refactor`,
  /// `Overhaul`, `Removal`, `Fix`. Free-form in practice, so it is displayed
  /// verbatim and never mapped to an icon or a colour.
  final String? category;

  static GbChangeLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = gbString(raw['text']);
    if (text == null || text.trim().isEmpty) return null;
    return GbChangeLogEntry(text: text.trim(), category: gbString(raw['cat']));
  }
}
