import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../utils/notifications.dart';

/// Reports why a mod stayed off because its shader files could not be placed.
void notifyShaderRefusal(
  BuildContext context,
  ShaderPlacementRefused refusal, {
  String? characterId,
}) =>
    reportShaderRefusal(context.loc, context.notify, refusal, characterId: characterId);

/// [notifyShaderRefusal] for work that outlives the page it started on, which takes [loc] and [notify] before it
/// waits.
void reportShaderRefusal(
  AppLocalizations loc,
  NotificationCenter notify,
  ShaderPlacementRefused refusal, {
  String? characterId,
}) {
  if (refusal.noShaderFolder) {
    notify.error(
      loc.t('mods.shader_fixes.no_folder_title'),
      body: loc.t('mods.shader_fixes.no_folder_body', params: {'mod': refusal.mod}),
      characterId: characterId,
    );
    return;
  }
  // Named after the first owner found; a second owner is found on the next try.
  final first = refusal.conflicts.where((c) => c.owner != null).firstOrNull;
  final owner = first?.owner;
  final files = refusal.conflicts.where((c) => c.owner == owner).map((c) => c.path).join(', ');
  final stillOn = refusal.stillOn;
  if (first != null && stillOn != null && first.ownerUid == stillOn.uid) {
    notify.error(
      loc.t('mods.shader_fixes.taken_still_on_title'),
      body: loc.t('mods.shader_fixes.taken_still_on_body',
          params: {'mod': refusal.mod, 'files': files, 'link': stillOn.link}),
      characterId: characterId,
    );
  } else if (owner != null && owner == refusal.mod) {
    // Another copy of this mod that no link it replaces leads to, such as one in a folder that can't be read.
    notify.error(
      loc.t('mods.shader_fixes.taken_copy_title'),
      body: loc.t('mods.shader_fixes.taken_copy_body', params: {'mod': refusal.mod, 'files': files}),
      characterId: characterId,
    );
  } else if (owner == null && refusal.conflicts.any((c) => c.link)) {
    notify.error(
      loc.t('mods.shader_fixes.taken_link_title'),
      body: loc.t('mods.shader_fixes.taken_link_body', params: {
        'mod': refusal.mod,
        'files': refusal.conflicts.where((c) => c.link).map((c) => c.path).join(', '),
      }),
      characterId: characterId,
    );
  } else if (owner == null) {
    notify.error(
      loc.t('mods.shader_fixes.taken_unowned_title'),
      body: loc.t('mods.shader_fixes.taken_unowned_body',
          params: {'mod': refusal.mod, 'files': files}),
      characterId: characterId,
    );
  } else {
    notify.error(
      loc.t('mods.shader_fixes.taken_title'),
      body: loc.t('mods.shader_fixes.taken_body',
          params: {'mod': refusal.mod, 'files': files, 'owner': owner}),
      characterId: characterId,
    );
  }
}

/// Says once that shader changes need a game restart, whichever flow made them,
/// says when a mod used shader files that were already there, reports a mod
/// an update left off because its shader files were refused, and reports another
/// copy's files that could not be put back after an enable that failed.
///
/// Mounted above the tabs like `DownloadQueueHost`, since an update or a delete
/// changes placed files as surely as a toggle does. Changes arriving together —
/// an update switches a mod off and on again — become one notice.
class ShaderRestartNoticeHost extends StatefulWidget {
  const ShaderRestartNoticeHost({super.key, required this.child});

  final Widget child;

  @override
  State<ShaderRestartNoticeHost> createState() => _ShaderRestartNoticeHostState();
}

class _ShaderRestartNoticeHostState extends State<ShaderRestartNoticeHost> {
  late final StreamSubscription<String> _subscription;
  late final StreamSubscription<ShaderPlacementRefused> _refusals;
  late final StreamSubscription<ShaderAdoption> _adoptions;
  late final StreamSubscription<ShaderRestoreShortfall> _shortfalls;
  final Set<String> _pending = {};
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _subscription = ShaderFixesService.changes.listen((mod) {
      _pending.add(mod);
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 800), _announce);
    });
    _refusals = ShaderFixesService.unattendedRefusals.listen((refusal) {
      if (mounted) notifyShaderRefusal(context, refusal);
    });
    _adoptions = ShaderFixesService.adoptions.listen(_announceAdoption);
    _shortfalls = ShaderFixesService.shortfalls.listen(_announceShortfall);
  }

  void _announceShortfall(ShaderRestoreShortfall shortfall) {
    if (!mounted) return;
    final loc = context.loc;
    context.notify.warning(
      loc.t('mods.shader_fixes.not_restored_title'),
      body: loc.t('mods.shader_fixes.not_restored_body',
          params: {'mod': shortfall.mod, 'folder': shortfall.folder, 'files': shortfall.files.join(', ')}),
    );
  }

  void _announce() {
    if (!mounted || _pending.isEmpty) return;
    final loc = context.loc;
    context.notify.note(
      loc.t('mods.shader_fixes.restart_title'),
      body: loc.t('mods.shader_fixes.restart_body', params: {'mods': _pending.join(', ')}),
    );
    _pending.clear();
  }

  void _announceAdoption(ShaderAdoption adoption) {
    if (!mounted) return;
    final loc = context.loc;
    // Several in a row count on one card, which lists the mods.
    context.notify.note(
      loc.t('mods.shader_fixes.adopted_title'),
      body: loc.plural('mods.shader_fixes.adopted_body', adoption.count,
          params: {'mod': adoption.mod, 'count': '${adoption.count}'}),
      repeat: NotificationRepeat(
        'shader-adopted',
        subjects: [adoption.mod],
        body: (count) => loc.plural('mods.shader_fixes.adopted_many', count, params: {'count': '$count'}),
      ),
    );
  }

  @override
  void dispose() {
    _settle?.cancel();
    _subscription.cancel();
    _refusals.cancel();
    _adoptions.cancel();
    _shortfalls.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
