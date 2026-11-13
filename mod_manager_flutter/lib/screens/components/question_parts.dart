/// The parts the question windows are built from, the patch window and the folders window (boards `PatchModal` and `FoldersModal`):
/// the header's tile, a radio card with a body that opens under it, a row to pick, a checkbox, a dashed hint and the library search.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../models/character_info.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'mod_thumb.dart';
import 'zenith_controls.dart';

/// How far a picked card or row leans toward the accent, as the boards mix it.
const double _pickedBorder = .55;
const double _pickedRowFill = .07;
const double _pickedCardFill = .06;

/// A picked row's ground: [ground] leaning toward the accent.
Color pickedRowFill(ZenithPalette palette, Color ground) => Color.lerp(ground, palette.accent, _pickedRowFill)!;

/// A picked compact card's ground: [ground] leaning toward the accent, a shade less than a row's.
Color pickedCardFill(ZenithPalette palette, Color ground) => Color.lerp(ground, palette.accent, _pickedCardFill)!;

/// A picked card's or row's border: [line] leaning toward the accent.
Color pickedChoiceBorder(ZenithPalette palette, Color line) => Color.lerp(line, palette.accent, _pickedBorder)!;

/// The tile at the head of a question window: the mod's own thumbnail when it is about [mod],
/// and otherwise the ground of [characterId], the install's character.
class QuestionTile extends StatelessWidget {
  const QuestionTile({super.key, this.mod, this.characterId});

  final ModInfo? mod;
  final String? characterId;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    if (mod case final mod?) return ModThumb(mod: mod, width: 64, height: 44, radius: 8, spacing: 7, bordered: true);
    return Container(
      width: 64,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.outline),
      ),
      child: DottedGround(ground: palette.groundFor(elementToneOf(characterId ?? unknownCharacterId)), spacing: 7),
    );
  }
}

/// The 18px radio of a card or a row, its dot inset 3px inside the ring as the boards draw it.
class ChoiceRadio extends StatelessWidget {
  const ChoiceRadio({super.key, required this.selected, this.enabled = true});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? palette.accent : palette.check, width: 1.5),
        ),
        padding: const EdgeInsets.all(3),
        child: selected ? DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: palette.accent)) : null,
      ),
    );
  }
}

/// The 18px checkbox of a folder row.
class ChoiceCheck extends StatelessWidget {
  const ChoiceCheck({super.key, required this.ticked});

  final bool ticked;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: ticked ? palette.accent : null,
        border: Border.all(color: ticked ? palette.accent : palette.check, width: 1.5),
      ),
      child: ticked ? Icon(Icons.check_rounded, size: 12, color: palette.onAccent) : null,
    );
  }
}

/// A radio card: a bold [title] with a grey [description] under it, and a [body] under that while it is picked (the boards' `.choice`).
/// [titleTrailing] sits after the title, a hint. A null [onTap] leaves the card dimmed and unpressable.
/// [compact] is the folders window's smaller card beside another (the board's `.how`), whose ground leans toward the accent too when picked.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.selected,
    required this.title,
    required this.description,
    required this.onTap,
    this.titleTrailing,
    this.body,
    this.compact = false,
  });

  final bool selected;
  final String title;
  final String description;
  final VoidCallback? onTap;
  final Widget? titleTrailing;
  final Widget? body;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final enabled = onTap != null;
    final head = Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      onTap: onTap,
      excludeSemantics: true,
      label: '$title, $description',
      child: InkWell(
        onTap: onTap,
        hoverColor: palette.rowHover,
        child: Padding(
          padding: compact ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12) : const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: ChoiceRadio(selected: selected, enabled: enabled)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text)),
                        ?titleTrailing,
                      ],
                    ),
                    Text(description, style: text.bodySmall?.copyWith(color: palette.text3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : .55,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: compact && selected ? pickedCardFill(palette, palette.card) : palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? pickedChoiceBorder(palette, palette.line) : palette.line),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              head,
              if (selected && body != null) Padding(padding: const EdgeInsets.fromLTRB(46, 0, 16, 16), child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// The width a [PickRow]'s name and hints need before the hints sit beside the name rather than under it.
const double _hintsBesideFrom = 420;

/// A row to pick from a list: a radio, a thumbnail, a name with a line under it, and hints at the right (the boards' `.row`), under the name on a narrow row.
/// A null [onTap] leaves it greyed and unpressable.
class PickRow extends StatelessWidget {
  const PickRow({
    super.key,
    required this.selected,
    required this.onTap,
    required this.title,
    this.leading,
    this.subtitle,
    this.hints = const <Widget>[],
    this.semanticsLabel,
  });

  final bool selected;
  final VoidCallback? onTap;
  final String title;
  final Widget? leading;
  final String? subtitle;
  final List<Widget> hints;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final enabled = onTap != null;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      onTap: onTap,
      excludeSemantics: true,
      label: semanticsLabel ?? [title, ?subtitle].join(', '),
      child: Opacity(
        opacity: enabled ? 1 : .5,
        child: Material(
          color: selected ? pickedRowFill(palette, palette.dialog) : palette.dialog,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: selected ? pickedChoiceBorder(palette, palette.outline) : palette.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: palette.rowHover,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                spacing: 12,
                children: [
                  ChoiceRadio(selected: selected, enabled: enabled),
                  ?leading,
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // On a narrow row the hints go under the name, and beside it they take at most half, so the name always keeps its room.
                        final under = constraints.maxWidth < _hintsBesideFrom;
                        final names = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text),
                            ),
                            if (subtitle case final subtitle?)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: palette.text3),
                              ),
                            if (under && hints.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Wrap(spacing: 6, runSpacing: 4, children: hints),
                              ),
                          ],
                        );
                        if (under || hints.isEmpty) return names;
                        return Row(
                          spacing: 12,
                          children: [
                            Expanded(child: names),
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                              child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 4, children: hints),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A guess about a row, drawn as a dashed tag (the boards' `.hint`). It informs and never picks anything.
class DashedHint extends StatelessWidget {
  const DashedHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          color: palette.textProse,
        );
    return DashedBox(
      color: palette.check,
      radius: 5,
      width: 1,
      dash: 3,
      gap: 3,
      child: SizedBox(
        height: 20,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7),
          child: Align(
            widthFactor: 1,
            child: Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style),
          ),
        ),
      ),
    );
  }
}

/// The library search over a list of rows (the boards' `.inp`): a search icon and a field.
/// [controller] holds what was typed, so the box still says it after the card it is in closes and opens again.
class QuestionSearchField extends StatelessWidget {
  const QuestionSearchField({super.key, required this.hint, required this.onChanged, this.controller});

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.fieldBorder),
      ),
      child: Row(
        spacing: 8,
        children: [
          Icon(Icons.search_rounded, size: 14, color: palette.text3),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: text.bodyMedium?.copyWith(color: palette.text),
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: text.bodyMedium?.copyWith(color: palette.text3),
                semanticCounterText: '',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A group of radio rows, for a screen reader; arrow keys move between them.
class ChoiceGroup extends StatelessWidget {
  const ChoiceGroup({super.key, required this.label, required this.children, this.spacing = 6});

  final String label;
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        role: ui.SemanticsRole.radioGroup,
        label: label,
        child: FocusTraversalGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: spacing, children: children),
        ),
      );
}

/// The footer's end of a question window: a grey status line, then the primary button.
/// It is flexible in the footer's row, so on a narrow window the status wraps rather than pushing the button off.
class QuestionFooterEnd extends StatelessWidget {
  const QuestionFooterEnd({super.key, required this.status, required this.label, required this.onPressed});

  final String? status;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          if (status case final status? when status.isNotEmpty)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  status,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2),
                ),
              ),
            ),
          Flexible(
            child: FilledButton(
              onPressed: onPressed,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}
