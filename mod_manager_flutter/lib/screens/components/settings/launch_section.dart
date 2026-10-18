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
import '../../../utils/state_providers.dart';
import '../../shell/launch_game.dart';
import '../zenith_switch.dart';
import 'settings_row.dart';

/// What the sidebar's Launch game button starts and how: the launcher, its arguments, and on Linux the Wine or Proton
/// that runs it and the prefix. Each row saves as it changes. See `docs/launch-game.md`.
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

    Widget path(String full) => Text(
      homeRelative(full, home: platform.homeDirectoryPath),
      style: ZenithType.of(context).mono.copyWith(color: palette.text2),
    );
    Widget plain(String key) => Text(loc.t(key), style: text.bodySmall?.copyWith(color: palette.text2));
    Widget warning(String key) => Text(loc.t(key), style: text.bodySmall?.copyWith(color: palette.amber));
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
    Widget controls(LaunchSetting setting, {required bool chosen}) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (chosen) TextButton(onPressed: () => write(setting, null), child: Text(loc.t('settings.launch.reset'))),
        OutlinedButton(onPressed: () => change(setting), child: Text(loc.t('settings.launch.change'))),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SettingsRow(
          label: loc.t('settings.launch.label'),
          description: loc.t('settings.launch.hint'),
          detail: launcher != null ? path(launcher) : warning('settings.launch.missing'),
          trailing: controls(LaunchSetting.target, chosen: target.isNotEmpty),
        ),
        SettingsRow(
          label: loc.t('settings.launch.arguments'),
          description: loc.t('settings.launch.arguments_hint'),
          trailing: _ArgumentsField(write: write),
        ),
        if (platform.launchesThroughWine) ...[
          SettingsRow(
            label: loc.t('settings.launch.runner'),
            description: loc.t('settings.launch.runner_hint'),
            detail: runner.isEmpty ? null : path(runner),
            trailing: _RunnerMenu(runner: runner, pickFile: () => (picker ?? pickLaunchPath)(context, LaunchSetting.runner), write: write),
          ),
          if (isProton)
            SettingsRow(
              label: loc.t('settings.launch.umu'),
              description: loc.t('settings.launch.umu_hint'),
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
            trailing: controls(LaunchSetting.prefix, chosen: prefix.isNotEmpty),
          ),
        ],
      ],
    );
  }
}

/// The Wine and Proton builds found on this machine, by the name the user knows them by (`dwproton-11.0-5`), with
/// System Wine first and Other file… last. Typing filters the list.
class _RunnerMenu extends ConsumerStatefulWidget {
  const _RunnerMenu({required this.runner, required this.pickFile, required this.write});

  final String runner;
  final Future<String?> Function() pickFile;
  final LaunchSettingWriter write;

  @override
  ConsumerState<_RunnerMenu> createState() => _RunnerMenuState();
}

class _RunnerMenuState extends ConsumerState<_RunnerMenu> {
  static const double _width = 300;

  /// The entry that opens a file picker. Not a path a runner could have.
  static const String _other = '\u0000other';

  /// Bumped after every pick through Other file…, so the menu shows the stored runner instead of Other file… even
  /// when the picker is cancelled or returns the file already stored.
  int _generation = 0;

  Future<void> _select(String? value) async {
    if (value == null || value == widget.runner) return;
    if (value != _other) return widget.write(LaunchSetting.runner, value.isEmpty ? null : value);
    final picked = await widget.pickFile();
    if (picked != null) await widget.write(LaunchSetting.runner, picked);
    if (mounted) setState(() => _generation++);
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3);
    final found = ref.watch(wineRunnersProvider).valueOrNull ?? const <WineRunner>[];
    final runner = widget.runner;

    DropdownMenuEntry<String> entry(String value, String name, String? tag) => DropdownMenuEntry(
      value: value,
      label: name,
      labelWidget: Text(name, overflow: TextOverflow.ellipsis),
      trailingIcon: tag == null ? null : Text(tag, style: small),
    );

    return DropdownMenu<String>(
      key: ValueKey('$runner#$_generation'),
      width: _width,
      menuHeight: 360,
      initialSelection: runner,
      enableFilter: true,
      requestFocusOnTap: true,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      dropdownMenuEntries: [
        entry('', loc.t('settings.launch.runner_default'), null),
        for (final build in found) entry(build.path, build.name, loc.t('settings.launch.source.${build.source.name}')),
        if (runner.isNotEmpty && !found.any((b) => b.path == runner))
          entry(runner, WineRunner.nameOf(runner), loc.t('settings.launch.runner_chosen')),
        entry(_other, loc.t('settings.launch.runner_other'), null),
      ],
      onSelected: _select,
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
  static const double _width = 260;

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
