import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../components/mod_thumb.dart';
import '../components/zenith_dialog.dart';

/// What the unrecorded-patch question was answered with. Closing it answers nothing, which is null.
enum UnrecordedPatchAnswer { updateAnyway, skip }

/// The small question an update asks when [mod]'s folder holds a patch nothing records (`docs/update-runs.md` §10):
/// updating removes the patch from the folder, and the saved copy keeps it.
Future<UnrecordedPatchAnswer?> showUnrecordedPatchDialog(BuildContext context, {required ModInfo mod}) {
  final loc = context.loc;
  return showDialog<UnrecordedPatchAnswer>(
    context: context,
    builder: (dialogContext) => ZenithDialog.compact(
      width: 460,
      alert: true,
      title: loc.t('downloads.update.unrecorded.title', params: {'mod': mod.name}),
      leading: ModThumb(mod: mod, width: 44, height: 32, radius: 6, bordered: true),
      body: Text(
        loc.t('downloads.update.unrecorded.body'),
        style: Theme.of(dialogContext).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(UnrecordedPatchAnswer.skip),
          child: Text(loc.t('downloads.update.skip')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(UnrecordedPatchAnswer.updateAnyway),
          child: Text(loc.t('downloads.update.update_anyway')),
        ),
      ],
    ),
  );
}
