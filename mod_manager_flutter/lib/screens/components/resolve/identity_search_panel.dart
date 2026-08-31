import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/gamebanana/content_filter.dart';
import '../../../utils/gamebanana_url.dart';
import '../../../utils/state_providers.dart';
import '../marketplace/gb_thumbnail.dart';
import 'resolve_fragments.dart';

/// [name] as a first search term.
///
/// A mod's name is a folder name out of an archive, so it routinely arrives as
/// `Ellen_Joe_Cheongsam` — which finds nothing, leaving the user to retype what
/// the app already knew. Underscores are the one substitution a filename makes
/// for a space, so they are the one thing undone here.
///
/// **A first guess, not a parse.** Hyphens, dots and version suffixes are how
/// mod pages are genuinely titled ("Ellen - Swimsuit v1.2"), and stripping them
/// would change the words rather than restore them. The box is editable either
/// way, and a clever guess that drops half the name is worse than a plain one.
String searchSeedFromName(String name) =>
    name.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// "Which remote mod is this?" — the search box, its results, and the two ways
/// a pasted url is answered without searching at all.
///
/// **It owns its own search state.** Both callers want identical behaviour and
/// neither wants to hold a controller, a results list, an in-flight flag and an
/// error for a question this widget is the whole of.
///
/// Two rules it carries rather than the caller:
///
/// - **The content filter degrades to blur here, never to omit.** Elsewhere
///   `hide` drops a flagged mod from a listing; doing that in a search the user
///   is running to identify a mod they *already own* would make that mod
///   permanently unresolvable, with no hint as to why.
/// - **A pasted `/dl/` link cannot name a mod.** It is a file id in a different
///   id space and neither GameBanana API can say which mod owns it, so this
///   says so rather than searching for the url as though it were a mod name.
class IdentitySearchPanel extends ConsumerStatefulWidget {
  const IdentitySearchPanel({
    super.key,
    required this.seed,
    required this.onPicked,
    this.heading,
  });

  /// What the box starts with — the mod's name, normally. It is the best
  /// available guess and the user edits it. Passed through
  /// [searchSeedFromName] here rather than by each caller, so both dialogs
  /// search the same thing.
  final String seed;

  /// A mod page the user chose, or pasted.
  final ValueChanged<int> onPicked;

  /// Localized heading above the box. Omitted when the caller draws its own.
  final String? heading;

  @override
  ConsumerState<IdentitySearchPanel> createState() =>
      _IdentitySearchPanelState();
}

class _IdentitySearchPanelState extends ConsumerState<IdentitySearchPanel> {
  final TextEditingController _controller = TextEditingController();

  List<GbMod>? _results;
  Object? _error;
  bool _searching = false;

  /// Set when a pasted url is a `/dl/` file link — which cannot name a mod.
  bool _pastedFileLink = false;

  @override
  void initState() {
    super.initState();
    _controller.text = searchSeedFromName(widget.seed);
    _search();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    setState(() {
      _pastedFileLink = false;
      _error = null;
    });

    // A pasted mod page resolves without searching at all.
    if (gameBananaModIdFromUrl(query) case final pastedId?) {
      widget.onPicked(pastedId);
      return;
    }
    if (gameBananaFileIdFromUrl(query) != null) {
      setState(() {
        _pastedFileLink = true;
        _results = const <GbMod>[];
      });
      return;
    }
    if (query.isEmpty) return;

    setState(() => _searching = true);
    try {
      final page = await ref.read(gameBananaClientProvider).searchMods(query);
      if (!mounted) return;
      setState(() {
        _results = page.records;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.heading case final heading?) ...[
          Text(
            heading,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _controller,
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
          resolveNotice(
              context, loc.t('mods.resolve.paste_is_file_link'), Icons.link_off)
        else if (_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          resolveNotice(
              context, loc.t('mods.resolve.load_failed'), Icons.cloud_off)
        else if (_results?.isEmpty ?? false)
          resolveNotice(
              context, loc.t('mods.resolve.no_results'), Icons.search_off)
        else
          // Bounded for the same reason as the file list: search returns up to
          // fifteen, and whatever the caller puts underneath has to stay one
          // click away.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final result in _results ?? const <GbMod>[]) _row(result),
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(GbMod mod) {
    final filter = ref.watch(contentFilterProvider);
    // Never omit here — see the class doc.
    final treatment = contentTreatment(
      mod.visibility ?? GbVisibility.warn,
      filter == ContentFilterMode.hide ? ContentFilterMode.blur : filter,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onPicked(mod.idRow),
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
}
