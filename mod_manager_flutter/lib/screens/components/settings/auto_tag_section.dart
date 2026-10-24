import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/button_working.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';
import 'settings_widgets.dart';

/// Tags every mod whose folder name names a character, answering `folder name → character id` for each one it tagged.
///
/// Production is the library service's `autoTagAllMods`, read through `modManagerServiceProvider`. A seam because the
/// pass rewrites sidecars in whatever library is mounted, and a test that merely pressed the button must not reach one.
typedef AutoTagRunner = Future<Map<String, String>> Function();

/// The Mods section's **Automatic tagging** row. The pass tags mods on another page, so it is a change the user can't
/// see and says what it did.
class AutoTagRow extends ConsumerWidget {
  const AutoTagRow({super.key, this.runner});

  final AutoTagRunner? runner;

  /// How many tagged mods the report names before it says "and N more".
  static const int _named = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    return SettingsRow(
      label: loc.t('settings.auto_tag.title'),
      description: loc.t('settings.auto_tag.description'),
      trailing: WorkingAction(
        onPressed: (work) => _run(context, ref, work),
        builder: (context, onPressed) => OutlinedButton.icon(
          onPressed: onPressed,
          icon: const WorkingIcon(Icon(Icons.auto_awesome_outlined)),
          label: Text(loc.t('settings.auto_tag.run_action')),
        ),
      ),
    );
  }

  Future<Map<String, String>> _runThroughLibrary(WidgetRef ref) async =>
      (await ref.read(modManagerServiceProvider.future)).autoTagAllMods();

  Future<void> _run(BuildContext context, WidgetRef ref, WorkSpan work) async {
    final loc = context.loc;
    final notify = context.notify;
    try {
      final tagged = await work(() => (runner ?? () => _runThroughLibrary(ref))());
      if (tagged.isEmpty) {
        notify.note(loc.t('settings.auto_tag.no_mods_title'), body: loc.t('settings.auto_tag.no_mods_body'));
        return;
      }
      final named = tagged.entries
          .take(_named)
          .map((entry) => '${entry.key} → ${getCharacterDisplayName(entry.value)}')
          .join('\n');
      final more = tagged.length > _named
          ? '\n${loc.t('mods.import.auto_tag_and_more', params: {'count': '${tagged.length - _named}'})}'
          : '';
      notify.done(
        loc.t(
          'settings.auto_tag.summary',
          params: {'count': '${tagged.length}', 'plural': loc.plural('settings.auto_tag.tag', tagged.length)},
        ),
        body: '$named$more',
      );
    } catch (e) {
      final title = loc.t('settings.auto_tag.error_title');
      notify.error(title, body: '$e', actions: [copyDetailsAction(loc, notify, title: title, body: '$e')]);
    }
  }
}
