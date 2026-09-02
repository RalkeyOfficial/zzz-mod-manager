import 'package:mod_manager_flutter/models/installed_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';

/// **Test-only shorthand for the bottom of a folder's stack.**
///
/// A `ModOrigin` is a stack of downloads plus the folder's own facts, and every
/// identity question is asked of a *layer*. Most of this suite is about folders
/// with one download, where "the folder's mod id" and "its bottom layer's mod
/// id" are the same thing — so spelling `origin.base?.modId` several hundred
/// times would add length without adding a single assertion.
///
/// **It is deliberately not on the model.** Production code has to say which
/// layer it means, because the whole point of the stack is that a folder can
/// hold more than one and the old shape let callers forget. Anything here that
/// genuinely tests layering reaches for `downloads`, `base` and `patches`
/// directly, and `mod_origin_test.dart` tests the real shape.
extension OriginShorthand on ModOrigin {
  ModDownload get _base => base ?? const ModDownload();

  int? get modId => base?.modId;
  OriginConfidence get modIdConfidence => _base.modIdConfidence;
  int? get fileId => _base.fileId;
  String? get version => _base.version;
  String? get versionLabel => _base.versionLabel;
  OriginConfidence get versionConfidence => _base.versionConfidence;
  String? get archiveMd5 => _base.archiveMd5;
  DateTime? get baselineRemoteDate => _base.baselineRemoteDate;
  bool get remoteMissing => _base.remoteMissing;
  DateTime? get updatesDismissedUntil => _base.updatesDismissedUntil;
  List<InstalledFile> get files => _base.files;

  /// Amends the bottom layer, for fixtures written as
  /// `origin.copyWith(fileId: …)` before those fields lived on a download.
  ModOrigin copyBase({
    int? modId,
    OriginConfidence? modIdConfidence,
    int? fileId,
    String? version,
    String? versionLabel,
    OriginConfidence? versionConfidence,
    String? archiveMd5,
    DateTime? baselineRemoteDate,
    bool? remoteMissing,
    DateTime? updatesDismissedUntil,
    List<InstalledFile>? files,
  }) =>
      withBase((download) => download.copyWith(
            modId: modId,
            modIdConfidence: modIdConfidence,
            fileId: fileId,
            version: version,
            versionLabel: versionLabel,
            versionConfidence: versionConfidence,
            archiveMd5: archiveMd5,
            baselineRemoteDate: baselineRemoteDate,
            remoteMissing: remoteMissing,
            updatesDismissedUntil: updatesDismissedUntil,
            files: files,
          ));
}

/// A folder holding **one** download, from the flat parameters this suite's
/// fixtures were written against.
///
/// [patches] adds layers on top, so a test that is about a mixed folder still
/// says so explicitly.
ModOrigin originFixture({
  String? source = 'gamebanana',
  int? modId,
  OriginConfidence modIdConfidence = OriginConfidence.unknown,
  int? fileId,
  String? version,
  String? versionLabel,
  OriginConfidence versionConfidence = OriginConfidence.unknown,
  OriginProvenance provenance = OriginProvenance.importedFolder,
  ModIngest? ingest,
  DateTime? installedAt,
  bool installedAtIsProxy = false,
  DateTime? baselineRemoteDate,
  String? archiveMd5,
  OriginTracking tracking = OriginTracking.auto,
  bool remoteMissing = false,
  DateTime? updatesDismissedUntil,
  List<InstalledFile> files = const <InstalledFile>[],
  List<ModDownload> patches = const <ModDownload>[],
}) =>
    ModOrigin(
      source: source,
      provenance: provenance,
      ingest: ingest,
      installedAt: installedAt,
      installedAtIsProxy: installedAtIsProxy,
      tracking: tracking,
      downloads: [
        ModDownload(
          modId: modId,
          modIdConfidence: modIdConfidence,
          fileId: fileId,
          version: version,
          versionLabel: versionLabel,
          versionConfidence: versionConfidence,
          archiveMd5: archiveMd5,
          baselineRemoteDate: baselineRemoteDate,
          remoteMissing: remoteMissing,
          updatesDismissedUntil: updatesDismissedUntil,
          files: files,
        ),
        for (var i = 0; i < patches.length; i++)
          patches[i].copyWith(role: DownloadRole.patch),
      ],
    );

/// One layer to sit on top of a fixture's base.
ModDownload patchFixture({
  int? modId = 605460,
  OriginConfidence modIdConfidence = OriginConfidence.exact,
  int? fileId,
  String? version,
  String? versionLabel,
  OriginConfidence versionConfidence = OriginConfidence.unknown,
  String? archiveMd5,
  DateTime? baselineRemoteDate,
  bool remoteMissing = false,
  DateTime? updatesDismissedUntil,
  List<InstalledFile> files = const <InstalledFile>[],
}) =>
    ModDownload(
      role: DownloadRole.patch,
      modId: modId,
      modIdConfidence: modIdConfidence,
      fileId: fileId,
      version: version,
      versionLabel: versionLabel,
      versionConfidence: versionConfidence,
      archiveMd5: archiveMd5,
      baselineRemoteDate: baselineRemoteDate,
      remoteMissing: remoteMissing,
      updatesDismissedUntil: updatesDismissedUntil,
      files: files,
    );
