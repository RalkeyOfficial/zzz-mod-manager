import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';
import '../../services/gamebanana/content_filter.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/gamebanana/remote_mod_metadata.dart';
import '../../services/origin_resolution.dart';
import '../../services/origin_summary.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../components/marketplace/gb_thumbnail.dart';
import '../components/mod_status_slot.dart';

/// Binds one library folder to one remote mod and file.
///
/// Returns true when something was written, so the caller can rescan — the
/// status slot is drawn from `ModInfo.origin`, which only a scan refreshes.
Future<bool> showResolveOriginDialog(BuildContext context, ModInfo mod) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => ResolveOriginDialog(mod: mod),
      ) ??
      false;
}

/// The local side of the dialog — everything it does that isn't a GameBanana
/// request.
///
/// Calling `ApiService` straight from a dialog is this codebase's convention
/// (delete, rename and edit all do), and the default here keeps it. What the
/// indirection buys is a test seam: `ApiService` lazily builds a `ConfigService`
/// that writes the developer's **real** `<appData>/config.json`, so a widget
/// test that so much as mounted this dialog would touch their library paths,
/// active mods and favourites.
class ResolveOriginGateway {
  const ResolveOriginGateway();

  /// The oldest file in the mod folder, when the sidecar records no install
  /// date of its own.
  Future<DateTime?> installDateProxy(String modId) =>
      ApiService.installDateProxy(modId);

  /// Applies one decision to the sidecar, re-reading it first. False means
  /// nothing was written.
  Future<bool> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) =>
      ApiService.updateModOrigin(modId, update);

  /// The optional "also fill in what's missing" pass.
  Future<void> fillMetadata(String modId, RemoteModMetadata remote) async {
    final service = await ApiService.getModManagerService();
    await service.applyRemoteMetadata([modId], remote);
  }
}

/// The per-mod resolve dialog: **one job, bind this folder to a remote mod and
/// file.**
///
/// Every rule about what an answer is allowed to claim lives in
/// `services/origin_resolution.dart`; this is the surface around it. Three
/// things about the surface are decisions rather than layout, so they are
/// recorded here:
///
/// - **Every suggestion says why.** A ranked list with no visible reason is
///   indistinguishable from a ranked list with a wrong reason, and the user is
///   the only one who can tell them apart.
/// - **Two escape hatches are always one click away.** "I don't know which"
///   and "not from GameBanana" are not failure paths — for most of a legacy
///   library they are the *correct* answers, and burying them would make the
///   dialog something to abandon rather than finish.
/// - **The content filter degrades to blur here, never to omit.** Elsewhere
///   `hide` drops a flagged mod from the list; doing that in a search the user
///   is running to identify a mod they *already own* would make that mod
///   permanently unresolvable, with no hint as to why. Blurring keeps the
///   setting's promise without breaking the screen.
class ResolveOriginDialog extends ConsumerStatefulWidget {
  const ResolveOriginDialog({
    super.key,
    required this.mod,
    this.gateway = const ResolveOriginGateway(),
  });

  final ModInfo mod;

  /// Injected only by tests — see [ResolveOriginGateway].
  final ResolveOriginGateway gateway;

  @override
  ConsumerState<ResolveOriginDialog> createState() =>
      _ResolveOriginDialogState();
}

class _ResolveOriginDialogState extends ConsumerState<ResolveOriginDialog> {
  final TextEditingController _searchController = TextEditingController();

  /// The identity currently on the table — from the sidecar, or whatever the
  /// user has since picked. Null puts the dialog in its search state.
  int? _modId;

  /// The install date used for ranking and for the "assume current" baseline.
  /// Probed when the sidecar has none, since a mod that never had a
  /// `source_url` was never walked by the offline backfill.
  DateTime? _installedAt;

  GbMod? _profile;
  Object? _profileError;
  bool _loadingProfile = false;

  List<GbMod>? _searchResults;
  Object? _searchError;
  bool _searching = false;

  /// Set when a pasted url is a `/dl/` file link — which cannot name a mod. See
  /// [gameBananaFileIdFromUrl].
  bool _pastedFileLink = false;

  GbFile? _selectedFile;
  bool _selectionIsExact = false;
  bool _alsoFillMetadata = false;
  bool _saving = false;

  ModOrigin? get _origin => widget.mod.origin;

  @override
  void initState() {
    super.initState();
    _modId = _origin?.modId;
    _installedAt = _origin?.installedAt;
    _searchController.text = widget.mod.name;
    // A mod the user declared their own renders one notice and one button, and
    // `build` shows nothing a mod page could fill in — so fetching one is a
    // round trip whose result can never be displayed.
    if (_origin?.tracking == OriginTracking.off) return;
    if (_modId case final id?) {
      _loadProfile(id);
    } else {
      _search();
    }
    if (_installedAt == null) _probeInstallDate();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  AppLocalizations get loc => context.loc;

  /// Fills in the install date for a mod whose sidecar has none.
  ///
  /// Runs **concurrently with the profile fetch**, so it can land on either side
  /// of it — and the ranking it feeds is recomputed on every build, so the list
  /// itself always catches up. What does not catch up on its own is the *default
  /// selection*, which runs once when the profile arrives. Nothing that
  /// preselects depends on the date today (a hash match and a single-file mod
  /// are both date-independent), so re-running it is insurance rather than a
  /// fix — but it costs a line, and the alternative is a rule whose correctness
  /// depends on how fast a folder walk finished.
  ///
  /// Guarded on nothing being selected yet, so a user who picked a row while the
  /// walk was still running keeps their choice.
  Future<void> _probeInstallDate() async {
    final probed = await widget.gateway.installDateProxy(widget.mod.id);
    if (!mounted || probed == null) return;
    setState(() => _installedAt = probed);
    if (_selectedFile == null) _applyDefaultSelection();
  }

  Future<void> _loadProfile(int modId) async {
    setState(() {
      _loadingProfile = true;
      _profileError = null;
      _profile = null;
      _selectedFile = null;
    });
    try {
      final profile = await ref.read(gameBananaClientProvider).modProfile(modId);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loadingProfile = false;
      });
      _applyDefaultSelection();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _profileError = e;
        _loadingProfile = false;
      });
    }
  }

  /// What the sidecar currently claims — the two lines in the identity card,
  /// and the row the file list marks as "on record".
  OriginSummary get _summary => summarizeOrigin(_origin);

  /// Selects the row the block already names, or failing that whatever the
  /// resolution rule says may be preselected — a banked-hash match or a mod
  /// with exactly one file. A merely *suggested* row is left unselected on
  /// purpose: guesses may inform, never drive.
  ///
  /// **The recorded file comes first, and it is not a suggestion.** Opening on
  /// a mod the user had already resolved and selecting nothing left the dialog
  /// unable to state its own subject's answer. The fix is to select it *and say
  /// why*, rather than to stop selecting things: every selected row carries a
  /// chip naming what put it there, so "on record" and "our best guess" cannot
  /// be mistaken for one another — which is the real ambiguity, not the
  /// selection itself.
  void _applyDefaultSelection() {
    if (_summary.fileId case final recorded?) {
      for (final candidate in _resolution.candidates) {
        if (candidate.file.idRow != recorded) continue;
        setState(() {
          _selectedFile = candidate.file;
          // The recorded tier is preserved by `pickFile` rather than re-derived
          // here; a hash match on the same row still reports itself as exact.
          _selectionIsExact = candidate.isExact;
        });
        return;
      }
    }
    final preselected = _resolution.preselected;
    if (preselected == null) return;
    setState(() {
      _selectedFile = preselected.file;
      _selectionIsExact = preselected.isExact;
    });
  }

  FileResolution get _resolution {
    final profile = _profile;
    if (profile == null) return FileResolution.empty;
    return rankResolveCandidates(
      files: profile.files,
      archivedFiles: profile.archivedFiles,
      folderName: widget.mod.name,
      installedAt: _installedAt,
      archiveMd5: _origin?.archiveMd5,
    );
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    setState(() {
      _pastedFileLink = false;
      _searchError = null;
    });

    // A pasted mod page resolves without searching at all.
    if (gameBananaModIdFromUrl(query) case final pastedId?) {
      setState(() => _modId = pastedId);
      await _loadProfile(pastedId);
      return;
    }
    // A pasted `/dl/` link names a *file*, and neither API can say which mod
    // owns it — so say that instead of searching for the url as if it were text.
    if (gameBananaFileIdFromUrl(query) != null) {
      setState(() {
        _pastedFileLink = true;
        _searchResults = const <GbMod>[];
      });
      return;
    }
    if (query.isEmpty) return;

    setState(() => _searching = true);
    try {
      final page = await ref.read(gameBananaClientProvider).searchMods(query);
      if (!mounted) return;
      setState(() {
        _searchResults = page.records;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e;
        _searching = false;
      });
    }
  }

  // ------------------------------------------------------------------ saving

  /// Whether the identity itself needs writing, as opposed to only the file.
  ///
  /// False when the sidecar already names this mod at a tier the user or a
  /// download established — then the only decision being written is the file,
  /// and [OriginResolution.pickFile]'s guard stays live: if the sidecar was
  /// rebound while this dialog was open, the write abandons instead of
  /// attaching a file id to somebody else's mod.
  bool get _identityNeedsWrite {
    final origin = _origin;
    if (origin == null || origin.modId != _modId) return true;
    return origin.modIdConfidence != OriginConfidence.user &&
        origin.modIdConfidence != OriginConfidence.exact;
  }

  /// Whether Save would change anything on disk.
  ///
  /// A file selection counts unless it re-states exactly what is already
  /// recorded, at the same tier. That exception arrives with the recorded row
  /// being preselected: without it Save is live the moment the dialog opens on
  /// an already-resolved mod, and pressing it rewrites the block byte-for-byte,
  /// closes and triggers a rescan — which reads as though it did something.
  ///
  /// **Asked of the write path rather than re-derived**, by running the same
  /// transform Save would and comparing the result to what is on record. The
  /// two must not be able to disagree, and the cases where they could are not
  /// obvious ones: re-picking a row recorded at `inferred` looks like a no-op
  /// but is the confirmation that tier is waiting for, while re-picking one
  /// recorded at `exact` genuinely changes nothing. `ModOrigin` has value
  /// equality already — it was added for the rescan guard — so this costs a
  /// comparison.
  bool get _hasSomethingToSave {
    if (_identityNeedsWrite) return true;
    if (_origin?.installedAt == null && _installedAt != null) return true;
    if (_selectedFile case final file?) {
      final origin = _origin;
      final modId = _modId;
      if (origin == null || modId == null) return true;
      final next = OriginResolution.pickFile(
        origin,
        modId: modId,
        file: file,
        exact: _selectionIsExact,
      );
      return next != null && next != origin;
    }
    return false;
  }

  Future<void> _save() async {
    final modId = _modId;
    if (modId == null) return;
    final file = _selectedFile;
    final exact = _selectionIsExact;
    final identityNeedsWrite = _identityNeedsWrite;
    final installedAt = _installedAt;

    await _write((current) {
      var next = current;
      if (identityNeedsWrite) next = OriginResolution.bind(current, modId);
      // Recorded even when the user changed nothing about it, because a folder
      // bound for the first time has no install date of its own — and the
      // "assume current" baseline and the file ranking both need one.
      if (next != null && next.installedAt == null && installedAt != null) {
        next = next.copyWith(
          installedAt: installedAt,
          installedAtIsProxy: true,
        );
      }
      if (file == null) return next;
      return OriginResolution.pickFile(
        next,
        modId: modId,
        file: file,
        exact: exact,
      );
    });
  }

  Future<void> _assumeCurrent() async {
    final modId = _modId;
    if (modId == null) return;
    final installedAt = _installedAt;
    final createdAt = _profile?.dateAdded;
    final identityNeedsWrite = _identityNeedsWrite;

    await _write((current) {
      final bound =
          identityNeedsWrite ? OriginResolution.bind(current, modId) : current;
      return OriginResolution.assumeCurrent(
        bound,
        installedAt: installedAt,
        remoteCreatedAt: createdAt,
      );
    });
  }

  /// **Never fills metadata**, whatever the checkbox says.
  ///
  /// The checkbox sits above this row in the same scrolling column, so ticking
  /// "also fill in what's missing" and then answering "actually, not from
  /// GameBanana" is an ordinary thing to do — and honouring both would write
  /// that mod page's description, gallery and tags into a mod the user has just
  /// declared isn't from there. Nothing would be destroyed (the fill rule is
  /// fill-absence-never-displace), but the result would contradict the answer.
  Future<void> _stopTracking() => _write(
        (current) => OriginResolution.stopTracking(current),
        fillMetadata: false,
      );

  Future<void> _resumeTracking() => _write(
        (current) =>
            current == null ? null : OriginResolution.resumeTracking(current),
        fillMetadata: false,
      );

  /// Runs one decision through the write path and closes on success.
  ///
  /// The transform is applied to the sidecar **as it is on disk now**, not to
  /// the block this dialog was opened with — see
  /// `ModMetadataRepository.updateOrigin`.
  /// [fillMetadata] gates the optional fill on top of the checkbox: only the
  /// answers that *endorse* the mod page may pull data from it.
  Future<void> _write(
    ModOrigin? Function(ModOrigin? current) update, {
    bool fillMetadata = true,
  }) async {
    setState(() => _saving = true);
    final ok = await widget.gateway.writeOrigin(widget.mod.id, update);

    if (ok && fillMetadata && _alsoFillMetadata && _profile != null) {
      // Best-effort and deliberately not gating the result: the tracking data is
      // what the user came here to set, and a failed gallery fetch must not read
      // as a failed resolve. The fill rule is "fill absence, never displace", so
      // it cannot damage what the mod already had either.
      try {
        await widget.gateway.fillMetadata(
          widget.mod.id,
          RemoteModMetadata.fromMod(_profile!),
        );
      } catch (e) {
        debugPrint('ResolveOriginDialog: metadata fill failed: $e');
      }
    }

    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      context.notify.warning(
        loc.t('mods.resolve.save_failed_title'),
        body: loc.t('mods.resolve.save_failed',
            params: {'mod': widget.mod.name}),
        characterId: widget.mod.characterId,
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        loc.t('mods.resolve.title', params: {'mod': widget.mod.name}),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_origin?.tracking == OriginTracking.off)
                _untrackedNotice()
              else if (_modId == null)
                _identitySearch()
              else
                ..._boundBody(),
            ],
          ),
        ),
      ),
      actions: _actions(),
    );
  }

  List<Widget> _actions() {
    final closing = _saving;
    return [
      TextButton(
        onPressed: closing ? null : () => Navigator.of(context).pop(false),
        child: Text(loc.t('mods.resolve.cancel')),
      ),
      if (_origin?.tracking == OriginTracking.off)
        FilledButton(
          onPressed: closing ? null : _resumeTracking,
          child: Text(loc.t('mods.resolve.resume_tracking')),
        )
      else if (_modId != null)
        FilledButton(
          // Disabled when there is nothing left to record — the identity is
          // already confirmed and no file has been picked. Enabled, it would
          // write the block back byte-for-byte, close, and trigger a rescan,
          // which reads as though it did something.
          onPressed: closing || _profile == null || !_hasSomethingToSave
              ? null
              : _save,
          child: Text(loc.t('mods.resolve.save')),
        ),
    ];
  }

  Widget _untrackedNotice() => _notice(
        loc.t('mods.resolve.tracking_off'),
        Icons.notifications_off_outlined,
      );

  // ------------------------------------------------------- identity: search

  Widget _identitySearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          loc.t('mods.resolve.identity_heading'),
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          autofocus: true,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            isDense: true,
            hintText: loc.t('mods.resolve.search_hint'),
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward, size: 18),
              tooltip: loc.t('mods.resolve.search_button'),
              onPressed: _search,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 12),
        if (_pastedFileLink)
          _notice(loc.t('mods.resolve.paste_is_file_link'), Icons.link_off)
        else if (_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_searchError != null)
          _notice(loc.t('mods.resolve.load_failed'), Icons.cloud_off)
        else if (_searchResults?.isEmpty ?? false)
          _notice(loc.t('mods.resolve.no_results'), Icons.search_off)
        else
          // Bounded for the same reason as the file list: search returns up to
          // fifteen, and the escape hatch underneath has to stay one click away.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final result in _searchResults ?? const <GbMod>[])
                  _searchResultRow(result),
              ],
            ),
          ),
        const SizedBox(height: 8),
        const Divider(),
        _stopTrackingTile(),
      ],
    );
  }

  Widget _searchResultRow(GbMod mod) {
    final filter = ref.watch(contentFilterProvider);
    // Never omit here — see the class doc. A mod the user owns must stay
    // reachable whatever the setting says about how to render it.
    final treatment = contentTreatment(
      mod.visibility ?? GbVisibility.warn,
      filter == ContentFilterMode.hide ? ContentFilterMode.blur : filter,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          setState(() => _modId = mod.idRow);
          _loadProfile(mod.idRow);
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: GbThumbnail(
                  image: mod.images.isEmpty ? null : mod.images.first,
                  treatment: treatment,
                  width: 64,
                  height: 40,
                  minWidth: 220,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mod.name ?? '#${mod.idRow}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        if (mod.submitter?.name case final by? when by.isNotEmpty)
                          by,
                        if (mod.subCategory?.name case final cat?) cat,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------- identity: bound

  List<Widget> _boundBody() {
    return [
      _identityCard(),
      const SizedBox(height: 12),
      if (_loadingProfile)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_profileError != null) ...[
        _notice(loc.t('mods.resolve.load_failed'), Icons.cloud_off),
        const Divider(),
        // Still offered with the mod page unreachable, because it needs nothing
        // from it: "it's my own" is a statement about the folder. The "assume
        // current" hatch is *not* here on purpose — its baseline has to be
        // clamped against the mod's own creation date, and that is the field we
        // just failed to fetch.
        _stopTrackingTile(),
      ] else if (_profile != null) ...[
        _fileSection(),
        const SizedBox(height: 8),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _alsoFillMetadata,
          onChanged: (v) => setState(() => _alsoFillMetadata = v ?? false),
          title: Text(
            loc.t('mods.resolve.also_fill_metadata'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const Divider(),
        _assumeCurrentTile(),
        _stopTrackingTile(),
      ],
    ];
  }

  /// The bound mod, and — while this dialog is still looking at the mod the
  /// sidecar names — **what is currently recorded about it.**
  ///
  /// The summary lives inside this card rather than in a panel of its own, and
  /// that is a constraint rather than a preference: a second bordered box cost
  /// about forty pixels and pushed the two escape hatches below the fold, which
  /// is the one thing this dialog must never do. Folded in it costs two lines,
  /// and it reads better anyway — the mod's name and how we came to believe it
  /// are one fact, not two.
  Widget _identityCard() {
    final profile = _profile;
    final modId = _modId!;
    final scheme = Theme.of(context).colorScheme;
    // Only describe what is on disk while the dialog is still pointed at it.
    // After "Change", `_modId` names a different mod than the block does, and
    // the recorded file, version and baseline all belong to the old one — so
    // showing them under the new mod's name would attribute one mod's history
    // to another.
    final summary = _modId == _origin?.modId ? _summary : OriginSummary.empty;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.t(summary.isEmpty
                          ? 'mods.resolve.identity_heading'
                          : 'mods.resolve.tracked_heading'),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile?.name ?? '#$modId',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.open_in_new, size: 18),
                tooltip: loc.t('mods.resolve.open_page'),
                onPressed: () =>
                    launchExternalUrl(context, gameBananaModUrl(modId)),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _modId = null;
                    _profile = null;
                    _profileError = null;
                    _selectedFile = null;
                    _searchResults = null;
                  });
                  // Run the seeded search straight away, as opening on an
                  // untracked mod does. Dropping back to an empty box with the
                  // folder name already typed in it looks like a control that
                  // did nothing.
                  _search();
                },
                child: Text(loc.t('mods.resolve.identity_change')),
              ),
            ],
          ),
          if (!summary.isEmpty) ..._trackedLines(summary),
        ],
      ),
    );
  }

  /// What the sidecar says **right now**, before anything here changes it.
  ///
  /// The statement the dialog was missing. Every other control is about what
  /// the user is *going* to record, and with no statement of the current answer
  /// a mod resolved months ago is indistinguishable from one never touched —
  /// which was the reported problem, and is why a seventeen-mod library could
  /// not be told apart without opening seventeen dialogs.
  ///
  /// Two lines, because the block has two independent axes that resolve
  /// separately: knowing the mod says nothing about knowing the file.
  List<Widget> _trackedLines(OriginSummary summary) {
    final identity = switch (summary.identity) {
      IdentitySummary.downloaded => loc.t('mods.resolve.tracked_id_downloaded'),
      IdentitySummary.confirmed => loc.t('mods.resolve.tracked_id_confirmed'),
      IdentitySummary.inferred => loc.t('mods.resolve.tracked_id_inferred'),
      IdentitySummary.none => null,
    };

    final version = switch (summary.version) {
      VersionSummary.downloaded =>
        loc.t('mods.resolve.tracked_file_downloaded'),
      // A matching key, never an integrity claim — the same phrasing the file
      // list and the duplicate-archive prompt use, deliberately.
      VersionSummary.checksumMatched =>
        loc.t('mods.resolve.tracked_file_hash'),
      VersionSummary.chosen => loc.t('mods.resolve.tracked_file_chosen'),
      VersionSummary.guessed => loc.t('mods.resolve.tracked_file_guessed'),
      VersionSummary.dateOnly => loc.t(
          'mods.resolve.tracked_file_date_only',
          // Straight from the block, not recomputed: the stored baseline is
          // clamped to the mod's creation date, so a value derived here could
          // quote a cutoff that is not the one in force.
          params: {
            'date':
                summary.baseline == null ? '?' : _formatDate(summary.baseline!),
          },
        ),
      VersionSummary.none => loc.t('mods.resolve.tracked_file_none'),
    };

    return [
      const SizedBox(height: 6),
      if (identity != null) _trackedLine(Icons.link, identity),
      _trackedLine(
        Icons.insert_drive_file_outlined,
        // The recorded version string leads when there is one — it is the fact
        // the user came for — with how we know it after.
        summary.versionLabel == null
            ? version
            : '${summary.versionLabel} — $version',
      ),
    ];
  }

  Widget _trackedLine(IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- file picker

  Widget _fileSection() {
    final resolution = _resolution;
    if (resolution.isEmpty) {
      return _notice(loc.t('mods.resolve.no_files'), Icons.block);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.t('mods.resolve.file_heading'),
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        // The picker is *skipped* rather than hidden when a banked hash settles
        // it: the rows stay, so the user can still see what it resolved to and
        // disagree. What changes is that they no longer have to decide.
        if (resolution.isSettled)
          _notice(
            loc.t('mods.resolve.settled'),
            Icons.check_circle_outline,
            // Not the amber every other notice here uses: this one is the
            // answer, not a caveat. It is still only a *match*, though — no
            // checkmark colour scheme borrowed from "verified", since md5 is a
            // matching key and nothing more.
            colour: Theme.of(context).colorScheme.primary,
          ),
        // Bounded and separately scrollable, so the two escape hatches below
        // stay **one click** away rather than sliding off the bottom. Not
        // hypothetical: a captured profile publishes six current files beside
        // eight archived ones, and every one of them is a row here.
        //
        // The bound came down from 280 when the identity card grew its two
        // "currently tracked" lines, and that is the right trade rather than an
        // arbitrary one: this list scrolls inside itself, so it loses no
        // content, while the hatches beneath it have nowhere to go. A test taps
        // them at the minimum window size for exactly this reason.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 230),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final candidate in resolution.candidates) _fileRow(candidate),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fileRow(ResolveCandidate candidate) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedFile?.idRow == candidate.file.idRow;
    final reason = _reasonLabel(candidate.reason);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          _selectedFile = candidate.file;
          _selectionIsExact = candidate.isExact;
        }),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.7)
                  : scheme.outlineVariant.withValues(alpha: 0.4),
            ),
            color: selected ? scheme.primary.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A Wrap, not a Row: the chips are three-word labels with
                    // nothing to ellipsise, so in a Row the filename is the only
                    // thing that can give way and the row overflows once it has.
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          fileDisplayName(candidate.file),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (candidate.file.isArchived)
                          _chip(loc.t('marketplace.badge_archived'),
                              scheme.onSurfaceVariant),
                        // "This is the answer already on file" is a different
                        // claim from "this is our best guess", and the row is
                        // the only place the difference can be seen. Filled
                        // rather than tinted, so it wins the glance against the
                        // suggestion chip beside it.
                        if (_summary.fileId == candidate.file.idRow)
                          _chip(
                            loc.t('mods.resolve.on_record'),
                            scheme.onPrimary,
                            background: scheme.primary,
                          ),
                        // Always spelled out, never implied by position: a
                        // ranking with no stated reason cannot be argued with.
                        if (reason != null) _chip(reason, scheme.primary),
                      ],
                    ),
                    // The author's label sits *under* the filename rather than
                    // replacing it. It is free text and often a sentence, so
                    // leading with it hid which file the row actually is.
                    if (fileDisplayDetail(candidate.file) case final detail?)
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (candidate.file.dateAdded case final date?)
                      Text(
                        _formatDate(date),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _reasonLabel(FileMatchReason reason) => switch (reason) {
        FileMatchReason.archiveHash => loc.t('mods.resolve.reason_hash'),
        FileMatchReason.folderName => loc.t('mods.resolve.reason_folder'),
        FileMatchReason.installDate => loc.t('mods.resolve.reason_date'),
        FileMatchReason.onlyFile => loc.t('mods.resolve.reason_only'),
        FileMatchReason.none => null,
      };

  // --------------------------------------------------------- escape hatches

  Widget _assumeCurrentTile() {
    // Offered only when a baseline can actually be derived: `assumed_latest`
    // with no date compares against nothing, so a disabled row with an
    // explanation beats a button that silently does nothing.
    // A baseline already on record wins over one derived here. The two can
    // legitimately differ — `assumeCurrent` clamps against the mod's creation
    // date, so a stored baseline is often *later* than the install date — and
    // quoting the derived one would promise a cutoff that is not in force.
    final baseline = _summary.baseline ?? _installedAt ?? _profile?.dateAdded;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: !_saving && baseline != null,
      leading: const Icon(Icons.help_outline, size: 20),
      title: Text(
        loc.t('mods.resolve.dont_know'),
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        baseline == null
            ? loc.t('mods.resolve.dont_know_unavailable')
            : loc.t('mods.resolve.dont_know_hint',
                params: {'date': _formatDate(baseline)}),
        style: const TextStyle(fontSize: 11),
      ),
      onTap: baseline == null ? null : _assumeCurrent,
    );
  }

  Widget _stopTrackingTile() {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: !_saving,
      leading: const Icon(Icons.notifications_off_outlined, size: 20),
      title: Text(
        loc.t('mods.resolve.not_gamebanana'),
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        loc.t('mods.resolve.not_gamebanana_hint'),
        style: const TextStyle(fontSize: 11),
      ),
      onTap: _stopTracking,
    );
  }

  // -------------------------------------------------------------- fragments

  Widget _chip(String label, Color color, {Color? background}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: background ?? color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _notice(String message, IconData icon, {Color? colour}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: colour ?? ModStatusSlot.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final d = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
