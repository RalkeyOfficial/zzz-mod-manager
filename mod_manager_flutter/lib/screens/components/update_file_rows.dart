import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../utils/byte_format.dart';
import 'resolve/resolve_fragments.dart' show formatResolveDate;
import 'zenith_controls.dart' show ZenithBadge;

/// Below this width a file's date and size move under its name, where beside it they would squeeze the name to a
/// column of letters.
const double _narrowRow = 420;

/// A group of [FileRadioRow]s in one rounded box with a line between each, the canvas's `.box` of radio rows.
///
/// [label] names what is chosen, for a screen reader. Arrow keys move focus between the rows, and Space or Enter picks
/// the one that has it.
class FileRadioGroup extends StatelessWidget {
  const FileRadioGroup({super.key, required this.label, required this.rows});

  final String label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Semantics(
      container: true,
      role: ui.SemanticsRole.radioGroup,
      label: label,
      child: FocusTraversalGroup(
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, row) in rows.indexed)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: i == rows.length - 1 ? null : Border(bottom: BorderSide(color: palette.rowDivider)),
                  ),
                  child: row,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One newer file to pick: a radio, the file's name in mono with the author's words for it under it, when it was
/// uploaded, and its size.
///
/// [chip] sits after the name: why the app suggests this file, which says nothing about whether it is the right one.
/// A screen reader hears it, and the size, with the name. A null [onTap] leaves the row as it is and unpressable.
class FileRadioRow extends StatelessWidget {
  const FileRadioRow({
    super.key,
    required this.file,
    required this.selected,
    required this.onTap,
    this.chip,
    this.verticalPadding = 11,
  });

  final GbFile file;
  final bool selected;
  final VoidCallback? onTap;
  final ZenithBadge? chip;

  /// 11 in a dialog of one mod, 9 in the cards of several.
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final date = file.dateAdded;
    final size = file.filesize;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      selected: selected,
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      label: [
        fileDisplayName(file),
        ?chip?.label,
        ?fileDisplayDetail(file),
        if (date != null) loc.t('mods.update.uploaded', params: {'date': formatResolveDate(date)}),
        if (size != null) formatBytes(size),
      ].join(', '),
      child: Material(
        color: selected ? palette.rowPicked : Colors.transparent,
        child: InkWell(
          hoverColor: palette.rowHover,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(14, verticalPadding, 14, verticalPadding),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < _narrowRow;
                final uploaded = date == null
                    ? null
                    : loc.t('mods.update.uploaded', params: {'date': formatResolveDate(date)});
                return Row(
                  spacing: 12,
                  children: [
                    _Radio(selected: selected, enabled: onTap != null),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(fileDisplayName(file), style: type.mono.copyWith(color: palette.text)),
                              ?chip,
                            ],
                          ),
                          VariantLine(fileDisplayDetail(file) ?? ''),
                          if (narrow && (uploaded != null || size != null))
                            Text(
                              [?uploaded, if (size != null) formatBytes(size)].join(' · '),
                              style: text.bodySmall?.copyWith(color: palette.text2),
                            ),
                        ],
                      ),
                    ),
                    if (!narrow) ...[
                      if (uploaded != null) Text(uploaded, style: text.bodySmall?.copyWith(color: palette.text2)),
                      SizedBox(
                        width: 52,
                        child: size == null
                            ? null
                            : Text(
                                formatBytes(size),
                                textAlign: TextAlign.end,
                                style: type.monoSmall.copyWith(color: palette.text3),
                              ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final ring = selected ? palette.accent : palette.check;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 1.5)),
        child: selected
            ? Padding(
                padding: const EdgeInsets.all(1.5),
                child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: palette.accent)),
              )
            : null,
      ),
    );
  }
}

/// What the author said about a file, in grey and wrapping: the canvas's `.variant`. An empty [text] says there is
/// none, in italics.
class VariantLine extends StatelessWidget {
  const VariantLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    if (text.isEmpty) {
      return Text(
        context.loc.t('library.history.no_variant'),
        style: style?.copyWith(color: palette.text3, fontStyle: FontStyle.italic),
      );
    }
    return Text(text, style: style?.copyWith(color: palette.text2));
  }
}

/// The file the mod holds now, above the newer ones: name, the author's words, when it was uploaded and its size, in a
/// box on the dialog's own ground.
///
/// [name] is a file name, set in mono, unless [plainName] says it is a sentence ("Marked as current"). A null
/// [variant] draws no line, and an empty one says there is none.
class YouHaveBox extends StatelessWidget {
  const YouHaveBox({
    super.key,
    required this.name,
    this.variant,
    this.uploaded,
    this.size,
    this.plainName = false,
  });

  /// The box for [file], the one the check matched the installed file to.
  YouHaveBox.file({super.key, required GbFile file, this.uploaded})
    : name = fileDisplayName(file),
      variant = fileDisplayDetail(file) ?? '',
      size = file.filesize,
      plainName = false;

  final String name;
  final String? variant;
  final String? uploaded;
  final int? size;
  final bool plainName;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < _narrowRow;
          return Row(
            spacing: 12,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      name,
                      style: plainName
                          ? text.bodyMedium?.copyWith(color: palette.text)
                          : type.mono.copyWith(color: palette.text),
                    ),
                    if (variant case final variant?) VariantLine(variant),
                    if (narrow && (uploaded != null || size != null))
                      Text(
                        [?uploaded, if (size != null) formatBytes(size!)].join(' · '),
                        style: text.bodySmall?.copyWith(color: palette.text2),
                      ),
                  ],
                ),
              ),
              if (!narrow) ...[
                if (uploaded case final uploaded?) Text(uploaded, style: text.bodySmall?.copyWith(color: palette.text2)),
                SizedBox(
                  width: 52,
                  child: size == null
                      ? null
                      : Text(
                          formatBytes(size!),
                          textAlign: TextAlign.end,
                          style: type.monoSmall.copyWith(color: palette.text3),
                        ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
