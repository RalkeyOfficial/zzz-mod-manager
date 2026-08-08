import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/state_providers.dart';

/// The green/red pill that toggles whether mod changes auto-send F10 to the
/// game. Owns its state through [autoF10ReloadProvider].
class AutoF10Toggle extends ConsumerWidget {
  const AutoF10Toggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final autoF10Enabled = ref.watch(autoF10ReloadProvider);

    return Tooltip(
      message: autoF10Enabled
          ? loc.t('mods.tooltips.auto_f10_on')
          : loc.t('mods.tooltips.auto_f10_off'),
      child: GestureDetector(
        onTap: () {
          ref.read(autoF10ReloadProvider.notifier).state = !autoF10Enabled;
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: autoF10Enabled
                ? const Color(0xFF10B981) // Зелений коли увімкнено
                : const Color(0xFFEF4444), // Червоний коли вимкнено
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:
                    (autoF10Enabled
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444))
                        .withValues(alpha: 0.4),
                blurRadius: 12,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            autoF10Enabled ? Icons.power : Icons.power_off,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

/// The "F10" button that reloads mods in the running game. [busy] disables it
/// and spins the icon; [onReload] performs the reload.
class F10ReloadButton extends StatelessWidget {
  const F10ReloadButton({
    super.key,
    required this.busy,
    required this.onReload,
  });

  final bool busy;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Tooltip(
      message: loc.t('mods.tooltips.reload'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: busy ? null : onReload,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: busy ? 1 : 0,
                    duration: const Duration(milliseconds: 1000),
                    child: Icon(Icons.refresh, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'F10',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "refresh" button that re-reads the mods list from disk. [busy] disables
/// it and swaps the icon for a spinner; [onRefresh] performs the refresh.
class RefreshModsButton extends StatelessWidget {
  const RefreshModsButton({
    super.key,
    required this.busy,
    required this.onRefresh,
  });

  final bool busy;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Tooltip(
      message: loc.t('mods.tooltips.refresh'),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: 0.3),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: busy ? null : onRefresh,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: busy
                        ? const SizedBox(
                            key: ValueKey('loader'),
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.sync,
                            key: ValueKey('icon'),
                            color: Colors.white,
                            size: 18,
                          ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    loc.t('mods.actions.refresh'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
