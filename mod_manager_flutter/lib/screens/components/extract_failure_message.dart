import '../../l10n/app_localizations.dart';
import '../../models/app_notification.dart';
import '../../services/archive_service.dart';

/// What to say when an archive could not be unpacked.
///
/// Shared because the two places an archive is extracted — a marketplace
/// install and an update being applied — had this composed inline, byte for
/// byte, which is how the two wordings drift apart on the next edit.
///
/// **The extractor's own reason string is deliberately dropped.** It is raw
/// 7-Zip stderr or a literal from `ArchiveService`, untranslated whichever
/// locale is running, and it describes the app's own tooling. It stays on the
/// result and in the console for diagnostics.
///
/// What is *not* dropped is [ExtractFailure], because one of its two values is
/// something the user can act on. A missing 7-Zip is not a broken archive: the
/// download is fine and the fix is to install a tool, which the generic wording
/// ("the file is still at …, extract it by hand") actively steers away from by
/// implying the app has done all it can.
NotificationLines extractFailureMessage(
  AppLocalizations loc, {
  required String archivePath,
  ExtractFailure reason = ExtractFailure.other,
}) {
  final key = switch (reason) {
    ExtractFailure.missingSevenZip => 'marketplace.extract_no_7zip',
    ExtractFailure.other => 'marketplace.extract_failed',
  };
  return NotificationLines(
    loc.t('${key}_title'),
    loc.t('${key}_body', params: {'path': archivePath}),
  );
}
