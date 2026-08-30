import 'package:flutter/material.dart';

import '../mod_status_slot.dart';

/// The small shared pieces the resolve surfaces are built from.
///
/// They live here rather than on one dialog because **two screens now ask the
/// same questions** — the folder's own identity, and the other download inside
/// it. A chip that means "on record" on one and something subtly different on
/// the other is the drift this exists to prevent.

/// A caveat, or — with [colour] overridden — an answer.
///
/// Amber by default because almost every use is a caveat. The one exception is
/// a banked-hash match, which is the answer rather than a warning about it.
Widget resolveNotice(
  BuildContext context,
  String message,
  IconData icon, {
  Color? colour,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(icon, size: 15, color: colour ?? ModStatusSlot.amber),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

/// A short label on a file row. [background] fills it rather than tinting it,
/// which is what separates "this is the answer already on file" from "this is
/// our best guess" at a glance.
Widget resolveChip(String label, Color color, {Color? background}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

String formatResolveDate(DateTime date) {
  final d = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
