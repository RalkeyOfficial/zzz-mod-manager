import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../components/zenith_dialog.dart';

/// The blocking card that stays up while an import writes (`docs/importing-mods.md` §7): how many mods it is writing
/// and that it may take a moment. Escape and a press on the scrim do nothing; the caller pops it when the write ends.
///
/// [count] is every mod the write touches, the updated ones included.
void showImportProgressDialog(BuildContext context, {required int count}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ImportProgressDialog(count: count),
  );
}

class ImportProgressDialog extends StatelessWidget {
  const ImportProgressDialog({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    return ZenithDialog.compact(
      busy: true,
      width: 400,
      title: loc.plural('mods.dialog.import_progress', count, params: {'count': '$count'}),
      subtitle: loc.t('mods.dialog.import_progress_hint'),
      body: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(minHeight: 4, color: palette.accent, backgroundColor: palette.track),
      ),
      actions: const [],
    );
  }
}
