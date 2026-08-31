/// Taking the person out of the log.
///
/// A log is written to be handed to somebody else, so the account name of the
/// machine it came from has no business in it. That name is not sprinkled about
/// by careless call sites — it is structural: **every** app-owned path contains
/// it (`~/.local/share/…`, `C:\Users\…\AppData\…`), and Dart bakes the offending
/// path into `FileSystemException.toString()`, so a call site that passes only an
/// exception still leaks it.
///
/// **Which is why this runs on the rendered line, not on the arguments.** There
/// is no set of well-behaved call sites that achieves the same thing; there is
/// only one function, applied by the router to every line on its way to every
/// sink (`logger.dart`). A call site must therefore **never** pre-censor: doing
/// so would hide the real path from the one place that knows how to shorten it,
/// and would rot the moment a new sink is added.
///
/// ## What it promises, and what it does not
///
/// It promises that the **home directory, the standard user-directory shapes,
/// and the current account name** do not appear. It does not promise that
/// nothing identifying survives: a mod folder a user named after themselves, a
/// GameBanana display name, a drive label on a second disk are all still there.
/// Anyone publishing a log should still read it. Saying so is better than
/// implying a guarantee this cannot make.
///
/// Pure, and constructed with explicit values so the awkward cases are testable
/// without an environment to arrange.
library;

/// Where a real path is cut off and `~` begins, for each platform's convention.
///
/// Matched for **any** account name rather than only the current one: a log can
/// carry a path from a second account, a service account, or another machine
/// entirely (a config copied between computers), and none of those is ours to
/// disclose either.
final RegExp _userDirectories = RegExp(
  r'(?:/home/|/Users/|[A-Za-z]:[\\/]Users[\\/])([^/\\\s"]+)',
  caseSensitive: false,
);

class LogRedactor {
  LogRedactor({
    this.home,
    this.username,
    this.caseInsensitive = false,
  });

  /// Knows no home and no account name, and still censors the standard
  /// user-directory shapes — [_userDirectories] does not depend on either.
  ///
  /// **That is the right default when the environment is unreadable**, which is
  /// a real state: `PathHelper` throws when `HOME` is unset. A redactor that
  /// gave up entirely because it could not identify *this* user would publish
  /// every path in the file.
  static final LogRedactor pathsOnly = LogRedactor();

  /// The user's home directory, replaced by `~` wherever it appears.
  final String? home;

  /// The account name, replaced by `<user>` where it appears **on its own**.
  final String? username;

  /// Windows paths and account names do not distinguish case; Linux ones do.
  final bool caseInsensitive;

  /// Below this a name is too short to substitute safely.
  ///
  /// A one- or two-character account name ("a", "pi", "vm") appears inside
  /// ordinary words hundreds of times in any log, and replacing all of them
  /// would destroy the file to protect a name that is barely identifying. The
  /// path rules still apply, and [censorsUsernameToken] is false so the header
  /// can say plainly that the bare name was left in.
  static const int minimumTokenLength = 3;

  bool get censorsUsernameToken =>
      (username?.length ?? 0) >= minimumTokenLength;

  late final RegExp? _homePattern = _patternFor(home);
  late final RegExp? _usernamePattern = username == null
      ? null
      : !censorsUsernameToken
          ? null
          // Not `\b`: an account name may contain a dot or a dash, and `\b`
          // would match inside `ralkey.old` and leave a stray fragment behind.
          : RegExp(
              '(?<![A-Za-z0-9_])${RegExp.escape(username!)}(?![A-Za-z0-9_])',
              caseSensitive: !caseInsensitive,
            );

  RegExp? _patternFor(String? path) {
    if (path == null || path.isEmpty) return null;
    // Either separator, whichever the path was written with: a Windows home
    // reaches us as `C:\Users\x` but appears in Dart output as `C:/Users/x` too.
    final either = RegExp.escape(path).replaceAll(RegExp(r'\\\\|/'), r'[\\/]');
    return RegExp(either, caseSensitive: !caseInsensitive);
  }

  /// The line with everything above applied, in order: the home directory first
  /// so it collapses to `~` rather than being partially replaced by the
  /// account-name rule, then the generic user directories, then the bare name.
  String call(String line) {
    var out = line;
    final homePattern = _homePattern;
    if (homePattern != null) out = out.replaceAll(homePattern, '~');
    // The match stops before the next separator, so the rest of the path
    // survives: `/home/x/mods` becomes `~/mods`, and a reader can still tell an
    // app-data path from a library one.
    out = out.replaceAll(_userDirectories, '~');
    final namePattern = _usernamePattern;
    if (namePattern != null) out = out.replaceAll(namePattern, '<user>');
    return out;
  }
}
