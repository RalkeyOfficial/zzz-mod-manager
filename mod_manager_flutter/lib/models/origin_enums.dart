/// The two independent axes of a mod's origin, plus how it was unpacked.
///
/// **Confidence and provenance are separate on purpose.** Confidence is how sure
/// we are *which remote file this is*; provenance is *where the folder came
/// from*. They came apart the moment a hand-imported archive could be matched
/// exactly by its checksum: that mod is known precisely despite never having
/// been downloaded by us, so a single enum named after a source would mislabel
/// it in the UI and, worse, in any gate built on it.
///
/// Every parser here is tolerant and **fails safe**, never throwing and never
/// escalating an unrecognised value into a stronger claim.
library;

/// How sure we are which remote file a local mod corresponds to.
enum OriginConfidence {
  /// We know precisely: we downloaded it, or its archive md5 matched the
  /// checksum the remote publishes. The only tier that may ever drive an
  /// unattended destructive path.
  exact('exact'),

  /// The user told us. Trusted, but confirmed actions still get a prompt.
  user('user'),

  /// Guessed from local data — a url parse, a name match, a single unambiguous
  /// remote file. May badge and suggest; every action through it is manual and
  /// labelled a guess, because it ultimately came from a free-form text field a
  /// human typed and could be a wrong paste entirely.
  inferred('inferred'),

  /// "I don't know what I have, I got it around then." Compares against a
  /// baseline date only.
  assumedLatest('assumed_latest'),

  /// Nothing known.
  unknown('unknown');

  const OriginConfidence(this.wire);

  final String wire;

  /// Whether this tier may drive an unattended overwrite. Deliberately a
  /// property of the enum rather than a scattered `== exact` check.
  bool get allowsUnattendedUpdate => this == OriginConfidence.exact;

  /// Whether somebody actually *established* this, as opposed to us guessing.
  ///
  /// The line every "is this a guess?" decision draws, and it is drawn once
  /// here rather than per caller: the update comparator caps its verdict on it,
  /// and the bulk resolution pass asks it to decide which identities still want
  /// a human's confirmation. [inferred] sits on the wrong side of it on purpose
  /// — it came from a free-form text field a human typed and may be a wrong
  /// paste entirely.
  bool get isConfirmed =>
      this == OriginConfidence.exact || this == OriginConfidence.user;

  /// Parses the stored value, **degrading anything unrecognised to [unknown]**.
  ///
  /// Load-bearing, not defensive habit: a future build inventing a stronger
  /// tier must never be read by this build as a claim it can act on. Erring
  /// toward "we don't know" costs a prompt; erring the other way overwrites
  /// somebody's files.
  static OriginConfidence parse(Object? value) {
    if (value is! String) return OriginConfidence.unknown;
    for (final tier in OriginConfidence.values) {
      if (tier.wire == value) return tier;
    }
    return OriginConfidence.unknown;
  }
}

/// Where a mod folder physically came from.
enum OriginProvenance {
  /// We fetched it ourselves, in-app.
  downloaded('downloaded'),

  /// The user supplied an archive and we unpacked it.
  importedArchive('imported_archive'),

  /// The user supplied a folder directly (drag-and-drop of an unpacked mod).
  importedFolder('imported_folder');

  const OriginProvenance(this.wire);

  final String wire;

  /// Whether the bytes reached disk through our own download.
  ///
  /// Note this is *not* the auto-update gate — that is [OriginConfidence].
  /// A hand-imported archive whose checksum matched is equally well known.
  bool get isOurDownload => this == OriginProvenance.downloaded;

  /// Parses the stored value, defaulting to the least-privileged answer.
  static OriginProvenance parse(Object? value) {
    if (value is! String) return OriginProvenance.importedFolder;
    for (final source in OriginProvenance.values) {
      if (source.wire == value) return source;
    }
    return OriginProvenance.importedFolder;
  }
}

/// Whether one archive became several mods or was merged into one.
enum IngestMode {
  /// Each selected top-level folder became its own mod.
  separate('separate'),

  /// The selected folders were merged into a single mod (a mod plus its
  /// dependency folder, typically).
  combined('combined');

  const IngestMode(this.wire);

  final String wire;

  static IngestMode parse(Object? value) {
    if (value is! String) return IngestMode.separate;
    for (final mode in IngestMode.values) {
      if (mode.wire == value) return mode;
    }
    return IngestMode.separate;
  }
}

/// Whether the app should keep looking this mod up remotely.
enum OriginTracking {
  /// Normal: check for updates.
  auto('auto'),

  /// The user declared this mod local ("not from GameBanana / it's my own").
  /// The status slot goes quiet permanently.
  off('off');

  const OriginTracking(this.wire);

  final String wire;

  static OriginTracking parse(Object? value) {
    if (value is! String) return OriginTracking.auto;
    for (final tracking in OriginTracking.values) {
      if (tracking.wire == value) return tracking;
    }
    return OriginTracking.auto;
  }
}
