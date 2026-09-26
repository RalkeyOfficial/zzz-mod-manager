import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/shader_fixes/shader_fixes_service.dart';
import '../../utils/state_providers.dart';

/// The details dialog's line for a mod that carries shader fixes: how many files,
/// and that they live in ZZMI's shader folder only while the mod is on. Nothing
/// for a mod without any.
class ShaderPartSummary extends ConsumerWidget {
  const ShaderPartSummary({super.key, required this.folderName});

  final String folderName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modsPath = ref.watch(modsPathProvider);
    if (modsPath.isEmpty) return const SizedBox.shrink();
    final loc = context.loc;
    final textTheme = Theme.of(context).textTheme;
    return FutureBuilder<int>(
      future: ShaderFixesService.shaderFileCount(p.join(modsPath, folderName)),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        if (count == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.t('mods.details.shader_fixes'),
                // The details dialog's section label.
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[400],
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                loc.plural('mods.details.shader_fixes_files', count, params: {'count': '$count'}),
                style: textTheme.bodyMedium,
              ),
            ],
          ),
        );
      },
    );
  }
}
