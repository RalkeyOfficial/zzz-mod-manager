import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_origin.dart';
import '../../services/api_service.dart';
import '../../utils/notifications.dart';
import '../../services/gamebanana/file_selection.dart';
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
  List<GbUpdate> _updates = const <GbUpdate>[];

  /// The **other** mods in this folder, by remote id.
  ///
  /// A mixed folder holds a patch plus the mod it patches, and the origin block
  /// names one of them. Without these the fold has nothing to say about the
  /// other half and answers `indeterminate` — on the one screen the user
  /// deliberately opened to find out.
  Map<int, GbMod> _companionProfiles = const <int, GbMod>{};
  Map<int, ReleaseGroups> _companionReleases = const <int, ReleaseGroups>{};

  /// Whether the release feed has been asked for at all.
  ///
  /// Opened from a card badge this dialog fetches nothing — the bulk pass
  /// already answered — so the notes are behind a button rather than costing a
  /// request every time somebody looks at a verdict they have already seen.
  bool _notesRequested = false;
  bool _loadingNotes = false;

  /// Whether the accordion is open. Starts closed even when a check has already
  /// fetched the feed: the verdict is what the dialog is for, and release notes
  /// are what you open when you have decided to care.
  bool _notesOpen = false;

  /// Which published file the update would install, when the user has chosen.
  ///
  /// Null means "whatever the check would pick". Only ever set by tapping a row,
  /// and only offered when there is more than one — with a single candidate
  /// there is nothing to choose between and a selection control would be a
  /// question with one answer.
  int? _chosenFileId;

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
    final modId = origin?.modId;
    if (modId == null || verdictWithoutAsking(origin) != null) return;
    setState(() {
      _checking = true;
      _error = null;
      // The list this selection indexed into is about to be replaced. Keeping
      // it means a row the author has since archived falls back to the app's
      // own candidate while still wearing the `your choice` chip — the app
      // taking credit for a decision the user did not make, which is precisely
      // what that chip exists to prevent.
      _chosenFileId = null;
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
      for (final companion in origin!.companions) {
        try {
          companionProfiles[companion.modId] =
              await fetchModRecord(client, companion.modId, refresh: refresh);
        } catch (_) {
          continue;
        }
        try {
          companionReleases[companion.modId] = ReleaseGroups.fromUpdates(
            await client.modUpdates(companion.modId, refresh: refresh),
          );
        } catch (_) {
          // As above: groups can only ever remove a flag, so their absence
          // leaves the louder, honest answer.
        }
      }

      if (!mounted) return;
      setState(() {
        _checking = false;
        _profile = profile;
        _releases = ReleaseGroups.fromUpdates(updates);
        _updates = updates;
        _companionProfiles = companionProfiles;
        _companionReleases = companionReleases;
        // The check already paid for the feed, so the notes are simply there.
        _notesRequested = true;
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
  Future<void> _loadNotes() async {
    final modId = widget.mod.origin?.modId;
    if (modId == null || _loadingNotes) return;
    setState(() {
      _loadingNotes = true;
      _notesRequested = true;
    });
    try {
      final updates = await ref.read(gameBananaClientProvider).modUpdates(modId);
      if (!mounted) return;
      setState(() {
        _updates = updates;
        _loadingNotes = false;
      });
    } catch (_) {
      // A feed that won't load is not a failed anything: the verdict beside it
      // is unaffected, and a mod with no update posts renders identically.
      if (!mounted) return;
      setState(() => _loadingNotes = false);
    }
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
      // **Onto the identity it was written to.** Re-applied to the primary, a
      // companion's dismissal both fails to silence the companion and silences
      // the folder's own mod.
      origin = origin.withDismissal(
        subject: _dismissedSubject,
        until: _dismissedUntil,
      );
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
  Future<void> _setDismissed(bool dismissed) async {
    final current = _stored;
    if (current == null) return;
    final until = dismissed ? current.dismissableUpTo : null;
    if (dismissed && until == null) return;

    // A dismissal belongs to the identity whose releases it waves away, not to
    // the folder. Written onto the primary, a companion's dismissal silences
    // nothing — the companion carries its own — and stamps another mod's date
    // onto this block.
    final subject = current.subjectModId;

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
    // Flipped on the verdict already in hand, **not** re-folded from a mod page.
    // Opened from a card badge this dialog never fetches one — the bulk pass
    // answered — so a re-fold produced null and updated nothing, which is
    // exactly how a successful write came to look like a dead button.
    _store(current.asDismissed(dismissed));
  }

  /// The file the Update button would install.
  ///
  /// The user's tap wins; otherwise it is the check's own pick, which the list
  /// already labels with the grounds it was chosen on. Null when the check named
  /// nothing at all — the installed file is gone and none of the current files
  /// is identifiably its replacement — and the button is absent rather than
  /// disabled there, because the honest action then is the mod page.
  GbFile? _fileToInstall(UpdateCheck? check) {
    if (check == null) return null;
    if (_chosenFileId case final id?) {
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
  Future<void> _applyUpdate(GbFile file) async {
    final check = _stored;
    // The identity this file belongs to, which is the folder's own only when the
    // verdict is about it. A companion's file recorded against the primary would
    // claim this folder is that other mod.
    final subject = check?.subjectModId;
    final modId = subject ?? widget.mod.origin?.modId;
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
    final modId = widget.mod.origin?.modId;
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
    final installable =
        modId == null || !hasFinding || route.kind == UpdateWriteKind.none
            ? null
            : _fileToInstall(check);

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
                  ..._verdict(check),
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
          if (check?.dismissed ?? false)
            TextButton(
              onPressed: _busy ? null : () => _setDismissed(false),
              child: Text(loc.t('mods.update.undismiss')),
            )
          else if (check?.hasUpdate ?? false)
            TextButton(
              onPressed: _busy || (check?.dismissableUpTo == null)
                  ? null
                  : () => _setDismissed(true),
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
              onPressed: _busy ? null : () => _applyUpdate(file),
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

  List<Widget> _verdict(UpdateCheck check) {
    final scheme = Theme.of(context).colorScheme;
    return [
      _headline(check),
      // Everything below describes a different mod from the one the folder is
      // named after, so it is said before any of it rather than left to notice.
      if (check.subjectModId case final subject?) ...[
        const SizedBox(height: 8),
        _notice(
          loc.t('mods.update.about_companion', params: {
            // The bulk pass's records too, not just this dialog's own fetch:
            // opened from a card badge nothing is fetched here, and that is
            // the common way to arrive at a verdict somebody wants explained.
            'mod': (_companionProfiles[subject] ??
                        ref.read(modUpdateRecordsProvider)[subject])
                    ?.name ??
                '#$subject',
            'folder': widget.mod.name,
          }),
          Icons.call_split,
        ),
      ],
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
              _installedDescription(check),
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
              if (_releaseName(check.candidate) case final release?) ...[
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
            if (check.comparedAgainst case final date?) ...[
              const SizedBox(height: 6),
              _line(
                Icons.event_outlined,
                loc.t('mods.update.compared_against'),
                _formatDate(date),
              ),
            ],
          ],
        ),
      ),
      if (check.newerFiles.length >= 2) ..._options(check),
      ..._releaseNotes(check),
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
  List<Widget> _options(UpdateCheck check) {
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
                isPick: file.idRow == _fileToInstall(check)?.idRow,
                // Only the check's *own* pick may claim grounds. Once the user
                // has tapped a row the chip says so, rather than the app taking
                // credit for their decision under a label it did not choose.
                pickLabelKey: _chosenFileId != null
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
  List<Widget> _releaseNotes(UpdateCheck check) {
    final modId = widget.mod.origin?.modId;
    if (modId == null) return const [];

    final since = check.comparedAgainst;
    final relevant = [
      for (final update in _updates)
        if (update.hasNotes &&
            (since == null || (update.dateAdded?.isAfter(since) ?? true)))
          update,
    ];
    // Nothing to offer, and nothing to say about it: a mod with no update posts
    // is ordinary, so an empty "Release notes" header would be noise.
    if (_notesRequested && !_loadingNotes && relevant.isEmpty) {
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
              onTap: _busy || _loadingNotes
                  ? null
                  : () {
                      if (!_notesRequested) {
                        setState(() => _notesOpen = true);
                        unawaited(_loadNotes());
                      } else {
                        setState(() => _notesOpen = !_notesOpen);
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
                    if (_loadingNotes)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _notesOpen ? Icons.expand_less : Icons.expand_more,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
            if (_notesOpen && !_loadingNotes && relevant.isNotEmpty)
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
    required bool isPick,
    required String pickLabelKey,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap:
            _busy ? null : () => setState(() => _chosenFileId = file.idRow),
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
                  if (_releaseName(file) case final release?)
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
    final (String key, IconData icon, Color colour) = switch (check.outcome) {
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

  /// What the user has, preferring the published record and falling back to
  /// what the sidecar stored.
  ///
  /// The fallback is the interesting half: the strongest verdict this feature
  /// produces is "the file you installed is gone from the mod page", and in
  /// exactly that case there is no published record left to describe. Saying
  /// "unknown" there would contradict the headline directly above it.
  String _installedDescription(UpdateCheck check) {
    if (check.installedFile case final file?) return _fileHeadline(file);
    final origin = widget.mod.origin;
    final parts = [
      if (origin?.version case final v? when v.isNotEmpty) v,
      if (origin?.versionLabel case final l? when l.isNotEmpty) l,
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    return loc.t('mods.update.unknown_file');
  }

  /// The update post that shipped [file], by name (`Version 1.5`).
  String? _releaseName(GbFile? file) {
    if (file == null) return null;
    for (final update in _updates) {
      if (!update.fileRowIds.contains(file.idRow)) continue;
      final name = update.name?.trim();
      return name == null || name.isEmpty ? null : name;
    }
    return null;
  }

  /// The filename with its upload date, for the compact "you have" /
  /// "published" pair. The author's own words go on the greyed line beneath —
  /// see [_fileDetail].
  String _fileHeadline(GbFile file) {
    final date = file.dateAdded;
    return date == null
        ? fileDisplayName(file)
        : '${fileDisplayName(file)} — ${_formatDate(date)}';
  }

  /// What the author said about the file, for the second line of those rows.
  ///
  /// It has to be *there*, not folded into the headline: those two rows sit
  /// directly above one another and are frequently the same variant of the
  /// same mod, so `7.4 · Main file` against `7.7 · Main file` is the comparison
  /// the user opened the dialog for. What changed is only that it no longer
  /// stands in for the filename.
  String? _fileDetail(GbFile file) => fileDisplayDetail(file);

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
