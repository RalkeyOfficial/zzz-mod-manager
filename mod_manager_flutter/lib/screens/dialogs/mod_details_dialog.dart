import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/keybind_info.dart';
import '../../services/api_service.dart';
import '../../utils/categories.dart';
import '../../utils/markdown_description.dart';
import '../../utils/markdown_editor.dart';
import '../../utils/url_utils.dart';
import '../../utils/zzz_characters.dart';

/// Read-only dialog showing everything about a mod: gallery, character,
/// description, tags, source link, and keybinds (VK_-stripped for readability).
/// [onEdit] opens the edit dialog (the pencil button); [onChanged] runs after
/// an inline description edit is saved so the caller can refresh.
void showModDetailsDialog(
  BuildContext context,
  ModInfo mod, {
  required VoidCallback onEdit,
  required VoidCallback onChanged,
}) {
  final loc = context.loc;
  final selectedImage = ValueNotifier<int>(0);
  final validKeybinds = (mod.keybinds ?? [])
      .where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty)
      .toList();
  final hasCharacter =
      mod.characterId.isNotEmpty && mod.characterId != 'unknown';
  final hasUrl = mod.sourceUrl != null && mod.sourceUrl!.isNotEmpty;

  // Inline description editing state, kept for the dialog's lifetime. The
  // rendered markdown swaps to a TextField when the user taps the pencil.
  final descController = TextEditingController(text: mod.description ?? '');
  String currentDescription = mod.description ?? '';
  bool isEditingDescription = false;

  // Own controller so the scrollbar sits in a reserved gutter (see the
  // right-padding below) instead of overlaying the info column's content.
  final detailScroll = ScrollController();

  showDialog(
    context: context,
    builder: (dialogContext) {
      final media = MediaQuery.of(dialogContext);
      final dialogWidth = (media.size.width * 0.85).clamp(420.0, 820.0);
      // Leave room for the dialog's title, actions, and insets so the
      // fixed-height content can't overflow on a small window.
      final dialogHeight = (media.size.height * 0.7).clamp(300.0, 560.0);

      return AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(mod.name, style: const TextStyle(fontSize: 18)),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: loc.t('mods.context_menu.edit'),
              onPressed: () {
                Navigator.pop(dialogContext);
                onEdit();
              },
            ),
          ],
        ),
        content: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left: gallery fills the available vertical space.
              SizedBox(
                width: 300,
                child: _detailGallery(dialogContext, mod, selectedImage),
              ),
              const SizedBox(width: 20),
              // Right: scrollable info column. The scrollbar gets its own
              // gutter (right padding) so it never overlaps the content.
              Expanded(
                child: Scrollbar(
                  controller: detailScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: detailScroll,
                    padding: const EdgeInsets.only(right: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasCharacter) ...[
                          Row(
                            children: [
                              if (isBuiltInCategory(mod.characterId))
                                Icon(
                                  categoryIcon(mod.characterId),
                                  size: 28,
                                  color: Colors.grey[700],
                                )
                              else
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.asset(
                                    'assets/characters/${getCharacterAssetName(mod.characterId)}.png',
                                    width: 28,
                                    height: 28,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                      Icons.person,
                                      size: 28,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                categoryDisplayName(mod.characterId, loc),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Description is always shown, even when empty, and can
                        // be edited inline via the pencil button.
                        StatefulBuilder(
                          builder: (context, setLocal) {
                            Future<void> saveDescription() async {
                              final newDesc = descController.text.trim();
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await ApiService.updateMod(
                                  mod.copyWith(description: newDesc),
                                );
                                currentDescription = newDesc;
                                setLocal(() => isEditingDescription = false);
                                onChanged();
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      loc.t(
                                        'mods.errors.generic',
                                        params: {'message': e.toString()},
                                      ),
                                    ),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    _detailSectionLabel(
                                      loc.t('mods.dialog.description'),
                                    ),
                                    const Spacer(),
                                    if (!isEditingDescription)
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 16,
                                        ),
                                        tooltip: loc.t(
                                          'mods.context_menu.edit',
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          descController.text =
                                              currentDescription;
                                          setLocal(
                                            () => isEditingDescription = true,
                                          );
                                        },
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                if (isEditingDescription) ...[
                                  markdownEditorField(
                                    descController,
                                    TextField(
                                      controller: descController,
                                      autofocus: true,
                                      minLines: 6,
                                      maxLines: 10,
                                      keyboardType: TextInputType.multiline,
                                      style: const TextStyle(fontSize: 13),
                                      decoration: InputDecoration(
                                        hintText: loc.t(
                                          'mods.dialog.description_hint',
                                        ),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: () {
                                          descController.text =
                                              currentDescription;
                                          setLocal(
                                            () =>
                                                isEditingDescription = false,
                                          );
                                        },
                                        child: Text(
                                          loc.t('mods.dialog.cancel'),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      FilledButton(
                                        onPressed: saveDescription,
                                        child: Text(
                                          loc.t('mods.dialog.save'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else if (currentDescription.isNotEmpty)
                                  buildDescriptionMarkdown(
                                    context,
                                    currentDescription,
                                    onLaunchUrl: (href) =>
                                        launchExternalUrl(context, href),
                                  )
                                else
                                  Text(
                                    loc.t('mods.details.no_description'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey[500],
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        if (mod.tags.isNotEmpty) ...[
                          _detailSectionLabel(loc.t('mods.dialog.tags')),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: mod.tags
                                .map(
                                  (t) => Chip(
                                    label: Text(t),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (hasUrl) ...[
                          _detailSectionLabel(
                            loc.t('mods.dialog.source_url'),
                          ),
                          const SizedBox(height: 4),
                          InkWell(
                            onTap: () => openModLink(dialogContext, mod),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.open_in_new,
                                  size: 16,
                                  color: Color(0xFF6366F1),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    mod.sourceUrl!,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF6366F1),
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (validKeybinds.isNotEmpty) ...[
                          _detailSectionLabel(loc.t('mods.details.keybinds')),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: validKeybinds
                                .map(_detailKeybindChip)
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(loc.t('mods.keybinds.close')),
          ),
        ],
      );
    },
  );
}

/// Left-hand gallery for the details dialog: a large cover that fills the
/// available height, with a thumbnail strip below when there's more than one
/// image. Shows a placeholder when the mod has no images.
Widget _detailGallery(
  BuildContext context,
  ModInfo mod,
  ValueNotifier<int> selected,
) {
  final loc = context.loc;
  if (mod.images.isEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: Colors.black.withOpacity(0.2),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 40,
              color: Colors.grey[600],
            ),
            const SizedBox(height: 8),
            Text(
              loc.t('mods.details.no_images'),
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }

  final hasThumbs = mod.images.length > 1;

  return LayoutBuilder(
    builder: (context, constraints) {
      // Size the cover to a square that fits the available space, reserving
      // room for the thumbnail strip so it sits directly beneath the image.
      const thumbsReserved = 64.0; // 56 strip + 8 gap
      final coverSize = min(
        constraints.maxWidth,
        constraints.maxHeight - (hasThumbs ? thumbsReserved : 0),
      ).clamp(80.0, 360.0).toDouble();

      return Column(
        // Keep the image + carousel together, centered as one group.
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Square cover box; the full image is fitted inside (contain) so
          // both portrait and landscape images show completely, letterboxed.
          SizedBox(
            width: coverSize,
            height: coverSize,
            child: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (context, index, _) {
                final safe = index.clamp(0, mod.images.length - 1);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _showImageLightbox(context, mod.images[safe]),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF334155),
                          width: 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.file(
                        File(mod.images[safe]),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            _detailImagePlaceholder(double.infinity),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (hasThumbs) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: ValueListenableBuilder<int>(
                valueListenable: selected,
                builder: (context, index, _) {
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    shrinkWrap: true,
                    itemCount: mod.images.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      final isSelected = i == index;
                      return InkWell(
                        onTap: () => selected.value = i,
                        child: Container(
                          width: 56,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF6366F1)
                                  : const Color(0xFF334155),
                              width: 2,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.file(
                            File(mod.images[i]),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                _detailImagePlaceholder(52),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// Opens an image large and centered over a translucent dark backdrop.
/// Tap anywhere (or the image) to dismiss — no chrome.
void _showImageLightbox(BuildContext context, String imagePath) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withOpacity(0.85),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, __) {
      return GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(
                File(imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.broken_image_outlined,
                  size: 64,
                  color: Colors.grey[500],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

Widget _detailImagePlaceholder(double height) {
  return Container(
    height: height.isFinite ? height : null,
    width: double.infinity,
    alignment: Alignment.center,
    color: Colors.black.withOpacity(0.2),
    child: Icon(Icons.broken_image_outlined, color: Colors.grey[600]),
  );
}

Widget _detailSectionLabel(String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
      color: Colors.grey[400],
      letterSpacing: 0.4,
    ),
  );
}

Widget _detailKeybindChip(KeybindInfo keybind) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          const Color(0xFF1E293B).withOpacity(0.8),
          const Color(0xFF0F172A).withOpacity(0.9),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFF334155), width: 1.5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          keybind.displayName,
          style: const TextStyle(
            color: Color(0xFFE2E8F0),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          keybind.displayKeyValue ?? '',
          style: const TextStyle(
            color: Color(0xFFFBBF24),
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    ),
  );
}
