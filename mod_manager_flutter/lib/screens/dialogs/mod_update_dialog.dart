import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_origin.dart';
import '../../services/api_service.dart';
import '../../services/gamebanana/file_selection.dart';
import '../../services/update_check.dart';
import '../../utils/gamebanana_url.dart';
import '../../utils/marketplace_providers.dart';
import '../../utils/state_providers.dart';
import '../../utils/url_utils.dart';
import '../components/mod_status_slot.dart';

/// One mod's update verdict, and the honest set of things a user can do about
/// it today.
///
/// Both entry points land here — the context menu's "check for updates", which
/// arrives with nothing on record, and the card's blue badge, which arrives
/// with a verdict from the last bulk pass. The difference is only whether a
/// request is made on open, so they are one dialog rather than two.
///
/// **There is no "update now" button, and its absence is deliberate rather than
/// unfinished-looking.** Replacing a mod folder in place is a separate piece of
/// work with its own hazards (the folder is usually a live symlink target, the
/// sidecar lives inside it, the user's `.ini` edits have to survive). Offering a
/// button that silently installed a *second* copy alongside the first would be
/// worse than offering none — so the marketplace shortcut below says exactly
/// that in one sentence instead of implying otherwise.
/// Returns true when it wrote to the sidecar, so the caller can rescan — a
/// dismissal lands in the origin block, which only a scan re-reads.
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

  /// Mirrors the sidecar edit this dialog has made, so the verdict on screen
  /// tracks it without waiting for a rescan the caller owns.
  DateTime? _dismissedUntil;
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
    });
    try {
      final client = ref.read(gameBananaClientProvider);
      // Both at once. The release feed is what tells a co-released *variant*
      // apart from a successor, and without it this dialog would show the
      // unrefined verdict the badge no longer shows — the two must agree.
      final profile = await client.modProfile(modId, refresh: refresh);
      // A mod with no update posts is normal, and a feed that fails to load is
      // not a failed check: the groups can only ever *remove* a flag, so their
      // absence leaves the honest, louder answer.
      List<GbUpdate> updates;
      try {
        updates = await client.modUpdates(modId, refresh: refresh);
      } catch (_) {
        updates = const <GbUpdate>[];
      }
      if (!mounted) return;
      setState(() {
        _checking = false;
        _profile = profile;
        _releases = ReleaseGroups.fromUpdates(updates);
        _updates = updates;
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
      origin = _dismissedUntil == null
          ? origin.withUpdatesUndismissed()
          : origin.copyWith(updatesDismissedUntil: _dismissedUntil);
    }
    return checkForUpdate(origin: origin, remote: profile, releases: _releases);
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

    setState(() => _writing = true);
    final ok = await widget.gateway.writeOrigin(widget.mod.id, (current) {
      if (current == null) return null;
      return dismissed
          ? current.copyWith(updatesDismissedUntil: until)
          : current.withUpdatesUndismissed();
    });
    if (!mounted) return;
    setState(() {
      _writing = false;
      if (!ok) return;
      _dismissedUntil = until;
      _dismissalEdited = true;
      _wrote = true;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loc.t(
              'mods.update.dismiss_failed',
              params: {'mod': widget.mod.name},
            ),
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    // Flipped on the verdict already in hand, **not** re-folded from a mod page.
    // Opened from a card badge this dialog never fetches one — the bulk pass
    // answered — so a re-fold produced null and updated nothing, which is
    // exactly how a successful write came to look like a dead button.
    _store(current.asDismissed(dismissed));
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
            FilledButton(
              onPressed: _busy ? null : () => _openInMarketplace(modId),
              child: Text(loc.t('mods.update.open_marketplace')),
            )
          else
            TextButton(
              onPressed: () => Navigator.of(context).pop(_wrote),
              child: Text(loc.t('mods.update.close')),
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
                  _fileDescription(candidate),
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
      // The caveat the locked decision requires, and it is placed *below* the
      // facts rather than above them: it qualifies the verdict, it is not the
      // verdict. Shown for every guessed answer, including the ones that came
      // back clean — "probably nothing new" and "nothing new" are different
      // claims and the weaker one must not borrow the stronger's certainty.
      if (check.isGuess && check.outcome != UpdateOutcome.untracked) ...[
        const SizedBox(height: 10),
        Text(
          loc.t('mods.update.guess_caveat'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
      if (check.hasUpdate) ...[
        const SizedBox(height: 10),
        Text(
          loc.t('mods.update.manual_note'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 2),
      Text(
        loc.t('mods.update.options_hint'),
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
                isPick: file.idRow == check.candidate?.idRow,
                matchesVariant: check.candidateMatchesVariant,
              ),
          ],
        ),
      ),
    ];
  }

  Widget _optionRow(
    GbFile file, {
    required bool isPick,
    required bool matchesVariant,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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
                  _fileLabel(file),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (isPick)
                  _chip(
                    loc.t(
                      matchesVariant
                          ? 'mods.update.pick_variant'
                          : 'mods.update.pick_newest',
                    ),
                    scheme.onPrimary,
                    background: ModStatusSlot.updateBlue,
                  ),
                if (_releaseName(file) case final release?)
                  _chip(release, scheme.primary),
              ],
            ),
            if (file.dateAdded case final date?)
              Text(
                _formatDate(date),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
          ],
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
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
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
        Icon(icon, size: 20, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            loc.t(key),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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
    if (check.installedFile case final file?) return _fileDescription(file);
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

  /// Version **and** variant label, where the marketplace's file list shows
  /// only the label.
  ///
  /// The "you have" and "published" lines sit directly above one another and
  /// are frequently the same variant of the same mod — `Main file` against
  /// `Main file` — so the label alone would render the before and after
  /// identically and leave the date as the only difference. `7.4 · Main file`
  /// against `7.7 · Main file` is the comparison the user opened this for.
  /// Joined the same way the resolve dialog joins them, so one reads as the
  /// other.
  String _fileLabel(GbFile file) {
    final version = file.version?.trim();
    return version == null || version.isEmpty
        ? fileDisplayLabel(file)
        : '$version · ${fileDisplayLabel(file)}';
  }

  /// [_fileLabel] with the upload date appended, for the one-line form. The
  /// option rows put the date on its own line instead, so they use the label.
  String _fileDescription(GbFile file) {
    final date = file.dateAdded;
    return date == null
        ? _fileLabel(file)
        : '${_fileLabel(file)} — ${_formatDate(date)}';
  }

  // ---------------------------------------------------------------- fragments

  Widget _line(IconData icon, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
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
          Icon(icon, size: 15, color: ModStatusSlot.amber),
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
