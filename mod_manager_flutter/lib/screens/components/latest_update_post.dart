import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gb_update.dart';
import '../../utils/html_to_markdown.dart';
import 'mod_detail_parts.dart';
import 'resolve/resolve_fragments.dart' show formatResolveDate;

/// The newest post of [updates] that says something: a post with no text and no change list is a file upload, not news.
/// With [since], only a post dated after it counts: one with no date cannot be shown to be newer.
GbUpdate? latestUpdatePost(List<GbUpdate>? updates, {DateTime? since}) {
  GbUpdate? latest;
  for (final update in updates ?? const <GbUpdate>[]) {
    if (!update.hasNotes) continue;
    final date = update.dateAdded;
    if (since != null && (date == null || !date.isAfter(since))) continue;
    final best = latest?.dateAdded;
    if (latest == null || (date != null && (best == null || date.isAfter(best)))) latest = update;
  }
  return latest;
}

/// The newest of the author's update posts: its title, the change list and the text. [footer] says where it is from;
/// by default that is the author's notes on GameBanana.
class LatestUpdatePost extends StatelessWidget {
  const LatestUpdatePost({super.key, required this.post, this.footer});

  final GbUpdate post;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final prose = post.text == null ? '' : htmlToMarkdown(post.text!).trim();
    final heading = [
      loc.t('library.history.latest_post'),
      if (post.dateAdded case final date?) formatResolveDate(date),
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: palette.dialog,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          SectionHeading(heading),
          if (post.name case final name? when name.trim().isNotEmpty)
            Text(name, style: text.bodyMedium?.copyWith(color: palette.text, fontWeight: FontWeight.w600)),
          for (final entry in post.changeLog)
            Text(
              entry.category == null ? '• ${entry.text}' : '• ${entry.text} (${entry.category})',
              style: text.bodyMedium?.copyWith(color: palette.textProse),
            ),
          if (prose.isNotEmpty) ModDescription(key: ValueKey('post_${post.idRow}'), text: prose),
          footer ?? Text(loc.t('library.history.post_source'), style: text.bodySmall?.copyWith(color: palette.text3)),
        ],
      ),
    );
  }
}
