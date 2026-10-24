import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/platform_service.dart';
import '../../../services/platform_service_factory.dart';
import '../../../utils/home_relative.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../../shell/launch_game.dart';
import '../zenith_switch.dart';
import 'settings_widgets.dart';

/// Where `umu-run` was found, or null when it is not installed. Only Linux has one.
final umuRunProvider = FutureProvider.autoDispose<String?>((ref) => PlatformServiceFactory.getInstance().findUmuRun());

/// Settings' **Launching** section: what the sidebar's Launch game button starts and how: the launcher, its
/// arguments, and on Linux the Wine or Proton that runs it and the prefix. Each row saves as it changes. See
/// `docs/launch-game.md`.
class LaunchSettingsSection extends ConsumerWidget {
  const LaunchSettingsSection({super.key, this.picker, this.writer, this.umuWriter, this.platform});

  final LaunchPathPicker? picker;
  final LaunchSettingWriter? writer;

  /// Saves the umu-launcher switch. Production is [ApiService.setWineUseUmu].
  final Future<void> Function(bool useUmu)? umuWriter;
  final PlatformService? platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final platform = this.platform ?? PlatformServiceFactory.getInstance();
    final write = writer ?? writeLaunchSetting;

    final target = ref.watch(launchTargetProvider);
    final launcher = target.isNotEmpty ? target : ref.watch(xxmiLauncherProvider).valueOrNull;
    final runner = ref.watch(wineRunnerProvider);
    final prefix = ref.watch(winePrefixProvider);
    final layout = ref.watch(winePrefixLayoutProvider).valueOrNull ?? WinePrefixLayout.compatData;
    final isProton = WineRunner.isProton(runner);
    final useUmu = ref.watch(wineUseUmuProvider);
    final directProton = isProton && !useUmu;

    Widget path(String full) => SettingsValue(homeRelative(full, home: platform.homeDirectoryPath));
    Widget plain(String key) => Text(loc.t(key), style: text.bodySmall?.copyWith(color: palette.text3));
    Widget warning(String key) => SettingsWarning(loc.t(key));
    Widget pathWith(String full, String warningKey) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [path(full), warning(warningKey)],
    );

    Future<void> change(LaunchSetting setting) async {
      final picked = await (picker ?? pickLaunchPath)(context, setting);
      if (picked != null) await write(setting, picked);
    }

    // Reset shows only while something is chosen, since there is nothing to go back from otherwise.
    Widget controls(LaunchSetting setting, {required bool chosen, String? open}) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (chosen) TextButton(onPressed: () => write(setting, null), child: Text(loc.t('settings.launch.reset'))),
        if (open != null)
          TextButton(
            onPressed: () => openFolderOrReport(loc, context.notify, open),
            child: Text(loc.t('settings.open')),
          ),
        OutlinedButton(onPressed: () => change(setting), child: Text(loc.t('settings.launch.change'))),
      ],
    );

    return SettingsSectionBlock(
      title: loc.t('settings.launch.title'),
      subtitle: loc.t(platform.launchesThroughWine ? 'settings.launch.subtitle_linux' : 'settings.launch.subtitle_windows'),
      children: [
        SettingsRow(
          label: loc.t('settings.launch.label'),
          description: loc.t('settings.launch.hint'),
          detail: launcher != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [path(launcher), SettingsOk(loc.t('settings.launch.found'))],
                )
              : warning('settings.launch.missing'),
          trailing: controls(LaunchSetting.target, chosen: target.isNotEmpty),
        ),
        SettingsRow(
          label: loc.t('settings.launch.arguments'),
          description: loc.t('settings.launch.arguments_hint'),
          trailing: _ArgumentsField(write: write),
        ),
        if (platform.launchesThroughWine) ...[
          SettingsRow(
            label: loc.t('settings.launch.umu'),
            description: loc.t('settings.launch.umu_hint'),
            detail: switch (ref.watch(umuRunProvider)) {
              AsyncData(value: final found?) => SettingsOk(
                loc.t('settings.launch.umu_found'),
                mono: found,
                top: 4,
              ),
              // Only a Proton runner goes through umu-run, so only for one is a missing umu-run a problem.
              AsyncData() when isProton => warning('settings.launch.umu_missing'),
              _ => null,
            },
            trailing: ZenithSwitch(
              value: useUmu,
              semanticLabel: loc.t('settings.launch.umu'),
              onChanged: (value) {
                ref.read(wineUseUmuProvider.notifier).state = value;
                (umuWriter ?? ApiService.setWineUseUmu)(value);
              },
            ),
          ),
          SettingsRow(
            label: loc.t('settings.launch.runner'),
            description: loc.t(useUmu ? 'settings.launch.runner_hint_umu' : 'settings.launch.runner_hint'),
            trailing: _RunnerControl(
              runner: runner,
              pickFile: () => (picker ?? pickLaunchPath)(context, LaunchSetting.runner),
              write: write,
            ),
          ),
          SettingsRow(
            label: loc.t('settings.launch.prefix'),
            description: loc.t('settings.launch.prefix_hint'),
            detail: prefix.isEmpty
                // Proton started directly has no default prefix of its own.
                ? (directProton ? warning('settings.launch.prefix_required') : plain('settings.launch.prefix_default'))
                : switch (layout) {
                    WinePrefixLayout.missing => pathWith(prefix, 'settings.launch.prefix_missing'),
                    WinePrefixLayout.plain when directProton => pathWith(prefix, 'settings.launch.prefix_nested'),
                    WinePrefixLayout.protonOnly when !isProton => pathWith(prefix, 'settings.launch.prefix_proton_only'),
                    _ => path(prefix),
                  },
            trailing: controls(LaunchSetting.prefix, chosen: prefix.isNotEmpty, open: prefix.isEmpty ? null : prefix),
          ),
        ],
      ],
    );
  }
}

/// The Wine and Proton builds found on this machine, by the name the user knows them by (`dwproton-11.0-5`), with
/// System Wine first, and beside them a folder button for a build that isn't on the list.
class _RunnerControl extends ConsumerWidget {
  const _RunnerControl({required this.runner, required this.pickFile, required this.write});

  final String runner;
  final Future<String?> Function() pickFile;
  final LaunchSettingWriter write;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final found = ref.watch(wineRunnersProvider).valueOrNull ?? const <WineRunner>[];

    Future<void> pick() async {
      final picked = await pickFile();
      if (picked != null) await write(LaunchSetting.runner, picked);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        SettingsSelect<String>(
          value: runner,
          semanticLabel: loc.t('settings.launch.runner'),
          options: [
            ('', loc.t('settings.launch.runner_default')),
            for (final build in found) (build.path, build.name),
            if (runner.isNotEmpty && !found.any((b) => b.path == runner)) (runner, WineRunner.nameOf(runner)),
          ],
          onChanged: (value) {
            if (value != runner) write(LaunchSetting.runner, value.isEmpty ? null : value);
          },
        ),
        SettingsIconButton(
          icon: Icons.folder_outlined,
          tooltip: loc.t('settings.launch.runner_choose'),
          onPressed: pick,
        ),
      ],
    );
  }
}

/// The arguments as one line of text. The button uses what is on screen at once; it is saved on Enter or when the
/// field loses focus, so typing doesn't rewrite `config.json` on every key.
class _ArgumentsField extends ConsumerStatefulWidget {
  const _ArgumentsField({required this.write});

  final LaunchSettingWriter write;

  @override
  ConsumerState<_ArgumentsField> createState() => _ArgumentsFieldState();
}

class _ArgumentsFieldState extends ConsumerState<_ArgumentsField> {
  static const double _width = 280;

  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  late String _saved;

  @override
  void initState() {
    super.initState();
    _saved = ref.read(launchArgumentsProvider);
    _controller = TextEditingController(text: _saved);
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The default typed back is stored as no value, so the setting keeps following the default.
  void _save() {
    if (_controller.text == _saved) return;
    _saved = _controller.text;
    widget.write(LaunchSetting.arguments, _saved == AppConstants.defaultLaunchArguments ? null : _saved);
  }

  void _reset() {
    _controller.text = AppConstants.defaultLaunchArguments;
    _saved = _controller.text;
    ref.read(launchArgumentsProvider.notifier).state = _saved;
    widget.write(LaunchSetting.arguments, null);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _controller.text == AppConstants.defaultLaunchArguments
              ? const SizedBox.shrink()
              : TextButton(onPressed: _reset, child: Text(context.loc.t('settings.launch.reset'))),
        ),
        SizedBox(
          width: _width,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            style: ZenithType.of(context).mono,
            onChanged: (value) => ref.read(launchArgumentsProvider.notifier).state = value,
            onSubmitted: (_) => _save(),
          ),
        ),
      ],
    );
  }
}
