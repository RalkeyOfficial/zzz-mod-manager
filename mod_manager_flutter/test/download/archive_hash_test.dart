import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/archive_hash.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('archive_hash_test_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File write(String name, List<int> bytes) {
    final file = File(path.join(temp.path, name));
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('md5OfFile', () {
    test('matches the published md5 test vectors', () async {
      // Pinned against the RFC vectors rather than against our own output, so a
      // hex-encoding or byte-order mistake can't hide behind self-consistency.
      expect(await md5OfFile(write('empty.bin', const [])),
          'd41d8cd98f00b204e9800998ecf8427e');
      expect(await md5OfFile(write('abc.bin', 'abc'.codeUnits)),
          '900150983cd24fb0d6963f7d28e17f72');
      expect(
        await md5OfFile(write('fox.bin',
            'The quick brown fox jumps over the lazy dog'.codeUnits)),
        '9e107d9d372bb6826bd81d3542a419d6',
      );
    });

    test('is 32 lowercase hex characters', () async {
      final digest = await md5OfFile(write('x.bin', [1, 2, 3]));
      expect(digest, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('handles a file bigger than one read buffer', () async {
      final big = Uint8List(1024 * 1024);
      for (var i = 0; i < big.length; i++) {
        big[i] = i % 251;
      }
      final digest = await md5OfFile(write('big.bin', big));
      expect(digest, isNotNull);

      // Same bytes, same digest — proves streaming doesn't lose or reorder.
      expect(await md5OfFile(write('big2.bin', big)), digest);
    });

    test('returns null for a missing file instead of throwing', () async {
      // A hash is a bonus fast-path, never load-bearing: failing to compute one
      // must never fail an install.
      expect(await md5OfFile(File(path.join(temp.path, 'nope.bin'))), isNull);
    });

    test('returns null for a directory instead of throwing', () async {
      expect(await md5OfFile(File(temp.path)), isNull);
    });
  });

  group('Md5Accumulator', () {
    test('agrees with md5OfFile over the same bytes', () async {
      final bytes = 'The quick brown fox jumps over the lazy dog'.codeUnits;
      final accumulator = Md5Accumulator()..add(bytes);
      expect(accumulator.close(), await md5OfFile(write('fox.bin', bytes)));
    });

    test('is independent of chunk boundaries', () {
      final bytes = List<int>.generate(5000, (i) => i % 256);

      final oneShot = Md5Accumulator()..add(bytes);
      final byteAtATime = Md5Accumulator();
      for (final b in bytes) {
        byteAtATime.add([b]);
      }
      final ragged = Md5Accumulator();
      for (var i = 0; i < bytes.length; i += 37) {
        ragged.add(bytes.sublist(i, (i + 37).clamp(0, bytes.length)));
      }

      final expected = oneShot.close();
      expect(expected, isNotNull);
      expect(byteAtATime.close(), expected);
      expect(ragged.close(), expected);
    });

    test('returns null when nothing was ever added', () {
      expect(Md5Accumulator().close(), isNull);
    });

    test('empty chunks do not count as data', () {
      final accumulator = Md5Accumulator()
        ..add(const [])
        ..add(const []);
      expect(accumulator.close(), isNull);
    });

    test('close is idempotent', () {
      final accumulator = Md5Accumulator()..add('abc'.codeUnits);
      final first = accumulator.close();
      expect(accumulator.close(), first);
      expect(first, '900150983cd24fb0d6963f7d28e17f72');
    });
  });
}
