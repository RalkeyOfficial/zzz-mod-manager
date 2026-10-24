import 'package:flutter/material.dart';

import '../../../core/button_feedback.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import 'row_or_stack.dart';

/// A Settings section's heading, with an optional line under it.
class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleMedium?.copyWith(color: palette.text)),
        ),
        if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: palette.text3)),
      ],
    );
  }
}

/// A section: its heading over a [SettingsGroup] of rows.
class SettingsSectionBlock extends StatelessWidget {
  const SettingsSectionBlock({super.key, required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        SettingsSectionTitle(title, subtitle: subtitle),
        SettingsGroup(children: children),
      ],
    );
  }
}

/// The card holding a section's rows, a hairline between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    // A Container insets its child by the border, as CSS does: a plain DecoratedBox would let the rows' dividers
    // paint over the border's pixel.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.field,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: palette.rowDivider),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One setting: a label, usually a sentence explaining it, and its control.
///
/// Every setting commits the user to something, and a bare label leaves them to guess what, so a row says it; the few
/// whose choice names itself, such as the theme, leave the description out. The control keeps its own size beside the
/// text, and drops under it when the text would be left with under 280px ([RowOrStack]).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    required this.description,
    required this.trailing,
    this.detail,
    this.dense = false,
    this.minTextWidth = 280,
  });

  final String label;
  final String? description;
  final Widget trailing;

  /// 14px of padding above and below, as About's rows are drawn, in place of Settings' 16px.
  final bool dense;

  /// The width the text keeps beside the control before the control drops under it: 280 on Settings' rows, 260 on
  /// About's.
  final double minTextWidth;

  /// Lines under the description holding the setting's value, such as a path, or a note about it.
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 3,
      children: [
        Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (description != null) Text(description!, style: theme.textTheme.bodySmall?.copyWith(color: palette.text3)),
        ?detail,
      ],
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: dense ? 14 : 16),
      child: RowOrStack(text: text, control: trailing, minTextWidth: minTextWidth),
    );
  }
}

/// A path or other value in the mono face, as a row's detail. [top] is the space above it, 6px under a description.
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.text, {super.key, this.top = 6, this.color});

  final String text;
  final double top;

  /// The text's colour, [ZenithPalette.textProse] unless told otherwise.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: SelectableText(text, style: ZenithType.of(context).mono.copyWith(color: color ?? palette.textProse)),
    );
  }
}

/// A line that says a thing was found: an accent check mark and 12px text in the row's grey. [mono] follows [text] in
/// the mono face.
class SettingsOk extends StatelessWidget {
  const SettingsOk(this.text, {super.key, this.mono, this.top = 2});

  final String text;
  final String? mono;
  final double top;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Icon(Icons.check_rounded, size: 14, color: palette.accent),
          Flexible(
            child: Text.rich(
              TextSpan(
                text: text,
                children: [if (mono != null) TextSpan(text: mono, style: ZenithType.of(context).mono)],
              ),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// A line that says something is wrong, in the amber of a warning.
class SettingsWarning extends StatelessWidget {
  const SettingsWarning(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.warning_amber_rounded, size: 14, color: palette.amber),
        ),
        Flexible(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.amber)),
        ),
      ],
    );
  }
}

/// A one-choice button that opens a menu, as the canvas's `.sel`: the choice and a chevron, 36px tall.
class SettingsSelect<T> extends StatelessWidget {
  const SettingsSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
    this.minWidth = 200,
  });

  final T value;

  /// Each choice and the words for it, in menu order.
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final String semanticLabel;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    final label = options.where((o) => o.$1 == value).map((o) => o.$2).firstOrNull ?? '';
    final enabled = onChanged != null;

    return Semantics(
      button: true,
      label: semanticLabel,
      value: label,
      excludeSemantics: true,
      child: KeyboardFocusRing(
        shape: shape,
        child: PopupMenuButton<T>(
          enabled: enabled,
          tooltip: '',
          position: PopupMenuPosition.under,
          onSelected: onChanged,
          itemBuilder: (_) => [
            for (final (option, text) in options)
              CheckedPopupMenuItem<T>(value: option, checked: option == value, child: Text(text)),
          ],
          child: Container(
            constraints: BoxConstraints(minWidth: minWidth),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(
              color: palette.chip,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: palette.fieldBorder),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              spacing: 10,
              children: [
                Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: enabled ? palette.text : palette.text3)),
                Icon(Icons.expand_more_rounded, size: 16, color: palette.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 36px square button holding an icon, as the canvas's `btn ibtn`.
class SettingsIconButton extends StatelessWidget {
  const SettingsIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(36, 36)),
        child: Tooltip(message: tooltip, child: Icon(icon, size: 16)),
      ),
    );
  }
}

/// A count with a button either side: the canvas's "Snapshots to keep".
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.fewerLabel,
    required this.moreLabel,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String fewerLabel;
  final String moreLabel;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.fieldBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            _step(Icons.remove_rounded, fewerLabel, value > min ? () => onChanged(value - 1) : null),
            SizedBox(
              width: 28,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: kMonoFont, color: palette.text),
                ),
              ),
            ),
            _step(Icons.add_rounded, moreLabel, value < max ? () => onChanged(value + 1) : null),
          ],
        ),
      ),
    );
  }

  Widget _step(IconData icon, String label, VoidCallback? onPressed) => SizedBox(
    width: 30,
    height: 30,
    child: IconButton(
      onPressed: onPressed,
      tooltip: label,
      padding: EdgeInsets.zero,
      iconSize: 16,
      icon: Icon(icon),
    ),
  );
}

/// The theme and mature-content choices: a few words in a row, one picked.
class SettingsSegments<T> extends StatelessWidget {
  const SettingsSegments({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    // The canvas's `.seg`: a 9px pill on the ground with 3px inside it, and the picked word on a 7px chip.
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: palette.ground,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: palette.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (option, text) in options)
              Flexible(
                child: _Segment(label: text, selected: option == value, onTap: () => onChanged(option)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(7));
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      child: KeyboardFocusRing(
        shape: shape,
        child: Material(
          color: selected ? palette.hover : Colors.transparent,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: palette.hover.withValues(alpha: selected ? 0 : 0.5),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 30),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: selected ? palette.text : palette.text2,
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
