import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/character_info.dart';
import '../../models/gamebanana/gamebanana.dart';
import '../../models/mod_download.dart';
import '../../services/origin_summary.dart';
import '../../services/patch_destination_ranking.dart';
import '../components/resolve/resolve_fragments.dart';
import 'companion_resolve_dialog.dart';

/// Which rule found a patch, and so what the prompt may say about it.
///
/// The two are different evidence and the wording has to be: one download asks
/// for content it did not bring, the other brought content nothing can load.
enum PatchKind { references, assets }

/// One mod an install is about to create that looks like a patch.
class PatchInstallSubject {
  const PatchInstallSubject({
    required this.modName,
    required this.patchModId,
    required this.kind,
    this.destinations = const <DestinationRank>[],
  });

  /// The name the mod will have, which is what the prompt calls it.
  final String modName;

  /// The patch's **own** remote identity, refused as an answer: a folder cannot
  /// patch itself, and recording it would have the check ask one page twice.
  ///
  /// **Null for a folder dragged off a disk**, which has no mod page at all.
  /// Nothing is refused then, because there is no identity to collide with.
  final int? patchModId;

  final PatchKind kind;

  /// Every library folder, ordered by how well it answers for this patch.
  ///
  /// Empty when there was nothing to rank on, or when a combined install means
  /// no library destination is offered at all. Ordering is the whole of what it
  /// does: nothing is filtered out of it and nothing in it is selected — see
  /// `patch_destination_ranking.dart` for the measurement that settles that.
  final List<DestinationRank> destinations;
}

/// Where one patch's files go.
///
/// A sealed pair rather than a nullable folder id, because the two are different
/// operations rather than one with an option: [InstallAsNewMod] copies into a
/// folder that does not exist yet, while [InstallIntoMod] writes over a live one
/// and must take a snapshot first.
sealed class PatchDestination {
  const PatchDestination();
}

/// A folder of its own — the default, and the one that cannot destroy anything.
///
/// [base] is what the user said it patches, when they said. It is recorded as a
/// layer **underneath** the patch on the new folder: a statement about what that
/// folder is *going* to hold, since the patch alone does nothing until the mod
/// it patches is in there with it.
class InstallAsNewMod extends PatchDestination {
  const InstallAsNewMod({this.base, this.baseName, this.baseFile});

  final ModDownload? base;

  /// The base mod page's own name, for the row to say. Not stored on the
  /// layer — a name is the remote's to change.
  final String? baseName;

  /// The file of the base mod the install should **fetch and write into this
  /// folder first**, when the user picked one.
  ///
  /// Naming what a patch patches used to record the answer and install nothing,
  /// which left the folder not working — the thing naming it was supposed to
  /// fix. Null means they could not say which file, so there is nothing to
  /// fetch: the answer is recorded and the folder stays as it is.
  final GbFile? baseFile;
}

/// Into a library mod's folder, which ends up holding both downloads.
///
/// That folder keeps its own identity: its `origin` is still the base mod,
/// because that is still what it mostly is. The patch is recorded on it as a
/// `role: patch` companion — the one path to `exact` on a companion, since we
/// downloaded those bytes ourselves.
class InstallIntoMod extends PatchDestination {
  const InstallIntoMod({required this.modId, required this.modName});

  /// The library folder id, which is what the write path acts on.
  final String modId;

  final String modName;
}

/// Asks where a patch goes and what it patches, **at the moment the install
/// finds one**.
///
/// The warning on its own left a research task: read it, understand it, switch
/// tabs, find the folder among the rest of the library, press a badge. This is
/// the same question asked while the user is still looking at the screen and the
/// app still has everything it knows in hand.
///
/// **Two questions with different search spaces, and that is not a detail.**
/// "Where do the files go?" is answered by a **library folder**, because a
/// destination has to exist. "What mod does this patch?" is answered by a **mod
/// page**, because the mod being patched may not be installed at all — finding
/// the patch first is an ordinary way round. Answering the first with a library
/// mod answers the second for free, so it stops being asked.
///
/// Returns a destination per mod name — **null when the user declined the
/// install**, which only this prompt can offer because it is the last point
/// before anything is copied.
///
/// **Nothing here is answered for the user.** The destinations are ordered by
/// what the patch's own files and its author's requirement point at, and that is
/// where it stops: nothing is preselected, nothing is hidden, and the confirm
/// button stays dead until a folder is actually chosen. The measurement that
/// rules out anything stronger is in `docs/patch-destinations.md` — with the mod
/// a patch really patches *not* installed, a wrong folder still comes top with a
/// perfect score often enough that a preselected row would be a wrong answer
/// nobody looked at. The second question is stricter still: what gets recorded
/// there is a **mod page**, and the only thing that names one is the person who
/// went and found the patch.
Future<Map<String, PatchDestination>?> showPatchInstallPrompt(
  BuildContext context, {
  required List<PatchInstallSubject> subjects,
  required List<ModInfo> library,
  bool combined = false,
}) {
  return showDialog<Map<String, PatchDestination>>(
    context: context,
    // A patch installed without an answer is a folder that does nothing until
    // the user acts, so the question is worth their attention rather than one
    // stray tap outside it.
    barrierDismissible: false,
    builder: (_) => PatchInstallPrompt(
      subjects: subjects,
      library: library,
      combined: combined,
    ),
  );
}

class PatchInstallPrompt extends ConsumerStatefulWidget {
  const PatchInstallPrompt({
    super.key,
    required this.subjects,
    required this.library,
    this.combined = false,
  });

  final List<PatchInstallSubject> subjects;

  /// Every folder in the library, offered **whether or not it is tracked**. A
  /// destination needs no remote identity of its own: `role: patch` records the
  /// *patch's* id, not the target's.
  final List<ModInfo> library;

  /// Whether the import picker already chose to merge these folders into one
  /// mod. Merging several folders into a new mod and writing them into an
  /// existing one are different destinations, so the second is not offered.
  final bool combined;

  @override
  ConsumerState<PatchInstallPrompt> createState() => _PatchInstallPromptState();
}

class _PatchInstallPromptState extends ConsumerState<PatchInstallPrompt> {
  /// Mod name -> the answer so far. Absent means the default: its own folder,
  /// nothing named.
  final Map<String, PatchDestination> _chosen = <String, PatchDestination>{};

  /// Mod name -> whether the second destination is selected but unanswered.
  /// Held apart from [_chosen] because a selected radio with no mod picked is
  /// **not** an answer, and must not be confirmable.
  final Set<String> _wantsLibrary = <String>{};

  /// Mod name -> what has been typed into its library search.
  final Map<String, String> _queries = <String, String>{};

  AppLocalizations get loc => context.loc;

  bool get _canOfferLibrary => !widget.combined && widget.library.isNotEmpty;

  /// Every subject has a destination the install can act on.
  bool get _complete => widget.subjects.every(
        (subject) => !_wantsLibrary.contains(subject.modName) ||
            _chosen[subject.modName] is InstallIntoMod,
      );

  PatchDestination _destinationFor(String modName) =>
      _chosen[modName] ?? const InstallAsNewMod();

  Future<void> _ask(PatchInstallSubject subject) async {
    final current = _destinationFor(subject.modName);
    final outcome = await showCompanionResolveDialog(
      context,
      modName: subject.modName,
      primaryModId: subject.patchModId,
      existing: current is InstallAsNewMod ? current.base : null,
    );
    if (outcome == null || !mounted) return;
    setState(() {
      _chosen[subject.modName] = switch (outcome) {
        CompanionNamed(:final companion, :final modName, :final file) =>
          InstallAsNewMod(
            base: companion,
            baseName: modName,
            baseFile: file,
          ),
        CompanionRemoved() => const InstallAsNewMod(),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(loc.t('mods.patch_install.title')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final subject in widget.subjects) ..._block(subject),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.t('mods.patch_install.decline')),
        ),
        FilledButton(
          // An incomplete answer cannot be confirmed. Falling back to a new
          // folder would quietly do the opposite of what was asked for.
          onPressed: _complete
              ? () => Navigator.of(context).pop({
                    for (final subject in widget.subjects)
                      subject.modName: _destinationFor(subject.modName),
                  })
              : null,
          child: Text(
            loc.t(
              // "Anyway" only while nothing at all has been answered — a radio
              // moved but not completed is mid-answer, not a decision to skip,
              // and labelling it "install anyway" beside a disabled button
              // describes the wrong state.
              _chosen.isEmpty && _wantsLibrary.isEmpty
                  ? 'mods.patch_install.keep'
                  : 'mods.patch_install.confirm',
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _block(PatchInstallSubject subject) {
    final wantsLibrary = _wantsLibrary.contains(subject.modName);
    return [
      Text(
        loc.t(
          switch (subject.kind) {
            PatchKind.references => 'mods.patch_install.body_ini',
            PatchKind.assets => 'mods.patch_install.body_asset',
          },
          params: {'mod': subject.modName},
        ),
        style: const TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 8),
      _option(
        subject: subject,
        selected: !wantsLibrary,
        title: loc.t('mods.patch_install.destination_new'),
        hint: loc.t('mods.patch_install.destination_new_hint'),
        onTap: () => setState(() => _wantsLibrary.remove(subject.modName)),
      ),
      // Only under the destination it belongs to. Chosen a library mod, the
      // question is already answered — that folder's own origin *is* the base —
      // and asking again invites a contradictory second answer.
      //
      // Given room of its own: it belongs to the destination above it but is a
      // control rather than part of that option's text, and pressed up against
      // both it reads as a third radio row.
      if (!wantsLibrary)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: _baseRow(subject),
        ),
      if (_canOfferLibrary)
        _option(
          subject: subject,
          selected: wantsLibrary,
          title: loc.t('mods.patch_install.destination_into'),
          hint: loc.t('mods.patch_install.destination_into_hint'),
          onTap: () => setState(() => _wantsLibrary.add(subject.modName)),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            loc.t(widget.combined
                ? 'mods.patch_install.destination_combined'
                : 'mods.patch_install.destination_no_library'),
            style: const TextStyle(fontSize: 11),
          ),
        ),
      if (wantsLibrary) _libraryList(subject),
      const SizedBox(height: 12),
    ];
  }

  Widget _option({
    required PatchInstallSubject subject,
    required bool selected,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13)),
                    Text(hint, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// "What does this patch?", and what has been answered so far.
  Widget _baseRow(PatchInstallSubject subject) {
    final destination = _destinationFor(subject.modName);
    final base = destination is InstallAsNewMod ? destination.base : null;
    if (base == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _ask(subject),
          icon: const Icon(Icons.call_split, size: 16),
          label: Text(loc.t('mods.patch_install.record')),
        ),
      );
    }

    final named = destination as InstallAsNewMod;
    return Row(
      children: [
        Expanded(
          child: resolveNotice(
            context,
            // **Both halves of the answer.** The pushed step asks which mod
            // *and* which file, and a row naming only the mod leaves a recorded
            // file indistinguishable from "I don't know" — which are checked
            // differently, and one of them marks the card.
            '${loc.t('mods.patch_install.recorded', params: {
                  'mod': named.baseName ?? '#${base.modId}',
                })}\n${describeRecordedFile(loc, summarizeDownload(base))}',
            Icons.call_split,
          ),
        ),
        TextButton(
          onPressed: () => _ask(subject),
          child: Text(loc.t('mods.patch_install.change')),
        ),
      ],
    );
  }

  /// Every library folder, in the order the patch's own files suggest, **with
  /// nothing preselected**.
  ///
  /// A real library is long, and scrolling it reading every folder name was the
  /// whole cost this picker was adding — while the user arrives already knowing
  /// which mod they mean. So the box comes first and the picture does the
  /// recognising; a name is the slow way to know which mod you are looking at.
  ///
  /// **Ordering is as far as it goes.** A row that has something going for it
  /// says so, in one line, and every other folder is still in the list under it.
  /// `patch_destination_ranking.dart` holds the measurement that rules out
  /// anything stronger: with the patch's real target not installed, a wrong
  /// folder still comes top with a perfect score often enough that a preselected
  /// answer would be a wrong answer nobody looked at.
  ///
  /// Rows carry **folder name plus the recorded variant label**, because one
  /// archive routinely becomes several mods and several folders can be bound to
  /// the same `mod_id` — the label is the field that exists to stop two variants
  /// of one release reading as two releases, and this is exactly that case.
  /// Both are matched by the search, because **a list that displays something it
  /// will not match on looks broken when you type the thing you can see.**
  Widget _libraryList(PatchInstallSubject subject) {
    final destination = _destinationFor(subject.modName);
    final picked = destination is InstallIntoMod ? destination.modId : null;
    final query = (_queries[subject.modName] ?? '').trim().toLowerCase();
    final matches = [
      for (final candidate in _ordered(subject))
        if (query.isEmpty ||
            candidate.mod.name.toLowerCase().contains(query) ||
            (candidate.mod.origin?.base?.versionLabel
                    ?.toLowerCase()
                    .contains(query) ??
                false))
          candidate,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: loc.t('mods.patch_install.destination_search'),
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 13),
          onChanged: (value) =>
              setState(() => _queries[subject.modName] = value),
        ),
        // The first row's thumbnail sits flush against the box without this.
        const SizedBox(height: 8),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              loc.t('mods.patch_install.destination_no_match'),
              style: const TextStyle(fontSize: 11),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: matches.length,
              itemBuilder: (_, index) {
                final mod = matches[index].mod;
                final rank = matches[index].rank;
                final label = mod.origin?.base?.versionLabel;
                final reason = _reasonFor(rank);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: mod.id == picked,
                  leading: _thumbnail(mod, selected: mod.id == picked),
                  title: Text(mod.name, style: const TextStyle(fontSize: 13)),
                  isThreeLine: label != null && reason != null,
                  subtitle: label == null && reason == null
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (label != null)
                              Text(label,
                                  style: const TextStyle(fontSize: 11)),
                            if (reason != null) reason,
                          ],
                        ),
                  onTap: () => setState(() {
                    _chosen[subject.modName] =
                        InstallIntoMod(modId: mod.id, modName: mod.name);
                  }),
                );
              },
            ),
          ),
      ],
    );
  }

  /// The library in ranked order, each folder with its standing if it has one.
  ///
  /// **Nothing is dropped.** A folder the ranking never covered — one added to
  /// the library between the walk and the render — keeps its place at the end
  /// rather than disappearing from a list the user can see.
  List<({ModInfo mod, DestinationRank? rank})> _ordered(
    PatchInstallSubject subject,
  ) {
    if (subject.destinations.isEmpty) {
      return [for (final mod in widget.library) (mod: mod, rank: null)];
    }

    final byId = {for (final mod in widget.library) mod.id: mod};
    final ordered = <({ModInfo mod, DestinationRank? rank})>[];
    final placed = <String>{};
    for (final rank in subject.destinations) {
      final mod = byId[rank.modId];
      if (mod == null) continue;
      ordered.add((mod: mod, rank: rank));
      placed.add(rank.modId);
    }
    for (final mod in widget.library) {
      if (!placed.contains(mod.id)) ordered.add((mod: mod, rank: null));
    }
    return ordered;
  }

  /// One line saying what puts a folder where it is, or nothing.
  ///
  /// Shown only where there is something to say, so the reason means "this is
  /// why this row is up here" rather than decorating every row alike. Phrased as
  /// what was observed — files held, an author's claim — and never as a verdict
  /// about the folder.
  Widget? _reasonFor(DestinationRank? rank) {
    if (rank == null || !rank.hasSignal) return null;
    final theme = Theme.of(context);
    final (text, color) = rank.requiredByAuthor
        ? (
            loc.t('mods.patch_install.destination_required'),
            theme.colorScheme.primary,
          )
        : (
            loc.plural(
              'mods.patch_install.destination_match',
              rank.fingerprint,
              params: {
                'matched': '${rank.matched}',
                'count': '${rank.fingerprint}',
              },
            ),
            theme.colorScheme.onSurfaceVariant,
          );
    return Text(
      text,
      style: TextStyle(fontSize: 11, color: color),
    );
  }

  /// The mod's cover at row size, or a placeholder.
  ///
  /// **Decoded at row size**, for the reason `AppConstants.modCardDecodeWidth`
  /// records: `ImageCache` is bounded by decoded bytes, a cover is a full
  /// screenshot, and a list scrolling a whole library decodes far more of them
  /// than a grid of cards does.
  ///
  /// A missing file falls to the placeholder through `errorBuilder` rather than
  /// an `existsSync` guard: this builds once per visible row while the user
  /// scrolls and types, and that guard is synchronous disk I/O on the frame.
  Widget _thumbnail(ModInfo mod, {required bool selected}) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder() => Icon(
          Icons.image_outlined,
          size: 20,
          color: scheme.onSurfaceVariant,
        );

    return SizedBox(
      width: 48,
      height: 40,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: mod.imagePath == null
                ? Center(child: placeholder())
                : Image.file(
                    File(mod.imagePath!),
                    fit: BoxFit.cover,
                    width: 48,
                    height: 40,
                    cacheWidth: AppConstants.modThumbnailDecodeWidth,
                    errorBuilder: (_, __, ___) => Center(child: placeholder()),
                  ),
          ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.check, size: 18, color: scheme.onPrimary),
            ),
        ],
      ),
    );
  }
}
