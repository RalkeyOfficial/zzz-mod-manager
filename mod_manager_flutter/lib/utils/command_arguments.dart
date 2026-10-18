/// Splits a typed argument line into words the way a POSIX shell would, without running one.
///
/// Whitespace separates words. `'…'` is literal; inside `"…"` only `\"` and `\\` are escapes; outside quotes a
/// backslash escapes the next character. `""` is one empty word, and an unclosed quote runs to the end rather than
/// refusing a launch over a typo. Nothing is expanded. See `docs/launch-game.md`.
List<String> splitCommandArguments(String line) {
  final words = <String>[];
  final word = StringBuffer();
  // A quoted empty string is still a word, so "is there a word" is tracked apart from its text.
  var inWord = false;
  String? quote;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quote == "'") {
      if (char == "'") {
        quote = null;
      } else {
        word.write(char);
      }
    } else if (quote == '"') {
      if (char == '"') {
        quote = null;
      } else if (char == r'\' && i + 1 < line.length && (line[i + 1] == '"' || line[i + 1] == r'\')) {
        word.write(line[++i]);
      } else {
        word.write(char);
      }
    } else if (char == "'" || char == '"') {
      quote = char;
      inWord = true;
    } else if (char == r'\') {
      inWord = true;
      // A trailing backslash has nothing to escape and is kept.
      word.write(i + 1 < line.length ? line[++i] : char);
    } else if (char.trim().isEmpty) {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
    } else {
      word.write(char);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}
