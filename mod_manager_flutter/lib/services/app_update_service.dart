/// Whether GitHub has a newer release of the app than the one running, asked only when the user presses Check for
/// updates in Settings > About. Nothing is downloaded or installed (`docs/app-updates.md`).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'http/http_transport.dart';
import 'http/package_http_transport.dart';
import 'log/logger.dart';

final Logger _log = Logger('update.app');

/// What a check found.
enum AppUpdateOutcome { upToDate, newer, failed }

/// Why a check found nothing out, in the words the About page has a line for.
enum AppUpdateFailure {
  /// No answer at all: no connection, DNS, TLS or a timeout.
  offline('offline'),

  /// GitHub refused the request for sending too many from this address (403 or 429).
  rateLimited('rate_limited'),

  /// The repository has no published release (404).
  noRelease('no_release'),

  /// An answer that is not a release the app can read: another status, a body that is not JSON, or a tag that is not
  /// a version.
  unreadable('unreadable');

  const AppUpdateFailure(this.reason);

  /// The value of the log's `reason` field, snake_case as the GameBanana client writes its own.
  final String reason;
}

/// The answer to one press of Check for updates, held for the session ([appUpdateResultProvider]).
@immutable
class AppUpdateResult {
  const AppUpdateResult._(
    this.outcome,
    this.checkedAt, {
    this.latest,
    this.releaseUrl,
    this.failure,
    this.runningPreRelease = false,
  });

  /// The release is not newer than the running app: the same version, an older one, or only a pre-release.
  const AppUpdateResult.upToDate(DateTime checkedAt, {String? releaseUrl, bool runningPreRelease = false})
    : this._(AppUpdateOutcome.upToDate, checkedAt, releaseUrl: releaseUrl, runningPreRelease: runningPreRelease);

  const AppUpdateResult.newer(DateTime checkedAt, {required String latest, String? releaseUrl})
    : this._(AppUpdateOutcome.newer, checkedAt, latest: latest, releaseUrl: releaseUrl);

  const AppUpdateResult.failed(DateTime checkedAt, AppUpdateFailure failure)
    : this._(AppUpdateOutcome.failed, checkedAt, failure: failure);

  final AppUpdateOutcome outcome;
  final DateTime checkedAt;

  /// The newer release's version without its `v`, for [AppUpdateOutcome.newer].
  final String? latest;

  /// The latest release's page on GitHub, when the answer named one on github.com.
  final String? releaseUrl;

  final AppUpdateFailure? failure;

  /// The running build is itself a pre-release. `releases/latest` never lists one, so "up to date" can only mean that no
  /// newer stable release exists, not that nothing newer does.
  final bool runningPreRelease;
}

/// A version of the form `1.2.3`, with an optional `-pre-release` and `+build`, and an optional leading `v`.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.preRelease});

  final int major;
  final int minor;
  final int patch;

  /// The part after the `-`, such as `beta.1`, or null for a release.
  final String? preRelease;

  static final RegExp _shape = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');

  /// [text] as a version, or null when it is not one.
  static AppVersion? tryParse(String text) {
    final match = _shape.firstMatch(text.trim());
    if (match == null) return null;
    final numbers = [for (var i = 1; i <= 3; i++) int.tryParse(match.group(i)!)];
    if (numbers.contains(null)) return null;
    return AppVersion(numbers[0]!, numbers[1]!, numbers[2]!, preRelease: match.group(4));
  }

  /// The numbers decide; for the same numbers a pre-release comes before the release. Two pre-releases of the same
  /// numbers compare equal, since the check only ever weighs a stable release against the running app.
  @override
  int compareTo(AppVersion other) {
    final byNumbers = switch ((major.compareTo(other.major), minor.compareTo(other.minor), patch.compareTo(other.patch))) {
      (final a, _, _) when a != 0 => a,
      (_, final b, _) when b != 0 => b,
      (_, _, final c) => c,
    };
    if (byNumbers != 0) return byNumbers;
    if ((preRelease == null) == (other.preRelease == null)) return 0;
    return preRelease == null ? 1 : -1;
  }

  /// The numbers alone, as the About page words a newer version.
  String get core => '$major.$minor.$patch';
}

/// Asks GitHub for the latest release of the app. Never throws: every failure is an [AppUpdateResult.failed].
class AppUpdateService {
  AppUpdateService({HttpTransport? transport, DateTime Function()? now, String? currentVersion, Duration? timeout})
    : _transport = transport,
      _now = now ?? DateTime.now,
      _current = currentVersion ?? AppConstants.appVersion,
      _timeout = timeout ?? const Duration(seconds: 15);

  final HttpTransport? _transport;
  final DateTime Function() _now;
  final String _current;

  /// Over the whole request, which is a few kilobytes: nothing like the transfer a download's stall timeout allows
  /// for.
  final Duration _timeout;

  /// The `releases/latest` endpoint of [AppConstants.repositoryUrl]. GitHub leaves drafts and pre-releases out of it.
  static final Uri latestReleaseUrl = Uri.parse(
    '${AppConstants.repositoryUrl.replaceFirst('https://github.com/', 'https://api.github.com/repos/')}/releases/latest',
  );

  Future<AppUpdateResult> check() async {
    final transport = _transport ?? PackageHttpTransport();
    try {
      final result = await _ask(transport);
      _log.info(
        'checked',
        fields: {
          'outcome': switch (result.outcome) {
            AppUpdateOutcome.upToDate => 'up_to_date',
            AppUpdateOutcome.newer => 'newer',
            AppUpdateOutcome.failed => 'failed',
          },
          'current': _current,
          if (result.latest != null) 'latest': result.latest,
          if (result.failure != null) 'reason': result.failure!.reason,
        },
      );
      return result;
    } finally {
      if (_transport == null) transport.close();
    }
  }

  Future<AppUpdateResult> _ask(HttpTransport transport) async {
    final HttpResponse response;
    try {
      response = await transport.get(
        latestReleaseUrl,
        headers: {'User-Agent': AppConstants.httpUserAgent, 'Accept': 'application/vnd.github+json'},
        timeout: _timeout,
      );
    } catch (error) {
      _log.error('request failed', error: error, fields: {'url': '$latestReleaseUrl'});
      return AppUpdateResult.failed(_now(), AppUpdateFailure.offline);
    }

    if (!response.isSuccess) {
      final failure = switch (response.statusCode) {
        403 || 429 => AppUpdateFailure.rateLimited,
        404 => AppUpdateFailure.noRelease,
        _ => AppUpdateFailure.unreadable,
      };
      _log.error(
        'github refused the request',
        fields: {'url': '$latestReleaseUrl', 'status': response.statusCode, 'reason': failure.reason},
      );
      return AppUpdateResult.failed(_now(), failure);
    }
    return _read(response);
  }

  AppUpdateResult _read(HttpResponse response) {
    final body = response.body;
    // The head of the body, not the body: enough to tell an interstitial from a changed shape (`docs/logging.md` §6).
    // Whitespace is collapsed first: a page's newlines would otherwise split the record over several lines.
    final flat = body.replaceAll(RegExp(r'\s+'), ' ');
    final answer = {
      'url': '$latestReleaseUrl',
      'status': response.statusCode,
      'bytes': body.length,
      'head': flat.length > 120 ? flat.substring(0, 120) : flat,
    };
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException catch (error) {
      _log.error('answer was not JSON', error: error, fields: answer);
      return AppUpdateResult.failed(_now(), AppUpdateFailure.unreadable);
    }
    if (json is! Map) {
      _log.error('answer was not a release', fields: answer);
      return AppUpdateResult.failed(_now(), AppUpdateFailure.unreadable);
    }

    final tag = json['tag_name'];
    final latest = tag is String ? AppVersion.tryParse(tag) : null;
    final current = AppVersion.tryParse(_current);
    if (latest == null || current == null) {
      _log.error(
        'tag is not a version',
        fields: {
          'url': '$latestReleaseUrl',
          'status': response.statusCode,
          'tag': tag is String ? tag : null,
          'current': _current,
        },
      );
      return AppUpdateResult.failed(_now(), AppUpdateFailure.unreadable);
    }

    final page = _githubPage(json['html_url']);
    final stable = json['draft'] != true && json['prerelease'] != true && latest.preRelease == null;
    if (stable && latest.compareTo(current) > 0) {
      return AppUpdateResult.newer(_now(), latest: latest.core, releaseUrl: page);
    }
    return AppUpdateResult.upToDate(_now(), releaseUrl: page, runningPreRelease: current.preRelease != null);
  }

  /// [value] when it is an https page on github.com, otherwise null: the link is opened in the user's browser, so it is
  /// only taken from the answer when it points where a release page does.
  static String? _githubPage(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' || uri.userInfo.isNotEmpty) return null;
    return value;
  }
}
