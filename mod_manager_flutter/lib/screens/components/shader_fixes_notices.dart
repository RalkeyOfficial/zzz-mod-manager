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
}) {
  final loc = context.loc;
  if (refusal.noShaderFolder) {
    context.notify.error(
      loc.t('mods.shader_fixes.no_folder_title'),
      body: loc.t('mods.shader_fixes.no_folder_body', params: {'mod': refusal.mod}),
      characterId: characterId,
    );
    return;
  }
  // Named after the first owner found; a second owner is found on the next try.
  final owner = refusal.conflicts.map((c) => c.owner).whereType<String>().firstOrNull;
  final files = refusal.conflicts.where((c) => c.owner == owner).map((c) => c.path).join(', ');
  if (owner == null) {
    context.notify.error(
      loc.t('mods.shader_fixes.taken_unowned_title'),
      body: loc.t('mods.shader_fixes.taken_unowned_body',
          params: {'mod': refusal.mod, 'files': files}),
      characterId: characterId,
    );
  } else {
    context.notify.error(
      loc.t('mods.shader_fixes.taken_title'),
      body: loc.t('mods.shader_fixes.taken_body',
          params: {'mod': refusal.mod, 'files': files, 'owner': owner}),
      characterId: characterId,
    );
  }
}

/// Says once that shader changes need a game restart, whichever flow made them,
/// and reports a mod an update left off because its shader files were refused.
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
  }

  void _announce() {
    if (!mounted || _pending.isEmpty) return;
    final loc = context.loc;
    context.notify.info(
      loc.t('mods.shader_fixes.restart_title'),
      body: loc.t('mods.shader_fixes.restart_body', params: {'mods': _pending.join(', ')}),
    );
    _pending.clear();
  }

  @override
  void dispose() {
    _settle?.cancel();
    _subscription.cancel();
    _refusals.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
