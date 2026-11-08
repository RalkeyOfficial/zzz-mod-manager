import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'key_combo.dart';
import 'log/logger.dart';

final Logger _log = Logger('ini');
final Logger _files = Logger('fileops');

/// What `;zenith:` starts: the app's own comments in a mod's `.ini` (`docs/key-editing.md` §5).
const String _prefix = ';zenith:';

/// How the parser and the editor read one line of an `.ini`, so they agree on what a section and a value are.
class IniLine {
  const IniLine._();

  static final RegExp _section = RegExp(r'^\[([^\]]+)\]\s*(;.*)?$');

  /// The name in a section header such as `[KeyHair]`, which may be followed by a comment. Null for any other line.
  /// [trimmed] is the line without its surrounding whitespace.
  static String? sectionName(String trimmed) => _section.firstMatch(trimmed)?.group(1);

  /// Splits the text after `=` into its value and the comment that follows it. A comment starts at a `;` that is
  /// the first character or comes after whitespace. [tail] is what follows the value's last character, spacing and
  /// comment together, for writing back.
  static ({String value, String tail}) splitComment(String text) {
    var comment = -1;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == ';' && (i == 0 || text[i - 1] == ' ' || text[i - 1] == '\t')) {
        comment = i;
        break;
      }
    }
    final before = comment < 0 ? text : text.substring(0, comment);
    final value = before.trim();
    // Everything after the value's last character, spacing and comment together.
    final end = before.trimRight().length;
    return (value: value, tail: text.substring(end));
  }
}

/// A change to one `.ini`, found by section name and occurrence (`KeybindInfo.section` and `.occurrence`).
sealed class IniKeyEdit {
  const IniKeyEdit();
}

/// Writes [key] as the section's key. The first change leaves `;zenith: key = <the old value>` above it.
class SetKey extends IniKeyEdit {
  const SetKey(this.section, this.occurrence, this.key);

  final String section;
  final int occurrence;
  final String key;

  @override
  String toString() => 'SetKey($section#$occurrence, $key)';
}

/// Comments the whole section out.
class Unbind extends IniKeyEdit {
  const Unbind(this.section, this.occurrence);

  final String section;
  final int occurrence;

  @override
  String toString() => 'Unbind($section#$occurrence)';
}

/// Uncomments the [index]th block an [Unbind] left in the file, and writes [key] as its key when that differs.
class RestoreBlock extends IniKeyEdit {
  const RestoreBlock(this.index, {this.key});

  final int index;
  final String? key;

  @override
  String toString() => 'RestoreBlock($index, $key)';
}

/// A section an [Unbind] commented out.
class IniBlock {
  const IniBlock({required this.index, required this.section, required this.key});

  /// Its place among the file's blocks, which [RestoreBlock] names it by.
  final int index;
  final String section;

  /// The key the section had before it was commented out, the author's when a marker says so. Null for a section
  /// with no `key` line.
  final String? key;
}

/// What a file holds of the app's own comments.
class IniKeyState {
  const IniKeyState({this.markers = const {}, this.blocks = const []});

  /// The author's key for each section whose key was changed, by lower-case section name and occurrence.
  final Map<({String section, int occurrence}), String> markers;

  final List<IniBlock> blocks;

  String? markerFor(String section, int occurrence) =>
      markers[(section: section.toLowerCase(), occurrence: occurrence)];
}

/// The result of [IniKeyEditor.apply].
class IniEditResult {
  const IniEditResult(this.text, {this.missing = const []});

  final String text;

  /// The edits that found no section or no `key` line to act on.
  final List<IniKeyEdit> missing;
}

class _Line {
  _Line(this.body, this.eol);

  String body;
  String eol;

  String get trimmed => body.trim();
}

class _Section {
  _Section(this.name, this.occurrence, this.header, this.end);

  final String name;
  final int occurrence;
  final int header;

  /// The last line that is not blank or a comment, so the comments above the next section stay out of it.
  final int end;
}

final RegExp _keyLine = RegExp(r'^(\s*)([Kk][Ee][Yy])(\s*=\s*)(.*)$');

/// Rewrites the `key` lines of an `.ini` and nothing else: a pure text transform, so every guarantee of
/// `docs/key-editing.md` §4 is a test on strings. [IniKeyFiles] does the reading and writing of the file.
class IniKeyEditor {
  const IniKeyEditor._();

  /// The markers and commented-out sections in [text].
  static IniKeyState inspect(String text) {
    final lines = _split(text);
    final markers = <({String section, int occurrence}), String>{};
    for (final section in _sections(lines)) {
      final key = _keyLineOf(lines, section);
      if (key == null) continue;
      final marker = _markerValue(lines, key);
      if (marker != null) markers[(section: section.name.toLowerCase(), occurrence: section.occurrence)] = marker;
    }
    return IniKeyState(
      markers: markers,
      blocks: [
        for (final (i, block) in _blocks(lines).indexed)
          IniBlock(index: i, section: block.name, key: _blockKey(lines, block)),
      ],
    );
  }

  /// [text] with [edits] applied, each against the sections as they are in [text]. An edit whose section or key
  /// line is not there is left out and returned in [IniEditResult.missing].
  static IniEditResult apply(String text, List<IniKeyEdit> edits) {
    final lines = _split(text);
    final eol = lines.firstWhere((l) => l.eol.isNotEmpty, orElse: () => _Line('', '\n')).eol;
    final sections = _sections(lines);
    final blocks = _blocks(lines);
    final missing = <IniKeyEdit>[];

    // Each edit is resolved against the text as it was, then they run from the bottom up so a line added or taken
    // out never moves one still to come.
    final resolved = <({int start, void Function() run})>[];
    for (final edit in edits) {
      switch (edit) {
        case SetKey():
          final section = _find(sections, edit.section, edit.occurrence);
          final key = section == null ? null : _keyLineOf(lines, section);
          if (section == null || key == null) {
            missing.add(edit);
            continue;
          }
          resolved.add((start: section.header, run: () => _setKey(lines, section, key, edit.key, eol)));
        case Unbind():
          final section = _find(sections, edit.section, edit.occurrence);
          if (section == null) {
            missing.add(edit);
            continue;
          }
          resolved.add((start: section.header, run: () => _comment(lines, section.header, section.end)));
        case RestoreBlock():
          if (edit.index < 0 || edit.index >= blocks.length) {
            missing.add(edit);
            continue;
          }
          final block = blocks[edit.index];
          resolved.add((start: block.start, run: () => _uncomment(lines, block, edit.key, eol)));
      }
    }
    resolved.sort((a, b) => b.start.compareTo(a.start));
    for (final r in resolved) {
      r.run();
    }
    return IniEditResult(lines.map((l) => l.body + l.eol).join(), missing: missing);
  }

  // Lines keep their own endings, so a file with mixed endings is written back with mixed endings.
  static List<_Line> _split(String text) {
    final lines = <_Line>[];
    var start = 0;
    for (final m in RegExp(r'\r\n|\n').allMatches(text)) {
      lines.add(_Line(text.substring(start, m.start), m.group(0)!));
      start = m.end;
    }
    if (start < text.length) lines.add(_Line(text.substring(start), ''));
    return lines;
  }

  static bool _isCommentOrBlank(String trimmed) =>
      trimmed.isEmpty || trimmed.startsWith(';') || trimmed.startsWith('#');

  static List<_Section> _sections(List<_Line> lines) {
    final headers = <(int, String)>[];
    for (var i = 0; i < lines.length; i++) {
      if (IniLine.sectionName(lines[i].trimmed) case final name?) headers.add((i, name));
    }
    final seen = <String, int>{};
    return [
      for (var h = 0; h < headers.length; h++)
        () {
          final (header, name) = headers[h];
          final limit = h + 1 < headers.length ? headers[h + 1].$1 : lines.length;
          var end = limit - 1;
          while (end > header && _isCommentOrBlank(lines[end].trimmed)) {
            end--;
          }
          return _Section(name, seen.update(name.toLowerCase(), (n) => n + 1, ifAbsent: () => 0), header, end);
        }(),
    ];
  }

  static _Section? _find(List<_Section> sections, String name, int occurrence) {
    final lower = name.toLowerCase();
    return sections.where((s) => s.name.toLowerCase() == lower && s.occurrence == occurrence).firstOrNull;
  }

  /// The last `key =` line of [section], which is the one the parser reports.
  static int? _keyLineOf(List<_Line> lines, _Section section) {
    for (var i = section.end; i > section.header; i--) {
      if (_keyLine.hasMatch(lines[i].body)) return i;
    }
    return null;
  }

  static String _valueOf(String body) {
    final match = _keyLine.firstMatch(body)!;
    return IniLine.splitComment(match.group(4)!).value;
  }

  /// The author's key a marker above [keyLine] holds, or null when there is none.
  static String? _markerValue(List<_Line> lines, int keyLine) {
    if (keyLine == 0) return null;
    final above = lines[keyLine - 1].trimmed;
    final match = RegExp('^$_prefix\\s*key\\s*=\\s*(.*)\$', caseSensitive: false).firstMatch(above);
    return match?.group(1)?.trim();
  }

  static void _setKey(List<_Line> lines, _Section section, int keyLine, String newKey, String fileEol) {
    final match = _keyLine.firstMatch(lines[keyLine].body)!;
    final indent = match.group(1)!;
    final split = IniLine.splitComment(match.group(4)!);
    if (sameCombo(split.value, newKey)) return;
    lines[keyLine].body = '$indent${match.group(2)}${match.group(3)}$newKey${split.tail}';

    final marker = _markerValue(lines, keyLine);
    if (marker == null) {
      // The first change: the author's value goes in a comment above, in the key line's own line ending.
      lines.insert(
        keyLine,
        _Line('$indent$_prefix key = ${split.value}', lines[keyLine].eol.isEmpty ? fileEol : lines[keyLine].eol),
      );
    } else if (sameCombo(marker, newKey)) {
      // Back to the author's own key: the marker has nothing left to say.
      lines.removeAt(keyLine - 1);
    }
  }

  static void _comment(List<_Line> lines, int from, int to) {
    for (var i = from; i <= to; i++) {
      final body = lines[i].body;
      lines[i].body = body.isEmpty ? _prefix : '$_prefix $body';
    }
  }

  static String _unprefix(String body) {
    final trimmed = body.trimLeft();
    final rest = trimmed.substring(_prefix.length);
    return rest.startsWith(' ') ? rest.substring(1) : rest;
  }

  static bool _isPrefixed(String body) => body.trimLeft().startsWith(_prefix);

  static bool _opensBlock(String body) => _isPrefixed(body) && IniLine.sectionName(_unprefix(body).trim()) != null;

  /// Runs of `;zenith:` lines that start with a commented-out header.
  static List<({int start, int end, String name})> _blocks(List<_Line> lines) {
    final blocks = <({int start, int end, String name})>[];
    var i = 0;
    while (i < lines.length) {
      if (!_opensBlock(lines[i].body)) {
        i++;
        continue;
      }
      var end = i;
      while (end + 1 < lines.length && _isPrefixed(lines[end + 1].body) && !_opensBlock(lines[end + 1].body)) {
        end++;
      }
      blocks.add((start: i, end: end, name: IniLine.sectionName(_unprefix(lines[i].body).trim())!));
      i = end + 1;
    }
    return blocks;
  }

  static String? _blockKey(List<_Line> lines, ({int start, int end, String name}) block) {
    final inner = [for (var i = block.start; i <= block.end; i++) _Line(_unprefix(lines[i].body), lines[i].eol)];
    final section = _Section(block.name, 0, 0, inner.length - 1);
    final key = _keyLineOf(inner, section);
    if (key == null) return null;
    return _markerValue(inner, key) ?? _valueOf(inner[key].body);
  }

  static void _uncomment(List<_Line> lines, ({int start, int end, String name}) block, String? key, String fileEol) {
    for (var i = block.start; i <= block.end; i++) {
      lines[i].body = _unprefix(lines[i].body);
    }
    if (key == null) return;
    // The block is a section again: the key line is changed the way any other is, which also takes a marker out
    // when the key goes back to the author's.
    final section = _Section(block.name, 0, block.start, block.end);
    final keyLine = _keyLineOf(lines, section);
    if (keyLine != null) _setKey(lines, section, keyLine, key, fileEol);
  }
}

/// Why a file was or was not written.
enum IniWriteStatus { written, unchanged, notUtf8, failed }

/// What [IniKeyFiles.write] did to one file. [missing] are the edits it found no place for.
class IniFileWrite {
  const IniFileWrite(this.file, this.status, {this.missing = const []});

  /// The file's path inside the mod folder.
  final String file;
  final IniWriteStatus status;
  final List<IniKeyEdit> missing;

  bool get problem => status == IniWriteStatus.notUtf8 || status == IniWriteStatus.failed || missing.isNotEmpty;
}

/// Reads and writes an `.ini` for [IniKeyEditor]: a file that is not UTF-8 is refused, the byte-order mark is kept,
/// and the new text replaces the old by a rename, so a crash leaves one or the other whole.
class IniKeyFiles {
  const IniKeyFiles._();

  static const List<int> _bom = [0xEF, 0xBB, 0xBF];

  /// The file's text and whether it began with a byte-order mark. Throws [FormatException] for a file that is not
  /// UTF-8.
  static Future<({String text, bool bom})> _read(String path) async {
    final bytes = await File(path).readAsBytes();
    final bom = bytes.length >= 3 && bytes[0] == _bom[0] && bytes[1] == _bom[1] && bytes[2] == _bom[2];
    return (text: utf8.decode(bom ? bytes.sublist(3) : bytes), bom: bom);
  }

  /// What [path] holds of the app's own comments, or null when it cannot be read as UTF-8.
  static Future<IniKeyState?> inspect(String path) async {
    try {
      return IniKeyEditor.inspect((await _read(path)).text);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Applies [edits] to [path]. [relative] names the file in logs and in the result.
  static Future<IniFileWrite> write(String path, String relative, List<IniKeyEdit> edits) async {
    final String text;
    final bool bom;
    try {
      final read = await _read(path);
      text = read.text;
      bom = read.bom;
    } on FormatException {
      _log.warning('key edit refused, the file is not UTF-8', fields: {'file': relative});
      return IniFileWrite(relative, IniWriteStatus.notUtf8);
    } on FileSystemException catch (e) {
      _log.warning('key edit failed, the file could not be read', error: e, fields: {'file': relative});
      return IniFileWrite(relative, IniWriteStatus.failed);
    }

    final result = IniKeyEditor.apply(text, edits);
    if (result.text == text) return IniFileWrite(relative, IniWriteStatus.unchanged, missing: result.missing);

    final temp = File(p.join(p.dirname(path), '.${p.basename(path)}.zenith.tmp'));
    try {
      await temp.writeAsBytes([if (bom) ..._bom, ...utf8.encode(result.text)], flush: true);
      await temp.rename(path);
    } on FileSystemException catch (e) {
      _files.error('key edit failed, the file could not be written', error: e, fields: {'file': relative});
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // Left behind is a hidden file the game does not load.
      }
      return IniFileWrite(relative, IniWriteStatus.failed);
    }
    _files.info('keys written', fields: {'file': relative, 'edits': edits.length - result.missing.length});
    return IniFileWrite(relative, IniWriteStatus.written, missing: result.missing);
  }
}
