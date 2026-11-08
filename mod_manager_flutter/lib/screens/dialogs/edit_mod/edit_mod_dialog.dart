import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;

import '../../../core/palette.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/character_info.dart';
import '../../../models/edit_image.dart';
import '../../../models/origin_enums.dart';
import '../../../services/api_service.dart';
import '../../../services/gamebanana/remote_mod_metadata.dart';
import '../../../services/installed_record.dart';
import '../../../services/ini_key_editor.dart';
import '../../../services/log/logger.dart';
import '../../../services/mod_manager_service.dart'
    show ModManagerService, RenameFolderFailed, RenameLinkFailed, RenameRefused;
import '../../../utils/markdown_editor.dart';
import '../../../utils/notification_actions.dart';
import '../../../utils/notifications.dart';
import '../../../utils/state_providers.dart';
import '../../components/character_pick.dart';
import '../../components/character_tile.dart' show libraryGroupName;
import '../../components/tags_field.dart';
import '../../components/zenith_dialog.dart';
import '../resolve_origin_dialog.dart';
import 'edit_cover.dart';
import 'edit_keys.dart';

final Logger _log = Logger('mods');

/// Where Edit info opens: at the top, or scrolled to the In-game keys, which the mod page's Change keys asks for.
enum EditSection { info, keys }

/// What a Save did, for the screen to bring its list in line.
class EditResult {
  const EditResult({required this.updated, this.renamedTo, this.keysWritten = false});

  /// The mod with the sidecar fields as saved, under the folder name it had when the dialog opened.
  final ModInfo updated;

  /// The folder's new name, when the Name field renamed it, including a rename that left the mod off.
  final String? renamedTo;

  /// An `.ini` was written, so the mod's keys are read again.
  final bool keysWritten;
}

/// Edits a mod's name, cover, author, description, tags and in-game keys in one window (`docs/library-screen.md`
/// §13, `docs/key-editing.md`). Nothing touches the disk until Save.
///
/// Answers with the [EditResult], or null when the dialog was closed without saving or the mod's folder was gone.
Future<EditResult?> showEditModDialog(BuildContext context, ModInfo mod, {EditSection section = EditSection.info}) =>
    showDialog<EditResult>(
      context: context,
      builder: (_) => EditModDialog(mod: mod, section: section),
    );

/// A save that was refused and already said so: the dialog stays open for another try.
class _SaveRefused implements Exception {
  const _SaveRefused();
}

class EditModDialog extends ConsumerStatefulWidget {
  const EditModDialog({super.key, required this.mod, this.section = EditSection.info});

  final ModInfo mod;
  final EditSection section;

  @override
  ConsumerState<EditModDialog> createState() => _EditModDialogState();
}

class _EditModDialogState extends ConsumerState<EditModDialog> {
  late final ModInfo _mod = widget.mod;
  late final TextEditingController _name = TextEditingController(text: _mod.name);
  late final TextEditingController _author;
  late final TextEditingController _description = TextEditingController(text: _mod.description ?? '');
  late final String _authorSeed;
  late List<String> _tags = [..._mod.tags];
  late String _characterId = _mod.characterId;
  late List<EditImage> _images = [for (final image in _mod.images) EditImage.existing(image)];
  late final EditKeysModel _keys;
  final GlobalKey<TagsFieldState> _tagsKey = GlobalKey();
  final GlobalKey _keysAnchor = GlobalKey();
  final FocusNode _coverFocus = FocusNode(debugLabel: 'cover', skipTraversal: true);
  String _typedTag = '';
  bool _saving = false;

  /// The mod page's text as this app would have written it into the description; null until it is known, or when the
  /// mod has no page, is not tracked, or the page could not be fetched.
  String? _pageText;

  @override
  void initState() {
    super.initState();
    final page = installedRecord(_mod, ref.read(knownModPagesProvider)).page;
    _authorSeed = modAuthor(_mod, page) ?? '';
    _author = TextEditingController(text: _authorSeed);
    _keys = EditKeysModel(keybinds: _mod.keybinds ?? const [], labels: ref.read(modKeysProvider)[_mod.id] ?? const {});
    _keys.addListener(_keysChanged);
    unawaited(_loadMarks());
    unawaited(_loadPageText());
    if (widget.section == EditSection.keys) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _keysAnchor.currentContext;
        if (target != null) Scrollable.ensureVisible(target, duration: Duration.zero, alignment: 0.1);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _description.dispose();
    _coverFocus.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _keysChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadMarks() async {
    try {
      final states = await ApiService.inspectKeyFiles(_mod.id);
      if (mounted) _keys.loadMarks(states);
    } catch (e) {
      _log.debug('could not read the key markers', fields: {'mod': _mod.id, 'reason': '$e'});
    }
  }

  /// The id of the page whose text "Use GameBanana text" offers: the mod's base page, while the mod is tracked.
  int? _pageId(ModInfo mod) => mod.origin?.tracking == OriginTracking.off ? null : mod.origin?.base?.modId;

  Future<void> _loadPageText() async {
    final id = _pageId(_mod);
    if (id == null) return;
    try {
      var page = ref.read(knownModPagesProvider)[id];
      // A page a check fetched carries no text, so one without is read again.
      if (page?.text == null) {
        page = await ref.read(gameBananaClientProvider).modProfile(id);
        if (!mounted) return;
        keepModPages(ref, {id: page});
      }
      final text = RemoteModMetadata.fromMod(page!).description?.trim();
      if (mounted && text != null && text.isNotEmpty) setState(() => _pageText = text);
    } catch (e) {
      // Offline, or the page is gone: the marker and the button are simply absent.
      _log.debug('could not read the page text', fields: {'mod': _mod.id, 'reason': '$e'});
    }
  }

  /// The folders of the other mods, for the name check.
  Set<String> _otherNames() => {
    for (final m in ref.read(modsProvider))
      if (m.id != _mod.id) m.id.toLowerCase(),
  };

  String? _nameError(AppLocalizations loc, String name) {
    if (name == _mod.name) return null;
    if (RegExp(r'[\\/<>:"|?*]').hasMatch(name) || name.startsWith('.') || name.startsWith('__')) {
      return loc.t('mods.dialog.rename_invalid');
    }
    if (_otherNames().contains(name.toLowerCase())) return loc.t('mods.dialog.rename_exists');
    return null;
  }

  /// Tags that other mods carry and this one lacks, the most used first.
  List<String> _suggestions() {
    final have = {for (final tag in _tags) tag.toLowerCase()};
    final counts = <String, ({String name, int count})>{};
    for (final other in ref.read(modsProvider)) {
      if (other.id == _mod.id) continue;
      for (final tag in other.tags) {
        final key = tag.toLowerCase();
        if (have.contains(key)) continue;
        final seen = counts[key];
        counts[key] = (name: seen?.name ?? tag, count: (seen?.count ?? 0) + 1);
      }
    }
    final ranked = counts.values.toList()
      ..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : a.name.compareTo(b.name));
    return [for (final tag in ranked.take(3)) tag.name];
  }

  bool get _imagesChanged {
    if (_images.length != _mod.images.length) return true;
    for (var i = 0; i < _images.length; i++) {
      if (_images[i].existingPath != _mod.images[i]) return true;
    }
    return false;
  }

  bool get _changed =>
      _name.text.trim() != _mod.name ||
      _author.text.trim() != _authorSeed ||
      _description.text.trim() != (_mod.description ?? '').trim() ||
      _characterId != _mod.characterId ||
      _typedTag.trim().isNotEmpty ||
      !_sameTags(_tags, _mod.tags) ||
      _imagesChanged ||
      _keys.changed;

  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pickImages() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result == null || !mounted) return;
    final added = [
      for (final file in result.files)
        if (file.path != null) EditImage.picked(file.path!),
    ];
    if (added.isNotEmpty) setState(() => _images = [..._images, ...added]);
  }

  Future<void> _pasteImage() async {
    final notify = context.notify;
    final loc = context.loc;
    final bytes = await Pasteboard.image;
    if (!mounted) return;
    if (bytes == null) {
      notify.note(loc.t('mods.snackbar.clipboard_empty_title'), body: loc.t('mods.snackbar.clipboard_empty_body'));
      return;
    }
    setState(() => _images = [..._images, EditImage.pasted(bytes)]);
  }

  /// Ctrl+V while focus is anywhere but a text field adds the picture on the clipboard.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyV) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    unawaited(_pasteImage());
    return KeyEventResult.handled;
  }

  Future<void> _updateTracking() async {
    final mod = _liveMod();
    if (await showResolveOriginDialog(context, mod)) {
      await ref.read(libraryProvider.notifier).rescan();
      if (mounted) unawaited(_loadPageText());
    }
  }

  /// The mod as the library holds it now, for what a tracking change rewrites.
  ModInfo _liveMod() => ref.read(modsProvider).where((m) => m.id == _mod.id).firstOrNull ?? _mod;

  Future<void> _save() async {
    final loc = context.loc;
    final notify = context.notify;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _saving = true);
    final tags = _tagsKey.currentState?.committed() ?? _tags;
    try {
      final result = await whileWritingMod(container, _mod.id, () => _write(container, notify, loc, tags: tags));
      if (mounted) Navigator.pop(context, result);
    } on _SaveRefused {
      if (mounted) setState(() => _saving = false);
    } catch (e) {
      final title = loc.t('mods.edit.save_failed_title');
      notify.error(
        title,
        body: '$e',
        characterId: _mod.characterId,
        actions: [copyDetailsAction(loc, notify, title: title, body: '$e')],
      );
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The save, in the order that leaves the most standing when a step fails: what goes into the folder as it is
  /// (pictures, sidecar, `.ini` keys, labels), then the character, and the rename last, so one that fails leaves
  /// every other edit saved and the folder where it was.
  Future<EditResult?> _write(
    ProviderContainer container,
    NotificationCenter notify,
    AppLocalizations loc, {
    required List<String> tags,
  }) async {
    final modManager = await container.read(modManagerServiceProvider.future);
    final modsPath = modManager.modsPath;
    // A folder renamed away since the dialog opened would be written to as a ghost.
    if (modsPath == null || !await Directory(path.join(modsPath, _mod.id)).exists()) {
      notify.error(
        loc.t('mods.snackbar.mod_gone_title'),
        body: loc.t('mods.snackbar.mod_gone_body'),
        characterId: _mod.characterId,
      );
      return null;
    }

    final images = await _commitGalleryImages(modManager, _mod, _images);
    final description = _description.text.trim();
    final author = _author.text.trim();
    final updated = ModInfo(
      id: _mod.id,
      name: _mod.name,
      characterId: _characterId,
      isActive: _mod.isActive,
      imagePath: images.isEmpty ? null : images.first,
      description: description,
      // Only a changed field is stored, so the page's submitter is not copied into the sidecar just by saving.
      author: author == _authorSeed ? _mod.author : author,
      tags: tags,
      images: images,
      isFavorite: _mod.isFavorite,
      keybinds: _mod.keybinds,
      origin: _mod.origin,
      uid: _mod.uid,
    );
    if (!await ApiService.updateMod(updated)) {
      notify.error(loc.t('mods.edit.save_failed_title'), body: _mod.name, characterId: _mod.characterId);
      throw const _SaveRefused();
    }

    final edits = _keys.keyEdits();
    var keysWritten = false;
    if (edits.isNotEmpty) {
      final results = await ApiService.writeKeyFiles(_mod.id, edits);
      keysWritten = results.any((r) => r.status == IniWriteStatus.written);
      final failed = [
        for (final r in results)
          if (r.problem) r.file,
      ];
      if (failed.isNotEmpty) {
        notify.warning(
          loc.t('mods.edit.keys_not_saved_title'),
          body: loc.t('mods.edit.keys_not_saved_body', params: {'files': failed.join(', ')}),
          characterId: _mod.characterId,
        );
      }
    }
    if (_keys.labelsChanged && !await ApiService.setModKeyLabels(_mod.id, _keys.labels())) {
      notify.warning(loc.t('mods.edit.labels_not_saved_title'), body: _mod.name, characterId: _mod.characterId);
    }

    if (_characterId != _mod.characterId) await ApiService.setModCharacter(_mod.id, _characterId);

    if (keysWritten && container.read(remindF10Provider) && await container.read(isGameRunningProvider)()) {
      notify.note(
        loc.t('notifications.f10.keys_title', params: {'name': _mod.name}),
        body: loc.t('notifications.f10.body'),
        keycap: 'F10',
        characterId: _characterId,
      );
    }

    final renamedTo = await _rename(container, notify, loc, _name.text.trim());
    return EditResult(updated: updated, renamedTo: renamedTo, keysWritten: keysWritten);
  }

  /// Renames the folder when the Name field says so. Returns the folder's new name when it has one, and says why in
  /// a card when the rename did not happen or left the mod off.
  Future<String?> _rename(
    ProviderContainer container,
    NotificationCenter notify,
    AppLocalizations loc,
    String name,
  ) async {
    if (name == _mod.name) return null;
    final failed = loc.t('mods.dialog.rename_failed_title');
    try {
      if (await ApiService.renameMod(_mod.id, name)) return name;
      notify.error(failed, body: loc.t('mods.dialog.rename_exists'), characterId: _mod.characterId);
    } on RenameRefused catch (refusal) {
      notify.error(
        failed,
        body: loc.t('mods.dialog.rename_link_taken', params: {'name': refusal.name}),
        characterId: _mod.characterId,
      );
    } on RenameFolderFailed {
      notify.error(
        failed,
        body: loc.t('mods.dialog.rename_folder_failed', params: {'name': _mod.name}),
        characterId: _mod.characterId,
      );
    } on RenameLinkFailed catch (failure) {
      if (failure.renamed) {
        // The folder has its new name and the mod is off, so the library reads the disk again.
        notify.warning(
          loc.t('mods.dialog.rename_left_off_title'),
          body: loc.t('mods.dialog.rename_left_off_body', params: {'name': failure.name}),
          characterId: _mod.characterId,
          // The mod won't load until the user turns it back on.
          stays: true,
        );
        return failure.name;
      }
      notify.error(
        failed,
        body: loc.t('mods.dialog.rename_link_failed', params: {'name': _mod.name}),
        characterId: _mod.characterId,
      );
    } catch (e) {
      final title = loc.t('mods.errors.generic_title');
      notify.error(
        title,
        body: '$e',
        characterId: _mod.characterId,
        actions: [copyDetailsAction(loc, notify, title: title, body: '$e')],
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final writing = !_saving && ref.watch(modWritesInProgressProvider).contains(_mod.id);
    // The mod as the library holds it, which a tracking change has rewritten.
    final live = ref.watch(modsProvider.select((mods) => mods.where((m) => m.id == _mod.id).firstOrNull)) ?? _mod;
    final name = _name.text.trim();
    final nameError = writing && name != _mod.name
        ? loc.t('mods.dialog.rename_busy', params: {'name': _mod.name})
        : _nameError(loc, name);
    final canSave = !_saving && !writing && name.isNotEmpty && nameError == null && _changed;

    final cover = EditCover(
      modName: _mod.name,
      characterId: _characterId,
      images: _images,
      onPick: _pickImages,
      onSetCover: (image) => setState(() => _images = [image, ..._images.where((e) => e != image)]),
      onRemove: (image) => setState(() => _images = _images.where((e) => e != image).toList()),
      onDrop: (dropped) {
        if (dropped.isNotEmpty) setState(() => _images = [..._images, ...dropped]);
      },
      focusNode: _coverFocus,
    );
    final left = [cover, EditTrackingBox(mod: live, onUpdateTracking: _updateTracking)];
    final right = _fields(context, loc, palette, text, nameError, live);

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _key,
      child: ZenithDialog.sectioned(
        title: loc.t('mods.edit.title'),
        subtitle: '${_mod.name} · ${libraryGroupName(_characterId, loc)}',
        width: 920,
        maxHeight: 820,
        headerDivider: true,
        busy: _saving,
        bodyPadding: EdgeInsets.zero,
        onSubmit: canSave ? _save : null,
        body: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 740) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 0, 20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 18, children: left),
                    ),
                  ),
                  Expanded(
                    child: Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 24), child: right),
                  ),
                ],
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 18, children: left),
                  right,
                ],
              ),
            );
          },
        ),
        footerStart: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            writing ? loc.t('mods.edit.busy', params: {'name': _mod.name}) : _footNote(loc),
            style: text.bodySmall?.copyWith(color: palette.text3),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(loc.t('mods.dialog.cancel')),
          ),
          FilledButton(onPressed: canSave ? _save : null, child: Text(loc.t('mods.edit.save'))),
        ],
      ),
    );
  }

  /// What Save writes into `.ini` files, when it writes any, and what an update does to it.
  String _footNote(AppLocalizations loc) {
    final writes = _keys.writes;
    final sentences = <String>[
      if (writes.count > 0)
        writes.files.length == 1
            ? loc.plural(
                'mods.edit.foot_keys',
                writes.count,
                params: {'count': '${writes.count}', 'file': keyFileName(writes.files.single)},
              )
            : loc.t('mods.edit.foot_keys_files', params: {'file': keyFileName(writes.files.first)}),
      loc.t('mods.edit.foot_update'),
    ];
    return sentences.join(' ');
  }

  Widget _label(BuildContext context, String label) => Text(
    label,
    style: Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: ZenithPalette.of(context).textProse),
  );

  Widget _fields(
    BuildContext context,
    AppLocalizations loc,
    ZenithPalette palette,
    TextTheme text,
    String? nameError,
    ModInfo live,
  ) {
    final pageText = _pageText;
    final current = _description.text.trim();
    final edited = pageText != null && current.isNotEmpty && current != pageText;
    final canUsePage = pageText != null && current != pageText;
    final small = text.labelSmall?.copyWith(fontWeight: FontWeight.w400);
    final keyFiles = {for (final row in _keys.rows) row.file};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 20,
      children: [
        _Labelled(
          label: _label(context, loc.t('mods.edit.name')),
          child: TextField(
            key: const ValueKey('edit_name'),
            controller: _name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(errorText: nameError, errorMaxLines: 3),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Expanded(
              flex: 12,
              child: _Labelled(
                label: _label(context, loc.t('mods.edit.character')),
                child: CharacterPick(groupId: _characterId, onChanged: (id) => setState(() => _characterId = id)),
              ),
            ),
            Expanded(
              flex: 10,
              child: _Labelled(
                label: _label(context, loc.t('mods.edit.author')),
                child: TextField(
                  key: const ValueKey('edit_author'),
                  controller: _author,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ],
        ),
        _Labelled(
          label: Row(
            spacing: 10,
            children: [
              Expanded(child: _label(context, loc.t('mods.edit.description'))),
              if (edited)
                Row(
                  spacing: 6,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(color: palette.accent, shape: BoxShape.circle),
                      child: const SizedBox(width: 6, height: 6),
                    ),
                    Text(loc.t('mods.edit.edited'), style: small?.copyWith(color: palette.text2)),
                  ],
                ),
              if (canUsePage)
                _UseText(
                  label: loc.t('mods.edit.use_gb_text'),
                  onPressed: () => setState(() => _description.text = pageText),
                ),
            ],
          ),
          child: markdownEditorField(
            _description,
            TextField(
              key: const ValueKey('edit_description'),
              controller: _description,
              minLines: 4,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              onChanged: (_) => setState(() {}),
              style: text.bodyMedium?.copyWith(height: 1.55, color: palette.text),
              decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
          ),
        ),
        _Labelled(
          label: Row(
            spacing: 10,
            children: [
              Expanded(child: _label(context, loc.t('mods.edit.tags'))),
              Text(loc.t('mods.edit.tags_hint'), style: small?.copyWith(color: palette.text3)),
            ],
          ),
          child: TagsField(
            key: _tagsKey,
            tags: _tags,
            suggestions: _suggestions(),
            onChanged: (tags) => setState(() => _tags = tags),
            onTyping: (typed) => setState(() => _typedTag = typed),
          ),
        ),
        KeyedSubtree(
          key: _keysAnchor,
          child: EditKeysSection(
            model: _keys,
            iniName: keyFiles.isEmpty ? '.ini' : keyFileName(keyFiles.first),
            modName: _mod.name,
          ),
        ),
      ],
    );
  }
}

/// A label over a field, 6px apart.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final Widget label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 6,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 20),
        child: Align(alignment: Alignment.centerLeft, child: label),
      ),
      child,
    ],
  );
}

/// "Use GameBanana text": 11px text-link, underlined, brightening under the pointer.
class _UseText extends StatefulWidget {
  const _UseText({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_UseText> createState() => _UseTextState();
}

class _UseTextState extends State<_UseText> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Text(
            widget.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w400,
              color: _hovered ? palette.text : palette.text3,
              decoration: TextDecoration.underline,
              decorationColor: _hovered ? palette.text : palette.text3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Commits the staged gallery to disk: imports newly picked files and pasted bytes into the mod folder, deletes
/// removed images **only when they are managed copies** (inside `.zzz-mod-manager/images/`, never the mod's own
/// files such as a shipped `Preview.png`, and the service is what draws that line), and returns the final absolute
/// paths.
Future<List<String>> _commitGalleryImages(ModManagerService modManager, ModInfo mod, List<EditImage> items) async {
  final modsPath = modManager.modsPath;
  if (modsPath == null) return mod.images;
  final folder = path.join(modsPath, mod.id);

  final finalAbs = <String>[];
  final keptExisting = <String>{};
  for (final item in items) {
    if (item.existingPath != null) {
      finalAbs.add(item.existingPath!);
      keptExisting.add(item.existingPath!);
    } else if (item.pastedBytes != null) {
      final rel = await modManager.metadataService.addImageBytes(folder, item.pastedBytes!);
      if (rel != null) finalAbs.add(path.join(folder, rel));
    } else if (item.pickedPath != null) {
      final rel = await modManager.metadataService.importImageFile(folder, item.pickedPath!);
      if (rel != null) finalAbs.add(path.join(folder, rel));
    }
  }

  for (final original in mod.images) {
    if (keptExisting.contains(original)) continue;
    await modManager.metadataService.removeManagedImage(folder, original);
  }
  return finalAbs;
}
