import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/state_providers.dart';

/// Shown in place of the mods grid when active filters match nothing. [onClear]
/// resets the filters.
class ModsNoResults extends StatelessWidget {
  const ModsNoResults({super.key, required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            loc.t('mods.toolbar.no_results'),
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.clear, size: 18),
            label: Text(loc.t('mods.toolbar.clear_filters')),
          ),
        ],
      ),
    );
  }
}

/// The dashed "add a mod" card. Highlights while [isDragging] to signal a valid
/// drop target; [onTap] opens the import dialog.
class AddModCard extends ConsumerWidget {
  const AddModCard({super.key, required this.isDragging, required this.onTap});

  final bool isDragging;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final isDarkMode = ref.watch(isDarkModeProvider);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDragging
                  ? [
                      const Color(0xFF0EA5E9).withOpacity(0.3),
                      const Color(0xFF06B6D4).withOpacity(0.3),
                    ]
                  : [
                      isDarkMode
                          ? const Color(0xFF1F2937).withOpacity(0.5)
                          : const Color(0xFFF9FAFB),
                      isDarkMode
                          ? const Color(0xFF111827).withOpacity(0.5)
                          : const Color(0xFFF3F4F6),
                    ],
            ),
            border: Border.all(
              color: isDragging
                  ? const Color(0xFF0EA5E9)
                  : isDarkMode
                  ? Colors.white.withOpacity(0.1)
                  : Colors.black.withOpacity(0.08),
              width: isDragging ? 2.5 : 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
            boxShadow: isDragging
                ? [
                    BoxShadow(
                      color: const Color(0xFF0EA5E9).withOpacity(0.3),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: isDarkMode
                          ? Colors.black.withOpacity(0.2)
                          : Colors.grey.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(19)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDragging
                        ? const Color(0xFF0EA5E9).withOpacity(0.2)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.05)
                              : Colors.black.withOpacity(0.03)),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isDragging ? Icons.file_download : Icons.add,
                    size: 48,
                    color: isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.6)
                              : Colors.black.withOpacity(0.4)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isDragging
                      ? loc.t('mods.empty.prompt')
                      : loc.t('mods.empty.cta'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isDragging
                        ? const Color(0xFF0EA5E9)
                        : (isDarkMode
                              ? Colors.white.withOpacity(0.7)
                              : Colors.black.withOpacity(0.6)),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    isDragging
                        ? loc.t('mods.empty.add_folders')
                        : loc.t('mods.empty.drag'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDarkMode
                          ? Colors.white.withOpacity(0.5)
                          : Colors.black.withOpacity(0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
