import '../../l10n/app_localizations.dart';
import '../../models/app_notification.dart';

/// What to say when an archive could not be unpacked.
///
/// Shared because the two places an archive is extracted — a marketplace
/// install and an update being applied — had this composed inline, byte for
/// byte, which is how the two wordings drift apart on the next edit.
///
/// **The extractor's own reason is deliberately dropped.** It is raw 7-Zip
/// stderr or a hardcoded literal from `ArchiveService`, untranslated whichever
/// locale is running, and it describes the app's own tooling rather than
/// anything the user can act on. It is still printed to the console and kept on
/// the result for diagnostics. What survives is the one fact that changes what
/// they do next: the archive is still on disk, and where.
NotificationLines extractFailureMessage(
  AppLocalizations loc, {
  required String archivePath,
}) {
  return NotificationLines(
    loc.t('marketplace.extract_failed_title'),
    loc.t('marketplace.extract_failed_body', params: {'path': archivePath}),
  );
}
