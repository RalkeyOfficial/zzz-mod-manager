import '../utils/detached_starter.dart';
import '../utils/process_probe.dart';
import 'log/system_report.dart';
import 'wine_runners.dart';

export 'wine_runners.dart' show WineRunner, WineRunnerKind, WineRunnerSource;

/// What happened when the app tried to start the game.
enum LaunchOutcome {
  started,

  /// The launcher file is gone.
  notFound,

  /// This platform cannot start that kind of file, such as a `.desktop` shortcut, which can't take arguments.
  unsupported,

  /// The Wine or Proton that runs the launcher couldn't be started: missing from PATH, or the chosen file is gone.
  runnerMissing,

  /// Proton started without umu-launcher has no prefix to run in: it has no default of its own.
  prefixRequired,

  /// Starting it threw.
  failed,
}

/// The [outcome] of a launch, and for [LaunchOutcome.runnerMissing] the [program] that couldn't be run.
class LaunchResult {
  const LaunchResult(this.outcome, {this.program});

  final LaunchOutcome outcome;
  final String? program;
}

/// What the Launch game button starts and how. See `docs/launch-game.md`.
class LaunchRequest {
  const LaunchRequest({
    required this.executable,
    required this.arguments,
    this.runner = '',
    this.prefix = '',
    this.useUmu = false,
  });

  /// The XXMI Launcher, or the file chosen instead, exactly as stored.
  final String executable;

  /// The arguments as typed: one string, split into words only where the platform needs a list.
  final String arguments;

  /// Linux only: the Wine binary or Proton script, empty for `wine` from PATH.
  final String runner;

  /// Linux only: the Wine prefix, empty for the runner's own default.
  final String prefix;

  /// Linux only: whether a Proton runner starts through umu-launcher rather than directly.
  final bool useUmu;
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

  /// Starts the launcher [request] names, with its arguments, and returns without waiting for it.
  ///
  /// Linux runs an `.exe` under Wine or Proton and an executable script directly; Windows starts what a double-click
  /// would. [starter] is the seam a test records the command through; Windows starts through the shell and ignores
  /// it. See `docs/launch-game.md`.
  Future<LaunchResult> launchGame(LaunchRequest request, {DetachedStarter starter = const DetachedStarter()});

  /// Whether Launch game runs the launcher under Wine or Proton, so Settings shows where to find them.
  bool get launchesThroughWine;

  /// The Wine and Proton builds Settings offers to run the launcher with; empty where [launchesThroughWine] is false.
  Future<List<WineRunner>> findWineRunners();

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
