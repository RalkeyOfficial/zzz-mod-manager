import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import 'zenith_controls.dart';

/// The tags a text holds: split on commas, trimmed, with empty ones dropped.
List<String> splitTags(String text) => [
  for (final part in text.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];

/// [tags] with each of [added] put on the end unless one of that name, in any letter case, is already there.
List<String> withTags(List<String> tags, Iterable<String> added) {
  final result = [...tags];
  for (final tag in added) {
    if (!result.any((t) => t.toLowerCase() == tag.toLowerCase())) result.add(tag);
  }
  return result;
}

/// The tag box of Edit info: a chip for each tag with an × that takes it out, and a field for the next one.
///
/// Enter or a comma adds what is typed, Backspace in the empty field takes the last chip out, and an addition that
/// matches a tag already there in any letter case is dropped. [suggestions] are drawn as dashed chips under the box
/// (the caller decides which; none hides the row), and pressing one adds it.
class TagsField extends StatefulWidget {
  const TagsField({super.key, required this.tags, required this.onChanged, this.onTyping, this.suggestions = const []});

  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  /// Called with what is typed and not yet a chip, as it changes.
  final ValueChanged<String>? onTyping;
  final List<String> suggestions;

  @override
  State<TagsField> createState() => TagsFieldState();
}

class TagsFieldState extends State<TagsField> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The tags with what is typed and not yet a chip added to them. For a Save while the field still holds text.
  List<String> committed() => withTags(widget.tags, splitTags(_input.text));

  void _add(Iterable<String> tags) {
    widget.onChanged(withTags(widget.tags, tags));
  }

  void _typed(String text) {
    // A comma ends a tag: what is before it is added and the rest stays in the field.
    if (text.contains(',')) {
      final last = text.lastIndexOf(',');
      final rest = text.substring(last + 1).trimLeft();
      _add(splitTags(text.substring(0, last)));
      _input.value = TextEditingValue(
        text: rest,
        selection: TextSelection.collapsed(offset: rest.length),
      );
      widget.onTyping?.call(rest);
      return;
    }
    widget.onTyping?.call(text);
  }

  void _enter() {
    _add(splitTags(_input.text));
    _input.clear();
    widget.onTyping?.call('');
    _focus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) _enter();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace && _input.text.isEmpty && widget.tags.isNotEmpty) {
      widget.onChanged([...widget.tags]..removeLast());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final suggestions = widget.suggestions.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Semantics(
          container: true,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: palette.field,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.fieldBorder),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final tag in widget.tags)
                  _TagChip(tag: tag, onRemove: () => widget.onChanged([...widget.tags]..remove(tag))),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 120, maxWidth: 240),
                  child: SizedBox(
                    height: 26,
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: _key,
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        onChanged: _typed,
                        style: text.bodyMedium?.copyWith(color: palette.text),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          hintText: loc.t('mods.edit.tag_add'),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          constraints: const BoxConstraints(minHeight: 26),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (suggestions.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(loc.t('mods.edit.tags_suggested'), style: text.bodySmall?.copyWith(color: palette.text3)),
              ),
              for (final tag in suggestions) _SuggestedChip(tag: tag, onPressed: () => _add([tag])),
            ],
          ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.onRemove});

  final String tag;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      height: 26,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: palette.tagChip,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.fieldBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(tag, style: text.bodySmall?.copyWith(color: palette.text)),
          _RemoveTag(
            label: context.loc.t('mods.edit.tag_remove', params: {'name': tag}),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _RemoveTag extends StatelessWidget {
  const _RemoveTag({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox(
        width: 20,
        height: 20,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            hoverColor: palette.line,
            onTap: onPressed,
            child: Icon(Icons.close_rounded, size: 12, color: palette.text3),
          ),
        ),
      ),
    );
  }
}

class _SuggestedChip extends StatefulWidget {
  const _SuggestedChip({required this.tag, required this.onPressed});

  final String tag;
  final VoidCallback onPressed;

  @override
  State<_SuggestedChip> createState() => _SuggestedChipState();
}

class _SuggestedChipState extends State<_SuggestedChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final color = _hovered ? palette.text : palette.text2;
    return Semantics(
      button: true,
      label: widget.tag,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: DashedBox(
            color: _hovered ? palette.check : palette.edge,
            radius: 6,
            width: 1,
            child: SizedBox(
              height: 26,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Icon(Icons.add_rounded, size: 12, color: color),
                    Text(widget.tag, style: text.bodySmall?.copyWith(color: color)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
