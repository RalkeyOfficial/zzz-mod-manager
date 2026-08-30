import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/screens/components/extract_failure_message.dart';
import 'package:mod_manager_flutter/services/archive_service.dart';

/// What an unpack failure tells the user.
///
/// One of the two reasons is something they can act on, and the wording has to
/// differ for it: a missing 7-Zip means the download is fine and a tool is
/// absent, where the generic message ("extract it by hand") implies the app has
/// done all it can and the archive is the problem.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations en;

  setUpAll(() async {
    en = AppLocalizations(const Locale('en'));
    await en.load();
  });

  const archive = '/home/someone/.local/share/zzz-mod-manager/downloads/mod.rar';

  test('a missing 7-Zip names the tool and says the download is fine', () {
    final lines = extractFailureMessage(en,
        archivePath: archive, reason: ExtractFailure.missingSevenZip);

    expect(lines.title, contains('7-Zip'));
    expect(lines.body, contains('7-Zip'));
    expect(lines.body, contains(archive),
        reason: 'the file is still there and they need to know where');
  });

  test('any other failure keeps the generic wording', () {
    final lines = extractFailureMessage(en,
        archivePath: archive, reason: ExtractFailure.other);

    expect(lines.title, "Couldn't extract the archive");
    expect(lines.body, contains(archive));
    expect(lines.title, isNot(contains('7-Zip')));
  });

  test('the two reasons do not share a message', () {
    // The regression this guards: routing both through one string is what hid
    // the actionable case, and it looks correct at every call site.
    final missing = extractFailureMessage(en,
        archivePath: archive, reason: ExtractFailure.missingSevenZip);
    final other = extractFailureMessage(en,
        archivePath: archive, reason: ExtractFailure.other);

    expect(missing.title, isNot(other.title));
    expect(missing.body, isNot(other.body));
  });

  test('every key it can reach resolves in both locales', () async {
    // `t` renders a missing key as its own dotted path, with no exception.
    final uk = AppLocalizations(const Locale('uk'));
    await uk.load();

    for (final loc in [en, uk]) {
      for (final reason in ExtractFailure.values) {
        final lines =
            extractFailureMessage(loc, archivePath: archive, reason: reason);
        expect(lines.title, isNot(startsWith('marketplace.')), reason: '$reason');
        expect(lines.body, isNot(startsWith('marketplace.')), reason: '$reason');
      }
    }
  });

  test('the reason defaults to the generic one', () {
    // So a caller that has not been updated cannot accidentally claim 7-Zip is
    // missing.
    expect(extractFailureMessage(en, archivePath: archive).title,
        extractFailureMessage(en, archivePath: archive, reason: ExtractFailure.other)
            .title);
  });
}
