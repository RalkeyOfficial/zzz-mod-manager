import 'dart:io';

/// Points `Directory.systemTemp` at [directory], so what an unpack leaves in the temp folder can be seen apart from
/// other tests' work. Set as `IOOverrides.global`, and set back to null in a tear-down.
final class SystemTempIn extends IOOverrides {
  SystemTempIn(this.directory);

  final Directory directory;

  @override
  Directory getSystemTempDirectory() => directory;
}
