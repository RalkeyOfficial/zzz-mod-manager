import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Which folder of a group is being written, and how far through.
class GroupWriteProgress {
  const GroupWriteProgress({
    required this.modName,
    required this.index,
    required this.total,
  });

  final String modName;

  /// One-based, so it reads as "2 of 3" rather than "1 of 3" while the second
  /// one is being written.
  final int index;
  final int total;

  double get fraction => total == 0 ? 0 : (index - 1) / total;
}

/// Progress while one download is written into several mod folders.
///
/// **Only ever shown for more than one folder.** A single update writes one
/// folder in a second or two and has nothing to report between the confirmation
/// and the result; several take that long each, and a dialog closing onto an
/// empty screen for ten seconds reads as the app having forgotten the request.
///
/// Not cancellable, deliberately. Each folder is written under its own snapshot
/// and the folder being copied into right now is the one place a stop would
/// leave a half-written mod — so the way back is "Restore a previous version…",
/// which the result dialog points at.
class UpdateProgressDialog extends StatelessWidget {
  const UpdateProgressDialog({super.key, required this.progress});

  final ValueListenable<GroupWriteProgress> progress;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;

    return ValueListenableBuilder<GroupWriteProgress>(
      valueListenable: progress,
      builder: (context, value, _) {
        return AlertDialog(
          title: Text(loc.t('mods.update_apply.group_progress_title')),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value.fraction),
                const SizedBox(height: 12),
                Text(
                  loc.t(
                    'mods.update_apply.group_progress_step',
                    params: {
                      'mod': value.modName,
                      'index': '${value.index}',
                      'count': '${value.total}',
                    },
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
