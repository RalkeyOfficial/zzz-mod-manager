import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../utils/byte_format.dart';
import '../components/mod_thumb.dart';
import '../components/resolve/resolve_fragments.dart' show formatResolveDate;
import '../components/zenith_dialog.dart';

/// Asks whether to write [file], the file [mod] came from, over the folder again, and says what that does. True when
/// the user said yes; the download, the question about the layout and the write follow (`docs/applying-updates.md` §6).
Future<bool> showReinstallDialog(BuildContext context, {required ModInfo mod, required GbFile file}) async =>
    await showDialog<bool>(context: context, builder: (_) => ReinstallDialog(mod: mod, file: file)) ?? false;

class ReinstallDialog extends StatelessWidget {
  const ReinstallDialog({super.key, required this.mod, required this.file});

  final ModInfo mod;
  final GbFile file;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final mono = ZenithType.of(context).mono;
    final variant = file.description?.trim();
    final date = file.dateAdded;
    final size = file.filesize;
    final facts = [
      if (variant != null && variant.isNotEmpty) loc.t('library.updates.variant', params: {'label': variant}),
      if (date != null) loc.t('library.details.uploaded_on', params: {'date': formatResolveDate(date)}),
      if (size != null) formatBytes(size),
    ];

    Widget step(int number, String key) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.raised,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.fieldBorder),
          ),
          child: Text('$number', style: ZenithType.of(context).monoSmall.copyWith(color: palette.textProse)),
        ),
        Expanded(
          child: Text(loc.t(key), style: text.bodyMedium?.copyWith(color: palette.textProse)),
        ),
      ],
    );

    return ZenithDialog.compact(
      width: 520,
      leading: ModThumb(mod: mod, width: 64, height: 44, radius: 8, spacing: 7, bordered: true),
      title: loc.t('mods.reinstall.title', params: {'mod': mod.name}),
      subtitleWidget: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: fileDisplayName(file), style: mono),
            for (final fact in facts) TextSpan(text: ' · $fact'),
          ],
        ),
        style: text.bodySmall?.copyWith(color: palette.text3),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 18,
        children: [
          Text(loc.t('mods.reinstall.intro'), style: text.bodyMedium?.copyWith(color: palette.textProse, height: 1.6)),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.ground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                step(1, 'mods.reinstall.step1'),
                step(2, 'mods.reinstall.step2'),
                step(3, 'mods.reinstall.step3'),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: Text(loc.t('mods.update_apply.cancel'))),
        FilledButton.icon(
          key: const ValueKey('reinstall_confirm'),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.download_rounded),
          label: Text(loc.t('mods.reinstall.confirm')),
        ),
      ],
    );
  }
}
