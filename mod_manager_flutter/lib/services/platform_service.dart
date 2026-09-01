import '../utils/process_probe.dart';
import 'log/system_report.dart';

/// What became of an attempt to send F10 to the game.
///
/// A `bool` cannot carry this. "The game is not running" and "the tool that
/// sends keystrokes is not installed" need different words on screen and
/// different actions from the user, and neither is the same as a key that was
/// delivered to a window that ignored it.
enum F10Outcome {
  /// A real key event was delivered to a located game window.
  ///
  /// **This is the strongest claim the app can make.** Whether 3DMigoto then
  /// reloaded anything is not observable from outside the game: with
  /// `hunting = 0` and `show_warnings = 0` — the shipped ZZMI defaults — a
  /// reload writes nothing and prints nothing. So nothing may report that mods
  /// *were* reloaded.
  sent,

  /// No game window exists, which is the ordinary answer when the game is not
  /// running.
  gameNotFound,

  /// The tool needed to find the window and press the key is not installed.
  toolMissing,

  /// A game window was found, and the key still did not reach it.
  sendFailed,
}

class F10Result {
  const F10Result.sent(this.tool) : outcome = F10Outcome.sent;
  const F10Result.gameNotFound()
      : outcome = F10Outcome.gameNotFound,
        tool = null;
  const F10Result.toolMissing(this.tool) : outcome = F10Outcome.toolMissing;
  const F10Result.sendFailed(this.tool) : outcome = F10Outcome.sendFailed;

  final F10Outcome outcome;

  /// The tool this outcome is about: the one that delivered the key, the one
  /// that is missing, or the one whose send failed.
  final String? tool;

  bool get sent => outcome == F10Outcome.sent;
}

/// Абстрактний клас для платформно-специфічних операцій
abstract class PlatformService {
  /// Presses F10 in the game's own window so 3DMigoto reloads its mods.
  ///
  /// **F10 is only ever sent to a window that was found first.** Sending it
  /// blind — to whatever holds focus — reaches the mod manager instead, since
  /// the mod manager is what the user just clicked in; and a blind send cannot
  /// fail, so it can only ever be reported as success. That combination is why
  /// this returns [F10Result] rather than a bool.
  Future<F10Result> sendF10ToGame();
  
  /// Створює symbolic link або його аналог (junction на Windows)
  Future<bool> createModLink(String sourcePath, String linkPath);
  
  /// Видаляє symbolic link або його аналог
  Future<bool> removeModLink(String linkPath);
  
  /// Перевіряє чи є шлях symbolic link
  Future<bool> isModLink(String linkPath);
  
  /// Отримує шлях до директорії даних додатку
  String getAppDataPath();
  
  /// Показує інструкції по налаштуванню для конкретної платформи
  void showSetupInstructions();
  
  /// Перевіряє наявність необхідних інструментів/залежностей
  Future<bool> checkDependencies();
  
  /// Знаходить процеси гри
  Future<List<String>> findGameProcesses();
  
  /// Визначає тип дисплейного сервера (для Linux)
  String getDisplayServerType() => 'unknown';
  
  /// Відкриває URL у зовнішньому браузері
  Future<bool> openUrlInBrowser(String url);
  
  /// Отримує шлях до системної Downloads директорії користувача
  String? getSystemDownloadsPath();

  /// Відкриває вказану папку у файловому менеджері системи
  Future<bool> openFolderInFileManager(String folderPath);

  /// Reads rich-text HTML from the system clipboard, or null when the
  /// clipboard holds no HTML (or the platform tool needed to read it is
  /// unavailable). Used to paste formatted text as markdown.
  Future<String?> getClipboardHtml();

  /// Filenames to look for when hunting a **bundled** 7-Zip beside the app's
  /// own executable, most preferred first.
  ///
  /// A bundled copy is how the portable builds — the Linux tarball and the
  /// Windows installer — guarantee an extractor without a package manager. The
  /// AUR package does not need one: it declares `7zip` and lets pacman keep it
  /// current, which vendoring would undo.
  List<String> get bundledSevenZipNames;

  /// The account name this app is running as, or null when the environment
  /// does not say.
  ///
  /// **For censoring it out of the log, and nothing else.** Reading the
  /// environment only — no process is spawned — because this is asked during
  /// logger bootstrap, before the Flutter binding exists, and must not be able
  /// to block or throw. It must never be *logged*; see `docs/logging.md`.
  String? get osUserName;

  /// Everything the log header reports about this machine that costs a process
  /// or a file read.
  ///
  /// **One method returning one struct, rather than a getter per fact.** The two
  /// platforms differ in *which questions exist*: there is no distro on Windows,
  /// no display server, and no xdotool — F10 goes through win32. A pile of
  /// nullable getters would push "is this meaningful here?" back to the caller
  /// and invite a `Platform.isWindows` at the call site, which is the rule this
  /// exists to protect.
  ///
  /// Never throws, and every probe is bounded: a header is a nice-to-have and
  /// must not be able to delay or break a launch.
  Future<SystemReport> describeSystem({ProcessProbe probe});

  /// The user's home directory, or null when the environment does not say.
  ///
  /// Same purpose and the same constraint as [osUserName]: every app-owned path
  /// begins with this, so it is what turns `/home/someone/.local/share/…` into
  /// `~/.local/share/…` on the way to a log line.
  String? get homeDirectoryPath;
}
