import '../../l10n/app_localizations.dart';
import '../../utils/notifications.dart';

/// Reports that [mods] stayed off because their link leads to a network folder, which this system can only link
/// with a symlink, and it refused one (`NetworkLinkRefused`).
void reportNetworkLinkRefused(
  AppLocalizations loc,
  NotificationCenter notify,
  Iterable<String> mods, {
  String? characterId,
}) {
  notify.error(
    loc.t('mods.errors.network_link_title'),
    body: loc.t('mods.errors.network_link_body', params: {'mods': mods.join(', ')}),
    characterId: characterId,
  );
}
