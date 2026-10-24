import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/core/constants.dart';
import 'package:mod_manager_flutter/services/app_update_service.dart';
import 'package:mod_manager_flutter/services/log/log_sinks.dart';
import 'package:mod_manager_flutter/services/log/logger.dart';

import 'support/fake_http_transport.dart';

/// The update check against GitHub's `releases/latest`, from a response captured from the real repository.
void main() {
  final latest = File('test/fixtures/github/latest_release.json').readAsStringSync();
  final notFound = File('test/fixtures/github/release_not_found.json').readAsStringSync();
  final clock = DateTime(2026, 10, 24, 12);

  late FakeHttpTransport transport;

  setUp(() => transport = FakeHttpTransport());

  AppUpdateService service({String current = '2.2.2'}) =>
      AppUpdateService(transport: transport, now: () => clock, currentVersion: current);

  group('the request', () {
    test('goes to the repository\'s latest release with the app\'s own User-Agent', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      await service().check();

      expect(transport.requests.single.toString(),
          'https://api.github.com/repos/RalkeyOfficial/zzz-mod-manager/releases/latest');
      expect(transport.sentHeaders.single['User-Agent'], AppConstants.httpUserAgent);
    });

    test('asks for GitHub\'s JSON, with a 15 second timeout over the whole request', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      await service().check();

      expect(transport.sentHeaders.single['Accept'], 'application/vnd.github+json');
      expect(transport.sentTimeouts.single, const Duration(seconds: 15));
    });

    test('each check is one request', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      await service().check();
      await service().check();

      expect(transport.callCount, 2);
    });
  });

  group('comparing the tag with the running version', () {
    test('the same version is up to date, and keeps the release page for Release notes', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      final result = await service(current: '2.2.2').check();

      expect(result.outcome, AppUpdateOutcome.upToDate);
      expect(result.checkedAt, clock);
      expect(result.releaseUrl, 'https://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2');
    });

    test('an older release is not an update', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      expect((await service(current: '3.0.0').check()).outcome, AppUpdateOutcome.upToDate);
    });

    test('a newer release names its version without the v, and its page', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      final result = await service(current: '2.2.1').check();

      expect(result.outcome, AppUpdateOutcome.newer);
      expect(result.latest, '2.2.2');
      expect(result.releaseUrl, 'https://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2');
    });

    test('compares numbers, not text: 2.10.0 is newer than 2.9.0', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"v2.10.0"'));

      expect((await service(current: '2.9.0').check()).outcome, AppUpdateOutcome.newer);
    });

    test('a release flagged as a pre-release is ignored', () async {
      transport.stub(
        AppUpdateService.latestReleaseUrl,
        body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"v3.0.0"').replaceFirst('"prerelease":false', '"prerelease":true'),
      );

      expect((await service().check()).outcome, AppUpdateOutcome.upToDate);
    });

    test('a draft is ignored', () async {
      transport.stub(
        AppUpdateService.latestReleaseUrl,
        body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"v3.0.0"').replaceFirst('"draft":false', '"draft":true'),
      );

      expect((await service().check()).outcome, AppUpdateOutcome.upToDate);
    });

    test('a pre-release tag is ignored even when the flag says stable', () async {
      transport.stub(
        AppUpdateService.latestReleaseUrl,
        body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"v3.0.0-beta.1"'),
      );

      expect((await service().check()).outcome, AppUpdateOutcome.upToDate);
    });

    test('a tag without a v still reads', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"2.3.0"'));

      expect((await service().check()).latest, '2.3.0');
    });

    test('a tag that is not a version is unreadable rather than an exception', () async {
      transport.stub(
        AppUpdateService.latestReleaseUrl,
        body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"nightly"'),
      );

      final result = await service().check();

      expect(result.outcome, AppUpdateOutcome.failed);
      expect(result.failure, AppUpdateFailure.unreadable);
    });

    test('a release page that is not on github.com is not offered', () async {
      transport.stub(
        AppUpdateService.latestReleaseUrl,
        body: latest.replaceFirst(
          '"html_url":"https://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2"',
          '"html_url":"https://example.com/phish"',
        ),
      );

      expect((await service().check()).releaseUrl, isNull);
    });

    for (final untrusted in [
      'http://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2',
      'https://github.com.evil.test/x',
      'https://github.com@evil.test/x',
      'https://evil.test@github.com/x',
    ]) {
      test('a release page of $untrusted is not offered', () async {
        transport.stub(
          AppUpdateService.latestReleaseUrl,
          body: latest.replaceFirst(
            '"html_url":"https://github.com/RalkeyOfficial/zzz-mod-manager/releases/tag/v2.2.2"',
            '"html_url":"$untrusted"',
          ),
        );

        expect((await service().check()).releaseUrl, isNull);
      });
    }

    test('a stable build is not marked as a pre-release, and a pre-release build is', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      expect((await service(current: '2.2.2').check()).runningPreRelease, isFalse);
      expect((await service(current: '3.0.0-beta.1').check()).runningPreRelease, isTrue);
    });

    test('a pre-release build is offered the stable release of its own numbers, and nothing older', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

      expect((await service(current: '3.0.0-beta.1').check()).outcome, AppUpdateOutcome.upToDate);
      expect((await service(current: '2.2.2-beta.1').check()).outcome, AppUpdateOutcome.newer);
      expect((await service(current: '2.2.1-beta.1').check()).outcome, AppUpdateOutcome.newer);
    });

    test('a tag that is not major.minor.patch is unreadable, such as v3', () async {
      transport.enqueue(AppUpdateService.latestReleaseUrl, body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"v3"'));
      transport.enqueue(AppUpdateService.latestReleaseUrl, body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"3.0"'));

      expect((await service().check()).failure, AppUpdateFailure.unreadable);
      expect((await service().check()).failure, AppUpdateFailure.unreadable);
    });
  });

  group('what the log says about a check that fails', () {
    late MemoryLogSink log;

    setUp(() {
      log = MemoryLogSink();
      Log.install(LogRouter(sinks: [log]));
      addTearDown(() => Log.install(LogRouter()));
    });

    Iterable<String> errors() => log.lines.where((line) => line.contains(' ERROR ') && line.contains('update.app'));

    test('every non-2xx answer logs its status as an error, so 403 and 429 and 500 and 301 differ', () async {
      for (final status in [301, 403, 404, 429, 500, 502]) {
        transport.enqueue(AppUpdateService.latestReleaseUrl, statusCode: status, body: 'x');
        await service().check();
      }

      final lines = errors().toList();
      expect(lines, hasLength(6));
      for (final (index, status) in [301, 403, 404, 429, 500, 502].indexed) {
        expect(lines[index], contains('status=$status'));
        expect(lines[index], contains('/releases/latest'));
      }
      expect(lines[1], contains('reason=rate_limited'));
      expect(lines[2], contains('reason=no_release'));
      expect(lines[4], contains('reason=unreadable'));
    });

    test('a body that is not JSON logs its status, length and first 120 characters', () async {
      final body = '<html>${'x' * 300}</html>';
      transport.stub(AppUpdateService.latestReleaseUrl, body: body);

      await service().check();

      final line = errors().single;
      expect(line, contains('answer was not JSON'));
      expect(line, contains('status=200'));
      expect(line, contains('bytes=${body.length}'));
      expect(line, contains('head=${body.substring(0, 120)}'));
      expect(line, isNot(contains(body.substring(0, 121))));
    });

    test('a page with newlines still logs as one line, with its whitespace collapsed', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: '<html>\n  <head>\r\n\t<title>Just a moment</title>\n</html>');

      await service().check();

      final line = errors().single;
      // The record's first line holds all of the head; the exception goes on its own line below it, as for every record.
      expect(line.split('\n').first, contains('head="<html> <head> <title>Just a moment</title> </html>"'));
    });

    test('an answer that is not a release logs its url, status and head', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: '[1]');

      await service().check();

      final line = errors().single;
      expect(line, contains('answer was not a release'));
      expect(line, contains('/releases/latest'));
      expect(line, contains('status=200'));
      expect(line, contains('head=[1]'));
    });

    test('a tag that is not a version logs its url, status and tag', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest.replaceFirst('"tag_name":"v2.2.2"', '"tag_name":"nightly"'));

      await service().check();

      final line = errors().single;
      expect(line, contains('tag is not a version'));
      expect(line, contains('/releases/latest'));
      expect(line, contains('status=200'));
      expect(line, contains('tag=nightly'));
    });

    test('the summary line names the outcome and the reason in snake_case', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: latest);
      await service().check();
      final limited = FakeHttpTransport()..enqueue(AppUpdateService.latestReleaseUrl, statusCode: 429);
      await AppUpdateService(transport: limited, now: () => clock).check();

      final checked = log.lines.where((line) => line.contains('checked')).toList();
      expect(checked.first, contains('outcome=up_to_date'));
      expect(checked.last, contains('outcome=failed'));
      expect(checked.last, contains('reason=rate_limited'));
    });

    test('a request that never got an answer logs the url', () async {
      transport.enqueueError(AppUpdateService.latestReleaseUrl, TimeoutException('slow'));

      await service().check();

      expect(errors().single, contains('request failed'));
      expect(errors().single, contains('/releases/latest'));
    });
  });

  group('when it cannot find out', () {
    test('no connection, a timeout or a TLS failure is offline', () async {
      transport.enqueueError(AppUpdateService.latestReleaseUrl, TimeoutException('slow'));

      final result = await service().check();

      expect(result.outcome, AppUpdateOutcome.failed);
      expect(result.failure, AppUpdateFailure.offline);
      expect(result.checkedAt, clock);
    });

    test('a repository with no release answers 404', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, body: notFound, statusCode: 404);

      expect((await service().check()).failure, AppUpdateFailure.noRelease);
    });

    test('GitHub limiting the address answers 403 or 429', () async {
      transport.enqueue(AppUpdateService.latestReleaseUrl, statusCode: 403, body: '{"message":"API rate limit exceeded"}');
      transport.enqueue(AppUpdateService.latestReleaseUrl, statusCode: 429, body: '');

      expect((await service().check()).failure, AppUpdateFailure.rateLimited);
      expect((await service().check()).failure, AppUpdateFailure.rateLimited);
    });

    test('any other status is unreadable', () async {
      transport.stub(AppUpdateService.latestReleaseUrl, statusCode: 500, body: 'oops');

      expect((await service().check()).failure, AppUpdateFailure.unreadable);
    });

    test('an empty 200 and a body that is not a release are unreadable', () async {
      transport.enqueue(AppUpdateService.latestReleaseUrl, body: '');
      transport.enqueue(AppUpdateService.latestReleaseUrl, body: '[]');
      transport.enqueue(AppUpdateService.latestReleaseUrl, body: '{}');

      for (var i = 0; i < 3; i++) {
        expect((await service().check()).failure, AppUpdateFailure.unreadable, reason: 'answer ${i + 1}');
      }
    });
  });

  group('versions', () {
    test('parse with or without a v, a pre-release and build metadata', () {
      expect(AppVersion.tryParse('v1.2.3')?.core, '1.2.3');
      expect(AppVersion.tryParse('1.2.3-rc.1+abc')?.preRelease, 'rc.1');
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse(''), isNull);
    });

    test('a pre-release comes before its release', () {
      expect(AppVersion.tryParse('3.0.0-rc.1')!.compareTo(AppVersion.tryParse('3.0.0')!), isNegative);
      expect(AppVersion.tryParse('3.0.0')!.compareTo(AppVersion.tryParse('2.99.99')!), isPositive);
    });
  });

  test('the app\'s own version parses, so the check can compare it', () async {
    transport.stub(AppUpdateService.latestReleaseUrl, body: latest);

    // Built the way the app builds it, with no version of its own.
    final result = await AppUpdateService(transport: transport, now: () => clock).check();

    expect(result.outcome, isNot(AppUpdateOutcome.failed));
  });
}
