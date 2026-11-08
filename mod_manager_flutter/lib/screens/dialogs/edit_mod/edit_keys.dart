import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/button_feedback.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/keybind_info.dart';
import '../../../services/ini_key_editor.dart';
import '../../../services/key_combo.dart';
import '../../components/zenith_controls.dart';
import '../../shell/keycap.dart';

/// One row of Edit info's In-game keys: a `[Key…]` section of a loaded `.ini`, or one an earlier Save commented out.
class KeyRow {
  KeyRow({
    required this.file,
    required this.section,
    required this.occurrence,
    required this.defaultLabel,
    required String label,
    required String key,
    this.blockIndex,
  }) : label = label,
       label0 = label,
       key = key,
       key0 = key,
       // A section commented out is a row only once Restore has brought it back.
       active = blockIndex == null;

  final String file;
  final String section;
  final int occurrence;
  final String defaultLabel;

  /// Set for a section an earlier Save commented out: its place among the file's blocks.
  final int? blockIndex;

  /// What the row is called now, and what it was when the dialog opened.
  String label;
  final String label0;

  /// The key as it will be written, and as it was when the dialog opened.
  String key;
  final String key0;

  /// The author's key, from the marker above the key line.
  String? authorKey;

  /// The X was pressed on a section of the file: Save comments it out.
  bool removed = false;

  /// False for a commented-out section that Restore has not brought back.
  bool active;

  bool get shown => active && !removed;

  bool get keyChanged => !sameCombo(key, key0);

  /// What "was …" says: the author's key when it differs from the current one, else the key the row had when the
  /// dialog opened if it was changed here.
  String? get was {
    final author = authorKey;
    if (author != null && !sameCombo(author, key)) return author;
    if (author == null && keyChanged) return key0;
    return null;
  }
}

/// The state of Edit info's In-game keys, which nothing writes until Save (`docs/key-editing.md`).
class EditKeysModel extends ChangeNotifier {
  EditKeysModel({required List<KeybindInfo> keybinds, required Map<String, String> labels}) : _labels = labels {
    for (final k in keybinds) {
      final key = k.keyValue;
      final file = k.file;
      if (file == null || key == null || key.isEmpty) continue;
      final label = labels[k.section.toLowerCase()] ?? k.displayName;
      rows.add(
        KeyRow(
          file: file,
          section: k.section,
          occurrence: k.occurrence,
          defaultLabel: k.displayName,
          label: label,
          key: key,
        ),
      );
    }
  }

  /// The labels stored for the mod, every section's, so a section the file no longer has keeps its name.
  final Map<String, String> _labels;

  final List<KeyRow> rows = [];

  /// Whether the files' markers and commented-out sections have been read.
  bool marksLoaded = false;

  Iterable<KeyRow> get shownRows => rows.where((r) => r.shown);

  /// Adds what the files' own comments say: each section's author key, and the sections that were commented out.
  void loadMarks(Map<String, IniKeyState> states) {
    for (final row in rows) {
      row.authorKey ??= states[row.file]?.markerFor(row.section, row.occurrence);
    }
    for (final entry in states.entries) {
      for (final block in entry.value.blocks) {
        final key = block.key;
        if (key == null) continue;
        final name = block.section;
        final defaultLabel = KeybindInfo(section: name, keys: const {}).displayName;
        rows.add(
          KeyRow(
            file: entry.key,
            section: name,
            occurrence: 0,
            defaultLabel: defaultLabel,
            label: _labels[name.toLowerCase()] ?? defaultLabel,
            key: key,
            blockIndex: block.index,
          ),
        );
      }
    }
    marksLoaded = true;
    notifyListeners();
  }

  void setKey(KeyRow row, String key) {
    row.key = key;
    notifyListeners();
  }

  void setLabel(KeyRow row, String label) {
    row.label = label;
    notifyListeners();
  }

  /// The X on a row: a section of the file is unbound on Save, one brought back by Restore goes back to being
  /// commented out.
  void remove(KeyRow row) {
    if (row.blockIndex != null) {
      row.active = false;
    } else {
      row.removed = true;
    }
    notifyListeners();
  }

  /// What [restore] would put back for [row].
  String _target(KeyRow row) => row.authorKey ?? row.key0;

  /// Whether [restore] would change anything: a key that is not the author's, a row removed here, or a section an
  /// earlier Save commented out.
  bool get canRestore =>
      rows.any((row) => row.blockIndex != null ? !row.active : (row.removed || !sameCombo(row.key, _target(row))));

  /// Stages the author's keys: every row goes back to its marker's key, or to the key it had when the dialog opened,
  /// removed rows come back, and the sections an earlier Save commented out are rows again.
  void restore() {
    for (final row in rows) {
      row.removed = false;
      row.active = true;
      row.key = row.blockIndex == null ? _target(row) : row.key;
    }
    notifyListeners();
  }

  /// Whether Save has anything to write: a key, a removal, or a restored section. Labels are not in it, since they
  /// write no `.ini`.
  bool get hasKeyChanges => keyEdits().isNotEmpty;

  /// The edits to write, by file.
  Map<String, List<IniKeyEdit>> keyEdits() {
    final edits = <String, List<IniKeyEdit>>{};
    for (final row in rows) {
      final IniKeyEdit? edit;
      if (row.blockIndex != null) {
        edit = row.active ? RestoreBlock(row.blockIndex!, key: row.key) : null;
      } else if (row.removed) {
        edit = Unbind(row.section, row.occurrence);
      } else if (row.keyChanged) {
        edit = SetKey(row.section, row.occurrence, row.key);
      } else {
        edit = null;
      }
      if (edit != null) edits.putIfAbsent(row.file, () => []).add(edit);
    }
    return edits;
  }

  /// How many keys Save writes, and into how many files.
  ({int count, List<String> files}) get writes {
    final edits = keyEdits();
    return (count: edits.values.fold(0, (n, list) => n + list.length), files: edits.keys.toList());
  }

  /// Whether a label differs from what it was when the dialog opened.
  bool get labelsChanged => rows.any((r) => r.label.trim() != r.label0.trim());

  /// The labels to store: the stored ones with each row's applied. A label equal to the section's default, or empty,
  /// is not stored.
  Map<String, String> labels() {
    final result = {..._labels};
    for (final row in rows) {
      if (row.blockIndex != null && !row.active) continue;
      final name = row.label.trim();
      final id = row.section.toLowerCase();
      if (name.isEmpty || name == row.defaultLabel) {
        result.remove(id);
      } else {
        result[id] = name;
      }
    }
    return result;
  }

  bool get changed => hasKeyChanges || labelsChanged;
}

/// The In-game keys section of Edit info: a row for each key with its label and a button that records a key
/// combination, the restore button, and the note on how recording is cancelled.
class EditKeysSection extends StatefulWidget {
  const EditKeysSection({super.key, required this.model, required this.iniName, required this.modName});

  final EditKeysModel model;

  /// The `.ini` the sentence under the heading names: the file the keys come from.
  final String iniName;

  final String modName;

  @override
  State<EditKeysSection> createState() => _EditKeysSectionState();
}

class _EditKeysSectionState extends State<EditKeysSection> {
  KeyRow? _recording;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
  }

  @override
  void didUpdateWidget(EditKeysSection old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) {
      old.model.removeListener(_changed);
      widget.model.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final model = widget.model;
    final rows = model.shownRows.toList();
    final caps = type.caps.copyWith(color: palette.text3);
    final labelStyle = text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.textProse);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(loc.t('library.details.keys'), style: labelStyle),
                  Text.rich(
                    TextSpan(
                      children: placeholderSentence(loc.t('mods.edit.keys_sub'), {
                        'file': TextSpan(
                          text: widget.iniName,
                          style: type.mono.copyWith(color: palette.textProse),
                        ),
                      }),
                    ),
                    style: text.bodySmall?.copyWith(color: palette.text3),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              style: smallButtonStyle(context),
              onPressed: model.canRestore ? model.restore : null,
              icon: const Icon(Icons.history_rounded),
              label: Text(loc.t('mods.edit.keys_restore')),
            ),
          ],
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(loc.t('mods.edit.keys_empty'), style: text.bodyMedium?.copyWith(color: palette.text3)),
          )
        else ...[
          _grid(
            Text(loc.t('mods.edit.keys_what').toUpperCase(), style: caps),
            Text(loc.t('mods.edit.keys_keys').toUpperCase(), style: caps),
            const SizedBox.shrink(),
          ),
          for (final (i, row) in rows.indexed)
            _grid(
              _LabelField(
                key: ObjectKey(row),
                row: row,
                semanticLabel: loc.t('mods.edit.keys_action_aria', params: {'n': '${i + 1}'}),
                onChanged: (value) => model.setLabel(row, value),
              ),
              _KeysButton(
                key: ValueKey('key_${row.file}_${row.section}_${row.occurrence}_${row.blockIndex}'),
                row: row,
                index: i + 1,
                recording: identical(_recording, row),
                onStart: () => setState(() => _recording = row),
                onCancel: () {
                  if (identical(_recording, row)) setState(() => _recording = null);
                },
                onRecorded: (key) {
                  setState(() => _recording = null);
                  model.setKey(row, key);
                },
              ),
              IconButton(
                style: smallButtonStyle(context, iconOnly: true),
                tooltip: loc.t('mods.edit.keys_remove_aria', params: {'n': '${i + 1}'}),
                onPressed: () => model.remove(row),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Text.rich(
              TextSpan(children: keycapSentence(context, loc.t('mods.edit.keys_esc'), 'Esc')),
              style: text.bodySmall?.copyWith(color: palette.text3),
            ),
          ),
        ],
      ],
    );
  }

  /// A row of the canvas's grid: the label, the keys, and a 30px column for the X.
  Widget _grid(Widget label, Widget keys, Widget remove) => Row(
    spacing: 8,
    children: [
      Expanded(child: label),
      SizedBox(width: 210, child: keys),
      SizedBox(width: 30, child: remove),
    ],
  );
}

class _LabelField extends StatefulWidget {
  const _LabelField({super.key, required this.row, required this.semanticLabel, required this.onChanged});

  final KeyRow row;
  final String semanticLabel;
  final ValueChanged<String> onChanged;

  @override
  State<_LabelField> createState() => _LabelFieldState();
}

class _LabelFieldState extends State<_LabelField> {
  late final TextEditingController _controller = TextEditingController(text: widget.row.label);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.semanticLabel,
    child: TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ZenithPalette.of(context).text),
    ),
  );
}

/// The keys button: the combination as keycaps, "was …" when it differs from the author's, and the recorder.
class _KeysButton extends StatefulWidget {
  const _KeysButton({
    super.key,
    required this.row,
    required this.index,
    required this.recording,
    required this.onStart,
    required this.onCancel,
    required this.onRecorded,
  });

  final KeyRow row;
  final int index;
  final bool recording;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final ValueChanged<String> onRecorded;

  @override
  State<_KeysButton> createState() => _KeysButtonState();
}

class _KeysButtonState extends State<_KeysButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'keys button');
  bool _unsupported = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    widget.onStart();
    setState(() => _unsupported = false);
    _focus.requestFocus();
  }

  /// Everything but Escape is the combination, or part of it, so nothing reaches the dialog while recording.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.recording) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) widget.onCancel();
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent || isModifierKey(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final combo = recordCombo(
      key: event.logicalKey,
      physical: event.physicalKey,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      windows: keyboard.isMetaPressed,
      previous: widget.row.key,
    );
    if (combo == null) {
      setState(() => _unsupported = true);
    } else {
      setState(() => _unsupported = false);
      widget.onRecorded(combo);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final row = widget.row;
    final recording = widget.recording;
    final accent = palette.accent;
    final was = recording ? null : row.was;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: recording ? accent : palette.fieldBorder),
    );
    final keys = keyCaps(row.key).join(' ');
    final semantic = recording
        ? loc.t('mods.edit.keys_recording_aria', params: {'n': '${widget.index}'})
        : was == null
        ? loc.t('mods.edit.keys_aria', params: {'n': '${widget.index}', 'keys': keys})
        : loc.t(
            'mods.edit.keys_aria_changed',
            params: {'n': '${widget.index}', 'keys': keys, 'was': keyCaps(was).join(' ')},
          );
    // On ink the recording text is the accent lifted towards white, and on paper the accent itself.
    final onField = Theme.of(context).brightness == Brightness.dark ? palette.accentOnInk : accent;
    return TapRegion(
      onTapOutside: recording ? (_) => widget.onCancel() : null,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _key,
        onFocusChange: (focused) {
          if (!focused && recording) widget.onCancel();
        },
        child: Semantics(
          button: true,
          label: semantic,
          excludeSemantics: true,
          onTap: _start,
          child: KeyboardFocusRing(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Material(
              color: recording ? Color.lerp(palette.field, accent, 0.08) : palette.field,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: _focus,
                onTap: _start,
                hoverColor: palette.hover.withValues(alpha: 0.4),
                child: SizedBox(
                  height: 36,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      spacing: 4,
                      children: [
                        if (recording) ...[
                          DecoratedBox(
                            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                            child: const SizedBox(width: 8, height: 8),
                          ),
                          Expanded(
                            child: _unsupported
                                ? Text(
                                    loc.t('mods.edit.keys_unsupported'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w400,
                                      color: palette.redText,
                                    ),
                                  )
                                : Text(
                                    loc.t('mods.edit.keys_recording'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium?.copyWith(color: onField),
                                  ),
                          ),
                        ] else ...[
                          for (final cap in keyCaps(row.key)) Keycap(cap),
                          const Spacer(),
                          if (was != null)
                            Text(
                              loc.t('mods.edit.keys_was', params: {'keys': keyCaps(was).join(' ')}),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelSmall?.copyWith(fontWeight: FontWeight.w400, color: palette.text3),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The name shown for a key's file in the footer: its name without the folders.
String keyFileName(String file) => p.posix.basename(file);
