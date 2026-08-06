import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_style.dart';

/// Renders a mod [description] as markdown for the details dialog. [onLaunchUrl]
/// is invoked when a link (in the body or inside an alert) is tapped.
///
/// The look comes from [buildMarkdownStyleSheet] — shared with every other
/// markdown surface, including the alert bodies below, so nothing here can
/// drift into a second style.
///
/// Adds three ZZZ-specific extensions on top of standard markdown:
/// - a run of `>` is treated as a single blockquote level
///   ([_FlatBlockquoteSyntax]) so decorative `>>>>> ... <<<<<` lines survive;
/// - GitHub-style alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`,
///   `[!CAUTION]`, plus a non-standard `[!INFO]` alias of note) render as
///   coloured callouts ([_AlertElementBuilder]);
/// - a run of blank lines keeps its height ([_BlankRunSyntax]) instead of
///   collapsing to a single paragraph break.
Widget buildDescriptionMarkdown(
  BuildContext context,
  String description, {
  required void Function(String href) onLaunchUrl,
}) {
  final styleSheet = buildMarkdownStyleSheet(context);

  return MarkdownBody(
    data: description,
    selectable: true,
    shrinkWrap: true,
    // Blocks span the full width instead of hugging their text. The default
    // (`fitContent: true`) shrink-wraps every block, which leaves a quote or a
    // code fence as a small box floating mid-paragraph rather than a band.
    fitContent: false,
    // Render single newlines as line breaks instead of collapsing them into
    // spaces (matches what users type in the plain-text editor).
    softLineBreak: true,
    // Alerts must be tried before the flat blockquote so `> [!WARNING]` wins
    // over the generic `>` handling.
    blockSyntaxes: const [
      _AlertBlockSyntax(),
      _FlatBlockquoteSyntax(),
      _BlankRunSyntax(),
    ],
    builders: {
      'alert': _AlertElementBuilder(
        onTapLink: onLaunchUrl,
        styleSheet: styleSheet,
      ),
      'spacer': _SpacerElementBuilder(),
    },
    onTapLink: (text, href, title) {
      if (href != null) onLaunchUrl(href);
    },
    styleSheet: styleSheet,
    syntaxHighlighter: MarkdownCodeBlockHighlighter(styleSheet),
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

/// Preserves the height of a run of blank lines as a `spacer` element.
///
/// Markdown collapses any number of blank lines into one paragraph break, but
/// authors use them as spacing — and GameBanana descriptions especially so,
/// because their editor writes runs of `<br>` which `htmlToMarkdown` turns
/// into blank lines. Without this, `a<br><br><br><br>b` renders identically to
/// `a<br><br>b` and a description loses the shape its author gave it.
///
/// The *first* blank line is the paragraph break itself and is left to the
/// normal block spacing, so only the surplus becomes a spacer — meaning
/// ordinary hand-written markdown (one blank line between paragraphs) is
/// untouched. [_SpacerElementBuilder] turns the count into height.
class _BlankRunSyntax extends md.BlockSyntax {
  const _BlankRunSyntax();

  static final _blank = RegExp(r'^[ \t]*$');

  @override
  RegExp get pattern => _blank;

  // Only a *run* is interesting. A lone blank line is left to the built-in
  // `EmptyBlockSyntax`, which handles the paragraph break and the parser
  // bookkeeping that goes with it.
  @override
  bool canParse(md.BlockParser parser) {
    if (!_blank.hasMatch(parser.current.content)) return false;
    final next = parser.peek(1);
    return next != null && _blank.hasMatch(next.content);
  }

  @override
  md.Node parse(md.BlockParser parser) {
    var lines = 0;
    while (!parser.isDone && _blank.hasMatch(parser.current.content)) {
      lines++;
      parser.advance();
    }
    // The blank lines still ended a block, and the parser uses this to decide
    // list tightness and to close setext headings.
    parser.encounteredBlankLine = true;

    return md.Element.empty('spacer')..attributes['lines'] = '${lines - 1}';
  }
}

/// Renders a `spacer` (see [_BlankRunSyntax]) as vertical space, clamped to
/// [MarkdownScale.maxBlankLines].
class _SpacerElementBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final requested = int.tryParse(element.attributes['lines'] ?? '') ?? 0;
    final lines = requested.clamp(0, MarkdownScale.maxBlankLines);
    // A spacer is a block, so it sits between *two* block gaps where the
    // paragraph break it extends only had one. Give that extra gap back, and
    // the run occupies exactly the height its blank lines asked for.
    return SizedBox(
      height: lines * MarkdownScale.blankLine - MarkdownScale.gap,
    );
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
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
              Icon(spec.icon, size: 18, color: spec.color),
              const SizedBox(width: 6),
              Text(
                spec.title,
                style: TextStyle(
                  fontSize: MarkdownScale.body,
                  height: 1.25,
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
              fitContent: false,
              softLineBreak: true,
              // Allow runs of `>` inside an alert body, but not nested alerts.
              blockSyntaxes: const [_FlatBlockquoteSyntax(), _BlankRunSyntax()],
              builders: {'spacer': _SpacerElementBuilder()},
              onTapLink: (text, href, title) {
                if (href != null) onTapLink(href);
              },
              styleSheet: styleSheet,
              syntaxHighlighter: MarkdownCodeBlockHighlighter(styleSheet),
            ),
          ],
        ],
      ),
    );
  }
}
