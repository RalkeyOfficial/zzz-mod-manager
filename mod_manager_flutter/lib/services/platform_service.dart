/// Абстрактний клас для платформно-специфічних операцій
abstract class PlatformService {
  /// Відправляє F10 у вікно гри для перезавантаження модів
  Future<bool> sendF10ToGame();
  
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
}
