import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../models/origin_enums.dart';
import '../../services/origin_resolution.dart';
import '../../utils/state_providers.dart';
import '../components/resolve/file_choice_panel.dart';
import '../components/resolve/identity_search_panel.dart';
import '../components/resolve/resolve_fragments.dart';

/// The answer this step returns: a companion to record, or an instruction to
/// remove the one already there.
///
/// A sealed pair rather than a nullable `ModCompanion`, because "cancel" and
/// "there is no other mod after all" are different answers and only the second
/// may write.
sealed class CompanionOutcome {
  const CompanionOutcome();
}

class CompanionNamed extends CompanionOutcome {
  const CompanionNamed(this.companion, {this.modName, this.file});

  final ModDownload companion;

  /// The mod page's own name, when this step had the profile in hand.
  ///
  /// Carried so a caller can say *which* mod was recorded rather than printing
  /// an id. Not stored on the companion: a name is the remote's to change, and
  /// a sidecar holding a stale copy would be a second source of truth for it.
  final String? modName;

  /// The file row the user picked, when they picked one.
  ///
  /// The companion carries its id, which is enough to *describe* it and not
  /// enough to fetch it — a download needs the row itself. Carried so a caller
  /// that is about to install this mod does not have to re-fetch the profile to
  /// find the file the user was just looking at.
  ///
  /// **Null means they answered "I don't know which file"**, and that is the
  /// answer: there is nothing to install, only something to record.
  final GbFile? file;
}

class CompanionRemoved extends CompanionOutcome {
  const CompanionRemoved();
}

/// Names the **other download in this folder**, and which file of it.
///
/// A pushed step rather than a section of the resolve dialog, and that is a
/// constraint rather than a preference: that dialog is already at its height
/// budget — the file picker came down from 280 to 230 to pay for the identity
/// card's two lines — and its two escape hatches must stay one click from the
/// bottom. A second identity card inline spends the budget again and pushes
/// them below the fold.
///
/// What it may claim is narrower than what the primary step may:
///
/// - **Nothing here ever reaches `exact`.** We did not download these bytes;
///   the user is telling us what they put in the folder. `user` is the honest
///   ceiling, and the one path that beats it is an install that writes the
///   files itself.
/// - **The folder's own mod is refused**, when it has one. It is the same mod
///   said twice, and recording it would have the update check ask one page twice
///   and report two verdicts for one folder. A folder with no identity of its
///   own — dragged off a disk — has nothing to collide with, so nothing is
///   refused.
Future<CompanionOutcome?> showCompanionResolveDialog(
  BuildContext context, {
  required String modName,
  required int? primaryModId,
  ModDownload? existing,
}) {
  return showDialog<CompanionOutcome>(
    context: context,
    builder: (_) => CompanionResolveDialog(
      modName: modName,
      primaryModId: primaryModId,
      existing: existing,
    ),
  );
}

/// Confirms dropping a **patch the app installed into this folder** from the
/// record. True when the user said to.
///
/// A confirmation and not [showCompanionResolveDialog], because the two
/// directions are not the same question. That step searches for a mod and picks
/// a file, which is what naming a download nobody recorded requires. A patch
/// written by the install prompt already has both at `exact` — the app fetched
/// those bytes — so there is nothing to search for and nothing to choose, and
/// offering either would let the user re-aim an exact record at a mod page it
/// did not come from. What is left is the one thing the record cannot know on
/// its own: whether those files are still in the folder.
///
/// **It says what does not happen.** Nothing is deleted from disk, which is the
/// first thing a delete icon suggests. What stops is the watching.
///
/// [removable] means the app knows which files that patch put in the folder, so
/// there is a real uninstall for it. This still only forgets the record — a row
/// in a dialog about *tracking* must not quietly become a write that deletes and
/// restores files — but it names the menu entry that does the other thing, since
/// a user who came here to get rid of a patch would otherwise leave believing
/// they had.
Future<bool> showCompanionRemoveDialog(
  BuildContext context, {
  required String modName,
  bool removable = false,
}) async {
  final loc = context.loc;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(loc.t('mods.resolve.companion_remove_patch_title')),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              loc.t('mods.resolve.companion_remove_patch_body',
                  params: {'mod': modName}),
            ),
            if (removable) ...[
              const SizedBox(height: 10),
              Text(
                loc.t('mods.resolve.companion_remove_patch_uninstall'),
                style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(dialogContext).colorScheme.primary,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(loc.t('mods.resolve.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(loc.t('mods.resolve.companion_remove_patch_confirm')),
        ),
      ],
    ),
  );
  return answer ?? false;
}

class CompanionResolveDialog extends ConsumerStatefulWidget {
  const CompanionResolveDialog({
    super.key,
    required this.modName,
    required this.primaryModId,
    this.existing,
  });

  /// The folder's name — what the search is seeded with. A patch folder is
  /// usually named after the patch, which is a decent search for the mod it
  /// patches, and the user edits it either way.
  final String modName;

  /// The identity the folder already carries, refused as a companion. Null when
  /// it carries none, where there is nothing to refuse.
  final int? primaryModId;

  /// **No role is asked for and none is stored here.** This step names the mod
  /// that goes *underneath* — the folder is recorded as patch-shaped, so the
  /// answer is always the bottom of the stack, and making the user classify
  /// their own folder is a quiz whose answer the app already has. The write that
  /// inserts the layer takes the role from the position it lands in.
  final ModDownload? existing;

  @override
  ConsumerState<CompanionResolveDialog> createState() =>
      _CompanionResolveDialogState();
}

class _CompanionResolveDialogState
    extends ConsumerState<CompanionResolveDialog> {
  int? _modId;
  GbMod? _profile;
  Object? _profileError;
  bool _loading = false;

  GbFile? _selectedFile;

  /// "I don't know which file" — the **answer**, not the date it resolves to.
  ///
  /// The date is read from the profile at write time rather than stored,
  /// because a stored one outlives the identity it came from: answered for one
  /// mod and then changed to another, it records the first mod's creation date
  /// as the second's baseline. A baseline later than the mod it describes hides
  /// every file published before it, silently.
  bool _assumeLatest = false;

  @override
  void initState() {
    super.initState();
    _modId = widget.existing?.modId;
    if (_modId case final id?) _loadProfile(id);
  }

  AppLocalizations get loc => context.loc;

  bool get _isSelf =>
      widget.primaryModId != null && _modId == widget.primaryModId;

  Future<void> _loadProfile(int modId) async {
    setState(() {
      _loading = true;
      _profileError = null;
      _profile = null;
      // A new identity has not been answered for yet — neither answer carries
      // across, because both are about the mod that was picked before it.
      _selectedFile = null;
      _assumeLatest = false;
    });
    try {
      final profile = await ref.read(gameBananaClientProvider).modProfile(modId);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _profileError = e;
        _loading = false;
      });
    }
  }

  FileResolution get _resolution {
    final profile = _profile;
    if (profile == null) return FileResolution.empty;
    return rankResolveCandidates(
      files: profile.files,
      archivedFiles: profile.archivedFiles,
      // All three signals describe the download this folder was installed
      // from, not the one being named here. The folder name is the *patch's*,
      // so ranking the base mod's files by it can only mislead.
      folderName: '',
      installedAt: null,
      archiveMd5: null,
    );
  }

  void _add() {
    final modId = _modId;
    if (modId == null || _isSelf) return;
    final file = _selectedFile;
    // Read here rather than when the tile was tapped, so it can only ever be
    // the date of the mod being written.
    final baseline =
        file == null && _assumeLatest ? _profile?.dateAdded : null;
    Navigator.of(context).pop(
      CompanionNamed(
        ModDownload(
          // No role: this layer goes **underneath** the folder's patch, and the
          // write that inserts it is what sets the role from the position.
          modId: modId,
          // `user`, never `exact` — see the class doc.
          modIdConfidence: OriginConfidence.user,
          fileId: file?.idRow,
          version: file?.version,
          versionLabel: file?.description,
          versionConfidence: file != null
              ? OriginConfidence.user
              : baseline != null
                  ? OriginConfidence.assumedLatest
                  : OriginConfidence.unknown,
          baselineRemoteDate: baseline,
        ),
        modName: _profile?.name,
        file: file,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(loc.t('mods.resolve.companion_title')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_modId == null)
                IdentitySearchPanel(
                  seed: widget.modName,
                  heading: loc.t('mods.resolve.companion_heading'),
                  onPicked: (id) {
                    setState(() => _modId = id);
                    if (id != widget.primaryModId) _loadProfile(id);
                  },
                )
              else
                ..._bound(),
              if (widget.existing != null) ...[
                const Divider(),
                _removeTile(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.t('mods.resolve.cancel')),
        ),
        FilledButton(
          onPressed: _modId == null || _isSelf || _loading ? null : _add,
          child: Text(loc.t('mods.resolve.companion_add')),
        ),
      ],
    );
  }

  List<Widget> _bound() {
    final modId = _modId!;
    return [
      _identityCard(modId),
      const SizedBox(height: 12),
      if (_isSelf)
        resolveNotice(
            context, loc.t('mods.resolve.companion_is_self'), Icons.block)
      else if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_profileError != null)
        resolveNotice(
            context, loc.t('mods.resolve.load_failed'), Icons.cloud_off)
      else ...[
        // Nothing records which variant is in the folder, and rows with no
        // reasons on them would imply the app simply failed to rank rather
        // than that it cannot.
        resolveNotice(
          context,
          loc.t('mods.resolve.companion_file_unknown'),
          Icons.help_outline,
        ),
        FileChoicePanel(
          resolution: _resolution,
          heading: loc.t('mods.resolve.file_heading'),
          recordedFileId: widget.existing?.fileId,
          selectedFileId: _selectedFile?.idRow,
          // `isExact` is discarded: a banked-hash match is a fact about the
          // archive *this folder's primary* was extracted from, and it says
          // nothing about a download somebody dragged in beside it.
          onSelected: (file, _) => setState(() {
            _selectedFile = file;
            _assumeLatest = false;
          }),
        ),
        const SizedBox(height: 8),
        _dontKnowTile(),
      ],
    ];
  }

  Widget _identityCard(int modId) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _profile?.name ?? '#$modId',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _modId = null;
              _profile = null;
              _profileError = null;
              _selectedFile = null;
              _assumeLatest = false;
            }),
            child: Text(loc.t('mods.resolve.identity_change')),
          ),
        ],
      ),
    );
  }

  /// The same "I don't know which file" answer the primary step offers, applied
  /// to this identity. Its baseline is the other mod's own creation date rather
  /// than an install date: the folder has one install date and it belongs to
  /// the download we performed, not to this one.
  Widget _dontKnowTile() {
    final baseline = _profile?.dateAdded;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: baseline != null,
      leading: const Icon(Icons.help_outline, size: 20),
      title: Text(
        loc.t('mods.resolve.dont_know'),
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        baseline == null
            ? loc.t('mods.resolve.dont_know_unavailable')
            : loc.t('mods.resolve.dont_know_hint',
                params: {'date': formatResolveDate(baseline)}),
        style: const TextStyle(fontSize: 11),
      ),
      selected: _selectedFile == null && _assumeLatest,
      onTap: baseline == null
          ? null
          : () => setState(() {
                _selectedFile = null;
                _assumeLatest = true;
              }),
    );
  }

  Widget _removeTile() => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.delete_outline, size: 20),
        title: Text(
          loc.t('mods.resolve.companion_remove'),
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          loc.t('mods.resolve.companion_remove_hint'),
          style: const TextStyle(fontSize: 11),
        ),
        onTap: () => Navigator.of(context).pop(const CompanionRemoved()),
      );
}
