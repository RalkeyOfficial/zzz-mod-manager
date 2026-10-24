import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/app_update_service.dart';
import '../../../services/platform_service_factory.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';

/// The card that closes the Settings page: the name and version, what the last update check found, and links to the
/// source and to reporting a problem. About's pane says more.
class SettingsAboutCard extends ConsumerWidget {
  const SettingsAboutCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    final result = ref.watch(appUpdateResultProvider);
    // A pre-release build is only known to have no newer stable release, which About says in full: the card says
    // nothing rather than claim "the latest".
    final status = switch (result?.outcome) {
      AppUpdateOutcome.upToDate when result?.runningPreRelease ?? false => null,
      AppUpdateOutcome.upToDate => loc.t('settings.about_card.latest'),
      AppUpdateOutcome.newer => loc.t('settings.about_card.newer', params: {'version': result?.latest ?? ''}),
      _ => null,
    };
    final dark = palette.brightness == Brightness.dark;

    Future<void> open(String url) async {
      final notify = context.notify;
      if (!await PlatformServiceFactory.getInstance().openUrlInBrowser(url)) {
        notify.error(loc.t('about.links.open_failed'), body: url);
      }
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 16,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 14,
              children: [
                Image.asset(
                  dark ? 'assets/brand/logo-mark-on-dark.png' : 'assets/brand/logo-mark-on-light.png',
                  width: 44,
                  height: 44,
                  excludeFromSemantics: true,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: 'Zenith ',
                        children: [
                          TextSpan(
                            text: AppConstants.appVersion,
                            style: TextStyle(fontFamily: kMonoFont, fontWeight: FontWeight.w400, color: palette.text2),
                          ),
                        ],
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text),
                    ),
                    if (status != null)
                      Text(status, style: theme.textTheme.bodySmall?.copyWith(color: palette.text3)),
                  ],
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => open(AppConstants.repositoryUrl),
                  child: Text(loc.t('about.links.source')),
                ),
                TextButton(
                  onPressed: () => open('${AppConstants.repositoryUrl}/issues/new'),
                  child: Text(loc.t('about.links.report')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
