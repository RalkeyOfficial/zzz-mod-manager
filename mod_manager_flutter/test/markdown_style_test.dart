import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/html_to_markdown.dart';
import 'package:mod_manager_flutter/utils/markdown_description.dart';
import 'package:mod_manager_flutter/utils/markdown_style.dart';

/// The markdown look is shared by every description surface, so the few values
/// a reader would notice going wrong are pinned here rather than left to a
/// visual check in the app.
void main() {
  late MarkdownStyleSheet sheet;

  Future<void> pumpSheet(WidgetTester tester, {Brightness? brightness}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0EA5E9),
            brightness: brightness ?? Brightness.dark,
          ),
        ),
        home: Builder(
          builder: (context) {
            sheet = buildMarkdownStyleSheet(context);
            return const SizedBox();
          },
        ),
      ),
    );
  }

  testWidgets('body text is set at the readable base size', (tester) async {
    await pumpSheet(tester);

    expect(sheet.p!.fontSize, MarkdownScale.body);
    expect(sheet.p!.height, MarkdownScale.lineHeight);
    // Links, list bullets and quoted text are body text too — a link rendering
    // a step smaller than the sentence around it is the bug this pins.
    expect(sheet.a!.fontSize, MarkdownScale.body);
    expect(sheet.listBullet!.fontSize, MarkdownScale.body);
    expect(sheet.blockquote!.fontSize, MarkdownScale.body);
  });

  testWidgets('a horizontal rule is a hairline, not a slab', (tester) async {
    await pumpSheet(tester);

    // The library default is a 5px bar. `---` is a separator, and the air
    // around it comes from the block gap — the rule renders as a childless
    // container, which can carry no margin of its own.
    final border = (sheet.horizontalRuleDecoration! as BoxDecoration).border!;
    expect(border.top.width, 1);
    expect(sheet.blockSpacing, MarkdownScale.gap);
  });

  testWidgets('headings descend in size and never fall under the body', (
    tester,
  ) async {
    await pumpSheet(tester);

    final sizes = [
      sheet.h1!.fontSize!,
      sheet.h2!.fontSize!,
      sheet.h3!.fontSize!,
      sheet.h4!.fontSize!,
      sheet.h5!.fontSize!,
      sheet.h6!.fontSize!,
    ];
    expect(sizes, [
      MarkdownScale.h1,
      MarkdownScale.h2,
      MarkdownScale.h3,
      MarkdownScale.h4,
      MarkdownScale.h5,
      MarkdownScale.h6,
    ]);
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i], lessThanOrEqualTo(sizes[i - 1]));
    }
    expect(sizes.first, greaterThan(MarkdownScale.body));
  });

  testWidgets('a code block drops the inline chip background', (tester) async {
    await pumpSheet(tester);

    // The block reuses `code` for its text and would otherwise paint the chip
    // tint over its own decoration once per line, striping the panel.
    expect(sheet.code!.backgroundColor, isNotNull);
    final blockText = MarkdownCodeBlockHighlighter(sheet).format('x');
    expect(blockText.style!.backgroundColor, Colors.transparent);
    expect(blockText.style!.fontFamily, sheet.code!.fontFamily);
  });

  group('blank lines keep the height their author gave them', () {
    /// Vertical distance between the two paragraphs of a rendered [markdown].
    Future<double> gapBetweenParagraphs(
      WidgetTester tester,
      String markdown,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: Builder(
                builder: (context) => buildDescriptionMarkdown(
                  context,
                  markdown,
                  onLaunchUrl: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getTopLeft(find.textContaining('BBB').first).dy -
          tester.getBottomLeft(find.textContaining('AAA').first).dy;
    }

    testWidgets('a paragraph break is one blank line tall', (tester) async {
      // GameBanana writes a paragraph break as `<br><br>`, which the browser
      // renders as one empty line. Block spacing alone (8px) reads as a hard
      // wrap instead, which is what made converted descriptions look cramped.
      expect(
        await gapBetweenParagraphs(tester, 'AAA\n\nBBB'),
        MarkdownScale.blankLine,
      );
    });

    testWidgets('a longer run of blank lines is not collapsed', (tester) async {
      // Markdown normally flattens any run of blank lines to one break, so
      // `a<br><br><br><br>b` would render identically to `a<br><br>b`.
      for (final blankLines in [2, 3, 4]) {
        expect(
          await gapBetweenParagraphs(
            tester,
            'AAA${'\n' * (blankLines + 1)}BBB',
          ),
          MarkdownScale.blankLine * blankLines,
          reason: '$blankLines blank lines',
        );
      }
    });

    testWidgets('an absurd run is clamped rather than scrolled through', (
      tester,
    ) async {
      final capped = await gapBetweenParagraphs(tester, 'AAA${'\n' * 40}BBB');
      expect(
        capped,
        MarkdownScale.blankLine * (MarkdownScale.maxBlankLines + 1),
        reason: 'a dozen <br> in a row must not push the text off screen',
      );
    });

    testWidgets('a converted <br> run matches what the browser showed', (
      tester,
    ) async {
      // N consecutive `<br>` put N-1 empty lines on the page. This is the whole
      // reason the rule above exists, so it is checked end to end through the
      // HTML conversion rather than on hand-written markdown.
      for (final brCount in [2, 3, 4]) {
        expect(
          await gapBetweenParagraphs(
            tester,
            htmlToMarkdown('AAA${'<br>' * brCount}BBB'),
          ),
          MarkdownScale.blankLine * (brCount - 1),
          reason: '$brCount <br>',
        );
      }
    });

    testWidgets('a rule sits evenly between the text it separates', (
      tester,
    ) async {
      // Paragraph padding is split top and bottom precisely so it cannot
      // bunch up on one side of a block that carries none of its own.
      const rule = 1.0;
      const air =
          MarkdownScale.gap + (MarkdownScale.blankLine - MarkdownScale.gap) / 2;
      expect(
        await gapBetweenParagraphs(tester, 'AAA\n\n---\n\nBBB'),
        air * 2 + rule,
      );
    });

    testWidgets('list items stay tight', (tester) async {
      // The paragraph rhythm must not leak into `li`, or every bullet list
      // turns into a stack of loose paragraphs.
      expect(await gapBetweenParagraphs(tester, '- AAA\n- BBB'), 8);
    });
  });

  testWidgets('a full document renders without overflowing', (tester) async {
    const document = '''
# Heading one
Body text with a [link](https://example.com), **bold**, _italic_ and
`inline code`.

## Heading two

- first bullet
- second bullet

1. numbered
2. numbered

---

> quoted text
>>>>> decorative quote <<<<<

> [!WARNING]
> Careful with this one.

```
fenced code block
```

| a | b |
|---|---|
| 1 | 2 |
''';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0EA5E9),
            brightness: Brightness.dark,
          ),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => buildDescriptionMarkdown(
                context,
                document,
                onLaunchUrl: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Heading one'), findsOneWidget);
    expect(find.text('Warning'), findsOneWidget);
  });
}
