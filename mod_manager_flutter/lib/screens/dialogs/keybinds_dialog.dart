import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/keybind_info.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';

/// Lists a mod's keybinds as chips; tapping one opens [showEditKeybindDialog].
/// [onSaved] runs after a keybind is successfully changed.
void showKeybindsDialog(
  BuildContext context,
  ModInfo mod, {
  required VoidCallback onSaved,
}) {
  if (mod.keybinds == null || mod.keybinds!.isEmpty) return;

  // Фільтруємо тільки keybinds з key значенням
  final validKeybinds = mod.keybinds!
      .where((kb) => kb.keyValue != null && kb.keyValue!.isNotEmpty)
      .toList();

  if (validKeybinds.isEmpty) return;

  final loc = context.loc;
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.keyboard_outlined, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              loc.t('mods.keybinds.title', params: {'name': mod.name}),
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: validKeybinds.map((keybind) {
              return InkWell(
                onTap: () {
                  Navigator.pop(dialogContext);
                  showEditKeybindDialog(context, mod, keybind, onSaved: onSaved);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF1E293B).withValues(alpha: 0.8),
                        const Color(0xFF0F172A).withValues(alpha: 0.9),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF334155),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        keybind.displayName,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFFBBF24).withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          keybind.keyValue ?? '',
                          style: const TextStyle(
                            color: Color(0xFFFBBF24),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.edit_outlined,
                        size: 14,
                        color: Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(loc.t('mods.keybinds.close')),
        ),
      ],
    ),
  );
}

/// Edits a single keybind's key value, writing it back into the mod's `.ini`.
/// [onSaved] runs after a successful save.
void showEditKeybindDialog(
  BuildContext context,
  ModInfo mod,
  KeybindInfo keybind, {
  required VoidCallback onSaved,
}) {
  final loc = context.loc;
  final keyController = TextEditingController(text: keybind.keyValue ?? '');

  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.edit_outlined, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              loc.t(
                'mods.keybinds.edit_title',
                params: {'name': keybind.displayName},
              ),
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loc.t('mods.keybinds.edit_prompt'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: keyController,
            decoration: InputDecoration(
              labelText: loc.t('mods.keybinds.field_label'),
              hintText: loc.t('mods.keybinds.field_hint'),
              prefixIcon: const Icon(
                Icons.keyboard,
                color: Color(0xFFFBBF24),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF334155)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: Color(0xFFFBBF24),
                  width: 2,
                ),
              ),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.t('mods.keybinds.common_title'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  loc.t('mods.keybinds.common_list'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(loc.t('mods.keybinds.cancel')),
        ),
        FilledButton(
          onPressed: () async {
            final newKey = keyController.text.trim();
            if (newKey.isNotEmpty) {
              await _saveKeybindChange(context, mod, keybind, newKey);
              if (!context.mounted) return;
              Navigator.pop(dialogContext);
              // Перезавантажити моди щоб побачити зміни
              onSaved();
            }
          },
          child: Text(loc.t('mods.keybinds.save')),
        ),
      ],
    ),
  );
}

Future<void> _saveKeybindChange(
  BuildContext context,
  ModInfo mod,
  KeybindInfo keybind,
  String newKey,
) async {
  final loc = context.loc;
  final notify = context.notify;
  try {
    final modManagerService = await ApiService.getModManagerService();
    final modsPath = modManagerService.modsPath;

    if (modsPath == null) {
      notify.error(loc.t('mods.keybinds.error_no_path'));
      return;
    }

    // Знаходимо INI файл моду
    final modPath = path.join(modsPath, mod.id);
    final modDir = Directory(modPath);

    if (!await modDir.exists()) {
      notify.error(loc.t('mods.keybinds.error_no_dir'));
      return;
    }

    // Шукаємо INI файли
    final iniFiles = await modDir
        .list(recursive: true)
        .where(
          (entity) =>
              entity is File && entity.path.toLowerCase().endsWith('.ini'),
        )
        .cast<File>()
        .toList();

    if (iniFiles.isEmpty) {
      notify.error(loc.t('mods.keybinds.error_no_ini'));
      return;
    }

    // Читаємо і оновлюємо INI файл
    for (final iniFile in iniFiles) {
      String content = await iniFile.readAsString();
      final lines = content.split('\n');
      bool inTargetSection = false;
      bool updated = false;

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();

        // Перевіряємо чи це наша секція
        if (line.toLowerCase() == '[${keybind.section.toLowerCase()}]') {
          inTargetSection = true;
          continue;
        }

        // Перевіряємо чи почалась нова секція
        if (line.startsWith('[') && line.endsWith(']')) {
          inTargetSection = false;
        }

        // Якщо ми в потрібній секції і знайшли рядок з key (key= або Key =)
        if (inTargetSection &&
            RegExp(r'^key\s*=', caseSensitive: false).hasMatch(line)) {
          lines[i] = 'key = $newKey';
          updated = true;
          break;
        }
      }

      if (updated) {
        await iniFile.writeAsString(lines.join('\n'));
        // The .ini changed — drop this mod's cached keybinds so the reload
        // re-parses it.
        await ApiService.invalidateKeybinds(mod.id);
        notify.success(
          loc.t(
            'mods.keybinds.updated',
            params: {'name': keybind.displayName, 'key': newKey},
          ),
          icon: Icons.keyboard_alt_outlined,
        );
        break;
      }
    }
  } catch (e) {
    print('Error saving keybind: $e');
    notify.error(
      loc.t('mods.keybinds.error_save', params: {'message': e.toString()}),
    );
  }
}
