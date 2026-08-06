/// The single definition of how markdown looks in this app.
///
/// Every markdown surface — a mod's own description, a GameBanana description
/// converted from HTML, the body of an alert callout — renders through
/// [buildMarkdownStyleSheet], so the reading experience is the same everywhere
/// and a change here moves all of them at once.
///
/// The defaults from `MarkdownStyleSheet.fromTheme` are a starting point, not a
/// design: they inherit `bodyMedium` (14px) for body text and draw a horizontal
/// rule as a **5px** slab, which reads as a bar rather than a separator. What
/// follows replaces every element that a description actually uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Sizes and colours the markdown look is built from.
///
/// Everything is derived from [body], so that one number rescales the whole
/// document. Sizes are logical pixels, not `em` — Flutter's `TextStyle` has no
/// relative unit — but they are chosen as multiples of [body] so the
/// relationships survive a change to it.
abstract final class MarkdownScale {
  /// Body text. The paragraph size a description is actually read at.
  static const double body = 16;

  /// One step of vertical rhythm: 0.5em at [body]. Used as the gap between
  /// blocks, which is also what puts air above and below a horizontal rule —
  /// the rule itself is a childless container and cannot carry a margin.
  static const double gap = body / 2;

  /// Heading sizes. Descriptions are read inside a dialog, so this scale is
  /// deliberately tighter than a web document's: past `h3` the headings stop
  /// growing and separate themselves by weight and colour instead.
  static const double h1 = 24;
  static const double h2 = 20;
  static const double h3 = 18;
  static const double h4 = body;
  static const double h5 = 15;
  static const double h6 = 14;

  /// Monospace reads optically larger than the body face at an equal size, so
  /// code is set a step down to sit level with the text around it.
  static const double code = 14;

  /// Line height for running text. Descriptions are wide and often dense;
  /// 1.5 is what keeps long paragraphs scannable.
  static const double lineHeight = 1.5;

  /// The height of one empty line of body text.
  ///
  /// This is the unit an author works in when they space a description out
  /// with blank lines — or, on GameBanana, with runs of `<br>`. Reproducing it
  /// is what keeps a converted description looking like it did on the site.
  static const double blankLine = body * lineHeight;

  /// How many blank lines in a row are honoured before the run is clamped.
  ///
  /// Descriptions sometimes carry a dozen or more `<br>` in a row; reproducing
  /// that literally would push the rest of the text off a dialog-sized
  /// viewport. Four blank lines is already an unmistakable break.
  static const int maxBlankLines = 4;

  /// Link colour, fixed rather than themed so a link is recognisable as one in
  /// both light and dark mode.
  static const Color link = Color(0xFF6366F1);
}

/// Builds the app-wide markdown style sheet from the ambient theme.
///
/// Cheap to call — it is a plain object graph, built per render like any other
/// style — so callers may build one per `build()` rather than caching it.
MarkdownStyleSheet buildMarkdownStyleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  final body = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: MarkdownScale.body,
    height: MarkdownScale.lineHeight,
  );
  final heading = body.copyWith(height: 1.25);

  // Inline code is a tinted chip and a fenced block is a bordered panel, but
  // the style sheet has a single `code` entry that a block reuses for its text.
  // Both tints are therefore kept translucent (so they read against whatever
  // surface the description sits on) and the chip is cancelled inside a block
  // by [MarkdownCodeBlockHighlighter] — otherwise the two would stack and band
  // the block line by line.
  final codeChip = scheme.onSurface.withValues(alpha: 0.10);

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    // Paragraphs top up `blockSpacing` so that two of them end up exactly one
    // blank line apart. `blockSpacing` alone is too tight for a paragraph
    // break: on GameBanana a break arrives as `<br><br>`, which the browser
    // renders as a full empty line, and at 8px it reads as a hard wrap
    // instead. Splitting the top-up across top and bottom (rather than putting
    // it all below) keeps every *other* block symmetrically spaced — notably a
    // horizontal rule with a paragraph on either side.
    pPadding: const EdgeInsets.symmetric(
      vertical: (MarkdownScale.blankLine - MarkdownScale.gap) / 2,
    ),
    a: body.copyWith(
      color: MarkdownScale.link,
      decoration: TextDecoration.underline,
      decorationColor: MarkdownScale.link.withValues(alpha: 0.5),
    ),
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.w700),
    del: const TextStyle(decoration: TextDecoration.lineThrough),

    // Headings lead the block that follows them, so their padding is
    // asymmetric: a wide gap above (on top of the inter-block `gap`) and a
    // narrow one below, which visually binds a heading to its own text.
    h1: heading.copyWith(
      fontSize: MarkdownScale.h1,
      fontWeight: FontWeight.w700,
    ),
    h1Padding: const EdgeInsets.only(top: MarkdownScale.gap, bottom: 2),
    h2: heading.copyWith(
      fontSize: MarkdownScale.h2,
      fontWeight: FontWeight.w700,
    ),
    h2Padding: const EdgeInsets.only(top: MarkdownScale.gap, bottom: 2),
    h3: heading.copyWith(
      fontSize: MarkdownScale.h3,
      fontWeight: FontWeight.w600,
    ),
    h3Padding: const EdgeInsets.only(top: MarkdownScale.gap, bottom: 2),
    h4: heading.copyWith(
      fontSize: MarkdownScale.h4,
      fontWeight: FontWeight.w600,
    ),
    h4Padding: const EdgeInsets.only(top: 4, bottom: 2),
    h5: heading.copyWith(
      fontSize: MarkdownScale.h5,
      fontWeight: FontWeight.w600,
    ),
    h5Padding: const EdgeInsets.only(top: 4, bottom: 2),
    // h6 has nowhere left to shrink to, so it separates itself by colour.
    h6: heading.copyWith(
      fontSize: MarkdownScale.h6,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    ),
    h6Padding: const EdgeInsets.only(top: 4, bottom: 2),

    blockSpacing: MarkdownScale.gap,
    listIndent: 20,
    listBullet: body,
    listBulletPadding: const EdgeInsets.only(right: 6),

    // A `>` at the start of a line is markdown blockquote syntax. Keep the text
    // readable (inherit the body colour) with a subtle accent bar instead of
    // the default washed-out, heavily padded box.
    blockquote: body,
    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
    blockquoteDecoration: BoxDecoration(
      color: scheme.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(4),
      border: const Border(
        left: BorderSide(color: MarkdownScale.link, width: 3),
      ),
    ),

    code: body.copyWith(
      fontFamily: 'monospace',
      fontSize: MarkdownScale.code,
      height: 1.45,
      backgroundColor: codeChip,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: scheme.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: scheme.outlineVariant),
    ),

    // A separator, not a bar: one hairline, with `blockSpacing` (0.5em)
    // providing the margin above and below.
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant)),
    ),

    tableHead: body.copyWith(fontWeight: FontWeight.w600),
    tableBody: body,
    tableBorder: TableBorder.all(color: scheme.outlineVariant),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableHeadCellsPadding: const EdgeInsets.symmetric(
      horizontal: 10,
      vertical: 6,
    ),
    tableHeadCellsDecoration: BoxDecoration(
      color: scheme.onSurface.withValues(alpha: 0.04),
    ),
  );
}

/// Styles the text inside a fenced code block.
///
/// A block would otherwise reuse `styleSheet.code` verbatim — chip background
/// included — and paint it behind every line *on top of* `codeblockDecoration`,
/// striping the panel. `flutter_markdown_plus` routes block text through the
/// syntax-highlighter seam when one is set, so cancelling the background here
/// is the whole job; this highlights nothing.
class MarkdownCodeBlockHighlighter extends SyntaxHighlighter {
  MarkdownCodeBlockHighlighter(this.styleSheet);

  final MarkdownStyleSheet styleSheet;

  @override
  TextSpan format(String source) => TextSpan(
    text: source,
    style: styleSheet.code?.copyWith(backgroundColor: Colors.transparent),
  );
}
