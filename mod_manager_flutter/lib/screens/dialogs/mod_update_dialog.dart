import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../models/mod_origin.dart';
import '../../models/origin_enums.dart';
import '../../services/api_service.dart';
import '../../services/download_names.dart';
import '../../services/log/logger.dart';
import '../../services/mod_manager_service.dart';
import '../../services/origin_summary.dart';
import '../../services/origin_write.dart';
import '../../services/patch_removal.dart';
import '../../services/update_apply/sibling_group.dart';
import '../../services/update_apply/update_write_route.dart';
import '../../services/update_check.dart';
import '../../services/update_check_run.dart';
import '../../utils/categories.dart' show libraryGroupOf;
import '../../utils/gamebanana_url.dart';
import '../../utils/marketplace_providers.dart';
import '../../utils/notifications.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../components/character_tile.dart' show libraryGroupName;
import '../components/folder_downloads_summary.dart';
import '../components/latest_update_post.dart';
import '../components/mod_thumb.dart';
import '../components/update_file_rows.dart';
import '../components/zenith_controls.dart';
import '../components/zenith_dialog.dart';
import 'apply_update_flow.dart';
import 'mod_update_parts.dart';
import 'remove_patch_flow.dart';

final Logger _log = Logger('update');

/// The one thing a layer's own menu offers.
enum _PatchAction { remove }

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
/// overwrite. It is offered only where an update was actually found, and it
/// stays disabled until a file has been named: with several candidates the user
/// picks the row first, because a ZZZ mod routinely ships an SFW and an NSFW
/// build together and only they know which one they have. The app's own
/// candidate starts picked and says on what grounds.
///
/// Returns true when anything the library renders changed — a dismissal writes
/// to the origin block and an applied update rewrites the folder, and both are
/// only re-read by a scan. The answer is the same however the dialog closed,
/// and comes once every write it started has ended ([ModUpdateWrites]).
///
/// [gateway] is for tests only — see [ModUpdateGateway].
Future<bool> showModUpdateDialog(
  BuildContext context,
  ModInfo mod, {
  ModUpdateGateway? gateway,
}) async {
  final writes = ModUpdateWrites();
  await showDialog<void>(
    context: context,
    builder: (_) => ModUpdateDialog(mod: mod, gateway: gateway, writes: writes),
  );
  return writes.settled();
}

/// What the update dialog wrote, held outside the dialog so the answer outlives it.
///
/// The route's own result can't carry it: Escape and a click outside pop with no result, and a write can still be
/// running when any close lands — Ignore's sidecar write, the names a check saves, an update or a Take out. Each
/// write goes through [track], and [settled] waits for the last of them, so the caller's rescan comes after it.
class ModUpdateWrites {
  bool _wrote = false;
  final Set<Future<void>> _running = <Future<void>>{};

  /// Counts [write] as a write once it ends with a result [changed] accepts. Returns [write] itself, so the dialog
  /// awaits it, and handles its error, as it would without this.
  Future<T> track<T>(Future<T> write, bool Function(T result) changed) {
    late final Future<void> ended;
    ended = write.then<void>(
      (result) {
        if (changed(result)) _wrote = true;
      },
      onError: (Object _) {},
    ).whenComplete(() => _running.remove(ended));
    _running.add(ended);
    return write;
  }

  /// Whether anything was written, once no write is running.
  Future<bool> settled() async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
    return _wrote;
  }
}

/// The local side of the dialog — what it does that isn't a request: the origin
/// write, the library read, and a patch's update written into the folder.
///
/// Same seam and same reason as `ResolveOriginGateway`: production wraps the
/// library service read through `modManagerServiceProvider`, and a test hands
/// the dialog a recorder so mounting it reaches no library at all.
class ModUpdateGateway {
  const ModUpdateGateway(this._service);

  final Future<ModManagerService> _service;

  Future<OriginWriteResult> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) async =>
      (await _service).updateModOrigin(modId, update);

  /// The library, for finding the other mods one archive installed.
  ///
  /// A folder scan, so it is asked for **only** when the mod on screen records a
  /// sibling group — one field already in hand, and null for every mod in a
  /// backfilled library.
  Future<List<ModInfo>> library() => ApiService.getMods();

  /// Writes a patch's update over its placement in this mod's folder, through [applyPatchUpdateFlow].
  Future<UpdateFlowOutcome> applyPatchUpdate(
    BuildContext context,
    WidgetRef ref, {
    required ModInfo mod,
    required int remoteModId,
    required GbFile file,
    required bool asCompanion,
    required List<GbFile> published,
    UpdateRunPosition? run,
  }) =>
      applyPatchUpdateFlow(
        context,
        ref,
        mod: mod,
        remoteModId: remoteModId,
        file: file,
        asCompanion: asCompanion,
        published: published,
        run: run,
      );
}

/// One download in the folder, with everything needed to render a section for
/// it: what it is, what it is called, and its own verdict.
class _Section {
  const _Section({
    required this.download,
    required this.key,
    required this.name,
    required this.check,
    this.file,
  });

  final ModDownload download;

  /// What a write, a dismissal and a file choice key on: this layer, by its
  /// page and its place. A page can be the base and a patch at once, and its
  /// id alone would reach both sections.
  final DownloadKey? key;

  final String name;
  final UpdateCheck check;

  /// Which file this layer is, set only when another layer shares its page and
  /// so its [name].
  final LayerFile? file;

  int? get modId => download.modId;
  bool get isPatch => key?.role == DownloadRole.patch;
}

class ModUpdateDialog extends ConsumerStatefulWidget {
  const ModUpdateDialog({
    super.key,
    required this.mod,
    this.gateway,
    this.writes,
  });

  final ModInfo mod;

  /// Injected only by tests — see [ModUpdateGateway].
  final ModUpdateGateway? gateway;

  /// Where the dialog counts its writes, handed in by [showModUpdateDialog].
  final ModUpdateWrites? writes;

  @override
  ConsumerState<ModUpdateDialog> createState() => _ModUpdateDialogState();
}

class _ModUpdateDialogState extends ConsumerState<ModUpdateDialog> {
  late final ModUpdateGateway _gateway = widget.gateway ??
      ModUpdateGateway(ref.read(modManagerServiceProvider.future));
  late final ModUpdateWrites _writes = widget.writes ?? ModUpdateWrites();

  bool _checking = false;
  bool _writing = false;
  Object? _error;

  /// Kept so a dismissal can re-fold the verdict without a second round trip.
  GbMod? _profile;
  ReleaseGroups _releases = ReleaseGroups.empty;

  /// Update posts, **by remote mod id**. The latest one that says something is shown under the file list.
  Map<int, List<GbUpdate>> _updatesByMod = const <int, List<GbUpdate>>{};

  /// Which mods' update posts have been asked for, so each is asked once.
  final Set<int> _feedAsked = <int>{};

  /// The **other** mods in this folder, by remote id.
  ///
  /// A mixed folder holds a patch plus the mod it patches, and the origin block
  /// names one of them. Without these the fold has nothing to say about the
  /// other half and answers `indeterminate` — on the one screen the user
  /// deliberately opened to find out.
  Map<int, GbMod> _companionProfiles = const <int, GbMod>{};
  Map<int, ReleaseGroups> _companionReleases = const <int, ReleaseGroups>{};

  /// Which published file the update would install, by section, when the user
  /// has chosen.
  ///
  /// Absent means "whatever the check would pick". Only set by tapping a row.
  final Map<DownloadKey, int> _chosenFileIdBy = <DownloadKey, int>{};

  /// Names fetched purely to label a section — see [_lookUpNames].
  final Map<int, String> _fetchedNames = <int, String>{};
  final Set<int> _askedNames = <int>{};

  /// Mirrors the sidecar edit this dialog has made, so the verdict on screen
  /// tracks it without waiting for a rescan the caller owns.
  DateTime? _dismissedUntil;

  /// Which layer that edit was written against. Carried because re-applying it
  /// to the wrong one is silent in both directions at once.
  DownloadKey? _dismissedSubject;
  bool _dismissalEdited = false;

  /// The Ignore pressed in this dialog on a folder of one download, which collapses the dialog to "Update ignored"
  /// with Undo. A mod that was already ignored when the dialog opened never collapses: its files stay on offer.
  bool _ignoredHere = false;

  /// The library as it was when this dialog opened, or null until it has been
  /// read — and permanently null for a mod with no sibling group, which is what
  /// stops the scan happening at all.
  List<ModInfo>? _library;

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
      unawaited(_lookUpSiblings());
      _lookUpPost();
    }
  }

  /// The other mods this mod's archive installed, for the notice below the
  /// file list.
  ///
  /// **Read on open rather than off `libraryProvider`.** This dialog is
  /// reachable from a card the marketplace has just installed, and the sibling
  /// it is looking for is the mod that came out of the same archive — the one
  /// most likely to be newer than the last scan. See
  /// `test/modal_freshness_test.dart`.
  ///
  /// A failure is silent: the notice is an aid to a dialog that works without
  /// it, and the confirmation reads the library again anyway.
  ///
  /// **Two gates, and both are about not paying for a folder walk over the whole
  /// library.** No sibling group is the case for every mod that predates the
  /// origin block, and no finding means there is no Update button for the notice
  /// to sit beside — so an up-to-date mod in a group must not pay for it either.
  Future<void> _lookUpSiblings() async {
    if (widget.mod.origin?.ingest?.siblingGroup == null) return;
    // **`read`, not `_stored`.** An async body runs synchronously up to its
    // first `await`, and one caller is `initState` — where `_stored`'s
    // `ref.watch` throws before the lookup ever starts. Same reason `initState`
    // reads the provider directly two lines above its own branch.
    final check = verdictWithoutAsking(widget.mod.origin) ??
        ref.read(modUpdateChecksProvider)[widget.mod.id];
    if (check == null || !(check.hasUpdate || check.dismissed)) return;
    try {
      final library = await _gateway.library();
      if (!mounted) return;
      setState(() => _library = library);
    } catch (e) {
      _log.debug('could not read the library for a sibling group',
          fields: {'mod': widget.mod.id, 'reason': '$e'});
    }
  }

  /// The author's update posts for the cards under the file lists, when this dialog opens on a verdict a check already
  /// made and so has fetched nothing. One request for each page the folder's layers come from, which the client caches
  /// for ten minutes; a feed that will not load leaves its card out and the verdict as it is.
  void _lookUpPost() {
    final check = verdictWithoutAsking(widget.mod.origin) ?? ref.read(modUpdateChecksProvider)[widget.mod.id];
    if (check == null || !(check.hasUpdate || check.dismissed)) return;
    final client = ref.read(gameBananaClientProvider);
    for (final download in widget.mod.origin?.downloads ?? const <ModDownload>[]) {
      final modId = download.modId;
      if (modId == null || !_feedAsked.add(modId)) continue;
      client.modUpdates(modId).then((updates) {
        if (!mounted) return;
        setState(() => _updatesByMod = {..._updatesByMod, modId: updates});
      }).catchError((Object _) {});
    }
  }

  /// Names for the section headers, when no check is going to fetch them.
  ///
  /// Only reached on the path where `initState` skips the check — a card badge,
  /// or reopening after this dialog's own check — and only for a folder holding
  /// more than one download, since a single one renders no header. Pages this
  /// session holds and names saved with the layers answer it without a request;
  /// what is left is a layer nothing has named yet.
  ///
  /// One `Mod/Multi` request each, at most once, and a failure is silent: the
  /// header falls back to the id, and an error notice about
  /// a label would be noise on a dialog opened to read a verdict.
  void _lookUpNames() {
    final origin = widget.mod.origin;
    if (origin == null || !origin.isMixed) return;
    final records = ref.read(knownModPagesProvider);
    final client = ref.read(gameBananaClientProvider);
    for (final download in origin.downloads) {
      final id = download.modId;
      if (id == null || !_askedNames.add(id)) continue;
      // A saved name answers it without a request.
      if (records.containsKey(id) || download.name != null) continue;
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
        // A page already asked once: the base's own, when the patch's file
        // comes from it, is read by both layers.
        if (patch.modId case final patchModId?
            when patchModId != modId && !companionProfiles.containsKey(patchModId)) {
        try {
          companionProfiles[patchModId] =
              await fetchModRecord(client, patchModId, refresh: refresh);
        } catch (_) {
          continue;
        }
        try {
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
        // The check already paid for the feeds, so the latest post is simply there.
        _feedAsked.addAll(feeds.keys);
      });
      _store(_fold());
      unawaited(_lookUpSiblings());

      // The pages serve the card and the details panel too, and their titles are saved so the panel keeps them
      // after a restart (`docs/origin-tracking.md` §10).
      final pages = {modId: profile, ...companionProfiles};
      keepModPages(ref, pages);
      await _rememberNames(pages);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _checking = false;
      });
    }
  }

  /// Saves the titles of [pages] on this mod's downloads, through the dialog's own write. Counted as a write, so the
  /// library rescans when the dialog closes, and marked on the mod while it runs, so a check on it sees the write.
  /// A failure is logged and nothing more: the check itself succeeded.
  Future<void> _rememberNames(Map<int, GbMod> pages) async {
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await _writes.track(
        whileWritingMod(
          container,
          widget.mod.id,
          () => rememberDownloadNames(mods: [widget.mod], pages: pages, write: _gateway.writeOrigin),
        ),
        (wrote) => wrote,
      );
    } catch (e) {
      _log.warning('download names were not saved', error: e, fields: {'mod': widget.mod.id});
    }
  }

  /// The folder's downloads that have a mod page, each paired with **its own**
  /// verdict and name. A download with no page, such as a patch from a local
  /// folder, has no verdict and no section, as the check leaves it out.
  ///
  /// One entry for an ordinary mod, several for a folder holding a patch as
  /// well as the mod it patches. **Order and roles are the stack's**, which is
  /// what makes install order unable to change how the folder reads.
  ///
  /// The fold keeps every layer's own verdict beside the winning one, so this is
  /// a **lookup**. Nothing has to be reconstructed, because the fold discards
  /// nothing: a stack has no privileged entry whose answer could be the one left
  /// out.
  List<_Section> _sections(UpdateCheck folded) {
    final origin = widget.mod.origin;
    final stack = origin?.downloads ?? const <ModDownload>[];
    final keyed = <(DownloadKey, ModDownload)>[
      for (var i = 0; i < stack.length; i++)
        if (origin!.keyAt(i) case final key?) (key, stack[i]),
    ];
    if (keyed.isEmpty) return const <_Section>[];

    final byLayer = <DownloadKey, UpdateCheck>{
      for (final layer in folded.layers)
        if (layer.key case final key?) key: layer.check,
    };

    // **A verdict with no per-layer breakdown belongs to the only layer there
    // is.** A folder with one download folds to it, so the two are the same
    // answer — and a check that arrived without the breakdown (an older stored
    // one, or a caller that built the verdict rather than computing it) must
    // not render as "nothing may be concluded" about a mod it plainly judged.
    if (byLayer.isEmpty && keyed.length == 1) {
      byLayer[keyed.single.$1] = folded;
    }

    return [
      for (final (key, download) in keyed)
        () {
          // **Never a stand-in verdict.** A download the fold has no answer
          // for has not been looked at, and `indeterminate` is what this file
          // says about anything it did not ask about — the same rule that
          // keeps a half-checked folder off "up to date".
          final check = byLayer[key] ??
              const UpdateCheck(outcome: UpdateOutcome.indeterminate);
          return _Section(
            download: download,
            key: key,
            name: _nameFor(download),
            check: check,
            file: sharedPageFile(origin, download,
                page: _pageOf(key.modId), file: check.installedFile),
          );
        }(),
    ];
  }

  /// The page of [modId] this dialog or the session holds, or null.
  GbMod? _pageOf(int modId) =>
      (_profile?.idRow == modId ? _profile : null) ??
      _companionProfiles[modId] ??
      ref.read(knownModPagesProvider)[modId];

  /// What to call a download: a page this dialog or the session holds, then
  /// the name saved with the layer, then its id ([downloadName]).
  String _nameFor(ModDownload download) {
    final id = download.modId;
    final fetched =
        id == null ? null : _pageOf(id)?.name ?? _fetchedNames[id];
    return downloadName(loc, download,
        folderName: widget.mod.name, fetched: fetched);
  }

  void _store(UpdateCheck? check) =>
      _storeIn(ProviderScope.containerOf(context, listen: false), check);

  /// [_store] through [container], for a write that can end after this dialog
  /// has closed.
  void _storeIn(ProviderContainer container, UpdateCheck? check) {
    if (check == null) return;
    final notifier = container.read(modUpdateChecksProvider.notifier);
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
  ///
  /// [collapse] is the dialog's own Ignore and Undo on a folder of one download, which switch it between the file list
  /// and "Update ignored"; a layer's Ignore in a mixed folder leaves the dialog as it is.
  Future<void> _setDismissed(_Section? section, bool dismissed, {bool collapse = false}) async {
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
    final subject = section?.key ?? folded.subject;

    if (subject == null) return;
    setState(() => _writing = true);
    // Taken before the write: the dialog can be closed while it runs, and what
    // follows it still has to reach the session verdict and the user.
    final container = ProviderScope.containerOf(context, listen: false);
    final notify = context.notify;
    final loc = this.loc;
    final result = await _writes.track(
      whileWritingMod(
        container,
        widget.mod.id,
        () => _gateway.writeOrigin(
          widget.mod.id,
          (block) => block?.withDismissal(subject: subject, until: until),
        ),
      ),
      (result) => result.ok,
    );
    final ok = result.ok;
    if (ok) {
      // Recorded whether or not the dialog is still open: the re-fold below
      // reads them.
      _dismissedUntil = until;
      _dismissedSubject = subject;
      _dismissalEdited = true;
      // Re-folded from the mod pages when this dialog has them. Opened from a
      // card badge it never fetches any — the bulk pass answered — so a re-fold
      // produces null there; stopping on that would leave a successful write
      // looking like a button that did nothing.
      //
      // The fallback re-runs the *fold* rather than flipping the folder's
      // verdict outright, because with several downloads a dismissal changes
      // which one wins: waving away the patch's update on a folder whose mod
      // also has one must leave the mod's finding standing, not mark the folder
      // dismissed.
      //
      // Through the app's container, so a dialog closed while the write ran
      // still leaves the badge reading what was written.
      _storeIn(container, _fold() ?? refoldDismissal(folded, subject, dismissed));
    } else {
      notify.error(
        loc.t('mods.update.dismiss_failed_title'),
        body: loc.t('mods.update.dismiss_failed',
            params: {'mod': widget.mod.name}),
        characterId: widget.mod.characterId,
      );
    }
    if (!mounted) return;
    setState(() {
      _writing = false;
      if (ok && collapse) {
        _ignoredHere = dismissed;
        _chosenFileIdBy.remove(subject);
      }
    });
  }

  /// The file the Update button would install.
  ///
  /// The user's tap wins; otherwise it is the check's own pick, which the list
  /// already labels with the grounds it was chosen on, or the one file there is.
  /// Null when the check named nothing: with several files and no candidate the
  /// button stays disabled until a row is picked, and with none at all there is
  /// no button, because the honest action then is the mod page.
  GbFile? _fileToInstall(_Section? section) {
    final check = section?.check;
    if (section == null || check == null) return null;
    if (_chosenFileIdBy[section.key] case final id?) {
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
    final subject = section?.key ?? _stored?.subject;
    final modId = subject?.modId ?? widget.mod.origin?.base?.modId;
    if (modId == null) return;

    // Not redundant with `build`'s guard: that one is a widget condition, this
    // is the call that overwrites a live folder.
    if (updateWriteRoute(origin: widget.mod.origin, subject: subject).kind == UpdateWriteKind.none) return;

    setState(() => _writing = true);
    // **What this check found newer than what this mod holds.** A pick below
    // the newest of them records the rest as passed over, and the group needs
    // it to tell a sibling that wants this file from one that has already gone
    // past it — see `sibling_group.dart`. The section's own list, because a
    // folder holding two downloads has one per layer.
    final published =
        (section?.check ?? _stored)?.newerFiles ?? const <GbFile>[];
    // Base by layout, patch by placement, and the verdicts the write settles are cleared inside.
    final outcome = await _writes.track(
      applyModUpdate(
        context,
        ref,
        mod: widget.mod,
        subject: subject,
        file: file,
        published: published,
        patchFlow: _gateway.applyPatchUpdate,
      ),
      (outcome) => outcome.changed,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (outcome.changed) Navigator.of(context).pop();
  }

  /// Opens this mod's page in the in-app marketplace.
  ///
  /// Two lines because the marketplace already owns "show me mod N" as state —
  /// and it is the only place in the app that can actually fetch a file.
  void _openInMarketplace(int modId) {
    ref.read(marketplaceOpenModProvider.notifier).state = modId;
    ref.read(destinationProvider.notifier).state = AppDestination.browse;
    Navigator.of(context).pop();
  }

  /// Takes this patch out of the folder, through the flow the context menu uses.
  ///
  /// Closes on success for the same reason [_applyUpdate] does: the sections are
  /// built from the block this dialog read when it opened, and one of the layers
  /// they describe is now gone. The flow drops the folder's session verdict.
  Future<void> _removePatch(_Section section) async {
    setState(() => _writing = true);
    final removed = await _writes.track(
      removePatchFlow(
        context,
        mod: widget.mod,
        patch: section.download,
        patchName: layerLine(section.name, section.file),
      ),
      (removed) => removed,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (removed) Navigator.of(context).pop();
  }

  /// Whether this section's layer is one the folder can be asked to give up.
  ///
  /// Through [removablePatches] rather than its own test, so "which patches can
  /// come out" is one rule: the context menu and this offer the same set, and a
  /// layer with no file registry is excluded by both.
  bool _removablePatch(_Section section) {
    if (!section.isPatch) return false;
    return removablePatches(widget.mod.origin)
        .any((patch) => patch.modId == section.download.modId);
  }

  // --------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final check = _stored;
    final sections = check == null || _checking ? const <_Section>[] : _sections(check);
    final view = _checking
        ? _View(title: loc.t('mods.update.title', params: {'mod': widget.mod.name}), body: [const UpdateSpinner()])
        : _error != null
        ? _View(title: loc.t('mods.update.title', params: {'mod': widget.mod.name}), body: _failure())
        : check == null
        ? _View(
            title: loc.t('mods.update.title', params: {'mod': widget.mod.name}),
            body: [UpdateHint(loc.t('mods.update.not_checked'))],
          )
        : sections.length >= 2
        ? _mixedView(sections)
        : _soleView(check, sections.isEmpty ? null : sections.single);

    final character = libraryGroupName(libraryGroupOf(widget.mod.characterId), loc);
    final state = loc.t(widget.mod.isActive ? 'mods.update.state_on_now' : 'mods.update.state_off_now');

    // Every close is a plain pop, Escape and a click outside included: whether anything was written is
    // `ModUpdateWrites`'s answer, never the route's result.
    return ZenithDialog.sectioned(
      width: 640,
      coverHeader: true,
      closeAlignsStart: false,
      leading: ModThumb(mod: widget.mod, width: 64, height: 44, radius: 8, spacing: 7, bordered: true),
      title: view.title,
      subtitle: '${widget.mod.name} · $character · $state',
      bodyPadding: view.bodyPadding,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 14,
        children: view.body,
      ),
      footerStart: view.footerStart,
      actions: view.actions ?? [_closeButton()],
    );
  }

  Widget _closeButton() =>
      OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(loc.t('mods.update.close')));

  Widget _laterButton() =>
      OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(loc.t('mods.update.later')));

  /// The couldn't-reach-GameBanana state, and **the only place a retry is
  /// offered**.
  ///
  /// There is deliberately no general "check again" button. Either the bulk
  /// pass has just answered this mod, in which case re-asking spends a request
  /// to redraw the same sentence, or the dialog opened with nothing on record
  /// and checked on the way in — neither leaves the user anything to press. A
  /// check that *failed* is the one case that does, and without this the only
  /// way to retry is closing and reopening.
  List<Widget> _failure() => [
    UpdateHint(loc.t('mods.update.check_failed')),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        style: smallButtonStyle(context),
        onPressed: _busy ? null : () => _check(refresh: true),
        icon: const Icon(Icons.refresh_rounded),
        label: Text(loc.t('mods.update.retry')),
      ),
    ),
  ];

  /// A folder of one download, or none that the record names.
  _View _soleView(UpdateCheck check, _Section? sole) {
    final section = sole ??
        _Section(
          // A folder with nothing recorded still renders one card: the verdict is `untracked` or `trackingOff`, and
          // there is no layer to attribute it to.
          download: const ModDownload(),
          key: null,
          name: widget.mod.name,
          check: check,
        );
    final modId = widget.mod.origin?.base?.modId;
    if (!(check.hasUpdate || check.dismissed)) return _quietView(section, modId);
    if (_ignoredHere) return _ignoredView(check, section);

    // **A verdict about either half of the folder can be installed**, because the write is chosen by which half it is:
    // base by layout with the patch placed back on top, patch by placement over the base. What is refused is a verdict
    // about a mod this folder does not claim to hold, which no write could apply without overwriting one mod with
    // another. There the files are listed and there is no Update, rather than a button that can never be pressed.
    final route = updateWriteRoute(origin: widget.mod.origin, subject: check.subject);
    final writable = modId != null && route.kind != UpdateWriteKind.none;
    final installable = writable ? _fileToInstall(section) : null;
    final files = check.newerFiles;
    final post = modId == null ? null : latestUpdatePost(_updatesByMod[modId], since: check.comparedAgainst);

    return _View(
      title: files.isEmpty
          ? loc.t(_verdictKey(check.outcome))
          : loc.plural('mods.update.newer_title', files.length, params: {'count': '${files.length}'}),
      body: [
        if (files.isNotEmpty) UpdateHint(loc.t('mods.update.intro'), prose: true),
        ..._layerBody(section),
        if (modId != null) _postOrLink(post, modId),
        if (installable case final file?) ..._siblingNotice(file),
      ],
      footerStart: _ignoreButton(section, check, collapse: true),
      actions: [
        _laterButton(),
        if (files.isNotEmpty && writable)
          FilledButton(
            key: const ValueKey('update_apply'),
            onPressed: _busy || installable == null ? null : () => _applyUpdate(section, installable),
            child: Text(loc.t('mods.update_apply.action')),
          ),
      ],
    );
  }

  /// The collapsed state after Ignore: what was ignored, and Undo.
  _View _ignoredView(UpdateCheck check, _Section section) {
    final count = check.newerFiles.isEmpty ? 1 : check.newerFiles.length;
    return _View(
      title: loc.t('mods.update.ignored_title'),
      bodyPadding: const EdgeInsets.fromLTRB(24, 4, 24, 22),
      body: [
        UpdateHint(
          loc.plural('mods.update.ignored_body', count, params: {'count': '$count', 'mod': widget.mod.name}),
          prose: true,
        ),
        UpdateHint(loc.t('mods.update.ignored_note')),
      ],
      footerStart: TextButton(
        key: const ValueKey('update_undo'),
        onPressed: _busy ? null : () => _setDismissed(section, false, collapse: true),
        child: Text(loc.t('library.updates.undo')),
      ),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(loc.t('mods.update.done')))],
    );
  }

  /// A verdict with nothing to install: up to date, not tracked, not comparable, the page gone.
  _View _quietView(_Section section, int? modId) {
    final check = section.check;
    return _View(
      title: loc.t(_verdictKey(check.outcome)),
      body: [..._quietBody(section)],
      footerStart: modId == null
          ? null
          : TextButton(
              onPressed: () => launchExternalUrl(context, gameBananaModUrl(modId)),
              child: Text(loc.t('mods.update.open_page')),
            ),
    );
  }

  /// A folder holding a patch as well as the mod it patches: one block for each, with its own Ignore and Update
  /// beside its own files, because a shared button would have to pick which mod it means and picking wrong writes
  /// another mod's archive over this folder.
  ///
  /// Each layer with a finding carries its page's latest update post and the link to compare on it. Two layers of one
  /// page share a feed, so the second one leaves both to the first.
  _View _mixedView(List<_Section> sections) {
    final postedFor = <int>{};
    return _View(
      title: loc.t('mods.update.title', params: {'mod': widget.mod.name}),
      body: [
        for (final (index, section) in sections.indexed) ...[
          if (index > 0) Divider(height: 1, color: ZenithPalette.of(context).divider),
          _layerHeader(section),
          if (section.check.hasUpdate || section.check.dismissed) ...[
            ..._layerBody(section, verdict: true),
            if (section.modId case final id? when postedFor.add(id))
              _postOrLink(latestUpdatePost(_updatesByMod[id], since: section.check.comparedAgainst), id),
            _layerActions(section),
          ] else
            ..._quietBody(section, verdict: true),
        ],
      ],
    );
  }

  /// The part of a block that is about its files: the "You have" box, and the newer ones to pick from. [verdict] says
  /// the layer's verdict in words first, for a block of a mixed folder with no title of its own to carry it.
  List<Widget> _layerBody(_Section section, {bool verdict = false}) {
    final check = section.check;
    final files = check.newerFiles;
    final picked = _fileToInstall(section);
    return [
      if (verdict) UpdateHint(loc.t(_verdictKey(check.outcome)), prose: true),
      if (check.dismissed) UpdateStrip(loc.t('mods.update.dismissed')),
      UpdateGroup(label: loc.t('mods.update.you_have'), child: _youHave(section)),
      if (files.isEmpty)
        UpdateHint(loc.t('mods.update.no_successor'))
      else
        UpdateGroup(
          label: loc.t('mods.update.newer_label'),
          child: FileRadioGroup(
            label: loc.t('mods.update.newer_label'),
            rows: [
              for (final file in files)
                FileRadioRow(
                  file: file,
                  selected: file.idRow == picked?.idRow,
                  chip: _pickChip(section, file, picked),
                  onTap: _busy || section.key == null
                      ? null
                      // Keyed by layer, so choosing a file for the patch cannot silently become the choice for the mod
                      // it patches, even from one page.
                      : () => setState(() => _chosenFileIdBy[section.key!] = file.idRow),
                ),
            ],
          ),
        ),
      if (check.isGuess && check.outcome != UpdateOutcome.untracked) UpdateHint(loc.t('mods.update.guess_caveat')),
    ];
  }

  /// What a verdict with nothing to install says: what the mod holds, and why there is no update.
  ///
  /// [verdict] says it in words, for a layer of a mixed folder whose block has no title of its own to carry it.
  List<Widget> _quietBody(_Section section, {bool verdict = false}) {
    final check = section.check;
    return [
      if (verdict) UpdateHint(loc.t(_verdictKey(check.outcome)), prose: true),
      if (check.installedFile != null || section.download.hasIdentity)
        UpdateGroup(label: loc.t('mods.update.you_have'), child: _youHave(section)),
      if (check.isObsolete) UpdateHint(loc.t('mods.update.obsolete')),
      if (check.outcome == UpdateOutcome.untracked) UpdateHint(loc.t('mods.update.untracked_hint')),
      if (check.outcome == UpdateOutcome.versionUnknown) UpdateHint(loc.t('mods.update.version_unknown_hint')),
      if (check.outcome == UpdateOutcome.tracksPatchOnly) UpdateHint(loc.t('mods.update.verdict_patch_only_detail')),
      if (check.isGuess && check.outcome != UpdateOutcome.untracked) UpdateHint(loc.t('mods.update.guess_caveat')),
    ];
  }

  /// The grounds of the row the Update button would install: why the app picked it, or that the user did. Only where
  /// there is a choice to make.
  ZenithBadge? _pickChip(_Section section, GbFile file, GbFile? picked) {
    final check = section.check;
    if (check.newerFiles.length < 2 || picked == null || file.idRow != picked.idRow) return null;
    final palette = ZenithPalette.of(context);
    // Only the check's *own* pick may claim grounds. Once the user has tapped a row the chip says so, rather than the
    // app taking credit for their decision under a label it did not choose.
    if (_chosenFileIdBy[section.key] != null) {
      return ZenithBadge(label: loc.t('mods.update.pick_chosen'), tone: palette.badgeInfo, small: true);
    }
    return check.candidateMatchesVariant
        ? ZenithBadge(label: loc.t('mods.update.pick_variant'), tone: palette.badgeInfo, small: true)
        : ZenithBadge(label: loc.t('mods.update.pick_newest'), tone: palette.badgeNeutral, small: true);
  }

  /// The file the layer holds, preferring the published record and falling back to what the sidecar stored.
  ///
  /// The fallback is the interesting half: the strongest verdict this feature produces is "the file you installed is
  /// gone from the mod page", and in exactly that case there is no published record left to describe. Saying
  /// "unknown" there would contradict the verdict beside it.
  Widget _youHave(_Section section) {
    // **This layer's own record, not the folder's.** Every layer carries its own `version` / `version_label`, and
    // reading another's here would describe the wrong download.
    final label = summarizeDownload(
      section.download,
      provenance: widget.mod.origin?.provenance ?? OriginProvenance.importedFolder,
    ).versionLabel;
    return YouHaveBox.parts(YouHaveParts.of(loc, section.check, recordedLabel: label));
  }

  /// "Ignore" against a live finding; "Stop ignoring it" once ignored. The undo sits in the same place as the thing it
  /// undoes, so a user who ignored the wrong mod does not have to work out where it went.
  Widget? _ignoreButton(_Section? section, UpdateCheck check, {bool collapse = false}) {
    if (check.dismissed) {
      return TextButton(
        key: const ValueKey('update_stop_ignoring'),
        onPressed: _busy ? null : () => _setDismissed(section, false, collapse: collapse),
        child: Text(loc.t('mods.update.undismiss')),
      );
    }
    if (!check.hasUpdate) return null;
    return TextButton.icon(
      key: const ValueKey('update_ignore'),
      onPressed: _busy || check.dismissableUpTo == null ? null : () => _setDismissed(section, true, collapse: collapse),
      icon: const Icon(Icons.visibility_off_outlined),
      label: Text(loc.t('library.updates.ignore')),
    );
  }

  /// Ignore and Update for one layer of a mixed folder.
  Widget _layerActions(_Section section) {
    final check = section.check;
    final installable = _fileToInstall(section);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _ignoreButton(section, check) ?? const SizedBox.shrink(),
        if (check.newerFiles.isNotEmpty)
          FilledButton(
            key: ValueKey('update_apply_${section.key?.role.name}'),
            onPressed: _busy || installable == null ? null : () => _applyUpdate(section, installable),
            child: Text(loc.t('mods.update_apply.action')),
          ),
      ],
    );
  }

  /// Names the download a block is about, and marks a patch as one.
  ///
  /// **The marker is a badge, not a position.** Which download a sidecar stores first is install order, so a patch has
  /// to be legible as a patch wherever it sits — see `docs/origin-tracking.md` §10.
  Widget _layerHeader(_Section section) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final file = section.file;
    return Row(
      spacing: 8,
      children: [
        ZenithBadge(
          label: loc.t(section.isPatch ? 'mods.folder.role_patch' : 'mods.folder.role_mod'),
          tone: section.isPatch ? palette.badgeNeutral : palette.badgeOn,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section.name, style: text.titleSmall?.copyWith(color: palette.text)),
              // Two layers of one page carry one name, so each names its file, with the variant text in grey beneath
              // (update-checks §7).
              if (file != null) ...[
                Text(file.name, style: text.bodySmall?.copyWith(color: palette.text2)),
                if (file.detail case final detail?) Text(detail, style: text.bodySmall?.copyWith(color: palette.text3)),
              ],
            ],
          ),
        ),
        if (section.modId case final id?)
          IconButton(
            style: smallButtonStyle(context, iconOnly: true),
            icon: const Icon(Icons.open_in_new_rounded),
            tooltip: loc.t('mods.folder.open_page'),
            onPressed: () => launchExternalUrl(context, gameBananaModUrl(id)),
          ),
        // **On the layer, not in the row of buttons below it.** Those two act on the update being reported; this acts
        // on whether the folder holds this patch at all, which is a different question about a different thing — and
        // the surface reporting a patch's update is where a user meets the patch they no longer have.
        if (_removablePatch(section))
          PopupMenuButton<_PatchAction>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: loc.t('mods.update.patch_menu'),
            enabled: !_busy,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _PatchAction.remove,
                child: Row(
                  spacing: 8,
                  children: [
                    const Icon(Icons.layers_clear_outlined),
                    Expanded(child: Text(loc.t('mods.context_menu.remove_patch'), overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ],
            onSelected: (_) => _removePatch(section),
          ),
      ],
    );
  }

  /// The author's latest update post with the link to compare on the mod's page, or the link alone when no post says
  /// anything.
  Widget _postOrLink(GbUpdate? post, int modId) {
    final palette = ZenithPalette.of(context);
    final link = ZenithLink(
      loc.t('mods.update.compare_link'),
      onTap: () {
        if (!_busy) _openInMarketplace(modId);
      },
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.link, decoration: TextDecoration.underline),
    );
    if (post == null) return Align(alignment: Alignment.centerLeft, child: link);
    return LatestUpdatePost(post: post, footer: Align(alignment: Alignment.centerLeft, child: link));
  }

  /// "2 other mods came from this archive."
  ///
  /// **It promises nothing about them**, deliberately. Whether each one's folder
  /// still matches this archive needs the archive, which is not downloaded yet
  /// — so this says how many share the download and leaves the offer to the
  /// confirmation, which can answer it.
  List<Widget> _siblingNotice(GbFile file) {
    final library = _library;
    final modId = widget.mod.origin?.base?.modId;
    if (library == null || modId == null) return const <Widget>[];

    final waiting = siblingsAwaiting(
      primary: widget.mod,
      library: library,
      subjectModId: modId,
      target: file,
      published: _stored?.newerFiles ?? const <GbFile>[],
    );
    if (waiting.isEmpty) return const <Widget>[];

    return [
      UpdateHint(loc.plural('mods.update.siblings', waiting.length, params: {'count': '${waiting.length}'})),
    ];
  }

  /// The headline of an outcome, one switch because the dialog's title and each layer's verdict say the same thing and
  /// a missing key renders as its own dotted path rather than throwing.
  String _verdictKey(UpdateOutcome outcome) => switch (outcome) {
    UpdateOutcome.updateAvailable => 'mods.update.verdict_update',
    UpdateOutcome.possiblyOutdated => 'mods.update.verdict_possibly',
    UpdateOutcome.upToDate => 'mods.update.verdict_current',
    UpdateOutcome.tracksPatchOnly => 'mods.update.verdict_patch_only',
    UpdateOutcome.versionUnknown => 'mods.update.verdict_version_unknown',
    UpdateOutcome.untracked => 'mods.update.verdict_untracked',
    UpdateOutcome.trackingOff => 'mods.update.verdict_tracking_off',
    UpdateOutcome.sourceGone => 'mods.update.verdict_source_gone',
    UpdateOutcome.indeterminate => 'mods.update.verdict_indeterminate',
  };
}

/// What [_ModUpdateDialogState.build] hands the dialog frame: the title, the body's blocks, and the footer.
class _View {
  const _View({
    required this.title,
    required this.body,
    this.footerStart,
    this.actions,
    this.bodyPadding = const EdgeInsets.fromLTRB(24, 0, 24, 18),
  });

  final String title;
  final List<Widget> body;
  final Widget? footerStart;

  /// Null leaves the dialog's one Close button.
  final List<Widget>? actions;
  final EdgeInsets bodyPadding;
}
