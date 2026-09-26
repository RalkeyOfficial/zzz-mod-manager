import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../core/constants.dart';
import '../services/api_service.dart';
import '../utils/notifications.dart';
import '../utils/state_providers.dart';
import '../l10n/app_localizations.dart';
import 'components/settings/appearance_section.dart';
import 'components/settings/auto_tag_section.dart';
import 'components/settings/diagnostics_section.dart';
import 'components/settings/marketplace_section.dart';
import 'components/settings/updates_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with TickerProviderStateMixin {
  final _modsPathController = TextEditingController();
  final _saveModsPathController = TextEditingController();
  /// Whether the first read of the config has landed. Flipped once, and never
  /// back: while it is false the whole page body is the loading spinner, and
  /// swapping the body disposes the [AnimationLimiter] below, so anything that
  /// cleared it later would make every section replay its staggered entrance.
  /// A long-running *action* reports on the control that started it instead.
  bool _loaded = false;
  String _selectedLanguage = 'en';
  bool _isUpdatingLanguage = false;
  late AnimationController _loadingAnimationController;
  late Animation<double> _loadingAnimation;

  @override
  void initState() {
    super.initState();
    _loadingAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _loadingAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _loadingAnimationController,
      curve: Curves.easeInOut,
    ));
    loadConfig();
  }

  @override
  void dispose() {
    _loadingAnimationController.dispose();
    _modsPathController.dispose();
    _saveModsPathController.dispose();
    super.dispose();
  }

  Future<void> loadConfig() async {
    try {
      final config = await ApiService.getConfig();
      if (!mounted) return;
      setState(() {
        _modsPathController.text = config['mods_path'] ?? '';
        _saveModsPathController.text = config['save_mods_path'] ?? '';
        _selectedLanguage = config['language'] ?? 'en';
        _loaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> pickModsPath() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() => _modsPathController.text = result);
    }
  }

  Future<void> pickSaveModsPath() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() => _saveModsPathController.text = result);
    }
  }

  Future<void> saveConfig() async {
    final loc = context.loc;
    try {
      await ApiService.updateConfig(
        modsPath: _modsPathController.text,
        saveModsPath: _saveModsPathController.text,
      );
      if (mounted) {
        context.notify.success(
          loc.t('settings.save_success_title'),
          body: loc.t('settings.save_success_body'),
        );
      }
    } catch (e) {
      if (mounted) {
        context.notify.error(
          loc.t('settings.errors.generic_title'),
          body: '$e',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final isDarkMode = ref.watch(isDarkModeProvider);

    return Column(
      children: [
        // Header
        Container(
          padding: EdgeInsets.all(AppConstants.defaultPadding * 1.5),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border(
              bottom: BorderSide(
                color: isDarkMode ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                loc.t('settings.title'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        // Content
        Expanded(
          child: !_loaded
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _loadingAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: 0.8 + (_loadingAnimation.value * 0.2),
                            child: Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF0EA5E9), Color(0xFF06B6D4)],
                                ),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                ],
                              ),
                              child: const CircularProgressIndicator(
                                strokeWidth: 3,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      AnimatedBuilder(
                        animation: _loadingAnimation,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _loadingAnimation.value,
                            child: Text(
                              loc.t('settings.loading'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                )
              : AnimationLimiter(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: AnimationConfiguration.toStaggeredList(
                        duration: const Duration(milliseconds: 375),
                        childAnimationBuilder: (widget) => SlideAnimation(
                          verticalOffset: 50.0,
                          child: FadeInAnimation(child: widget),
                        ),
                        children: [
                          // Paths Section
                          _buildSectionTitle(loc.t('settings.sections.paths')),
                          const SizedBox(height: 16),
                          _buildPathField(
                            label: loc.t('settings.paths.mods'),
                            hint: loc.t('settings.paths.mods_hint'),
                            controller: _modsPathController,
                            onBrowse: pickModsPath,
                            isDarkMode: isDarkMode,
                            loc: loc,
                          ),
                          const SizedBox(height: 16),
                          _buildPathField(
                            label: loc.t('settings.paths.save_mods'),
                            hint: loc.t('settings.paths.save_mods_hint'),
                            controller: _saveModsPathController,
                            onBrowse: pickSaveModsPath,
                            isDarkMode: isDarkMode,
                            loc: loc,
                          ),
                          const SizedBox(height: 32),
                          // Language Section
                          _buildSectionTitle(loc.t('settings.sections.language')),
                          const SizedBox(height: 16),
                          _buildLanguageSelector(loc, isDarkMode),
                          const SizedBox(height: 32),
                          // Updates Section
                          _buildSectionTitle(loc.t('settings.sections.updates')),
                          const SizedBox(height: 16),
                          const UpdatesSettingsSection(),
                          const SizedBox(height: 32),
                          // Marketplace Section
                          _buildSectionTitle(
                            loc.t('settings.sections.marketplace'),
                          ),
                          const SizedBox(height: 16),
                          const MarketplaceSettingsSection(),
                          const SizedBox(height: 32),
                          // Auto-Tagging Section
                          _buildSectionTitle(loc.t('settings.sections.auto_tag')),
                          const SizedBox(height: 16),
                          const AutoTagSettingsSection(),
                          const SizedBox(height: 32),
                          // Appearance Section
                          _buildSectionTitle(loc.t('settings.sections.appearance')),
                          const SizedBox(height: 16),
                          const AppearanceSettingsSection(),
                          const SizedBox(height: 32),
                          // Diagnostics — last, because it is about the app
                          // rather than about the user's mods.
                          _buildSectionTitle(
                            loc.t('settings.sections.diagnostics'),
                          ),
                          const SizedBox(height: 16),
                          const DiagnosticsSettingsSection(),
                          const SizedBox(height: 32),
                          // Save Button
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: saveConfig,
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: Text(loc.t('settings.actions.save_configuration')),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF0EA5E9),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Info Card
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0EA5E9).withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFF0EA5E9).withValues(alpha: 0.1),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 20,
                                  color: const Color(0xFF0EA5E9),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    loc.t('settings.info.symlinks'),
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildLanguageSelector(AppLocalizations loc, bool isDarkMode) {
    final languageItems = {
      'en': loc.t('language_names.en'),
      'uk': loc.t('language_names.uk'),
    };

    return _buildSettingRow(
      label: loc.t('settings.language.label'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedLanguage,
              onChanged: _isUpdatingLanguage
                  ? null
                  : (value) => _changeLanguage(value, loc),
              items: languageItems.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
            ),
          ),
          if (_isUpdatingLanguage) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 16,
              height: 16,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
      isDarkMode: isDarkMode,
    );
  }

  Future<void> _changeLanguage(String? languageCode, AppLocalizations loc) async {
    if (languageCode == null || languageCode == _selectedLanguage) {
      return;
    }

    setState(() {
      _selectedLanguage = languageCode;
      _isUpdatingLanguage = true;
    });

    ref.read(localeProvider.notifier).state = Locale(languageCode);

    try {
      await ApiService.setLanguage(languageCode);
    } catch (e) {
      if (mounted) {
        context.notify.error(
          context.loc.t('settings.language.error_title'),
          body: '$e',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingLanguage = false);
      }
    }
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildPathField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required VoidCallback onBrowse,
    required bool isDarkMode,
    required AppLocalizations loc,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: Colors.grey[600],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[500]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDarkMode ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.1),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: isDarkMode ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.1),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF0EA5E9)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  isDense: true,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onBrowse,
              icon: const Icon(Icons.folder_outlined, size: 18),
              label: Text(loc.t('settings.paths.browse')),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingRow({
    required String label,
    required Widget trailing,
    required bool isDarkMode,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDarkMode ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
          ),
          trailing,
        ],
      ),
    );
  }
}
