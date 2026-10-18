import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../services/platform_service_factory.dart';
import '../../utils/home_relative.dart';
import '../../utils/state_providers.dart';

/// The strip along the bottom of the window: where ZZMI is, how many library mods are on (one link each in ZZMI's
/// Mods folder), the version. A link the library doesn't own isn't counted.
class AppStatusBar extends ConsumerWidget {
  const AppStatusBar({super.key});

  static const double height = 28;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final zzmi = ref.watch(zzmiPathProvider);
    final active = ref.watch(modsProvider).where((m) => m.isActive).length;
    final mono = ZenithType.of(context).monoSmall.copyWith(color: palette.text3);
    final plain = Theme.of(context).textTheme.labelSmall?.copyWith(color: palette.text3, fontWeight: FontWeight.w400);

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Row(
        spacing: 18,
        children: [
          Expanded(
            child: Row(
              spacing: 18,
              children: [
                if (zzmi.isNotEmpty)
                  Flexible(
                    child: Text(
                      loc.t('shell.status.zzmi', params: {'path': _homeRelative(zzmi)}),
                      style: mono,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Text(loc.plural('shell.status.links', active, params: {'count': '$active'}), style: plain),
              ],
            ),
          ),
          Text('v${AppConstants.appVersion}', style: mono),
        ],
      ),
    );
  }

  static String _homeRelative(String path) =>
      homeRelative(path, home: PlatformServiceFactory.getInstance().homeDirectoryPath);
}
