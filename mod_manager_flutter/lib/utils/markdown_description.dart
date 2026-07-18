import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders a mod [description] as markdown for the details dialog. [onLaunchUrl]
/// is invoked when a link (in the body or inside an alert) is tapped.
///
/// Adds two ZZZ-specific extensions on top of standard markdown:
/// - a run of `>` is treated as a single blockquote level
///   ([_FlatBlockquoteSyntax]) so decorative `>>>>> ... <<<<<` lines survive;
/// - GitHub-style alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`,
///   `[!CAUTION]`, plus a non-standard `[!INFO]` alias of note) render as
///   coloured callouts ([_AlertElementBuilder]).
Widget buildDescriptionMarkdown(
  BuildContext context,
  String description, {
  required void Function(String href) onLaunchUrl,
}) {
  final styleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: const TextStyle(fontSize: 13),
    a: const TextStyle(
      fontSize: 13,
      color: Color(0xFF6366F1),
      decoration: TextDecoration.underline,
    ),
    // A `>` at the start of a line is markdown blockquote syntax. Keep the
    // text readable (inherit the body color) with a subtle accent bar
    // instead of the default washed-out, heavily padded box.
    blockquote: TextStyle(
      fontSize: 13,
      color: Theme.of(context).textTheme.bodyMedium?.color,
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
    blockquoteDecoration: BoxDecoration(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(4),
      border: const Border(
        left: BorderSide(color: Color(0xFF6366F1), width: 3),
      ),
    ),
  );

  return MarkdownBody(
    data: description,
    selectable: true,
    shrinkWrap: true,
    // Render single newlines as line breaks instead of collapsing them into
    // spaces (matches what users type in the plain-text editor).
    softLineBreak: true,
    // Alerts must be tried before the flat blockquote so `> [!WARNING]` wins
    // over the generic `>` handling.
    blockSyntaxes: const [_AlertBlockSyntax(), _FlatBlockquoteSyntax()],
    builders: {
      'alert': _AlertElementBuilder(
        onTapLink: onLaunchUrl,
        styleSheet: styleSheet,
      ),
    },
    onTapLink: (text, href, title) {
      if (href != null) onLaunchUrl(href);
    },
    styleSheet: styleSheet,
  );
}

/// A blockquote syntax that flattens consecutive `>` markers into a single
/// quote level. CommonMark treats `>>>>>` as five *nested* blockquotes; mod
/// descriptions use runs of `>` decoratively (e.g. `>>>>> NOTE <<<<<`), so we
/// strip every leading marker and render one quote level instead of N.
///
/// Passed to [MarkdownBody.blockSyntaxes], where it is tried before the
/// built-in [md.BlockquoteSyntax] and wins on the same `>` lines.
class _FlatBlockquoteSyntax extends md.BlockquoteSyntax {
  const _FlatBlockquoteSyntax();

  // Any remaining leading `>` markers (each with an optional following space)
  // after the base parser has already stripped the first one.
  static final _extraMarkers = RegExp(r'^[ ]{0,3}(?:>[ \t]?)+');

  @override
  md.Node parse(md.BlockParser parser) {
    // The base implementation strips only the first `>` from each line; remove
    // the rest so the recursive parse can't build nested blockquotes.
    final childLines = parseChildLines(parser)
        .map((line) => md.Line(line.content.replaceFirst(_extraMarkers, '')))
        .toList();
    final children = md.BlockParser(
      childLines,
      parser.document,
    ).parseLines(parentSyntax: this);
    return md.Element('blockquote', children);
  }
}

/// Parses GitHub-style alerts — a `> [!TYPE]` line followed by `>`-prefixed
/// body lines — into an `alert` element carrying the type and the raw body
/// markdown. Rendered by [_AlertElementBuilder]. Also accepts a non-standard
/// `[!INFO]` type (GitHub has no such alert); people unfamiliar with GitHub's
/// flavour commonly reach for `INFO` over `NOTE`, so it renders identically to
/// `[!NOTE]`.
///
/// The body is kept as raw markdown (rather than pre-parsed AST children)
/// because a custom block builder replaces the auto-built children; the builder
/// re-renders the body in a nested [MarkdownBody] so links/bold/lists work.
class _AlertBlockSyntax extends md.BlockSyntax {
  const _AlertBlockSyntax();

  // The opener line: `> [!NOTE]` and friends (case-insensitive).
  static final _opener = RegExp(
    r'^\s{0,3}>\s{0,3}\\?\[!(note|tip|important|caution|warning|info)\\?\]\s*$',
    caseSensitive: false,
  );
  static final _quoteLine = RegExp(r'^\s{0,3}>');
  static final _quoteMarker = RegExp(r'^\s{0,3}>[ \t]?');

  @override
  RegExp get pattern => _opener;

  @override
  bool canParse(md.BlockParser parser) =>
      _opener.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final type = _opener
        .firstMatch(parser.current.content)!
        .group(1)!
        .toLowerCase();
    parser.advance(); // consume the `[!TYPE]` marker line

    // Collect the following `>`-prefixed lines as the raw body, stripping the
    // leading marker (and one optional space) from each.
    final bodyLines = <String>[];
    while (!parser.isDone) {
      final content = parser.current.content;
      if (!_quoteLine.hasMatch(content)) break;
      bodyLines.add(content.replaceFirst(_quoteMarker, ''));
      parser.advance();
    }

    return md.Element('alert', <md.Node>[])
      ..attributes['type'] = type
      ..attributes['body'] = bodyLines.join('\n');
  }
}

/// Visual spec for one alert type: label, icon, and accent colour.
class _AlertSpec {
  const _AlertSpec(this.title, this.icon, this.color);
  final String title;
  final IconData icon;
  final Color color;
}

const Map<String, _AlertSpec> _alertSpecs = {
  'note': _AlertSpec('Note', Icons.info_outline, Color(0xFF3B82F6)),
  'info': _AlertSpec('Info', Icons.info_outline, Color(0xFF3B82F6)),
  'tip': _AlertSpec('Tip', Icons.lightbulb_outline, Color(0xFF22C55E)),
  'important': _AlertSpec(
    'Important',
    Icons.campaign_outlined,
    Color(0xFF8B5CF6),
  ),
  'warning': _AlertSpec(
    'Warning',
    Icons.warning_amber_rounded,
    Color(0xFFF59E0B),
  ),
  'caution': _AlertSpec('Caution', Icons.report_outlined, Color(0xFFEF4444)),
};

/// Renders an `alert` element (see [_AlertBlockSyntax]) as a coloured callout
/// with an icon, a title, and the body rendered as nested markdown.
class _AlertElementBuilder extends MarkdownElementBuilder {
  _AlertElementBuilder({required this.onTapLink, required this.styleSheet});

  final void Function(String href) onTapLink;
  final MarkdownStyleSheet styleSheet;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final spec =
        _alertSpecs[element.attributes['type']] ?? _alertSpecs['note']!;
    final body = element.attributes['body'] ?? '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: spec.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: spec.color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 16, color: spec.color),
              const SizedBox(width: 6),
              Text(
                spec.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: spec.color,
                ),
              ),
            ],
          ),
          if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            MarkdownBody(
              data: body,
              selectable: true,
              shrinkWrap: true,
              softLineBreak: true,
              // Allow runs of `>` inside an alert body, but not nested alerts.
              blockSyntaxes: const [_FlatBlockquoteSyntax()],
              onTapLink: (text, href, title) {
                if (href != null) onTapLink(href);
              },
              styleSheet: styleSheet,
            ),
          ],
        ],
      ),
    );
  }
}
