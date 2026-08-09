/// The building blocks the update flow's dialogs are made of.
///
/// They exist because those dialogs were written as loose `Text` widgets with
/// hardcoded 11/12/13px sizes, and both problems that produced are the same
/// problem: **nothing said where one idea ended and the next began, and
/// everything was too small to read.**
///
/// So the sizes come from the theme rather than from literals —
/// `bodyLarge` (16) for anything the user is meant to read, `bodyMedium` (14)
/// for the line that explains it — and a block of facts always arrives under a
/// heading that says what the block is for.
///
/// Kept out of any one dialog because three of them share it, and a fourth
/// copy is how the sizes drifted in the first place.
library;

import 'package:flutter/material.dart';

import 'mod_status_slot.dart';

/// A headed group of related facts.
class DialogSection extends StatelessWidget {
  const DialogSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;

  /// The line that explains why this section exists. Optional, because some
  /// sections are self-evident — but where it is present it is the difference
  /// between a list and an answer.
  final String? subtitle;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle case final text?) ...[
          const SizedBox(height: 4),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 10),
        ...children,
      ],
    );
  }
}

/// One `label — value` line inside a [DialogSection].
class DialogFact extends StatelessWidget {
  const DialogFact({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String value;

  /// The author's own words about [value], greyed underneath. Never standing in
  /// for it — the two are frequently the same variant of the same mod, and the
  /// comparison is the whole point.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: theme.textTheme.bodyLarge),
                if (detail case final text?)
                  Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A boxed aside — something true of the whole operation rather than a fact
/// about one of its parts.
///
/// [emphasis] paints it amber, which is this app's one "read this" colour: the
/// mod card's status slot uses the same literal, deliberately not a scheme
/// colour, so it means the same thing wherever it appears. Reserved for the
/// notices that change what the user should expect to happen — the patch
/// warning, a layout the app refuses to guess at — and never used for more than
/// one notice in a view, or it stops being emphasis.
class DialogNotice extends StatelessWidget {
  const DialogNotice({
    super.key,
    required this.icon,
    required this.message,
    this.emphasis = false,
  });

  final IconData icon;
  final String message;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: emphasis
            ? ModStatusSlot.amber.withValues(alpha: 0.10)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: emphasis
            ? Border.all(color: ModStatusSlot.amber.withValues(alpha: 0.55))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: emphasis ? ModStatusSlot.amber : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: emphasis ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
