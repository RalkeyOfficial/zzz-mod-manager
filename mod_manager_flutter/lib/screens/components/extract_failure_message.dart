import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/archive_service.dart';
import '../../utils/byte_format.dart';
import '../../utils/notification_actions.dart';
import '../../utils/notifications.dart';

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
///
/// Every wording says the archive is still where it was, so with [notify] the card offers Open folder on the folder
/// it is in. [notify] reports that button's own failure.
NotificationLines extractFailureMessage(
  AppLocalizations loc, {
  required String archivePath,
  ExtractFailure reason = ExtractFailure.other,
  int? requiredBytes,
  int? availableBytes,
  NotificationCenter? notify,
}) {
  final actions = [
    if (notify != null) openFolderAction(loc, notify, p.dirname(archivePath)),
  ];

  // Its own branch rather than a third key in the switch: it is the one reason
  // whose body is numbers rather than the archive's path, and it says the
  // archive is still there in the same breath — nothing was written, so
  // clearing space and pressing install again is all there is to do.
  if (reason == ExtractFailure.insufficientSpace &&
      requiredBytes != null &&
      availableBytes != null) {
    return NotificationLines(
      loc.t('marketplace.extract_no_space_title'),
      loc.t('marketplace.extract_no_space_body', params: {
        'required': formatBytes(requiredBytes),
        'available': formatBytes(availableBytes),
        'path': archivePath,
      }),
      kind: NotificationKind.error,
      actions: actions,
    );
  }

  final key = switch (reason) {
    ExtractFailure.missingSevenZip => 'marketplace.extract_no_7zip',
    // Without its two numbers there is nothing to say beyond the generic
    // wording, and the generic wording is true: the archive is where it was.
    ExtractFailure.insufficientSpace => 'marketplace.extract_failed',
    // Asked about before it gets here; an archive still refused is where it was.
    ExtractFailure.passwordRequired ||
    ExtractFailure.wrongPassword ||
    ExtractFailure.other =>
      'marketplace.extract_failed',
  };
  return NotificationLines(
    loc.t('${key}_title'),
    loc.t('${key}_body', params: {'path': archivePath}),
    kind: NotificationKind.error,
    actions: actions,
  );
}
