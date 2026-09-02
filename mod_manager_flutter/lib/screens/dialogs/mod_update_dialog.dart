import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_origin.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/origin_summary.dart';
import '../../services/update_check.dart';
import '../../services/update_check_run.dart';
import '../../services/update_apply/update_write_route.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/html_to_markdown.dart';
import '../../utils/markdown_description.dart';
import '../../utils/marketplace_providers.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../components/mod_status_slot.dart';
import 'apply_update_flow.dart';

/// One mod's update verdict, and the honest set of things a user can do about
/// it today.
///
/// Both entry points land here — the context menu's "check for updates", which
/// arrives with nothing on record, and the card's blue badge, which arrives
/// with a verdict from the last bulk pass. The difference is only whether a
/// request is made on open, so they are one dialog rather than two.
///
/// **The "Update" button writes over the installed folder**, through
/// `apply_update_flow.dart` — download, extract to temp, snapshot, then
/// overwrite. It is offered only where an update was actually found, and only
/// once a file has been named: with several candidates the user picks the row
/// first, because a ZZZ mod routinely ships an SFW and an NSFW build together
/// and only they know which one they have.
///
/// Returns true when anything the library renders changed — a dismissal writes
/// to the origin block and an applied update rewrites the folder, and both are
/// only re-read by a scan.
Future<bool> showModUpdateDialog(BuildContext context, ModInfo mod) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => ModUpdateDialog(mod: mod),
      ) ??
      false;
}

/// The local side of the dialog — the one thing it does that isn't a request.
///
/// Same seam and same reason as `ResolveOriginGateway`: `ApiService` lazily
/// builds a `ConfigService` against the developer's **real**
/// `<appData>/config.json`, so a widget test that merely mounted this dialog
/// would rewrite their library paths.
class ModUpdateGateway {
  const ModUpdateGateway();

  Future<bool> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) => ApiService.updateModOrigin(modId, update);
}

/// One download in the folder, with everything needed to render a section for
/// it: what it is, what it is called, and its own verdict.
class _Section {
  const _Section({
    required this.download,
    required this.name,
    required this.check,
  });

  final ModDownload download;
  final String name;
  final UpdateCheck check;

  int? get modId => download.modId;
  bool get isPatch => download.role == DownloadRole.patch;

  /// What a write and a dismissal key on.
  ///
  /// **Always this layer's own id.** It used to be null for the folder's own
  /// download, because that was the one the block kept in its own fields and
  /// every write had a separate spelling for it. In a stack every layer is
  /// addressed the same way.
  int? get subjectModId => download.modId;
}

class ModUpdateDialog extends ConsumerStatefulWidget {
  const ModUpdateDialog({
    super.key,
    required this.mod,
    this.gateway = const ModUpdateGateway(),
  });

  final ModInfo mod;

  /// Injected only by tests — see [ModUpdateGateway].
  final ModUpdateGateway gateway;

  @override
  ConsumerState<ModUpdateDialog> createState() => _ModUpdateDialogState();
}

class _ModUpdateDialogState extends ConsumerState<ModUpdateDialog> {
  bool _checking = false;
  bool _writing = false;
  Object? _error;

  /// Kept so a dismissal can re-fold the verdict without a second round trip.
  GbMod? _profile;
  ReleaseGroups _releases = ReleaseGroups.empty;

  /// Release feeds, **by remote mod id** — the folder's own and every companion
  /// alike.
  ///
  /// Keyed rather than held in one field because a folder holding two downloads
  /// renders a full section each, notes accordion included, and two mods'
  /// changelogs are not interchangeable. Everything else that used to be a
  /// single value for "the mod this dialog is about" is keyed the same way and
  /// for the same reason.
  Map<int, List<GbUpdate>> _updatesByMod = const <int, List<GbUpdate>>{};

  /// The **other** mods in this folder, by remote id.
  ///
  /// A mixed folder holds a patch plus the mod it patches, and the origin block
  /// names one of them. Without these the fold has nothing to say about the
  /// other half and answers `indeterminate` — on the one screen the user
  /// deliberately opened to find out.
  Map<int, GbMod> _companionProfiles = const <int, GbMod>{};
  Map<int, ReleaseGroups> _companionReleases = const <int, ReleaseGroups>{};

  /// Which mods' release feeds have been asked for at all.
  ///
  /// Opened from a card badge this dialog fetches nothing — the bulk pass
  /// already answered — so the notes are behind a button rather than costing a
  /// request every time somebody looks at a verdict they have already seen.
  final Set<int> _notesRequestedFor = <int>{};
  final Set<int> _loadingNotesFor = <int>{};

  /// Which accordions are open. All start closed even when a check has already
  /// fetched the feed: the verdict is what the dialog is for, and release notes
  /// are what you open when you have decided to care.
  final Set<int> _notesOpenFor = <int>{};

  /// Which published file the update would install, by mod id, when the user
  /// has chosen.
  ///
  /// Absent means "whatever the check would pick". Only ever set by tapping a
  /// row, and only offered when there is more than one — with a single candidate
  /// there is nothing to choose between and a selection control would be a
  /// question with one answer.
  final Map<int, int> _chosenFileIdBy = <int, int>{};

  /// Names fetched purely to label a section — see [_lookUpNames].
  final Map<int, String> _fetchedNames = <int, String>{};
  final Set<int> _askedNames = <int>{};

  /// Mirrors the sidecar edit this dialog has made, so the verdict on screen
  /// tracks it without waiting for a rescan the caller owns.
  DateTime? _dismissedUntil;

  /// Which identity that edit was written against — a companion's mod id, or
  /// null for the folder's own. Carried because re-applying it to the wrong one
  /// is silent in both directions at once.
  int? _dismissedSubject;
  bool _dismissalEdited = false;
  bool _wrote = false;

  @override
  void initState() {
    super.initState();
    // Only when nothing is on record *and* a request could tell us anything.
    // Re-checking a mod the bulk pass just answered would spend a request to
    // redraw the same sentence — and the client's ten-minute cache would very
    // likely answer it from memory anyway, which looks identical to having
    // done nothing.
    if (verdictWithoutAsking(widget.mod.origin) == null &&
        ref.read(modUpdateChecksProvider)[widget.mod.id] == null) {
      _check();
    } else {
      _lookUpNames();
    }
  }

  /// Names for the section headers, when no check is going to fetch them.
  ///
  /// Only reached on the path where `initState` skips the check — a card badge,
  /// or reopening after this dialog's own check — and only for a folder holding
  /// more than one download, since a single one renders no header. A per-mod
  /// check banks nothing in the session, so on a reopen there is otherwise
  /// nothing local to name either download from and both headers fall back.
  ///
  /// One `Mod/Multi` request each, at most once, and a failure is silent: the
  /// header falls back to the folder name or the id, and an error notice about
  /// a label would be noise on a dialog opened to read a verdict.
  void _lookUpNames() {
    final origin = widget.mod.origin;
    if (origin == null || !origin.isMixed) return;
    final records = ref.read(modUpdateRecordsProvider);
    final client = ref.read(gameBananaClientProvider);
    for (final download in origin.downloads) {
      final id = download.modId;
      if (id == null || !_askedNames.add(id)) continue;
      if (records.containsKey(id)) continue;
      fetchModRecord(client, id).then((record) {
        if (!mounted) return;
        final name = record.name;
        if (name == null || name.isEmpty) return;
        setState(() => _fetchedNames[id] = name);
      }).catchError((_) {});
    }
  }

  AppLocalizations get loc => context.loc;

  /// Any in-flight work. One flag, because every control here is disabled by
  /// either of them and two would drift apart.
  bool get _busy => _checking || _writing;

  /// The verdict on screen.
  ///
  /// An offline answer wins over anything in the session map, and is never
  /// written into it: "untracked" and "you marked this as your own" are
  /// properties of the sidecar that the status slot already derives for itself.
  /// Storing them would also mean writing a provider from `initState`, which
  /// Riverpod refuses outright — the bug this shape avoids rather than guards
  /// against.
  UpdateCheck? get _stored =>
      verdictWithoutAsking(widget.mod.origin) ??
      ref.watch(modUpdateChecksProvider)[widget.mod.id];

  /// Fetches the mod page and folds it against the sidecar.
  ///
  /// [refresh] bypasses the response cache, because a manual "check again" that
  /// can answer from a ten-minute-old copy is a control that cannot do its one
  /// job — the same reason the marketplace's refresh button routes around it.
  Future<void> _check({bool refresh = false}) async {
    final origin = widget.mod.origin;
    final modId = origin?.base?.modId;
    if (modId == null || verdictWithoutAsking(origin) != null) return;
    setState(() {
      _checking = true;
      _error = null;
      // The list this selection indexed into is about to be replaced. Keeping
      // it means a row the author has since archived falls back to the app's
      // own candidate while still wearing the `your choice` chip — the app
      // taking credit for a decision the user did not make, which is precisely
      // what that chip exists to prevent.
      _chosenFileIdBy.clear();
    });
    try {
      final client = ref.read(gameBananaClientProvider);
      // Both at once. The release feed is what tells a co-released *variant*
      // apart from a successor, and without it this dialog would show the
      // unrefined verdict the badge no longer shows — the two must agree.
      //
      // `Mod/Multi` for one id rather than the mod's profile: the comparator
      // reads six fields and a profile is four times the bytes for the same
      // answer. See `fetchModRecord`, which also records why `DownloadPage` —
      // the obvious cheaper choice — cannot serve this.
      final profile = await fetchModRecord(client, modId, refresh: refresh);
      // A mod with no update posts is normal, and a feed that fails to load is
      // not a failed check: the groups can only ever *remove* a flag, so their
      // absence leaves the honest, louder answer.
      List<GbUpdate> updates;
      try {
        updates = await client.modUpdates(modId, refresh: refresh);
      } catch (_) {
        updates = const <GbUpdate>[];
      }

      // The other downloads in this folder. Sequential rather than concurrent:
      // there is at most a handful, and the client's own throttling is what
      // keeps a burst from being answered with a 429 the user would read as a
      // failed check.
      //
      // A companion whose page will not load is simply **left out** — the fold
      // reads that as "not asked" and refuses to call the folder clean, which
      // is the honest answer and the safe direction.
      final companionProfiles = <int, GbMod>{};
      final companionReleases = <int, ReleaseGroups>{};
      final feeds = <int, List<GbUpdate>>{modId: updates};
      for (final patch in origin!.patches) {
        if (patch.modId case final patchModId?) {
        try {
          companionProfiles[patchModId] =
              await fetchModRecord(client, patchModId, refresh: refresh);
        } catch (_) {
          continue;
        }
        try {
          // Kept whole, not just folded into groups: a folder holding two
          // downloads renders a notes accordion each, and the author's prose is
          // what those show.
          final patchUpdates =
              await client.modUpdates(patchModId, refresh: refresh);
          feeds[patchModId] = patchUpdates;
          companionReleases[patchModId] =
              ReleaseGroups.fromUpdates(patchUpdates);
        } catch (_) {
          // As above: groups can only ever remove a flag, so their absence
          // leaves the louder, honest answer.
        }
        }
      }

      if (!mounted) return;
      setState(() {
        _checking = false;
        _profile = profile;
        _releases = ReleaseGroups.fromUpdates(updates);
        _updatesByMod = feeds;
        _companionProfiles = companionProfiles;
        _companionReleases = companionReleases;
        // The check already paid for the feeds, so those notes are simply
        // there. Only for the mods it actually reached.
        _notesRequestedFor.addAll(feeds.keys);
      });
      _store(_fold());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _checking = false;
      });
    }
  }

  /// Fetches the author's release feed for its **notes**, on demand.
  ///
  /// Separate from [_check] and deliberately not folded into it. The check reads
  /// the same feed for `_aFileRowIds` and would happily hand over `_sText` too —
  /// but the path that matters here is the one where no check ran, and spending
  /// a request on every badge click to show a changelog nobody asked for is
  /// exactly the cost that path exists to avoid.
  Future<void> _loadNotes(int modId) async {
    if (_loadingNotesFor.contains(modId)) return;
    setState(() {
      _loadingNotesFor.add(modId);
      _notesRequestedFor.add(modId);
    });
    try {
      final updates = await ref.read(gameBananaClientProvider).modUpdates(modId);
      if (!mounted) return;
      setState(() {
        _updatesByMod = {..._updatesByMod, modId: updates};
        _loadingNotesFor.remove(modId);
      });
    } catch (_) {
      // A feed that won't load is not a failed anything: the verdict beside it
      // is unaffected, and a mod with no update posts renders identically.
      if (!mounted) return;
      setState(() => _loadingNotesFor.remove(modId));
    }
  }

  /// The folder's downloads, each paired with **its own** verdict and name.
  ///
  /// One entry for an ordinary mod, several for a folder holding a patch as
  /// well as the mod it patches. **Order and roles are the stack's**, which is
  /// what makes install order unable to change how the folder reads.
  ///
  /// The fold keeps every layer's own verdict beside the winning one, so this is
  /// a lookup rather than a reconstruction — there is no discarded verdict to
  /// recover, which is what `folderOwn` used to exist for.
  List<_Section> _sections(UpdateCheck folded) {
    final downloads = widget.mod.origin?.downloads ?? const <ModDownload>[];
    if (downloads.isEmpty) return const <_Section>[];

    final byMod = <int, UpdateCheck>{
      for (final layer in folded.layers)
        if (layer.download.modId case final id?) id: layer.check,
    };

    return [
      for (final download in downloads)
        _Section(
          download: download,
          name: _nameFor(download),
          // **Never a stand-in verdict.** A download the fold has no answer for
          // has not been looked at, and `indeterminate` is what this file says
          // about anything it did not ask about — the same rule that keeps a
          // half-checked folder off "up to date".
          check: byMod[download.modId ?? -1] ??
              const UpdateCheck(outcome: UpdateOutcome.indeterminate),
        ),
    ];
  }

  /// What to call a download. The bottom layer falls back to the folder name,
  /// which is what the user knows it by everywhere else; a layer above it falls
  /// back to its id, which is at least something to look up.
  String _nameFor(ModDownload download) {
    final id = download.modId;
    final isBase = download.role == DownloadRole.base;
    final fetched = id == null
        ? null
        : (isBase ? _profile?.name : _companionProfiles[id]?.name) ??
            _fetchedNames[id] ??
            ref.read(modUpdateRecordsProvider)[id]?.name;
    if (fetched != null && fetched.isNotEmpty) return fetched;
    if (isBase) return widget.mod.name;
    return loc.t('mods.folder.unnamed', params: {'id': '${id ?? '?'}'});
  }

  void _store(UpdateCheck? check) {
    if (check == null) return;
    final notifier = ref.read(modUpdateChecksProvider.notifier);
    notifier.state = {...notifier.state, widget.mod.id: check};
  }

  /// The verdict for a mod page **this dialog fetched**, including any
  /// dismissal it has since written.
  ///
  /// Only the check path uses it, and only that path can: arriving from a card
  /// badge there is no profile to fold, because the bulk pass already answered
  /// and re-asking would spend a request to redraw the same sentence. The
  /// dismissal path therefore flips the flag on the verdict in hand
  /// ([UpdateCheck.asDismissed]) rather than coming back through here.
  ///
  /// [_dismissalEdited] is what keeps the two consistent: a "check again" after
  /// an ignore has to re-apply it, since `widget.mod.origin` is the block as it
  /// was when the dialog opened and a rescan is the caller's business.
  UpdateCheck? _fold() {
    final profile = _profile;
    if (profile == null) return null;
    var origin = widget.mod.origin;
    if (_dismissalEdited && origin != null) {
      if (_dismissedSubject case final subject?) {
        // **Onto the layer it was written to.** Applied to another one it both
        // fails to silence the layer the user pressed and stamps that layer's
        // release date where it can hide a finding nobody dismissed.
        origin = origin.withDismissal(
          subject: subject,
          until: _dismissedUntil,
        );
      }
    }
    return checkForUpdate(
      origin: origin,
      remote: profile,
      releases: _releases,
      companionRemotes: _companionProfiles,
      companionReleases: _companionReleases,
    );
  }

  /// "Ignore this update" and its undo.
  ///
  /// The dismissal is written as **the date of the thing being dismissed**, not
  /// as "now": a mod page can publish something between the check and the
  /// press, and dismissing to the current time would swallow it before the user
  /// ever saw it. Anything published after this date speaks up again on its
  /// own, which is what makes this "ignore *this*" rather than a mute.
  Future<void> _setDismissed(_Section? section, bool dismissed) async {
    final folded = _stored;
    if (folded == null) return;
    // The section's own verdict when there is one, and the folded verdict when
    // the folder holds a single download — those are the same thing there.
    final current = section?.check ?? folded;
    final until = dismissed ? current.dismissableUpTo : null;
    if (dismissed && until == null) return;

    // A dismissal belongs to the identity whose releases it waves away, not to
    // the folder. Written onto the primary, a companion's dismissal silences
    // nothing — the companion carries its own — and stamps another mod's date
    // onto this block. With a section in hand that identity is the section's;
    // without one it is whichever the fold picked.
    final subject = section?.subjectModId ?? folded.subjectModId;

    if (subject == null) return;
    setState(() => _writing = true);
    final ok = await widget.gateway.writeOrigin(
      widget.mod.id,
      (block) => block?.withDismissal(subject: subject, until: until),
    );
    if (!mounted) return;
    setState(() {
      _writing = false;
      if (!ok) return;
      _dismissedUntil = until;
      _dismissedSubject = subject;
      _dismissalEdited = true;
      _wrote = true;
    });
    if (!ok) {
      context.notify.warning(
        loc.t('mods.update.dismiss_failed_title'),
        body: loc.t('mods.update.dismiss_failed',
            params: {'mod': widget.mod.name}),
        characterId: widget.mod.characterId,
      );
      return;
    }
    // Re-folded from the mod pages when this dialog has them. Opened from a
    // card badge it never fetches any — the bulk pass answered — so a re-fold
    // produces null there, and returning early on that is exactly how a
    // successful write once looked like a dead button.
    //
    // The fallback re-runs the *fold* rather than flipping the folder's verdict
    // outright, because with several downloads a dismissal changes which one
    // wins: waving away the patch's update on a folder whose mod also has one
    // must leave the mod's finding standing, not mark the folder dismissed.
    _store(_fold() ?? _refoldDismissal(folded, subject, dismissed));
  }

  /// Applies a dismissal to one identity's verdict and folds the folder again,
  /// with no mod page in hand.
  ///
  /// [subject] names the layer the user pressed. A folder with one layer folds
  /// to that layer, so this is `asDismissed` on the one verdict there is.
  ///
  /// **Re-folded rather than patched in place**, because a dismissal can change
  /// which layer wins: a live finding beats a dismissed stronger one, so
  /// silencing the winner has to let another layer through.
  UpdateCheck _refoldDismissal(
    UpdateCheck folded,
    int? subject,
    bool dismissed,
  ) {
    if (folded.layers.length < 2) return folded.asDismissed(dismissed);
    return foldDownloads([
      for (final layer in folded.layers)
        DownloadCheck(
          download: layer.download,
          check: layer.download.modId == subject
              ? layer.check.asDismissed(dismissed)
              : layer.check,
        ),
    ]);
  }

  /// The file the Update button would install.
  ///
  /// The user's tap wins; otherwise it is the check's own pick, which the list
  /// already labels with the grounds it was chosen on. Null when the check named
  /// nothing at all — the installed file is gone and none of the current files
  /// is identifiably its replacement — and the button is absent rather than
  /// disabled there, because the honest action then is the mod page.
  GbFile? _fileToInstall(_Section? section) {
    final check = section?.check;
    if (section == null || check == null) return null;
    if (_chosenFileIdBy[section.modId ?? -1] case final id?) {
      for (final file in check.newerFiles) {
        if (file.idRow == id) return file;
      }
    }
    return check.candidate ??
        (check.newerFiles.length == 1 ? check.newerFiles.single : null);
  }

  /// Downloads the chosen file and writes it over this mod's folder.
  ///
  /// The dialog closes on success: everything on it — the verdict, the file
  /// list, the dismissal state — describes a folder that no longer exists. The
  /// session verdict is dropped for the same reason, so the card falls back to
  /// "not checked since" instead of keeping a blue mark for an update that has
  /// been taken.
  Future<void> _applyUpdate(_Section? section, GbFile file) async {
    // The identity this file belongs to, which is the folder's own only when the
    // verdict is about it. A companion's file recorded against the primary would
    // claim this folder is that other mod. With a section in hand the answer is
    // the section's — which is the point of a button per download rather than
    // one shared button that has to work out which mod it means.
    final subject = section?.subjectModId ?? _stored?.subjectModId;
    final modId = subject ?? widget.mod.origin?.base?.modId;
    if (modId == null) return;

    final route = updateWriteRoute(
      origin: widget.mod.origin,
      subjectModId: subject,
    );
    // Not redundant with `build`'s guard: that one is a widget condition, this
    // is the call that overwrites a live folder.
    if (route.kind == UpdateWriteKind.none) return;

    setState(() => _writing = true);
    // **Base by layout, patch by placement**, and the folder decides which this
    // is rather than the button. See `update_write_route.dart`.
    final changed = route.kind == UpdateWriteKind.patch
        ? await applyPatchUpdateFlow(
            context,
            ref,
            mod: widget.mod,
            remoteModId: modId,
            file: file,
            asCompanion: route.asCompanion,
          )
        : await applyUpdateFlow(
            context,
            ref,
            mod: widget.mod,
            remoteModId: modId,
            file: file,
            patchFiles: route.patchFiles,
            patchModId: route.patchModId,
            asCompanion: route.asCompanion,
            flattensPatch: route.flattensPatch,
          );
    if (!mounted) return;
    setState(() {
      _writing = false;
      _wrote = _wrote || changed;
    });
    if (!changed) return;
    final notifier = ref.read(modUpdateChecksProvider.notifier);
    notifier.state = {...notifier.state}..remove(widget.mod.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Opens this mod's page in the in-app marketplace.
  ///
  /// Two lines because the marketplace already owns "show me mod N" as state —
  /// and it is the only place in the app that can actually fetch a file.
  void _openInMarketplace(int modId) {
    ref.read(marketplaceOpenModProvider.notifier).state = modId;
    ref.read(tabIndexProvider.notifier).state = 1;
    Navigator.of(context).pop(_wrote);
  }

  @override
  Widget build(BuildContext context) {
    final check = _stored;
    final modId = widget.mod.origin?.base?.modId;
    // An *ignored* update is still installable: the user waved the badge away,
    // not the file. The dialog is where they come to change their mind, so the
    // action has to be here rather than only while the mark is showing.
    final hasFinding =
        check != null && (check.hasUpdate || check.dismissed);
    // **A verdict about either half of the folder can be installed**, because
    // the write is chosen by which half it is: base by layout with the patch
    // placed back on top, patch by placement over the base. What is refused is
    // a verdict about a mod this folder does not claim to hold, which no write
    // could apply without overwriting one mod with another.
    final route = hasFinding
        ? updateWriteRoute(
            origin: widget.mod.origin,
            subjectModId: check.subjectModId,
          )
        : UpdateWriteRoute.refused;
    // **One subject, one action bar.** A folder holding several downloads gives
    // each its own Ignore and Update beneath its own facts, because a shared
    // button would have to pick which mod it means and picking wrong writes
    // another mod's archive over this folder. With one download nothing moves.
    final sections = check == null ? const <_Section>[] : _sections(check);
    final sole = sections.length == 1 ? sections.single : null;
    final barActions = sections.length < 2;
    final installable = modId == null ||
            !hasFinding ||
            !barActions ||
            route.kind == UpdateWriteKind.none
        ? null
        : _fileToInstall(sole);

    // Tapping the barrier or pressing Escape pops with **null**, which the
    // caller reads as "nothing was written" — so a dismissal saved and then
    // closed that way would skip the rescan and leave `ModInfo.origin` stale
    // until the next one. Intercepting and re-popping with the real result is
    // the only way to carry it out through a route the user closed rather than
    // a button we drew.
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_wrote);
      },
      child: AlertDialog(
        title: Text(
          loc.t('mods.update.title', params: {'mod': widget.mod.name}),
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_checking)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  ..._failure()
                else if (check == null)
                  _notice(loc.t('mods.update.not_checked'), Icons.help_outline)
                else
                  ..._body(check),
              ],
            ),
          ),
        ),
        // A Wrap, not the default Row: five controls at their longest wording
        // overflow an AlertDialog's action bar, and an OverflowBar clips rather
        // than wrapping. Buttons here are whole words with nothing to ellipsise.
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          if (modId != null)
            TextButton.icon(
              onPressed: () =>
                  launchExternalUrl(context, gameBananaModUrl(modId)),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(loc.t('mods.update.open_page')),
            ),
          // "Ignore" against a live finding; "stop ignoring" once dismissed. The
          // undo sits in the same place as the thing it undoes, so a user who
          // dismissed the wrong mod does not have to work out where it went.
          if (barActions && (check?.dismissed ?? false))
            TextButton(
              onPressed: _busy ? null : () => _setDismissed(sole, false),
              child: Text(loc.t('mods.update.undismiss')),
            )
          else if (barActions && (check?.hasUpdate ?? false))
            TextButton(
              onPressed: _busy || (check?.dismissableUpTo == null)
                  ? null
                  : () => _setDismissed(sole, true),
              child: Text(loc.t('mods.update.dismiss')),
            ),
          if (modId != null &&
              ((check?.hasUpdate ?? false) || (check?.dismissed ?? false)))
            TextButton(
              onPressed: _busy ? null : () => _openInMarketplace(modId),
              child: Text(loc.t('mods.update.open_marketplace')),
            )
          else
            TextButton(
              onPressed: () => Navigator.of(context).pop(_wrote),
              child: Text(loc.t('mods.update.close')),
            ),
          // The primary action, and the only one that touches the mod folder.
          // Present only where a file could actually be named — with the
          // installed file gone and nothing identifiable as its successor, the
          // honest offer is the mod page, not a guess installed over a live mod.
          if (installable case final file?)
            FilledButton.icon(
              onPressed: _busy ? null : () => _applyUpdate(sole, file),
              icon: const Icon(Icons.download_for_offline_outlined, size: 16),
              label: Text(loc.t('mods.update_apply.action')),
            ),
        ],
      ),
    );
  }

  /// The couldn't-reach-GameBanana state, and **the only place a retry is
  /// offered**.
  ///
  /// There is deliberately no general "check again" button. Either the bulk
  /// pass has just answered this mod, in which case re-asking spends a request
  /// to redraw the same sentence, or the dialog opened with nothing on record
  /// and checked on the way in — neither leaves the user anything to press. A
  /// check that *failed* is the one case that does, and without this the only
  /// way to retry is closing and reopening.
  ///
  /// Inline with the message rather than in the action bar: that row already
  /// carries up to three buttons in the normal case, and a control that is
  /// meaningless in every state but this one should not occupy space in all of
  /// them.
  List<Widget> _failure() => [
    _notice(loc.t('mods.update.check_failed'), Icons.cloud_off),
    const SizedBox(height: 4),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _busy ? null : () => _check(refresh: true),
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(loc.t('mods.update.retry')),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
        ),
      ),
    ),
  ];

  // ------------------------------------------------------------------ verdict

  /// The dialog's content: **one full report per download in the folder.**
  ///
  /// A check is about the mods *in a folder*, and a folder frequently holds two
  /// — a patch and the mod it patches. Both are in scope, so both get the whole
  /// treatment: a verdict, the before-and-after box, the file list where there
  /// is a choice, and the author's notes. Summarising the second one in a line
  /// was answering a different question from the one the first one answers.
  ///
  /// **A folder with one download renders exactly as it always has**, including
  /// keeping its Update and Ignore in the action bar. The per-section controls
  /// below exist because two subjects cannot share one action row; introducing
  /// them for a single subject would move a button nobody asked to have moved.
  List<Widget> _body(UpdateCheck check) {
    final sections = _sections(check);
    if (sections.length < 2) {
      return _verdict(
        sections.isEmpty
            ? _Section(
                // A folder with nothing recorded still renders one card: the
                // verdict is `untracked` or `trackingOff`, and there is no layer
                // to attribute it to.
                download: const ModDownload(),
                name: widget.mod.name,
                check: check,
              )
            : sections.single,
        withActions: false,
      );
    }

    return [
      for (final (index, section) in sections.indexed) ...[
        if (index > 0) ...[
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
        ],
        _sectionHeader(section),
        const SizedBox(height: 10),
        ..._verdict(section, withActions: true),
      ],
    ];
  }

  /// Names the download a section is about, and marks a patch as one.
  ///
  /// **The marker is a left rule and a chip, not a position.** Which download a
  /// sidecar stores first is install order, so a patch has to be legible as a
  /// patch wherever it sits — see `docs/origin-tracking.md` §10.
  Widget _sectionHeader(_Section section) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 3,
          height: 22,
          decoration: BoxDecoration(
            color: section.isPatch ? scheme.tertiary : scheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            section.name,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 6),
        _chip(
          loc.t(section.isPatch
              ? 'mods.folder.role_patch'
              : 'mods.folder.role_mod'),
          section.isPatch ? scheme.tertiary : scheme.primary,
        ),
        if (section.modId case final id?)
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 16),
            tooltip: loc.t('mods.folder.open_page'),
            visualDensity: VisualDensity.compact,
            onPressed: () => launchExternalUrl(context, gameBananaModUrl(id)),
          ),
      ],
    );
  }

  List<Widget> _verdict(_Section section, {required bool withActions}) {
    final check = section.check;
    final scheme = Theme.of(context).colorScheme;
    return [
      _headline(check),
      if (check.isObsolete) ...[
        const SizedBox(height: 8),
        // Its own line, never folded into the verdict: an obsolete mod still
        // exists and still downloads, and it can be perfectly up to date. It is
        // the author saying "there is something better now", which is a
        // different sentence from "your copy is old".
        _notice(loc.t('mods.update.obsolete'), Icons.new_releases_outlined),
      ],
      if (check.dismissed) ...[
        const SizedBox(height: 8),
        // Shown *with* the finding rather than instead of it. "You dismissed an
        // update" and "there is nothing new" are different facts, and a user
        // opening this dialog after dismissing is almost always here to change
        // their mind.
        _notice(
          loc.t('mods.update.dismissed'),
          Icons.notifications_paused_outlined,
        ),
      ],
      if (check.outcome == UpdateOutcome.untracked) ...[
        const SizedBox(height: 8),
        _notice(loc.t('mods.update.untracked_hint'), Icons.link_off),
      ],
      if (check.outcome == UpdateOutcome.versionUnknown) ...[
        const SizedBox(height: 8),
        _notice(loc.t('mods.update.version_unknown_hint'), Icons.help_outline),
      ],
      // "Your file is gone and nothing on the page replaces it." Reachable when
      // every file the mod still offers was shipped alongside the archived one,
      // so the release grouping filters them all out. Without this the dialog
      // says an update is available and then shows nothing at all, which reads
      // as a rendering failure rather than as the answer it is.
      if (check.outcome == UpdateOutcome.updateAvailable &&
          check.candidate == null &&
          check.newerFiles.isEmpty) ...[
        const SizedBox(height: 8),
        _notice(loc.t('mods.update.no_successor'), Icons.help_outline),
      ],
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _line(
              Icons.inventory_2_outlined,
              loc.t('mods.update.you_have'),
              _installedDescription(section),
              // Only when there is a published record to read it from. With the
              // installed file gone from the page the headline already falls
              // back to what the sidecar stored, and repeating it underneath
              // would print the same words twice.
              detail: check.installedFile == null
                  ? null
                  : _fileDetail(check.installedFile!),
            ),
            // One file gets a line; several get a list. A mod that ships an SFW
            // and an NSFW build together offers a *choice*, and the user knows
            // which of them they installed — so the check says which one it
            // would pick and on what grounds, and shows the rest rather than
            // quietly discarding them.
            if (check.newerFiles.length < 2) ...[
              if (check.candidate case final candidate?) ...[
                const SizedBox(height: 6),
                _line(
                  Icons.arrow_circle_up,
                  loc.t('mods.update.published'),
                  _fileHeadline(candidate),
                  detail: _fileDetail(candidate),
                ),
              ],
              if (_releaseName(section, check.candidate) case final release?) ...[
                const SizedBox(height: 6),
                // The author's own title for the release ("Version 1.5") — very
                // often the only real version number a mod page has, since
                // `_sVersion` on the files themselves is routinely null.
                _line(
                  Icons.label_outline,
                  loc.t('mods.update.release'),
                  release,
                ),
              ],
            ],
            // **The cutoff, and only where it is not already on screen.**
            //
            // The check reads a mod page's file list; it never reads the mod
            // folder, so "compared against <date>" invited the reading that
            // something about the *files* was compared. On the ordinary path
            // that date is the upload date of the file named in the row above,
            // so the line was restating it under a label that overclaimed.
            //
            // It survives only where there is no installed file to name — an
            // `assumed_latest` install, where a date really is the whole of
            // what the answer rests on — and it says what the date does rather
            // than what it is, in the same words the resolve dialog uses for
            // the same state.
            if (check.installedFile == null)
              if (check.comparedAgainst case final date?) ...[
                const SizedBox(height: 6),
                _line(
                  Icons.event_outlined,
                  loc.t('mods.update.baseline_label'),
                  loc.t('mods.update.baseline_value',
                      params: {'date': _formatDate(date)}),
                ),
              ],
          ],
        ),
      ),
      if (check.newerFiles.length >= 2) ..._options(section),
      ..._releaseNotes(section),
      // The caveat the locked decision requires, and it is placed *below* the
      // facts rather than above them: it qualifies the verdict, it is not the
      // verdict. Shown for every guessed answer, including the ones that came
      // back clean — "probably nothing new" and "nothing new" are different
      // claims and the weaker one must not borrow the stronger's certainty.
      if (check.isGuess && check.outcome != UpdateOutcome.untracked) ...[
        const SizedBox(height: 10),
        Text(
          loc.t('mods.update.guess_caveat'),
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
      if (check.hasUpdate) ...[
        const SizedBox(height: 10),
        Text(
          loc.t('mods.update.manual_note'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
      // The per-section controls. **Only where there are several sections** —
      // with one subject the action bar keeps them, which is where they have
      // always been. Two subjects cannot share one action row: an "Update"
      // there would have to pick a mod on the user's behalf, and picking the
      // wrong one writes another mod's archive over this folder.
      if (withActions) ..._sectionActions(section),
    ];
  }

  /// Ignore and Update, for one download.
  ///
  /// Right-aligned under that download's own facts, so which mod a press acts
  /// on is answered by where the button is rather than by the user tracking a
  /// subject through a shared action bar.
  List<Widget> _sectionActions(_Section section) {
    final check = section.check;
    final installable = _fileToInstall(section);
    final canDismiss = check.hasUpdate && check.dismissableUpTo != null;
    if (!check.dismissed && !canDismiss && installable == null) {
      return const <Widget>[];
    }

    return [
      const SizedBox(height: 10),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 4,
        children: [
          if (check.dismissed)
            TextButton(
              onPressed: _busy ? null : () => _setDismissed(section, false),
              child: Text(loc.t('mods.update.undismiss')),
            )
          else if (canDismiss)
            TextButton(
              onPressed: _busy ? null : () => _setDismissed(section, true),
              child: Text(loc.t('mods.update.dismiss')),
            ),
          if (installable case final file?)
            FilledButton.icon(
              onPressed: _busy ? null : () => _applyUpdate(section, file),
              icon: const Icon(Icons.download_for_offline_outlined, size: 16),
              label: Text(loc.t('mods.update_apply.action')),
            ),
        ],
      ),
    ];
  }

  /// Every file published since the installed one, newest first.
  ///
  /// Shown whenever there is more than one, because that is precisely when
  /// naming a single file stops being an answer. A ZZZ mod routinely publishes
  /// an SFW and an NSFW build in the same release, and only the user knows
  /// which they installed — so the row we would pick carries a chip saying
  /// **why**, and the alternatives stay visible rather than being discarded.
  ///
  /// The chip distinguishes two very different grounds: `matches your variant`
  /// is a real match on the author's own label, while `newest published` is the
  /// fallback that fires when labels drift, and which may well be somebody
  /// else's variant. Presenting those identically would be the whole problem.
  ///
  /// Bounded and separately scrollable for the reason the resolve dialog's
  /// picker is: a mod can publish more than a screenful, and the buttons below
  /// must stay reachable.
  List<Widget> _options(_Section section) {
    final check = section.check;
    final chosen = _chosenFileIdBy[section.modId ?? -1];
    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 12),
      Text(
        loc.t('mods.update.options_heading'),
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 2),
      Text(
        loc.t('mods.update.options_hint'),
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 210),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final file in check.newerFiles)
              _optionRow(
                file,
                section: section,
                isPick: file.idRow == _fileToInstall(section)?.idRow,
                // Only the check's *own* pick may claim grounds. Once the user
                // has tapped a row the chip says so, rather than the app taking
                // credit for their decision under a label it did not choose.
                pickLabelKey: chosen != null
                    ? 'mods.update.pick_chosen'
                    : check.candidateMatchesVariant
                        ? 'mods.update.pick_variant'
                        : 'mods.update.pick_newest',
              ),
          ],
        ),
      ),
    ];
  }

  /// What the author says changed — the thing you read *before* pressing
  /// update.
  ///
  /// Scoped to releases published **after** the file you have, because that is
  /// the question: a mod with forty update posts is not offering to tell you
  /// about all of them, it is offering to tell you what you would be getting.
  /// With no date to compare against (an `assumed_latest` install, or a page
  /// whose files carry none) the whole feed is shown rather than nothing — an
  /// over-long list is a worse answer than an empty one, but only slightly, and
  /// silently hiding notes is worse than both.
  ///
  /// Two shapes, and they are complementary rather than alternatives:
  /// `_aChangeLog` is the author's categorised bullet list and `_sText` is their
  /// prose, and captured feeds carry each without the other. The prose is HTML,
  /// so it goes through the same `htmlToMarkdown` a mod page's description does.
  ///
  /// **An accordion, not a section that appears and then cannot leave.** The
  /// first version dropped the notes into the middle of the dialog with no
  /// boundary around them and no way to put them away again, so an author's
  /// three paragraphs pushed the verdict and the file list off the top of a
  /// scroll view the user had not asked to grow. Collapsing is the fix, and it
  /// also gives the section the edge it was missing — the header *is* the
  /// separator.
  List<Widget> _releaseNotes(_Section section) {
    final modId = section.modId;
    if (modId == null) return const [];

    final requested = _notesRequestedFor.contains(modId);
    final loading = _loadingNotesFor.contains(modId);
    final open = _notesOpenFor.contains(modId);
    final since = section.check.comparedAgainst;
    final relevant = [
      for (final update in _updatesByMod[modId] ?? const <GbUpdate>[])
        if (update.hasNotes &&
            (since == null || (update.dateAdded?.isAfter(since) ?? true)))
          update,
    ];
    // Nothing to offer, and nothing to say about it: a mod with no update posts
    // is ordinary, so an empty "Release notes" header would be noise.
    if (requested && !loading && relevant.isEmpty) {
      return const [];
    }

    final scheme = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 14),
      Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              // Expanding is also what *fetches* on the badge path, so one
              // gesture does both and there is no separate "show notes" button
              // that turns into a heading.
              onTap: _busy || loading
                  ? null
                  : () {
                      if (!requested) {
                        setState(() => _notesOpenFor.add(modId));
                        unawaited(_loadNotes(modId));
                      } else {
                        setState(() => open
                            ? _notesOpenFor.remove(modId)
                            : _notesOpenFor.add(modId));
                      }
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.notes_outlined, size: 20,
                        color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        loc.t('mods.update.notes_heading'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (loading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        open ? Icons.expand_less : Icons.expand_more,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
            if (open && !loading && relevant.isNotEmpty)
              // Bounded and scrolling inside itself, the rule every list in
              // these dialogs follows: the buttons underneath must stay one
              // click away.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    for (final update in relevant) _releaseNote(update, scheme),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _releaseNote(GbUpdate update, ColorScheme scheme) {
    final theme = Theme.of(context);
    final prose = update.text == null ? '' : htmlToMarkdown(update.text!).trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                update.name ?? loc.t('mods.update.notes_untitled'),
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (update.dateAdded case final date?)
                Text(
                  _formatDate(date),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          for (final entry in update.changeLog)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text(
                entry.category == null
                    ? '• ${entry.text}'
                    : '• ${entry.text} (${entry.category})',
                style: theme.textTheme.bodyLarge,
              ),
            ),
          if (prose.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: buildDescriptionMarkdown(
                context,
                prose,
                onLaunchUrl: (href) => launchExternalUrl(context, href),
              ),
            ),
        ],
      ),
    );
  }

  /// One candidate row. **Tappable**, because there is now something to do with
  /// the answer: the row decides which file the Update button installs, and the
  /// user is the only one who knows which variant they run.
  ///
  /// [isPick] is the row that would be used — the check's own choice until the
  /// user overrides it — so the highlight moves with the tap rather than staying
  /// on the suggestion.
  Widget _optionRow(
    GbFile file, {
    required _Section section,
    required bool isPick,
    required String pickLabelKey,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        // Keyed by mod, so choosing a file for the patch cannot silently become
        // the choice for the mod it patches.
        onTap: _busy
            ? null
            : () => setState(
                  () => _chosenFileIdBy[section.modId ?? -1] = file.idRow,
                ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isPick
                  ? ModStatusSlot.updateBlue.withValues(alpha: 0.7)
                  : scheme.outlineVariant.withValues(alpha: 0.4),
            ),
            color: isPick
                ? ModStatusSlot.updateBlue.withValues(alpha: 0.06)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A Wrap, not a Row: the chips are short phrases with nothing to
              // ellipsise, so in a Row the filename is the only thing that can
              // give way and the row overflows once it has.
              Wrap(
                spacing: 6,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    fileDisplayName(file),
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (isPick)
                    _chip(
                      loc.t(pickLabelKey),
                      scheme.onPrimary,
                      background: ModStatusSlot.updateBlue,
                    ),
                  if (_releaseName(section, file) case final release?)
                    _chip(release, scheme.primary),
                ],
              ),
              if (fileDisplayDetail(file) case final detail?)
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              if (file.dateAdded case final date?)
                Text(
                  _formatDate(date),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color, {Color? background}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: background ?? color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
    ),
  );

  Widget _headline(UpdateCheck check) {
    final (key, icon, colour) = _outcomeStyle(check.outcome);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 24, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            loc.t(key),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  /// How an outcome is worded, iconed and coloured.
  ///
  /// One switch, because the headline states the folder's verdict and the
  /// companion section states each other identity's — and two switches over the
  /// same enum is how one of them ends up missing a case, silently, since a
  /// missing key renders as its own dotted path rather than throwing.
  (String, IconData, Color) _outcomeStyle(UpdateOutcome outcome) {
    return switch (outcome) {
      UpdateOutcome.updateAvailable => (
        'mods.update.verdict_update',
        Icons.arrow_circle_up,
        ModStatusSlot.updateBlue,
      ),
      UpdateOutcome.possiblyOutdated => (
        'mods.update.verdict_possibly',
        Icons.arrow_circle_up,
        ModStatusSlot.updateBlue,
      ),
      UpdateOutcome.upToDate => (
        'mods.update.verdict_current',
        Icons.check_circle_outline,
        Theme.of(context).colorScheme.primary,
      ),
      // Amber rather than the primary tick: this is the absence of an answer,
      // not a clean bill of health, and it reads next to the tick it replaces.
      UpdateOutcome.tracksPatchOnly => (
        'mods.update.verdict_patch_only',
        Icons.call_split,
        ModStatusSlot.amber,
      ),
      UpdateOutcome.versionUnknown => (
        'mods.update.verdict_version_unknown',
        Icons.priority_high,
        ModStatusSlot.amber,
      ),
      UpdateOutcome.untracked => (
        'mods.update.verdict_untracked',
        Icons.link_off,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      UpdateOutcome.trackingOff => (
        'mods.update.verdict_tracking_off',
        Icons.notifications_off_outlined,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      UpdateOutcome.sourceGone => (
        'mods.update.verdict_source_gone',
        Icons.link_off,
        ModStatusSlot.amber,
      ),
      UpdateOutcome.indeterminate => (
        'mods.update.verdict_indeterminate',
        Icons.help_outline,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
  }

  /// What the user has, preferring the published record and falling back to
  /// what the sidecar stored.
  ///
  /// The fallback is the interesting half: the strongest verdict this feature
  /// produces is "the file you installed is gone from the mod page", and in
  /// exactly that case there is no published record left to describe. Saying
  /// "unknown" there would contradict the headline directly above it.
  String _installedDescription(_Section section) {
    if (section.check.installedFile case final file?) return _fileHeadline(file);
    // **This layer's own record, not the folder's.** Every layer carries its
    // own `version` / `version_label`, and reading another's here would
    // describe the wrong download — exactly the confusion a section per
    // download exists to remove.
    if (summarizeDownload(
          section.download,
          provenance: widget.mod.origin?.provenance ??
              OriginProvenance.importedFolder,
        ).versionLabel
        case final label?) {
      if (label.isNotEmpty) return label;
    }
    return loc.t('mods.update.unknown_file');
  }

  /// The update post that shipped [file], by name (`Version 1.5`).
  String? _releaseName(_Section section, GbFile? file) {
    if (file == null) return null;
    for (final update in _updatesByMod[section.modId ?? -1] ??
        const <GbUpdate>[]) {
      if (!update.fileRowIds.contains(file.idRow)) continue;
      final name = update.name?.trim();
      return name == null || name.isEmpty ? null : name;
    }
    return null;
  }

  /// The filename with its upload date, for the compact "you have" /
  /// "published" pair. The author's own words go on the greyed line beneath —
  /// see [_fileDetail].
  /// **The filename, and nothing glued to it.**
  ///
  /// The upload date used to be appended with a dash, which read as part of the
  /// name — `v77.zip — 2026-06-19` looks like a file called that. It is a fact
  /// *about* the file, the same kind as its version, so it belongs on the
  /// greyed line with them.
  String _fileHeadline(GbFile file) => fileDisplayName(file);

  /// What the author said about the file **and when it went up**, for the
  /// second line of those rows.
  ///
  /// It has to be *there*, not folded into the headline: those two rows sit
  /// directly above one another and are frequently the same variant of the
  /// same mod, so `7.4 · Main file` against `7.7 · Main file` is the comparison
  /// the user opened the dialog for.
  ///
  /// The date joins it rather than the filename because it is the same kind of
  /// thing — a fact about the file — and because on the rows where the author's
  /// labels are identical it is the only thing telling them apart.
  String? _fileDetail(GbFile file) {
    final parts = [
      if (fileDisplayDetail(file) case final detail?) detail,
      if (file.dateAdded case final date?)
        loc.t('mods.update.uploaded', params: {'date': _formatDate(date)}),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ---------------------------------------------------------------- fragments

  Widget _line(IconData icon, String label, String value, {String? detail}) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: Theme.of(context).textTheme.bodyLarge),
              // The author's description, greyed and underneath, never standing
              // in for the filename above it.
              if (detail != null)
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _notice(String message, IconData icon) {
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
          Icon(icon, size: 20, color: ModStatusSlot.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
