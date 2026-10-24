import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/platform_service_factory.dart';
import '../../../services/shader_fixes/zzmi_layout.dart';
import '../../../utils/byte_format.dart';
import '../../../utils/home_relative.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../network_link_notice.dart';
import 'settings_widgets.dart';

/// Saves the two folders. Production is [ApiService.updateConfig]; it answers the mods whose links couldn't follow a
/// changed library.
typedef PathsWriter =
    Future<List<String>> Function({required String modsPath, required String zzmiPath, Set<String>? networkRefused});

/// Asks the user for a folder, or null when they cancel.
typedef FolderPicker = Future<String?> Function();

/// Where ZZMI's links and shader fixes go, or null when the ZZMI folder holds no `d3dx.ini`.
typedef ZzmiPlaces = ({String links, String shaders});

final zzmiPlacesProvider = FutureProvider.autoDispose<ZzmiPlaces?>((ref) async {
  final zzmi = ref.watch(zzmiPathProvider);
  if (zzmi.isEmpty) return null;
  final shaders = await shaderFolderIn(zzmi);
  if (shaders == null) return null;
  return (links: linksFolderIn(zzmi), shaders: shaders);
});

/// What is free on the drive the library is on, or null when that can't be read.
final libraryFreeSpaceProvider = FutureProvider.autoDispose<int?>((ref) async {
  final library = ref.watch(modsPathProvider);
  if (library.isEmpty) return null;
  return PlatformServiceFactory.getInstance().freeSpaceBytes(library);
});

/// Settings' **Game & folders** section: the ZZMI folder and the Mod library.
///
/// A pick applies at once, with no Save button. Changing the library re-points the links of the mods the new library
/// has (`docs/configuration.md`), and the ones that couldn't follow are named.
class FoldersSection extends ConsumerWidget {
  const FoldersSection({super.key, this.picker, this.writer});

  final FolderPicker? picker;
  final PathsWriter? writer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final platform = PlatformServiceFactory.getInstance();
    final zzmi = ref.watch(zzmiPathProvider);
    final library = ref.watch(modsPathProvider);
    final places = ref.watch(zzmiPlacesProvider);
    final free = ref.watch(libraryFreeSpaceProvider).valueOrNull;
    String shown(String path) => homeRelative(path, home: platform.homeDirectoryPath);

    return SettingsSectionBlock(
      title: loc.t('settings.nav.folders'),
      children: [
        SettingsRow(
          label: loc.t('settings.paths.zzmi'),
          description: loc.t('settings.paths.zzmi_hint'),
          detail: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              if (zzmi.isNotEmpty) SettingsValue(shown(zzmi)),
              switch (places) {
                AsyncData(value: _?) => SettingsOk(loc.t('settings.paths.zzmi_found')),
                AsyncData() when zzmi.isEmpty => SettingsWarning(loc.t('settings.paths.zzmi_unset')),
                AsyncData() => SettingsWarning(loc.t('settings.paths.zzmi_status_missing')),
                _ => const SizedBox.shrink(),
              },
            ],
          ),
          trailing: OutlinedButton(
            onPressed: () => _changeZzmi(context, ref),
            child: Text(loc.t('settings.launch.change')),
          ),
        ),
        SettingsRow(
          label: loc.t('settings.paths.mods'),
          description: loc.t('settings.paths.mods_hint'),
          detail: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              if (library.isNotEmpty) SettingsValue(shown(library)),
              if (library.isEmpty) SettingsWarning(loc.t('settings.paths.mods_unset')),
              if (free != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    loc.t('settings.paths.free', params: {'free': formatBytes(free)}),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: ZenithPalette.of(context).text3),
                  ),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              if (library.isNotEmpty)
                TextButton(
                  onPressed: () => openFolderOrReport(loc, context.notify, library),
                  child: Text(loc.t('settings.open')),
                ),
              OutlinedButton(
                onPressed: () => _changeLibrary(context, ref),
                child: Text(loc.t('settings.launch.change')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _changeZzmi(BuildContext context, WidgetRef ref) async {
    final picked = await (picker ?? _pickFolder)();
    if (picked == null || !context.mounted) return;
    final resolved = await resolveZzmiFolder(picked) ?? picked;
    if (!context.mounted) return;
    await _apply(context, ref, modsPath: ref.read(modsPathProvider), zzmiPath: resolved);
  }

  Future<void> _changeLibrary(BuildContext context, WidgetRef ref) async {
    final picked = await (picker ?? _pickFolder)();
    if (picked == null || !context.mounted) return;
    await _apply(context, ref, modsPath: p.normalize(picked), zzmiPath: ref.read(zzmiPathProvider));
  }

  Future<String?> _pickFolder() => FilePicker.platform.getDirectoryPath();

  /// Saves the folders and reads the library again, since either one changes which mods read as on. Says only what
  /// went wrong: a mod whose link couldn't follow, a folder the library can't be, a write that failed.
  Future<void> _apply(BuildContext context, WidgetRef ref, {required String modsPath, required String zzmiPath}) async {
    final loc = context.loc;
    final notify = context.notify;
    final library = ref.read(libraryProvider.notifier);
    try {
      final onNetwork = <String>{};
      final failed = await (writer ?? ApiService.updateConfig)(
        modsPath: modsPath,
        zzmiPath: zzmiPath,
        networkRefused: onNetwork,
      );
      await library.rescan();
      // A mod refused for its network folder is told why on its own, and named only there.
      if (onNetwork.isNotEmpty) reportNetworkLinkRefused(loc, notify, onNetwork);
      final notRelinked = [
        for (final name in failed)
          if (!onNetwork.contains(name)) name,
      ];
      if (notRelinked.isNotEmpty) {
        notify.warning(
          loc.plural('settings.relink_failed_title', notRelinked.length, params: {'count': '${notRelinked.length}'}),
          body: loc.t('settings.relink_failed_body', params: {'names': notRelinked.join(', ')}),
        );
      }
    } on LibraryOverlapsLinksFolder catch (refusal) {
      notify.error(
        loc.t('settings.library_is_links_folder_title'),
        body: loc.t(refusal.bodyKey, params: {'folder': refusal.folder}),
      );
    } catch (e) {
      final title = loc.t('settings.errors.generic_title');
      notify.error(title, body: '$e', actions: [copyDetailsAction(loc, notify, title: title, body: '$e')]);
    }
  }
}
