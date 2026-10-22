import 'package:flutter/material.dart';

import '../../core/palette.dart';
import 'zenith_controls.dart';

/// One step of a page's crumbs: a link when [onTap] is set, plain text when it is null.
typedef Crumb = ({String label, VoidCallback? onTap});

/// The strip under the title bar on a mod's page, in the Library and in Browse: a back button, where the page is
/// ("Characters / Ellen Joe / Victorian Ballgown"), the last crumb being the page itself, and [trailing] at the right.
class PageCrumbs extends StatelessWidget {
  const PageCrumbs({
    super.key,
    required this.backTooltip,
    required this.onBack,
    required this.trail,
    required this.current,
    this.trailing,
  });

  final String backTooltip;
  final VoidCallback onBack;

  /// The crumbs before [current], each followed by a slash.
  final List<Crumb> trail;

  final String current;

  final Widget? trailing;

  /// The strip's sides, the same as the page under it.
  static const double gutter = 32;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    final crumb = style?.copyWith(color: palette.text3);
    final slash = Text('/', style: style?.copyWith(color: palette.check));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: 8,
          children: [
            IconButton(
              style: smallButtonStyle(context, iconOnly: true),
              tooltip: backTooltip,
              onPressed: onBack,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            for (final step in trail) ...[
              // Cut to a quarter of the strip, so a long mod name before the page's own leaves room for the rest.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 4),
                child: step.onTap == null
                    ? Text(step.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: crumb)
                    : ZenithLink(step.label, onTap: step.onTap!, maxLines: 1, style: crumb),
              ),
              slash,
            ],
            Expanded(
              child: Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(color: palette.text),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
