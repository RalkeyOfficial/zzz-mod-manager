import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The ratchet on the print migration.
///
/// 223 `print` calls were replaced by `Logger`, and the value of that is not the
/// tidiness — it is that a failure now lands in a file somebody can attach to a
/// bug report. One `print` added back is one failure that goes nowhere, and it
/// is invisible in review because it looks exactly like the code that used to be
/// there.
///
/// `avoid_print` covers the first half and is enabled. It does **not** cover
/// `debugPrint`, which is worse for a logger: it throttles at ~12.8 KB/s and
/// *defers* the overflow, so output arrives reordered or not at all during
/// exactly the burst worth reading. Hence this test as well as the lint.
void main() {
  test('nothing in lib/ prints', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The one legitimate writer to stdout, and the reason it is allowed is
      // in its own doc comment.
      if (entity.path.endsWith('log_sinks.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//') ||
            line.trimLeft().startsWith('///')) {
          continue;
        }
        // Word-boundary, so `destinationFingerprint(` and `sprint(` are not
        // matched — the naive `print(` search finds both.
        if (RegExp(r'(?<![A-Za-z0-9_])(print|debugPrint)\s*\(')
            .hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'use `Logger(<tag>)` from services/log/logger.dart instead — '
          'see docs/logging.md',
    );
  });
}
