/// Constants for the application
class AppConstants {
  // Private constructor to prevent instantiation
  AppConstants._();

  /// The app version, kept in sync with `pubspec.yaml`'s `version:`.
  ///
  /// Single source for everything that has to *say* the version: the badge in
  /// the UI and the `User-Agent` we send to GameBanana. Bumping the release
  /// means updating this alongside `pubspec.yaml` — see CLAUDE.md's checklist.
  static const String appVersion = '2.2.2';

  /// What we identify ourselves as on every outbound request — the JSON client,
  /// the file downloader and the preview-image fetcher alike. One string, so a
  /// version bump can't leave one of them claiming the old release.
  static const String httpUserAgent = 'zzz-mod-manager/$appVersion';

  /// Zenless Zone Zero's game id on GameBanana. Every remote request is scoped
  /// to it: <https://gamebanana.com/games/19567>.
  static const int gameBananaGameId = 19567;

  /// GameBanana's "Character Skins" root category for ZZZ.
  ///
  /// Its ~60 children are effectively the live character roster, which is what
  /// the marketplace's character filter is built from — fetched at runtime
  /// rather than hardcoded, because new characters arrive with every game patch.
  /// Note the local roster in `utils/zzz_characters.dart` carries **no**
  /// GameBanana ids, so it cannot substitute for this list as a filter source.
  static const int gameBananaCharacterSkinsCategoryId = 30305;

  /// The GameBanana source name recorded in a mod's origin block.
  static const String gameBananaSourceName = 'gamebanana';

  // UI Scaling
  static const double minScale = 0.8;
  static const double maxScale = 1.5;
  static const int scaleSteps = 7;

  // UI Dimensions
  static const double tabBarTopPadding = 25;
  static const double tabBarWidth = 300;
  static const double tabBarHeight = 42;
  static const double tabBarBorderWidth = 3;

  // Character Card Dimensions
  static const double characterCardWidth = 50;
  static const double characterCardHeight = 50;
  static const double characterCardBorderWidth = 2;
  static const double characterCardBorderWidthSelected = 3;
  static const double characterCardBorderWidthHover = 4;
  static const double characterCardBlurRadius = 12;
  static const double characterCardSpreadRadiusSelected = 2;
  static const double characterCardSpreadRadiusHover = 3;
  static const double characterCardMarginRight = 12;

  // Mod Card Dimensions
  static const double modCardWidth = 320;

  /// Width to decode mod cover images at, for [modCardWidth]-wide cards.
  ///
  /// 2× the card so it stays sharp on a hi-DPI display, and **far** below what
  /// these files actually are. `ImageCache` is bounded by *decoded* bytes (100 MiB
  /// by default), and a cover is a full screenshot: measured on a real library,
  /// 49 covers came to **213 MB decoded at native size** — over twice the limit,
  /// with single images at 14 MB, so about seven cards could evict everything else.
  ///
  /// That cache is shared with the marketplace's network thumbnails, which is how
  /// this became visible: opening the Mods tab flushed them, and returning to the
  /// marketplace re-downloaded every preview. Decoding at display size instead
  /// takes those same 49 covers to roughly 5 MB.
  static const int modCardDecodeWidth = 640;
  static const double modCardBorderRadius = 12;
  static const double modCardBorderWidthActive = 2;
  static const double modCardBorderWidthInactive = 1;
  static const double modCardBlurRadiusActive = 12;
  static const double modCardBlurRadiusInactive = 8;
  static const double modCardSpreadRadiusActive = 1;
  static const double modCardPadding = 16;
  static const double modCardImageHeight = 280;

  // Drag and Drop
  static const Duration dragDelay = Duration(milliseconds: 500);
  static const double dragFeedbackElevation = 8;
  static const double dragFeedbackOpacity = 0.5;

  // Colors
  static const int primaryColor = 0xFF0EA5E9;
  static const int secondaryColor = 0xFF06B6D4;
  static const int activeModBorderColor = 0xFF6366F1;
  static const int activeModCountColor = 0xFF10B981;

  // Animation Durations
  static const Duration defaultAnimationDuration = Duration(milliseconds: 300);
  static const Duration fastAnimationDuration = Duration(milliseconds: 150);
  static const Duration slowAnimationDuration = Duration(milliseconds: 500);
  static const Duration snackBarDuration = Duration(milliseconds: 800);
  static const Duration imageSavedSnackBarDuration = Duration(seconds: 2);

  // Debounce delays
  static const Duration modToggleDebounceDelay = Duration(milliseconds: 200);
  static const Duration characterSelectionDebounceDelay = Duration(milliseconds: 100);
  static const Duration modeSwitchDebounceDelay = Duration(milliseconds: 100);

  // Layout Spacing
  static const double defaultPadding = 16;
  static const double smallPadding = 8;
  static const double tinyPadding = 4;
  static const double defaultMargin = 12;
  static const double smallMargin = 6;

  // Text Sizes
  static const double headerTextSize = 16;
  static const double titleTextSize = 14;
  static const double bodyTextSize = 13;
  static const double captionTextSize = 12;
  static const double smallCaptionTextSize = 10;

  // File Names
  static const List<String> imageFileNames = [
    'Preview.png',
    'preview.png',
    'thumbnail.png',
    'icon.png',
  ];

  // Paths (note: assetsCharactersPath is relative to Flutter assets bundle)
  static const String assetsCharactersPath = 'assets/characters/';
  static const String assetsIconPath = 'assets/icon.png';
  // Note: For mod_images path, use PathHelper.getModImagesPath() instead
  // of a hardcoded constant, as it needs to work in different environments
  static const String configFileName = 'config.json';

  // Per-mod metadata, stored inside each mod's own folder so it travels with
  // the mod (shareable, rename-safe). Layout: <mod>/.zzz-mod-manager/metadata.json
  // and <mod>/.zzz-mod-manager/images/*
  static const String modMetadataDirName = '.zzz-mod-manager';
  static const String modMetadataFileName = 'metadata.json';
  static const String modMetadataImagesDirName = 'images';

  // Window dimensions
  static const double minWindowWidth = 800;
  static const double minWindowHeight = 500;
  static const double defaultWindowWidth = 1400;
  static const double defaultWindowHeight = 900;
}
