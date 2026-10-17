import '../utils/process_probe.dart';
import 'log/system_report.dart';

/// What happened when the app tried to start the game.
enum LaunchOutcome {
  started,

  /// The chosen file is gone.
  notFound,

  /// This platform cannot start that kind of file, such as a Windows `.exe` on Linux.
  unsupported,

  /// Starting it threw.
  failed,
}

/// Абстрактний клас для платформно-специфічних операцій
///
/// **There is deliberately nothing here for reloading mods in the running
/// game.** Pressing F10 for the user was tried and removed — see
/// [`docs/mod-reload.md`](../../../docs/mod-reload.md) for what was measured and
/// why it loses. Press F10 in the game.
abstract class PlatformService {
  /// Створює symbolic link або його аналог (junction на Windows)
  Future<bool> createModLink(String sourcePath, String linkPath);
  
  /// Видаляє symbolic link або його аналог
  Future<bool> removeModLink(String linkPath);
  
  /// Перевіряє чи є шлях symbolic link
  Future<bool> isModLink(String linkPath);
  
  /// Отримує шлях до директорії даних додатку
  String getAppDataPath();
  
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

  /// Starts [target], the file the Launch game button was pointed at, and returns without waiting for it.
  ///
  /// What counts as startable differs: Linux runs an executable or a `.desktop` shortcut and cannot run a Windows
  /// program directly, Windows starts whatever the shell would on a double-click. See `docs/launch-game.md`.
  Future<LaunchOutcome> launchGame(String target);

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
  /// platforms differ in *which questions exist*: there is no distro and no
  /// display server on Windows, and each platform finds its extractor its own
  /// way. A pile of nullable getters would push "is this meaningful here?" back
  /// to the caller and invite a `Platform.isWindows` at the call site, which is
  /// the rule this exists to protect.
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

  /// Free bytes on the volume holding [forPath], or **null when that cannot be
  /// asked** — the path does not exist, the tool is missing, the call failed.
  ///
  /// Here rather than at the call site because Dart exposes no portable free
  /// space API at all, and the two platforms answer by completely different
  /// means: Linux reads it out of `df`, Windows asks `kernel32` directly.
  ///
  /// **Null is a real answer and means "do not check".** Its one caller refuses
  /// a download that provably will not fit, and a refusal is worse than a
  /// failure when the number behind it is a guess — so an unknown free space
  /// lets the transfer run and fail honestly if it must.
  ///
  /// Never throws, and bounded like every other probe here: a preflight must
  /// not be able to hang the thing it is checking.
  Future<int?> freeSpaceBytes(String forPath, {ProcessProbe probe});
}
