import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';

/// Tags every mod whose folder name names a character, answering
/// `folder name → character id` for each one it tagged.
///
/// Production is the library service's `autoTagAllMods`, read through
/// `modManagerServiceProvider`. A seam because the pass rewrites sidecars in
/// whatever library is mounted, and a test that merely pressed the button must
/// not reach one.
typedef AutoTagRunner = Future<Map<String, String>> Function();

/// The Settings tab's **Automatic tagging** section.
///
/// **The progress is on the button, not over the page.** The run disables the
/// button and puts a spinner in place of its icon, and nothing else on the
/// page moves. The tagging happens to mods on another tab, so it is a change
/// the user cannot see, and its success is reported in a dialog.
class AutoTagSettingsSection extends ConsumerStatefulWidget {
  const AutoTagSettingsSection({super.key, this.runner});

  final AutoTagRunner? runner;

  @override
  ConsumerState<AutoTagSettingsSection> createState() =>
      _AutoTagSettingsSectionState();
}

class _AutoTagSettingsSectionState
    extends ConsumerState<AutoTagSettingsSection> {
  static const _accent = Color(0xFF8B5CF6);

  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final isDarkMode = ref.watch(isDarkModeProvider);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkMode ? Colors.grey[850] : Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_accent, Color(0xFFA855F7)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                loc.t('settings.auto_tag.title'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            loc.t('settings.auto_tag.description'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          _Requirement(loc.t('settings.auto_tag.import_hint'), Colors.green),
          const SizedBox(height: 8),
          _Requirement(
            loc.t(
              'settings.auto_tag.characters_supported',
              params: {'count': '${zzzCharactersData.length}'},
            ),
            Colors.green,
          ),
          const SizedBox(height: 8),
          _Requirement(loc.t('settings.auto_tag.naming_hint'), Colors.blue),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _accent.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.lightbulb_outline, color: _accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loc.t('settings.auto_tag.example'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // Disabled while it runs, which is the whole guard: the work is a
              // pass over every mod folder, and two of them interleaving would
              // race on the same sidecars.
              onPressed: _running ? null : _run,
              icon: _running
                  // Sized to the icon it replaces, so the label does not shift
                  // sideways when the spinner appears.
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(
                _running
                    ? loc.t('settings.auto_tag.running')
                    : loc.t('settings.auto_tag.run_action'),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            loc.t('settings.auto_tag.note'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<Map<String, String>> _runThroughLibrary() async =>
      (await ref.read(modManagerServiceProvider.future)).autoTagAllMods();

  Future<void> _run() async {
    final loc = context.loc;
    setState(() => _running = true);
    try {
      final tagged = await (widget.runner ?? _runThroughLibrary)();
      if (!mounted) return;
      if (tagged.isEmpty) {
        context.notify.warning(
          loc.t('settings.auto_tag.no_mods_title'),
          body: loc.t('settings.auto_tag.no_mods_body'),
        );
      } else {
        _showResult(tagged);
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(loc.t('settings.auto_tag.error_title'), body: '$e');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _showResult(Map<String, String> tagged) {
    final loc = context.loc;
    final summary = loc.t(
      'settings.auto_tag.summary',
      params: {
        'count': '${tagged.length}',
        'plural': loc.plural('settings.auto_tag.tag', tagged.length),
      },
    );

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.auto_awesome, color: _accent, size: 28),
            const SizedBox(width: 8),
            Text(loc.t('settings.auto_tag.success_title')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              summary,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accent.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.label, color: _accent, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        loc.t('settings.auto_tag.list_title'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _accent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...tagged.entries.take(5).map(
                        (entry) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '• ${entry.key} → ${getCharacterDisplayName(entry.value)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                  if (tagged.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        loc.t(
                          'mods.import.auto_tag_and_more',
                          params: {'count': '${tagged.length - 5}'},
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              loc.t('settings.auto_tag.success_message'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            child: Text(loc.t('settings.auto_tag.ok')),
          ),
        ],
      ),
    );
  }
}

/// One line of what the pass needs, ticked in [color].
class _Requirement extends StatelessWidget {
  const _Requirement(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          alignment: Alignment.center,
          child: Text(
            '✓',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
          ),
        ),
      ],
    );
  }
}
