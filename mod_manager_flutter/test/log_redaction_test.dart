import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/log/log_redaction.dart';

/// The one guarantee a log file has to keep.
///
/// Everything here is a line the app really produces — an app-data path, a
/// library path, an exception Dart stringified with the offending file baked in.
/// The redactor sees only the finished line, which is the whole design: there is
/// no arrangement of well-behaved call sites that would do this instead.
void main() {
  LogRedactor linux({String user = 'ralkey'}) =>
      LogRedactor(home: '/home/$user', username: user);

  LogRedactor windows({String user = 'ralkey'}) => LogRedactor(
        home: 'C:\\Users\\$user',
        username: user,
        caseInsensitive: true,
      );

  group('the home directory', () {
    test('collapses to ~ wherever it appears', () {
      expect(
        linux()('opened /home/ralkey/.local/share/zzz-mod-manager/logs'),
        'opened ~/.local/share/zzz-mod-manager/logs',
      );
    });

    test('is caught in a Windows path written either way', () {
      // Dart hands back `C:\Users\x` from the environment and `C:/Users/x` out
      // of anything that has been through `path.join` on a posix-ish string.
      expect(windows()(r'appdata C:\Users\ralkey\AppData\Roaming\zzz'),
          r'appdata ~\AppData\Roaming\zzz');
      expect(windows()('appdata C:/Users/ralkey/AppData/Roaming/zzz'),
          'appdata ~/AppData/Roaming/zzz');
    });

    test('is caught regardless of case on Windows', () {
      expect(windows()(r'c:\users\RALKEY\AppData'), r'~\AppData');
    });

    test('is censored on Linux even shouted, by the generic rule', () {
      // The home pattern itself is case-sensitive on Linux, where the
      // filesystem is — but the user-directory rule below it is not, and it
      // catches this anyway. Censoring a path that is merely *shaped* like a
      // home directory costs nothing; missing a real one costs the guarantee.
      expect(linux()('/HOME/RALKEY/mods'), '~/mods');
    });
  });

  group('an exception that baked the path into its own message', () {
    test('is censored, because the line is what is censored', () {
      // The case that makes call-site censoring impossible: nothing was
      // interpolated by us at all.
      const line = 'ERROR metadata  could not write\n'
          '    FileSystemException: Cannot open file, path = '
          "'/home/ralkey/XXMI Launcher/ZZMI/_Mods/Ellen/metadata.json' "
          '(OS Error: Permission denied, errno = 13)';

      final out = linux()(line);

      expect(out, isNot(contains('ralkey')));
      expect(out, contains('~/XXMI Launcher/ZZMI/_Mods/Ellen/metadata.json'));
      expect(out, contains('errno = 13'), reason: 'the rest survives intact');
    });
  });

  group('any account, not just this one', () {
    test('another user\'s home is not ours to disclose either', () {
      expect(linux()('copied from /home/someone-else/mods/Ellen'),
          'copied from ~/mods/Ellen');
    });

    test('the macOS shape is covered too, though we do not ship there', () {
      // A log can be pasted from anywhere; the rule costs nothing.
      expect(linux()('/Users/jane/Library/thing'), '~/Library/thing');
    });

    test('a Windows user directory is caught with no home set at all', () {
      final blind = LogRedactor();
      expect(blind(r'D:\Users\admin\stuff'), r'~\stuff');
    });
  });

  group('the bare account name', () {
    test('is replaced when it stands alone', () {
      expect(linux()('running as ralkey'), 'running as <user>');
    });

    test('is left inside a longer word', () {
      // `ralkeyson` is not the account, and mangling it would corrupt a mod
      // name for no privacy gain.
      expect(linux()('mod "ralkeyson edit" installed'),
          'mod "ralkeyson edit" installed');
    });

    test('is replaced next to punctuation a name can contain', () {
      expect(linux()('user=ralkey, home=/home/ralkey'),
          'user=<user>, home=~');
    });

    test('survives a name with a dot in it', () {
      final dotted = LogRedactor(home: '/home/jan.k', username: 'jan.k');
      expect(dotted('owner jan.k here'), 'owner <user> here');
      expect(dotted('owner jan.klaassen here'), 'owner jan.klaassen here',
          reason: 'a longer name that merely starts the same is not the user');
    });
  });

  group('a name too short to substitute', () {
    test('is left alone rather than shredding the file', () {
      // An account called "pi" appears inside "copying", "pinned", "pipe".
      // Replacing all of them would destroy the log to protect two characters.
      final short = LogRedactor(home: '/home/pi', username: 'pi');

      expect(short.censorsUsernameToken, isFalse);
      expect(short('copying pinned pipe'), 'copying pinned pipe');
    });

    test('still gets its paths censored', () {
      final short = LogRedactor(home: '/home/pi', username: 'pi');
      expect(short('/home/pi/.local/share/x'), '~/.local/share/x');
    });
  });

  test('a line with nothing to hide is returned unchanged', () {
    expect(
      linux()('14:02:11 WARN  gamebanana  empty body status=200 bytes=0'),
      '14:02:11 WARN  gamebanana  empty body status=200 bytes=0',
    );
  });

  test('knowing no user at all still censors user directories', () {
    // `PathHelper` throws when `HOME` is unset, so "we could not work out who
    // this is" is a state that happens — and it must fail towards censoring,
    // not towards publishing every path in the file.
    expect(LogRedactor.pathsOnly('/home/ralkey/x'), '~/x');
    expect(LogRedactor.pathsOnly.censorsUsernameToken, isFalse);
  });
}
