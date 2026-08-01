import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_transport.dart';

/// The real [HttpTransport], over `package:http`.
///
/// Chosen over a raw `dart:io` `HttpClient` for one reason above the others:
/// **`http.Client` exposes no `badCertificateCallback`.** The old inline
/// download code disabled certificate validation wholesale on both shipping
/// platforms, and a client that has no way to express that cannot inherit it by
/// accident. It also hands back a decoded body and a plain header map, which is
/// all a JSON endpoint needs.
///
/// Where `dart:io`'s extras genuinely matter — range requests, resume, redirect
/// inspection, socket backpressure — those belong to the file downloader, which
/// is a separate concern with its own client, not this interface.
class PackageHttpTransport implements HttpTransport {
  PackageHttpTransport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<HttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _client.get(url, headers: headers).timeout(timeout);
    return HttpResponse(
      statusCode: response.statusCode,
      // `response.body` decodes using the charset from Content-Type, defaulting
      // to latin-1 when the server omits it. GameBanana serves UTF-8 JSON
      // without always saying so, and mod names are full of non-ASCII, so
      // decode the bytes explicitly instead.
      body: _decodeUtf8(response),
      headers: response.headers, // package:http already lower-cases these.
    );
  }

  String _decodeUtf8(http.Response response) {
    try {
      return const Utf8Decoder().convert(response.bodyBytes);
    } on FormatException {
      // Malformed bytes: fall back rather than throwing here, so the JSON layer
      // is the single place that reports an unusable body.
      return const Utf8Decoder(allowMalformed: true).convert(response.bodyBytes);
    }
  }

  @override
  void close() => _client.close();
}
