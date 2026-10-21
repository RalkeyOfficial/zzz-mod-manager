import 'app_notification.dart';

/// The outcome of installing an archive into the mod library.
///
/// Five outcomes, not two, because "nothing was installed" is not automatically
/// a failure: the user may have cancelled the folder-selection dialog, every
/// folder in the archive may already exist, or the archive may hold no mod
/// folder at all. Those deserve different words — silence, a note and a
/// warning — and only a failure is an error.
///
/// Lives here rather than inside a screen because both ingest entry points
/// produce one and both need to render it identically.
class InstallResult {
  const InstallResult._({
    required this.mods,
    this.warnings = const [],
    this.failure,
    this.failureKind,
    this.characterId,
  });

  /// Names of the mods that were created.
  final List<String> mods;

  /// What the user has to **act on** — a mod with no `.ini`, a download that
  /// turned out to be a patch, a sidecar that could not be written.
  ///
  /// A list rather than one joined string: each of these needs a different
  /// thing doing about it, so each is raised as its own warning beside the
  /// success. Joining them with newlines made one notification that had to be
  /// read to the end to find out how many problems it described.
  ///
  /// Deliberately not a description of what the install did. It used to carry
  /// the auto-tags and the list of metadata fields copied off the mod page, and
  /// that is the app narrating its own bookkeeping at the one moment the user
  /// wants a single fact: the mod arrived.
  final List<NotificationLines> warnings;

  /// The message for an outcome that installed nothing, with [failureKind]
  /// saying whether that is a problem or merely a note.
  final NotificationLines? failure;
  final NotificationKind? failureKind;

  /// The character every folder in this archive was filed under, when the
  /// install knew it. One archive comes from one mod page, so a result naming
  /// five folders still has one character.
  final String? characterId;

  factory InstallResult.success(
    List<String> mods, {
    List<NotificationLines> warnings = const [],
    String? characterId,
  }) =>
      InstallResult._(
        mods: mods,
        warnings: warnings,
        characterId: characterId,
      );

  /// Nothing installed, and nothing went wrong: every folder already exists.
  factory InstallResult.note(String title, String body) => InstallResult._(
        mods: const [],
        failure: NotificationLines(title, body, kind: NotificationKind.note),
        failureKind: NotificationKind.note,
      );

  /// Nothing installed, though nothing failed either: the archive held no mod folder.
  factory InstallResult.warning(String title, String body) => InstallResult._(
        mods: const [],
        failure: NotificationLines(title, body),
        failureKind: NotificationKind.warning,
      );

  /// [actions] are the error card's buttons, such as Open folder where the archive was kept.
  factory InstallResult.error(String title, String body, {List<NotificationAction> actions = const []}) =>
      InstallResult._(
        mods: const [],
        failure: NotificationLines(title, body, kind: NotificationKind.error, actions: actions),
        failureKind: NotificationKind.error,
      );

  /// No-op result (e.g. the user cancelled the folder-selection dialog):
  /// [when] renders nothing.
  factory InstallResult.cancelled() => const InstallResult._(mods: []);

  void when({
    required void Function(
      List<String> mods,
      List<NotificationLines> warnings,
      String? characterId,
    ) success,
    required void Function(NotificationLines lines) failed,
  }) {
    if (failure case final lines?) {
      failed(lines);
      return;
    }

    if (mods.isNotEmpty) {
      success(mods, warnings, characterId);
    }
  }
}
