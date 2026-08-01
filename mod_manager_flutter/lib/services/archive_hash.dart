/// md5 fingerprints for mod archives.
///
/// **Why md5, and what it is and isn't for.** GameBanana publishes an md5 per
/// file, so hashing an archive lets us say *which* published file a local
/// install came from — including for archives a user supplied by hand, which is
/// otherwise unknowable. That is the entire purpose: it is a **matching key**.
///
/// It is emphatically **not** an integrity or authenticity check. md5 is
/// cryptographically broken and deliberate collisions are constructible. That
/// costs nothing here precisely because a match grants no trust: it sets a
/// version label, skips no security check, and doesn't change what gets
/// extracted — the user already supplied the file. Never render a match as
/// "verified" or with a shield icon; the honest phrasing is "byte-identical to
/// file X on the mod page". If real integrity is ever wanted, add sha256
/// alongside rather than reinterpreting this.
///
/// **Timing matters more than it looks.** The archive is deleted once extracted,
/// and a zip cannot be reproduced byte-for-byte from its extracted contents. The
/// hash is the one cheap residue that survives that deletion, and it cannot be
/// recovered afterwards — so it has to be taken on the way past.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streams [file] and returns its md5 as 32 lowercase hex characters.
///
/// Returns null — never throws — if the file is missing or unreadable. A hash is
/// a bonus fast-path, never load-bearing, so a failure to compute one must not
/// fail an install.
Future<String?> md5OfFile(File file) async {
  try {
    if (!await file.exists()) return null;
    final digest = await md5.bind(file.openRead()).first;
    return digest.toString();
  } catch (_) {
    return null;
  }
}

/// Accumulates an md5 from chunks as they stream past.
///
/// Used by the downloader, where the bytes are already flowing through memory on
/// their way to disk — so the hash costs no extra read at all, on exactly the
/// files large enough for a second read to matter.
class Md5Accumulator {
  Md5Accumulator() {
    _sink = md5.startChunkedConversion(_output);
  }

  final _DigestSink _output = _DigestSink();
  late final ByteConversionSink _sink;

  bool _any = false;
  String? _result;

  void add(List<int> chunk) {
    if (chunk.isEmpty || _result != null) return;
    _any = true;
    _sink.add(chunk);
  }

  /// Finishes and returns the digest, or null if nothing was ever added.
  ///
  /// Safe to call more than once; later calls return the same value.
  String? close() {
    if (_result != null) return _result;
    _sink.close();
    if (!_any) return null;
    return _result = _output.value?.toString();
  }
}

/// Captures the single [Digest] a chunked md5 conversion emits on close.
///
/// Hand-rolled rather than using `package:convert`'s `AccumulatorSink` so this
/// needs no dependency beyond `crypto` itself.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
