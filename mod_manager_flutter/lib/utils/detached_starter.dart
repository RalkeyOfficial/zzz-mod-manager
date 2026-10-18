import 'dart:io';

/// Starts a program that outlives the app and is never waited on, such as the game's launcher.
///
/// A seam, like `ProcessProbe`: a test passes a recording fake to see the command without starting anything.
/// `ProcessProbe` itself doesn't fit, since it waits for the program and kills it on a timeout.
class DetachedStarter {
  const DetachedStarter();

  /// Returns the started program's process id. Throws a [ProcessException] when [executable] can't be run at all.
  Future<int> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}
