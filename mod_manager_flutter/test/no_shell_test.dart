import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **No command line is put together for a shell to read.** A shell reads `&`, `^` and `%` in a folder name as its
/// own syntax, so a mod's name could start another program or point a link at the wrong folder. Guarded: `runInShell`
/// set to anything but `false`, and any use of the Windows shells and their link command.
///
/// Not guarded, and safe: the Linux screen lock's `sh -c` runs a fixed script and gets its values as arguments, which
/// the shell never reads as syntax. Comments are skipped, since one may name a shell to say why it isn't used. A `.cmd`
/// file extension is no shell.
void main() {
  final forbidden = {
    'runInShell: anything but false': RegExp(r'\brunInShell\s*:(?!\s*false\b)', caseSensitive: false),
    'cmd': RegExp(r'(?<![.\w])cmd\b', caseSensitive: false),
    'cmd.exe': RegExp(r'\bcmd\.exe\b', caseSensitive: false),
    'powershell': RegExp(r'\bpowershell\b', caseSensitive: false),
    'ComSpec': RegExp(r'\bcomspec\b', caseSensitive: false),
    'mklink': RegExp(r'\bmklink\b', caseSensitive: false),
  };
  // A `//` that starts a comment, not the one in a URL such as `https://`.
  final comment = RegExp(r'(^|\s)//.*$');

  test('no source file in lib/ names a shell outside a comment', () {
    final hits = <String>[];
    final sources = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    for (final file in sources) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].replaceFirst(comment, '');
        forbidden.forEach((name, pattern) {
          if (pattern.hasMatch(code)) hits.add('${file.path}:${i + 1}: $name');
        });
      }
    }
    expect(hits, isEmpty);
  });

  test('the scan finds each of them', () {
    final runInShell = forbidden['runInShell: anything but false']!;
    expect(runInShell.hasMatch('Process.run(x, [], runInShell:true)'), isTrue);
    expect(runInShell.hasMatch('Process.start(x, [], runInShell: Platform.isWindows)'), isTrue);
    expect(runInShell.hasMatch('Process.start(x, [], runInShell: shell)'), isTrue);
    expect(runInShell.hasMatch('Process.start(x, [], runInShell: false)'), isFalse);
    expect(forbidden['cmd']!.hasMatch("Process.start('CMD', ['/c', name])"), isTrue);
    expect(forbidden['cmd.exe']!.hasMatch("'C:/Windows/System32/cmd.exe'"), isTrue);
    expect(forbidden['powershell']!.hasMatch("Process.run('PowerShell', [])"), isTrue);
    expect(forbidden['ComSpec']!.hasMatch("Platform.environment['COMSPEC']"), isTrue);
    expect(forbidden['mklink']!.hasMatch("['/c', 'mklink', '/J']"), isTrue);
    expect(forbidden['cmd']!.hasMatch("{'.bat', '.cmd'}"), isFalse);
    expect(forbidden['cmd']!.hasMatch('command'), isFalse);
  });
}
