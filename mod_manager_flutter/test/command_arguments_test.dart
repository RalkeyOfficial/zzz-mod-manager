import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/utils/command_arguments.dart';

/// The Launch arguments field split into words for Wine, the way a shell would split it.
void main() {
  test('the default arguments are three words', () {
    expect(splitCommandArguments('--nogui --xxmi ZZMI'), ['--nogui', '--xxmi', 'ZZMI']);
  });

  test('nothing, or only spaces, is no words', () {
    expect(splitCommandArguments(''), isEmpty);
    expect(splitCommandArguments('   \t '), isEmpty);
  });

  test('runs of whitespace separate words once', () {
    expect(splitCommandArguments('  a \t  b  '), ['a', 'b']);
  });

  test('single quotes are literal, backslashes included', () {
    expect(splitCommandArguments(r"'C:\Games\R&D' x"), [r'C:\Games\R&D', 'x']);
  });

  test('double quotes keep spaces, and only \\" and \\\\ are escapes inside them', () {
    expect(splitCommandArguments(r'"a b" "say \"hi\"" "c:\dir\\"'), ['a b', 'say "hi"', r'c:\dir\']);
  });

  test('outside quotes a backslash escapes the next character', () {
    expect(splitCommandArguments(r'a\ b c\"d'), ['a b', 'c"d']);
  });

  test('quotes join with the text around them', () {
    expect(splitCommandArguments('--name="Ellen Joe"x'), ['--name=Ellen Joex']);
  });

  test('an empty quoted string is still a word', () {
    expect(splitCommandArguments('a "" b'), ['a', '', 'b']);
  });

  test('an unclosed quote runs to the end instead of refusing', () {
    expect(splitCommandArguments('a "b c'), ['a', 'b c']);
  });

  test('a trailing backslash is kept', () {
    expect(splitCommandArguments(r'a\'), [r'a\']);
  });

  test('nothing is expanded', () {
    expect(splitCommandArguments(r'$HOME ~ *'), [r'$HOME', '~', '*']);
  });
}
