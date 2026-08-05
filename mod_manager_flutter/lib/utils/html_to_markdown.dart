import 'package:html2md/html2md.dart' as html2md;

/// Converts an HTML fragment to markdown, in the one style this app's
/// descriptions are written in.
///
/// Two callers, one conversion on purpose:
///
/// - the description editors, where Ctrl+V pastes rich text from the clipboard;
/// - GameBanana's `_sText`, which is **HTML** while every description we store
///   and render is markdown (`docs/gamebanana-api.md` §11).
///
/// Keeping the style options in one place is the point. They are not cosmetic:
/// ATX headers (`## x`) and `-` bullets match how descriptions are written by
/// hand, and fenced code blocks render in `buildDescriptionMarkdown` while
/// indented ones are ambiguous with quoted output. Two copies of this map would
/// drift, and the drift would only show up as pasted text and imported text
/// rendering differently.
String htmlToMarkdown(String html) {
  if (html.trim().isEmpty) return '';
  return html2md.convert(
    html,
    styleOptions: {
      'headingStyle': 'atx',
      'bulletListMarker': '-',
      'codeBlockStyle': 'fenced',
    },
  ).trim();
}
