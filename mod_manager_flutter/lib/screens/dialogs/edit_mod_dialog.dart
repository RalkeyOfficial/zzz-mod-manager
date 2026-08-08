import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as path;
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/edit_image.dart';
import '../../services/api_service.dart';
import '../../utils/categories.dart';
import '../../utils/markdown_editor.dart';
import '../../utils/zzz_characters.dart';
import '../components/category_picker.dart';

/// Edits a mod's character tag, source URL, description, tags, and gallery.
/// Nothing touches disk until Save. [onSaved] runs after a successful save with
/// the updated [ModInfo] (as written to disk), so the caller can apply a
/// targeted in-memory update instead of a full rescan.
Future<void> showEditModDialog(
  BuildContext context,
  ModInfo mod, {
  required void Function(ModInfo updated) onSaved,
}) {
  final loc = context.loc;
  final messenger = ScaffoldMessenger.of(context);
  final selectedChar = ValueNotifier<String>(mod.characterId);
  final urlController = TextEditingController(text: mod.sourceUrl ?? '');
  final descController = TextEditingController(text: mod.description ?? '');
  final tagController = TextEditingController();
  final tags = ValueNotifier<List<String>>(List<String>.from(mod.tags));
  // Staged gallery: edits only affect this working list and are committed to
  // disk on Save (Cancel discards them). Seeded from the mod's current images.
  final images = ValueNotifier<List<EditImage>>(
    mod.images.map((p) => EditImage.existing(p)).toList(),
  );

  Future<void> pasteImageInto() async {
    final bytes = await Pasteboard.image;
    if (bytes == null) {
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(loc.t('mods.snackbar.clipboard_empty'))),
        );
      }
      return;
    }
    images.value = [...images.value, EditImage.pasted(bytes)];
  }

  Future<void> pickImagesInto() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );
    if (result == null) return;
    final added = result.files
        .where((f) => f.path != null)
        .map((f) => EditImage.picked(f.path!))
        .toList();
    if (added.isNotEmpty) images.value = [...images.value, ...added];
  }

  void removeImage(EditImage item) {
    images.value = images.value.where((e) => e != item).toList();
  }

  void setCover(EditImage item) {
    images.value = [item, ...images.value.where((e) => e != item)];
  }

  void addTag(String raw) {
    // Allow comma- or enter-separated entry; dedupe case-insensitively.
    final parts = raw
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    final current = List<String>.from(tags.value);
    for (final t in parts) {
      if (!current.any((e) => e.toLowerCase() == t.toLowerCase())) {
        current.add(t);
      }
    }
    tags.value = current;
    tagController.clear();
  }

  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(loc.t('mods.dialog.edit_title')),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mod.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('mods.dialog.character_tag'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: selectedChar,
                builder: (context, value, _) {
                  final isCategory = isBuiltInCategory(value);
                  final isCharacter =
                      !isCategory && characterById(value) != null;
                  final hasValue = isCategory || isCharacter;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () async {
                      final picked = await showCategoryPicker(
                        context,
                        currentId: value,
                      );
                      if (picked != null) selectedChar.value = picked;
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        isDense: true,
                      ),
                      child: Row(
                        children: [
                          if (isCategory)
                            Icon(
                              categoryIcon(value),
                              size: 24,
                              color: Colors.grey[700],
                            )
                          else if (isCharacter)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.asset(
                                'assets/characters/${getCharacterAssetName(value)}.png',
                                width: 24,
                                height: 24,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(
                                  Icons.person,
                                  size: 24,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                          if (hasValue) const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              hasValue
                                  ? categoryDisplayName(value, loc)
                                  : loc.t('mods.dialog.no_category'),
                              style: TextStyle(
                                color: hasValue ? null : Colors.grey[600],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            color: Colors.grey[600],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('mods.dialog.source_url'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: loc.t('mods.dialog.source_url_hint'),
                  prefixIcon: const Icon(Icons.link, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('mods.dialog.description'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              markdownEditorField(
                descController,
                TextField(
                  controller: descController,
                  minLines: 8,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: loc.t('mods.dialog.description_hint'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('mods.dialog.tags'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tagController,
                textInputAction: TextInputAction.done,
                onSubmitted: addTag,
                decoration: InputDecoration(
                  hintText: loc.t('mods.dialog.tag_add_hint'),
                  prefixIcon: const Icon(Icons.label_outline, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: loc.t('mods.dialog.tag_add'),
                    onPressed: () => addTag(tagController.text),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<List<String>>(
                valueListenable: tags,
                builder: (context, value, _) {
                  if (value.isEmpty) return const SizedBox.shrink();
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: value
                        .map(
                          (tag) => Chip(
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onDeleted: () {
                              tags.value = List<String>.from(value)
                                ..remove(tag);
                            },
                          ),
                        )
                        .toList(),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                loc.t('mods.dialog.images'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<List<EditImage>>(
                valueListenable: images,
                builder: (context, value, _) {
                  if (value.isEmpty) {
                    return Text(
                      loc.t('mods.details.no_images'),
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (int i = 0; i < value.length; i++)
                        _editImageThumb(
                          context,
                          value[i],
                          isCover: i == 0,
                          onSetCover: () => setCover(value[i]),
                          onRemove: () => removeImage(value[i]),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: pasteImageInto,
                    icon: const Icon(Icons.content_paste, size: 16),
                    label: Text(loc.t('mods.dialog.image_paste')),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: pickImagesInto,
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 16,
                    ),
                    label: Text(loc.t('mods.dialog.image_add')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(loc.t('mods.dialog.cancel')),
        ),
        FilledButton(
          onPressed: () async {
            // Fold any text still in the tag input into the list.
            addTag(tagController.text);

            // Guard against a save that races a rename: if the folder this
            // dialog was opened on no longer exists (it was renamed away), the
            // writes below would be no-ops but could otherwise leave a ghost
            // folder. Bail out and tell the user instead of silently dropping
            // their edits.
            final modManager = await ApiService.getModManagerService();
            final modsPath = modManager.modsPath;
            final stillExists = modsPath != null &&
                await Directory(path.join(modsPath, mod.id)).exists();
            if (!stillExists) {
              if (!context.mounted) return;
              Navigator.pop(dialogContext);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(loc.t('mods.snackbar.mod_gone')),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            // 1) Persist everything (the actual save — fast disk writes):
            //    commit staged images, then the metadata + character tag.
            final committedImages = await _commitGalleryImages(
              mod,
              images.value,
            );
            final updated = mod.copyWith(
              characterId: selectedChar.value,
              sourceUrl: urlController.text.trim(),
              description: descController.text.trim(),
              tags: tags.value,
              images: committedImages,
            );
            await ApiService.updateMod(updated);
            await ApiService.setModCharacter(mod.id, selectedChar.value);

            if (!context.mounted) return;
            // 2) Close + confirm immediately — the save is done.
            Navigator.pop(dialogContext);
            messenger.showSnackBar(
              SnackBar(
                content: Text(loc.t('mods.snackbar.tag_saved')),
                duration: const Duration(seconds: 1),
              ),
            );
            // 3) Let the caller apply a targeted in-memory update.
            onSaved(updated);
          },
          child: Text(loc.t('mods.dialog.save')),
        ),
      ],
    ),
  );
}

/// A thumbnail in the edit dialog's image manager: shows the (possibly not
/// yet saved) image, a cover badge / set-as-cover tap, and a remove button.
Widget _editImageThumb(
  BuildContext context,
  EditImage item, {
  required bool isCover,
  required VoidCallback onSetCover,
  required VoidCallback onRemove,
}) {
  final loc = context.loc;
  final Widget image = item.pastedBytes != null
      ? Image.memory(
          item.pastedBytes!,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
        )
      : Image.file(
          File(item.existingPath ?? item.pickedPath!),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
        );
  return SizedBox(
    width: 72,
    height: 72,
    child: Stack(
      children: [
        Positioned.fill(
          child: Tooltip(
            message: loc.t('mods.dialog.image_set_cover'),
            child: InkWell(
              onTap: isCover ? null : onSetCover,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isCover
                        ? const Color(0xFF6366F1)
                        : const Color(0xFF334155),
                    width: 2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: image,
              ),
            ),
          ),
        ),
        if (isCover)
          Positioned(
            left: 2,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                loc.t('mods.dialog.image_cover'),
                style: const TextStyle(fontSize: 9, color: Colors.white),
              ),
            ),
          ),
        Positioned(
          right: 0,
          top: 0,
          child: InkWell(
            onTap: onRemove,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Commits the staged gallery to disk: imports newly picked files and pasted
/// bytes into the mod folder, deletes removed images **only when they are
/// managed copies** (inside `.zzz-mod-manager/images/` — never the mod's own
/// files like a shipped Preview.png), and returns the final absolute paths.
Future<List<String>> _commitGalleryImages(
  ModInfo mod,
  List<EditImage> items,
) async {
  final modManager = await ApiService.getModManagerService();
  final modsPath = modManager.modsPath;
  if (modsPath == null) return mod.images;
  final folder = path.join(modsPath, mod.id);
  final managedDir = modManager.metadataService.imagesDir(folder);

  final finalAbs = <String>[];
  final keptExisting = <String>{};
  for (final item in items) {
    if (item.existingPath != null) {
      finalAbs.add(item.existingPath!);
      keptExisting.add(item.existingPath!);
    } else if (item.pastedBytes != null) {
      final rel = await modManager.metadataService.addImageBytes(
        folder,
        item.pastedBytes!,
      );
      if (rel != null) finalAbs.add(path.join(folder, rel));
    } else if (item.pickedPath != null) {
      final rel = await modManager.metadataService.importImageFile(
        folder,
        item.pickedPath!,
      );
      if (rel != null) finalAbs.add(path.join(folder, rel));
    }
  }

  for (final original in mod.images) {
    if (keptExisting.contains(original)) continue;
    if (path.isWithin(managedDir, original)) {
      try {
        final file = File(original);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Ignore: file may already be gone.
      }
    }
  }
  return finalAbs;
}
