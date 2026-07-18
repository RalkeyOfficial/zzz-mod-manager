import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html2md/html2md.dart' as html2md;
import '../services/api_service.dart';

/// Wraps a description [field] with the markdown editing shortcuts:
/// Ctrl/Cmd+V pastes rich text as markdown; Ctrl/Cmd+B/I/E wrap the selection
/// in bold/italic/inline-code (toggling off if already wrapped); Ctrl/Cmd+K
/// makes a link; Ctrl+1/2/3 toggle a heading on the current line.
Widget markdownEditorField(TextEditingController c, Widget field) {
  return CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
          _smartPasteMarkdown(c),
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
          _smartPasteMarkdown(c),
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
          _toggleEmphasis(c, bold: true),
      const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
          _toggleEmphasis(c, bold: true),
      const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
          _toggleEmphasis(c, bold: false),
      const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
          _toggleEmphasis(c, bold: false),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
          _toggleWrap(c, '`', 'code'),
      const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () =>
          _toggleWrap(c, '`', 'code'),
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
          _toggleLink(c),
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
          _toggleLink(c),
      const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
          _toggleHeading(c, 1),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
          _toggleHeading(c, 2),
      const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
          _toggleHeading(c, 3),
    },
    child: field,
  );
}

/// Wraps the selection in [marker] (e.g. `**`), or unwraps it when already
/// wrapped — the smart toggle. With no selection, inserts
/// `marker+placeholder+marker` and selects the [placeholder] so it can be
/// typed over.
void _toggleWrap(TextEditingController c, String marker, String placeholder) {
  final text = c.text;
  final sel = c.selection.isValid
      ? c.selection
      : TextSelection.collapsed(offset: text.length);
  final start = sel.start;
  final end = sel.end;
  final m = marker.length;

  // No selection → insert a placeholder and select it.
  if (start == end) {
    final newText = text.replaceRange(start, start, '$marker$placeholder$marker');
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start + m,
        extentOffset: start + m + placeholder.length,
      ),
    );
    return;
  }

  final selected = text.substring(start, end);

  // Unwrap case A: the selection itself includes the markers.
  if (selected.length >= 2 * m &&
      selected.startsWith(marker) &&
      selected.endsWith(marker)) {
    final inner = selected.substring(m, selected.length - m);
    final newText = text.replaceRange(start, end, inner);
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + inner.length,
      ),
    );
    return;
  }

  // Unwrap case B: the markers sit immediately outside the selection.
  final hasBefore = start >= m && text.substring(start - m, start) == marker;
  final hasAfter = end + m <= text.length && text.substring(end, end + m) == marker;
  if (hasBefore && hasAfter && _markersAreExact(text, start, end, marker)) {
    // Remove the trailing marker first so the leading removal keeps its index.
    final newText = text
        .replaceRange(end, end + m, '')
        .replaceRange(start - m, start, '');
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start - m,
        extentOffset: end - m,
      ),
    );
    return;
  }

  // Otherwise wrap, keeping the inner text selected.
  final newText = text.replaceRange(start, end, '$marker$selected$marker');
  c.value = TextEditingValue(
    text: newText,
    selection: TextSelection(baseOffset: start + m, extentOffset: end + m),
  );
}

/// Ensures the [marker]s just outside the selection aren't part of a longer
/// run of the same character — so `*` (italic) doesn't match inside `**`
/// (bold); wrapping bold text with italic then yields `***…***` instead of
/// corrupting the bold markers.
bool _markersAreExact(String text, int start, int end, String marker) {
  final ch = marker[0];
  final beforeIdx = start - marker.length - 1;
  final afterIdx = end + marker.length;
  final beforeOk = beforeIdx < 0 || text[beforeIdx] != ch;
  final afterOk = afterIdx >= text.length || text[afterIdx] != ch;
  return beforeOk && afterOk;
}

/// Toggles the bold (or italic) component of the selection independently,
/// treating the surrounding run of `*` as markdown emphasis: 1 star = italic,
/// 2 = bold, 3 = both. Ctrl+B on `***x***` (bold+italic) therefore drops to
/// `*x*` (italic kept) rather than adding more stars. With no selection it
/// inserts a `bold`/`italic` placeholder and selects it.
void _toggleEmphasis(TextEditingController c, {required bool bold}) {
  final text = c.text;
  final sel = c.selection.isValid
      ? c.selection
      : TextSelection.collapsed(offset: text.length);
  final selStart = sel.start;
  final selEnd = sel.end;

  // No selection → insert a placeholder wrapped in the right stars.
  if (selStart == selEnd) {
    final marker = bold ? '**' : '*';
    final placeholder = bold ? 'bold' : 'italic';
    final newText =
        text.replaceRange(selStart, selStart, '$marker$placeholder$marker');
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: selStart + marker.length,
        extentOffset: selStart + marker.length + placeholder.length,
      ),
    );
    return;
  }

  // Locate the star run and the star-free core. The stars may sit just inside
  // the selection (user selected `**word**`) or just outside it (selected
  // only `word`); handle both, preferring the inside case when present.
  int insideBefore = 0;
  while (selStart + insideBefore < selEnd &&
      text[selStart + insideBefore] == '*') {
    insideBefore++;
  }
  int insideAfter = 0;
  while (selEnd - insideAfter - 1 >= selStart &&
      text[selEnd - insideAfter - 1] == '*') {
    insideAfter++;
  }

  int coreStart;
  int coreEnd;
  int n;
  final insideN =
      insideBefore < insideAfter ? insideBefore : insideAfter;
  if (insideN > 0 && (selEnd - selStart) >= 2 * insideN) {
    n = insideN;
    coreStart = selStart + n;
    coreEnd = selEnd - n;
  } else {
    int before = 0;
    while (selStart - before - 1 >= 0 && text[selStart - before - 1] == '*') {
      before++;
    }
    int after = 0;
    while (selEnd + after < text.length && text[selEnd + after] == '*') {
      after++;
    }
    n = before < after ? before : after;
    coreStart = selStart;
    coreEnd = selEnd;
  }

  final hasStrong = n >= 2;
  final hasEm = n.isOdd;
  final newStrong = bold ? !hasStrong : hasStrong;
  final newEm = bold ? hasEm : !hasEm;
  final target = (newStrong ? 2 : 0) + (newEm ? 1 : 0);

  final core = text.substring(coreStart, coreEnd);
  final left = text.substring(0, coreStart - n);
  final right = text.substring(coreEnd + n);
  final stars = '*' * target;
  final newText = '$left$stars$core$stars$right';
  final newStart = (coreStart - n) + target;
  c.value = TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: newStart,
      extentOffset: newStart + core.length,
    ),
  );
}

/// Turns the selection into `[selection](url)` with `url` selected; with no
/// selection inserts `[text](url)` and selects `text`. Toggles off when the
/// selection is already exactly a `[label](url)` link.
void _toggleLink(TextEditingController c) {
  final text = c.text;
  final sel = c.selection.isValid
      ? c.selection
      : TextSelection.collapsed(offset: text.length);
  final start = sel.start;
  final end = sel.end;
  final selected = text.substring(start, end);

  if (start == end) {
    const insertion = '[text](url)';
    final newText = text.replaceRange(start, start, insertion);
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start + 1, // after '['
        extentOffset: start + 5, // before ']'
      ),
    );
    return;
  }

  // Toggle off an existing [label](url).
  final linkMatch = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)$').firstMatch(selected);
  if (linkMatch != null) {
    final label = linkMatch.group(1)!;
    final newText = text.replaceRange(start, end, label);
    c.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + label.length,
      ),
    );
    return;
  }

  // Wrap: [selection](url), select "url".
  final newText = text.replaceRange(start, end, '[$selected](url)');
  final urlStart = start + selected.length + 3; // '[' + selected + ']('
  c.value = TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: urlStart,
      extentOffset: urlStart + 3, // 'url'
    ),
  );
}

/// Toggles a level-[level] heading prefix (`#`, `##`, `###`) on the line the
/// caret is on. Re-applying the same level removes it.
void _toggleHeading(TextEditingController c, int level) {
  final text = c.text;
  final caret = c.selection.isValid ? c.selection.start : text.length;
  final lineStart = caret > 0 ? text.lastIndexOf('\n', caret - 1) + 1 : 0;
  var lineEnd = text.indexOf('\n', caret);
  if (lineEnd == -1) lineEnd = text.length;
  final line = text.substring(lineStart, lineEnd);

  final match = RegExp(r'^(#{1,6})\s+').firstMatch(line);
  final body = match != null ? line.substring(match.end) : line;
  final currentLevel = match != null ? match.group(1)!.length : 0;

  final newLine = currentLevel == level ? body : '${'#' * level} $body';
  final newText = text.replaceRange(lineStart, lineEnd, newLine);
  c.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: lineStart + newLine.length),
  );
}

/// Reads the clipboard, converting HTML to markdown when present, and inserts
/// the result at the current selection of [controller].
Future<void> _smartPasteMarkdown(TextEditingController controller) async {
  String toInsert;
  final html = await ApiService.getClipboardHtml();
  if (html != null && html.trim().isNotEmpty) {
    // ATX headers (`## x`) and `-` bullets match how the description is
    // written by hand; fenced code blocks render better than indented.
    toInsert = html2md
        .convert(
          html,
          styleOptions: {
            'headingStyle': 'atx',
            'bulletListMarker': '-',
            'codeBlockStyle': 'fenced',
          },
        )
        .trim();
  } else {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    toInsert = data?.text ?? '';
  }
  if (toInsert.isEmpty) return;

  final value = controller.value;
  final sel = value.selection;
  // Replace the selection (or insert at the caret); guard against an
  // invalid/absent selection by appending to the end.
  final start = sel.isValid ? sel.start : value.text.length;
  final end = sel.isValid ? sel.end : value.text.length;
  final newText = value.text.replaceRange(start, end, toInsert);
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start + toInsert.length),
  );
}
