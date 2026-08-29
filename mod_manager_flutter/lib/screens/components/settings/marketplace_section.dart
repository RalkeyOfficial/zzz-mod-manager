import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/state_providers.dart';
import 'settings_row.dart';

/// Persists the content filter. Production is [ApiService].
///
/// A seam for the same reason [UpdatesSettingsSection]'s is — see
/// `updates_section.dart`.
typedef ContentFilterWriter = Future<void> Function(ContentFilterMode mode);

/// The Settings tab's **Marketplace** section: the adult-content filter.
///
/// **A second home for a control that already exists in the marketplace
/// toolbar, deliberately.** The toolbar is where it is first needed — the grid
/// is the first thing a user hits it on — but it is also where nobody looks for
/// a preference they set once. Both write the same key and both read the same
/// provider, so the two can never disagree; what the toolbar has that this does
/// not is proximity to the thing being filtered.
///
/// A dropdown rather than the toolbar's icon menu: an icon is enough beside the
/// grid it acts on, where a settings list has to name the current value without
/// being hovered.
class MarketplaceSettingsSection extends ConsumerWidget {
  const MarketplaceSettingsSection({super.key, this.writer});

  final ContentFilterWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final mode = ref.watch(contentFilterProvider);

    return SettingsRow(
      label: loc.t('marketplace.content_filter'),
      description: loc.t('settings.marketplace.content_filter_hint'),
      trailing: DropdownButton<ContentFilterMode>(
        value: mode,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(8),
        items: [
          for (final value in ContentFilterMode.values)
            DropdownMenuItem(
              value: value,
              child: Text(
                loc.t('marketplace.content_filter_${value.wire}'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
        onChanged: (value) {
          if (value == null) return;
          ref.read(contentFilterProvider.notifier).state = value;
          (writer ?? ApiService.setContentFilter)(value);
        },
      ),
    );
  }
}
