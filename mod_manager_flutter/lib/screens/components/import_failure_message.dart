import '../../l10n/app_localizations.dart';
import '../../models/app_notification.dart';
import '../../services/import_result.dart';
import '../../utils/byte_format.dart';

/// What to say when an import installed nothing.
///
/// Shared by the marketplace install and the drag-in path, so the two cannot
/// word the same refusal differently. **A genuine duplicate never reaches
/// here** — it carries no [ImportFailure], and each caller keeps its own
/// wording for it; everything that does reach here is something the user can
/// act on, and says which.
///
/// Only the space case has numbers, and it needs them: "not enough space"
/// without a figure leaves the user guessing how much to clear.
NotificationLines importFailureMessage(
  AppLocalizations loc,
  ImportFailure failure, {
  int? requiredBytes,
  int? availableBytes,
}) {
  if (failure == ImportFailure.notEnoughSpace &&
      requiredBytes != null &&
      availableBytes != null) {
    return NotificationLines(
      loc.t('mods.import_failed.no_space_title'),
      loc.t('mods.import_failed.no_space_body', params: {
        'required': formatBytes(requiredBytes),
        'available': formatBytes(availableBytes),
      }),
      kind: NotificationKind.error,
    );
  }

  final key = switch (failure) {
    // Without its figures there is nothing specific left to say, and the copy
    // did fail — which is what the generic wording says.
    ImportFailure.notEnoughSpace => 'mods.import_failed.copy',
    ImportFailure.libraryNotConfigured => 'mods.import_failed.library',
    ImportFailure.copyFailed => 'mods.import_failed.copy',
    ImportFailure.nothingUsable => 'mods.import_failed.nothing',
  };
  return NotificationLines(loc.t('${key}_title'), loc.t('${key}_body'), kind: NotificationKind.error);
}
