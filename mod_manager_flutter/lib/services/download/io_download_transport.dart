import 'dart:io';

import '../../core/constants.dart';
import 'download_transport.dart';

/// The real [DownloadTransport], and the only `dart:io` [HttpClient] left in the
/// app.
///
/// `package:http` can't serve this role: its `Response` buffers the whole body,
/// which is untenable for archives that reach 1.24 GB. `HttpClientResponse` *is*
/// a `Stream<List<int>>`, so it can be handed straight to the service and its
/// `pause()` reaches the socket.
///
/// Three settings below are load-bearing rather than incidental — see each.
class IoDownloadTransport implements DownloadTransport {
  IoDownloadTransport({HttpClient? client, String? userAgent})
      : _client = client ?? HttpClient(),
        _userAgent = userAgent ?? 'zzz-mod-manager/${AppConstants.appVersion}' {
    // Must stay false. With auto-uncompress on, Dart adds `accept-encoding:
    // gzip` and transparently inflates the body — at which point `Content-Length`
    // describes the compressed size while the bytes we write are the inflated
    // ones, so every resume offset and every `Range` we send is wrong. Archives
    // don't compress, but nothing stops a proxy from trying.
    _client.autoUncompress = false;

    // Note what is NOT here: `badCertificateCallback`. The old inline downloader
    // disabled certificate validation on both shipping platforms. Nothing in
    // this class re-enables that, and nothing should.
  }

  final HttpClient _client;
  final String _userAgent;

  @override
  Future<DownloadResponse> open(
    Uri url, {
    Map<String, String> headers = const {},
    Duration connectTimeout = const Duration(seconds: 20),
  }) async {
    // Applies to establishing the connection only. There is deliberately no
    // timeout on the body: a legitimate transfer over a degraded CDN node can
    // take 25 minutes, so the service enforces a *stall* timeout instead.
    _client.connectionTimeout = connectTimeout;

    final request = await _client.getUrl(url);
    // Two cross-host hops: gamebanana.com/dl/<id> -> files.gamebanana.com ->
    // filecacheNN.gamebanana.com. A client that doesn't follow them gets an
    // empty 302 body. Default is already true; set explicitly so it stays that
    // way. `Range` survives both hops, which is why a resolved CDN url never
    // needs persisting.
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    headers.forEach(request.headers.set);

    final response = await request.close();

    return DownloadResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      headers: _lowerCased(response.headers),
      body: response,
      onDiscard: () => response.drain<void>(),
    );
  }

  static Map<String, String> _lowerCased(HttpHeaders headers) {
    final result = <String, String>{};
    headers.forEach((name, values) {
      if (values.isNotEmpty) result[name.toLowerCase()] = values.first;
    });
    return result;
  }

  @override
  void close() => _client.close(force: true);
}
