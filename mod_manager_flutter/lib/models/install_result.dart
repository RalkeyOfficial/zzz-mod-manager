/// The outcome of installing an archive into the mod library.
///
/// Four outcomes, not two, because "nothing was installed" is not automatically
/// a failure: the user may have cancelled the folder-selection dialog, or every
/// folder in the archive may already exist. Those deserve different words —
/// silence, a note, and an error respectively.
///
/// Lives here rather than inside a screen because both ingest entry points
/// produce one and both need to render it identically.
class InstallResult {
  const InstallResult._({required this.mods, this.message, this.errorMessage});

  /// Names of the mods that were created.
  final List<String> mods;

  /// Informational detail — auto-tags applied, mods missing a `.ini`, and so on.
  final String? message;

  /// Set only when the install genuinely failed.
  final String? errorMessage;

  factory InstallResult.success(List<String> mods, {String? message}) =>
      InstallResult._(mods: mods, message: message);

  factory InstallResult.warning(String message) =>
      InstallResult._(mods: const [], message: message);

  factory InstallResult.error(String message) =>
      InstallResult._(mods: const [], errorMessage: message);

  /// No-op result (e.g. the user cancelled the folder-selection dialog):
  /// [when] renders nothing.
  factory InstallResult.cancelled() => const InstallResult._(mods: []);

  void when({
    required void Function(List<String> mods, String? message) success,
    required void Function(String message) warning,
    required void Function(String message) error,
  }) {
    if (errorMessage != null) {
      error(errorMessage!);
      return;
    }

    if (mods.isNotEmpty) {
      success(mods, message);
      return;
    }

    if (message != null) {
      warning(message!);
    }
  }
}
