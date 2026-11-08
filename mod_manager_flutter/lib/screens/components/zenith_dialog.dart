import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import 'zenith_controls.dart';

/// The card every v3 dialog is drawn on: the canvas's 18px-radius card with its border and shadow, over the scrim.
///
/// Two kinds. [ZenithDialog.sectioned] is a header, a body that scrolls and a footer, for the dialogs that hold a
/// form or a list. [ZenithDialog.compact] is one padded column with no dividers, for a question.
/// Shown with `showDialog`, which draws the scrim; [busy] keeps Escape and a press on the scrim from closing it.
class ZenithDialog extends StatelessWidget {
  const ZenithDialog.sectioned({
    super.key,
    required this.title,
    required this.width,
    required this.body,
    required this.actions,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.maxHeight = 860,
    this.headerPadding = const EdgeInsets.fromLTRB(24, 20, 24, 16),
    this.headerDivider = false,
    this.closeAlignsStart = true,
    this.coverHeader = false,
    this.bodyPadding = const EdgeInsets.fromLTRB(24, 0, 24, 18),
    this.footerStart,
    this.footerPadding = const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    this.belowCard,
    this.onClose,
    this.onSubmit,
    this.busy = false,
  }) : compact = false,
       alert = false;

  const ZenithDialog.compact({
    super.key,
    required this.title,
    required this.width,
    required this.body,
    required this.actions,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.alert = false,
    this.onSubmit,
    this.busy = false,
  }) : compact = true,
       maxHeight = 860,
       headerPadding = EdgeInsets.zero,
       headerDivider = false,
       closeAlignsStart = false,
       coverHeader = false,
       bodyPadding = EdgeInsets.zero,
       footerStart = null,
       footerPadding = EdgeInsets.zero,
       belowCard = null,
       onClose = null;

  final bool compact;

  /// The compact kind is a question that needs an answer, so a screen reader announces it as an alert.
  final bool alert;

  final String title;
  final String? subtitle;

  /// In place of [subtitle], for a subtitle that holds more than a line of text, such as a badge.
  final Widget? subtitleWidget;

  /// Before the title: a mod's cover thumbnail.
  final Widget? leading;

  /// The card's width, which gives way to the window's when that is narrower.
  final double width;

  /// The card's height at most, which gives way to the window's when that is shorter.
  final double maxHeight;

  final EdgeInsets headerPadding;
  final bool headerDivider;
  final bool closeAlignsStart;

  /// The header of a dialog about one mod, led by its cover: the title in the 17px Geist of a question rather than
  /// the page-title face, and the subtitle quieter.
  final bool coverHeader;
  final Widget body;
  final EdgeInsets bodyPadding;

  /// The footer's start: a note, a switch, or a button that leaves without doing anything.
  final Widget? footerStart;
  final EdgeInsets footerPadding;

  /// The footer's end, in order: the leaving button, then the primary one.
  final List<Widget> actions;

  /// A line under the card, right-aligned: why the primary button is disabled.
  final Widget? belowCard;

  /// What the close button does; null pops the dialog.
  final VoidCallback? onClose;

  /// Pressed by Enter while focus is in a single-line text field, which is the primary action. Null while that
  /// action is not available.
  final VoidCallback? onSubmit;

  /// Work is in progress that closing would not stop: the close button, Escape and the scrim do nothing.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.line),
        boxShadow: [BoxShadow(color: palette.dialogShadow, offset: const Offset(0, 30), blurRadius: 80)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: compact ? _compact(context, palette) : _sectioned(context, palette),
      ),
    );
    Widget content = SizedBox(
      width: width,
      child: belowCard == null
          ? ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: card)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: card),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2),
                      textAlign: TextAlign.end,
                      child: belowCard!,
                    ),
                  ),
                ),
              ],
            ),
    );
    if (onSubmit != null) {
      content = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): _submitFromTextField,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _submitFromTextField,
        },
        child: content,
      );
    }
    return PopScope(
      canPop: !busy,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        // The theme's own shape would outline the Material, and the card draws its own border.
        shape: const RoundedRectangleBorder(),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          role: alert ? ui.SemanticsRole.alertDialog : ui.SemanticsRole.dialog,
          label: title,
          child: content,
        ),
      ),
    );
  }

  /// Enter inside a multi-line field is a new line and on a button is that button's press, so only a field of one
  /// line submits.
  void _submitFromTextField() {
    final field = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>();
    if (field != null && field.maxLines == 1) onSubmit?.call();
  }

  Widget _sectioned(BuildContext context, ZenithPalette palette) {
    final text = Theme.of(context).textTheme;
    final border = BorderSide(color: palette.divider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: headerPadding,
          decoration: headerDivider ? BoxDecoration(border: Border(bottom: border)) : null,
          child: Row(
            crossAxisAlignment: closeAlignsStart ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            spacing: 14,
            children: [
              ?leading,
              Expanded(
                child: coverHeader
                    ? _titles(context, palette, text.titleLarge!, text.bodySmall!, 2, subtitleColor: palette.text3)
                    : _titles(context, palette, text.headlineSmall!, text.bodyMedium!, 4),
              ),
              _CloseButton(onPressed: busy ? null : (onClose ?? () => Navigator.of(context).maybePop())),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(padding: bodyPadding, child: body),
        ),
        Container(
          padding: footerPadding,
          decoration: BoxDecoration(border: Border(top: border)),
          child: Wrap(
            alignment: footerStart == null ? WrapAlignment.end : WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              ?footerStart,
              Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions),
            ],
          ),
        ),
      ],
    );
  }

  Widget _compact(BuildContext context, ZenithPalette palette) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 18,
        children: [
          Row(
            spacing: 14,
            children: [
              ?leading,
              Expanded(child: _titles(context, palette, text.titleLarge!, text.bodySmall!, 2, subtitleColor: palette.text3)),
            ],
          ),
          Flexible(child: SingleChildScrollView(child: body)),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, spacing: 8, children: actions),
            ),
        ],
      ),
    );
  }

  Widget _titles(
    BuildContext context,
    ZenithPalette palette,
    TextStyle titleStyle,
    TextStyle subtitleStyle,
    double gap, {
    Color? subtitleColor,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    spacing: gap,
    children: [
      Semantics(header: true, child: Text(title, style: titleStyle.copyWith(color: palette.text))),
      if (subtitleWidget case final widget?)
        widget
      else if (subtitle case final subtitle?)
        Text(subtitle, style: subtitleStyle.copyWith(color: subtitleColor ?? palette.text2)),
    ],
  );
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = context.loc.t('common.close');
    return IconButton(
      style: smallButtonStyle(context, iconOnly: true),
      tooltip: label,
      onPressed: onPressed,
      icon: const Icon(Icons.close_rounded),
    );
  }
}
