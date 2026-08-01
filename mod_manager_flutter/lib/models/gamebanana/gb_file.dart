import 'gb_coerce.dart';

/// One downloadable file — an entry of `_aFiles` or `_aArchivedFiles`, which
/// share an identical shape.
///
/// A GameBanana mod routinely publishes several files (variants, optional
/// add-ons, an installer plus a manual zip), so "which file is installed" is a
/// separate question from "which mod is installed". [idRow] is the handle that
/// answers it and the thing worth recording — the filename is not stable.
class GbFile {
  const GbFile({
    required this.idRow,
    this.file,
    this.filesize,
    this.dateAdded,
    this.version,
    this.description,
    this.downloadUrl,
    this.md5Checksum,
    this.downloadCount,
    this.isArchived = false,
    this.avResult,
    this.analysisResult,
  });

  /// `_idRow` — the **file** id. `https://gamebanana.com/dl/<idRow>` downloads
  /// it. Not to be confused with the mod id.
  final int idRow;

  /// `_sFile` — the original filename, e.g. `remielleswimlite.rar`. The only
  /// place a filename exists: downloads carry no `Content-Disposition`.
  final String? file;

  /// `_nFilesize` in bytes. Verified to equal the eventual `Content-Length`
  /// exactly, so it is safe as a progress denominator and a preflight
  /// disk-space check.
  final int? filesize;

  /// `_tsDateAdded` — when this file was uploaded.
  final DateTime? dateAdded;

  /// `_sVersion` — a **per-file** version string, distinct from the mod-level
  /// one and frequently absent.
  ///
  /// Must never be conflated with [description]; see that field.
  final String? version;

  /// `_sDescription` — the author's free-text label for this file
  /// ("RabbitFX Fixer EXE Version", "white hair ver", "Full Mod").
  ///
  /// This is the **variant** marker, *not* a version. The two are separate
  /// fields carrying separate meanings, and collapsing them would make two
  /// variants of the same release look like two different releases.
  final String? description;

  /// `_sDownloadUrl` — `https://gamebanana.com/dl/<idRow>`.
  final String? downloadUrl;

  /// `_sMd5Checksum` — md5 of the archive as uploaded.
  ///
  /// A **matching key, never an integrity or authenticity claim.** It exists
  /// here only because it is what GameBanana publishes; md5 is cryptographically
  /// broken. A match means "byte-identical to this file on the mod page" and
  /// must never be rendered as "verified" or with a shield icon. For a real
  /// safety signal show [avResult] instead.
  final String? md5Checksum;

  /// `_nDownloadCount` — useful for guessing which file is the "main" one.
  final int? downloadCount;

  /// `_bIsArchived` — true for entries from `_aArchivedFiles`, i.e. superseded
  /// files. They remain downloadable, and an old local install matches one of
  /// these more often than it matches the current file.
  final bool isArchived;

  /// `_sAvResult` — virus-scan verdict, e.g. `clean`. Unlike an md5 match this
  /// genuinely is a safety signal, and it costs nothing to surface verbatim.
  final String? avResult;

  /// `_sAnalysisResult` — the deeper content analysis verdict.
  final String? analysisResult;

  static GbFile? fromJson(Map<String, dynamic> json) {
    final id = gbInt(json['_idRow']);
    if (id == null) return null;
    return GbFile(
      idRow: id,
      file: gbString(json['_sFile']),
      filesize: gbInt(json['_nFilesize']),
      dateAdded: gbTimestamp(json['_tsDateAdded']),
      version: gbString(json['_sVersion']),
      description: gbString(json['_sDescription']),
      downloadUrl: gbString(json['_sDownloadUrl']),
      md5Checksum: gbString(json['_sMd5Checksum']),
      downloadCount: gbInt(json['_nDownloadCount']),
      isArchived: gbBool(json['_bIsArchived']),
      avResult: gbString(json['_sAvResult']),
      analysisResult: gbString(json['_sAnalysisResult']),
    );
  }

  static List<GbFile> listFrom(Object? value) =>
      <GbFile>[for (final e in gbObjects(value)) if (fromJson(e) case final f?) f];
}
