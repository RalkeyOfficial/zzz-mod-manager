import 'dart:io';
import 'log/logger.dart';
import 'platform_service.dart';
import 'platform_service_linux.dart';
import 'platform_service_windows.dart';

/// Factory для створення платформно-специфічного сервісу
class PlatformServiceFactory {
  static PlatformService? _instance;
  
  /// Отримати singleton instance платформного сервісу
  static PlatformService getInstance() {
    _instance ??= _createService();
    return _instance!;
  }
  
  /// Створити новий instance (для тестування)
  static PlatformService createNew() {
    return _createService();
  }
  
  /// Скинути singleton (для тестування)
  static void reset() {
    _instance = null;
  }
  
  static PlatformService _createService() {
    if (Platform.isWindows) {
      Logger('platform').debug('service created', fields: {'os': 'windows'});
      return WindowsPlatformService();
    } else if (Platform.isLinux) {
      Logger('platform').debug('service created', fields: {'os': 'linux'});
      return LinuxPlatformService();
    } else if (Platform.isMacOS) {
      throw UnsupportedError('MacOS is not supported yet. Please contribute!');
    } else {
      throw UnsupportedError('Platform ${Platform.operatingSystem} is not supported');
    }
  }
}
