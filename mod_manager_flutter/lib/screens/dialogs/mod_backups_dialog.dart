import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';
import '../../services/backup/snapshot_service.dart';
import '../../services/update_apply/mod_activation_port.dart';
import '../../services/update_apply/update_applier.dart';
import '../../utils/state_providers.dart';

/// Rolling an update back.
///
/// **This dialog is what makes the update path's accepted losses defensible.**
/// The mechanism deliberately does not try to preserve a rebound keybind or a
/// hand-applied patch it cannot distinguish from the mod itself; the answer to
/// every one of those is "the snapshot has it". That answer is only real while
/// the snapshot is reachable *from inside the app* — if recovering means finding
/// `<appData>/backups` in a file manager, it is not an answer to a user who has
/// just lost a mesh fix.
///
/// A restore is itself snapshotted first, so rolling back the wrong mod, or
/// discovering the old version was the broken one, costs one more click rather
/// than being final.
///
/// Returns true when the mod folder changed, so the caller rescans.
Future<bool> showModBackupsDialog(BuildContext context, ModInfo mod) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => ModBackupsDialog(mod: mod),
    ) ??
    false;

class ModBackupsDialog extends ConsumerStatefulWidget {
  const ModBackupsDialog({super.key, required this.mod});

  final ModInfo mod;

  @override
  ConsumerState<ModBackupsDialog> createState() => _ModBackupsDialogState();
}

class _ModBackupsDialogState extends ConsumerState<ModBackupsDialog> {
  List<ModSnapshot>? _snapshots;
  bool _busy = false;
  bool _changed = false;

  AppLocalizations get loc => context.loc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // By the folder's uid, not its name: a mod renamed in a file manager still
    // finds the versions taken before the rename.
    final snapshots =
        await ref.read(snapshotServiceProvider).list(widget.mod.uid);
    if (!mounted) return;
    setState(() => _snapshots = snapshots);
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = _snapshots;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: AlertDialog(
        title: Text(
          loc.t('mods.backups.title', params: {'mod': widget.mod.name}),
        ),
        content: SizedBox(
          width: 480,
          child: snapshots == null
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator()),
                )
              : snapshots.isEmpty
                  ? Text(loc.t('mods.backups.empty'))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          loc.t('mods.backups.intro'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: [
                              for (final snapshot in snapshots)
                                _row(snapshot),
                            ],
                          ),
                        ),
                      ],
                    ),
        ),
        actions: [
          TextButton(
            onPressed:
                _busy ? null : () => Navigator.of(context).pop(_changed),
            child: Text(loc.t('mods.update.close')),
          ),
        ],
      ),
    );
  }

  Widget _row(ModSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    // The date leads, and the version follows it rather than the other way
    // round: most of a real library records neither `version` nor
    // `version_label`, so a list keyed on those would be a column of blanks.
    final subtitle = [
      _formatSize(snapshot.sizeBytes),
      if (snapshot.version case final v? when v.isNotEmpty) v,
      if (snapshot.versionLabel case final l? when l.isNotEmpty) l,
      loc.t(
        snapshot.reason == SnapshotReason.beforeRestore
            ? 'mods.backups.reason_restore'
            : 'mods.backups.reason_update',
      ),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatDate(snapshot.takenAt),
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: loc.t('mods.backups.delete'),
              onPressed: _busy ? null : () => _delete(snapshot),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _restore(snapshot),
              child: Text(loc.t('mods.backups.restore')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore(ModSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.loc.t('mods.backups.confirm_title')),
        content: Text(
          dialogContext.loc.t(
            'mods.backups.confirm_body',
            params: {
              'mod': widget.mod.name,
              'date': _formatDate(snapshot.takenAt),
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.loc.t('mods.update_apply.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.loc.t('mods.backups.restore')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final config = await ApiService.getConfig();
    final modsPath = config['mods_path'] ?? '';
    if (modsPath.isEmpty) {
      // Not reachable from a configured app, but without this the restore runs
      // against a *relative* `Directory(mod.id)` and fails through the generic
      // "couldn't restore" message, which says nothing the user can act on.
      if (!mounted) return;
      setState(() => _busy = false);
      context.notify.error(
        loc.t('marketplace.install_missing_path_title'),
        body: loc.t('marketplace.install_missing_path_body'),
      );
      return;
    }
    final mods = await ApiService.getModManagerService();
    final snapshots = ref.read(snapshotServiceProvider);
    final applier = UpdateApplier(
      snapshots: snapshots,
      activation: ModManagerActivationPort(mods),
    );
    final result = await applier.restore(
      modName: widget.mod.id,
      modFolder: Directory(path.join(modsPath, widget.mod.id)),
      snapshot: snapshot,
    );

    // **A rollback takes a safety copy of its own before it writes**, so the
    // budget has moved here as much as on any other write — and rolling back is
    // when the store is most likely to be large, since that is what having one
    // is for. Whether the restore landed or not: the copy was taken first.
    if (result.snapshot != null) await snapshots.prune();
    if (!mounted) return;

    _changed = _changed || result.success;
    ref.invalidate(modBackupsProvider);
    setState(() => _busy = false);
    await _load();
    if (!mounted) return;

    context.notify.show(
      loc.t(result.success
          ? 'mods.backups.restored_title'
          : 'mods.backups.restore_failed_title'),
      body: widget.mod.name,
      severity: result.success
          ? NotificationSeverity.success
          : NotificationSeverity.error,
      characterId: widget.mod.characterId,
    );
  }

  Future<void> _delete(ModSnapshot snapshot) async {
    setState(() => _busy = true);
    await ref.read(snapshotServiceProvider).delete(snapshot);
    ref.invalidate(modBackupsProvider);
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  static String _formatDate(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
