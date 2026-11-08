import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/button_feedback.dart';
import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/categories.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'zenith_menu.dart';

/// The pill that shows which character or type a mod is filed under, and opens [showCharacterPicker] under itself.
///
/// [groupId] is a roster id, a built-in category id or [unknownCharacterId]. Null is a mod that has no answer yet,
/// drawn in the amber "needs a choice" look so the user sees what is left to do.
class CharacterPick extends StatelessWidget {
  const CharacterPick({super.key, required this.groupId, required this.onChanged, this.offerUnassigned = true});

  final String? groupId;
  final ValueChanged<String> onChanged;

  /// Whether the list offers Unassigned.
  final bool offerUnassigned;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final picked = await showCharacterPicker(
      context,
      currentId: groupId ?? '',
      offerUnassigned: offerUnassigned,
      anchor: anchor,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final loc = context.loc;
    final text = Theme.of(context).textTheme;
    final id = groupId;
    final needs = id == null;
    final name = needs ? loc.t('mods.picker.choose') : libraryGroupName(id, loc);
    final color = needs ? palette.needsPick.foreground : palette.text;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: needs ? palette.needsPick.border! : palette.fieldBorder),
    );
    return Semantics(
      button: true,
      label: needs ? name : loc.t('mods.picker.aria', params: {'name': name}),
      excludeSemantics: true,
      onTap: () => _open(context),
      child: KeyboardFocusRing(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.arrowDown): () => _open(context)},
          child: Material(
            color: needs ? palette.needsPick.background : palette.chip,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _open(context),
              hoverColor: palette.hover.withValues(alpha: 0.5),
              child: SizedBox(
                height: 36,
                child: Padding(
                  padding: EdgeInsets.only(left: needs ? 12 : 6, right: 10),
                  child: Row(
                    spacing: 8,
                    children: [
                      if (id != null)
                        CharacterTile(groupId: id, size: 24, radius: 6, initialsStyle: ZenithType.of(context).initialsSmall),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(color: color),
                        ),
                      ),
                      Icon(Icons.expand_more_rounded, color: needs ? palette.needsPick.foreground : palette.text3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks which character or built-in type to file under: a popover of a search field over the types and the agents,
/// opened under [anchor] (a pill) or near the top of the window when there is none.
///
/// Returns the chosen id, or null when it was closed without a choice. Unassigned, [unknownCharacterId], is listed
/// only when [offerUnassigned] says so.
Future<String?> showCharacterPicker(
  BuildContext context, {
  required String currentId,
  bool offerUnassigned = false,
  Rect? anchor,
}) {
  final window = MediaQuery.sizeOf(context);
  final target = anchor ?? Rect.fromLTWH(window.width / 2 - _pickerMinWidth / 2, 96, _pickerMinWidth, 0);
  return showZenithPopover<String>(
    context,
    target: target,
    builder: (_) => _CharacterPicker(
      currentId: currentId,
      offerUnassigned: offerUnassigned,
      width: math.max(target.width, _pickerMinWidth),
    ),
  );
}

const double _pickerMinWidth = 320;

class _CharacterPicker extends StatefulWidget {
  const _CharacterPicker({required this.currentId, required this.offerUnassigned, required this.width});

  final String currentId;
  final bool offerUnassigned;
  final double width;

  @override
  State<_CharacterPicker> createState() => _CharacterPickerState();
}

class _CharacterPickerState extends State<_CharacterPicker> {
  final TextEditingController _search = TextEditingController();
  final GlobalKey _hotKey = GlobalKey();
  String _query = '';

  /// The hot row, as an index into the rows now listed. Null until an arrow key or the pointer picks one.
  int? _hot;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(String haystack) => _query.isEmpty || haystack.toLowerCase().contains(_query);

  /// The rows shown, in order: Unassigned, the types, the agents. The groups are for the labels.
  ({List<String> unassigned, List<String> types, List<String> agents}) _rows(AppLocalizations loc) => (
    unassigned: [if (widget.offerUnassigned && _matches(libraryGroupName(unknownCharacterId, loc))) unknownCharacterId],
    types: [
      for (final category in builtInCategories)
        if (_matches(loc.t(category.labelKey))) category.id,
    ],
    agents: [
      for (final id in zzzCharacterIds)
        if (_matches('${libraryGroupName(id, loc)} ${getCharacterDisplayName(id)} ${getCharacterRealName(id) ?? ''} $id')) id,
    ]..sort((a, b) => libraryGroupName(a, loc).toLowerCase().compareTo(libraryGroupName(b, loc).toLowerCase())),
  );

  void _pick(String id) => Navigator.of(context).pop(id);

  void _moveHot(int step, int count) {
    if (count == 0) return;
    setState(() => _hot = _hot == null ? (step > 0 ? 0 : count - 1) : (_hot! + step) % count);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hot = _hotKey.currentContext;
      if (hot != null) Scrollable.ensureVisible(hot);
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final rows = _rows(loc);
    final all = [...rows.unassigned, ...rows.types, ...rows.agents];
    var index = 0;

    Widget row(String id) {
      final mine = index++;
      return KeyedSubtree(
        key: _hot == mine ? _hotKey : ValueKey(id),
        child: ZenithMenuRow(
          label: libraryGroupName(id, loc),
          leading: CharacterTile(groupId: id, size: 24, radius: 6, initialsStyle: ZenithType.of(context).initialsSmall),
          trailing: id == widget.currentId ? Icon(Icons.check_rounded, size: 14, color: palette.accent) : null,
          hot: _hot == mine,
          onHover: (inside) => setState(() {
            if (inside) {
              _hot = mine;
            } else if (_hot == mine) {
              _hot = null;
            }
          }),
          onTap: () => _pick(id),
        ),
      );
    }

    Widget caption(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Text(label.toUpperCase(), style: ZenithType.of(context).caps.copyWith(color: palette.text3)),
    );

    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _moveHot(1, all.length);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _moveHot(-1, all.length);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: loc.t('mods.dialog.search_category'),
        child: ZenithMenuSurface(
          width: widget.width,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360 - 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onChanged: (value) => setState(() {
                    _query = value.trim().toLowerCase();
                    _hot = null;
                  }),
                  onSubmitted: (_) {
                    final hot = _hot;
                    if (hot != null && hot < all.length) {
                      _pick(all[hot]);
                    } else if (all.isNotEmpty) {
                      _pick(all.first);
                    }
                  },
                  decoration: InputDecoration(hintText: loc.t('mods.dialog.search_category')),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: all.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: Text(
                              loc.t('mods.picker.no_results'),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text3),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final id in rows.unassigned) row(id),
                              if (rows.types.isNotEmpty) caption(loc.t('mods.picker.types')),
                              for (final id in rows.types) row(id),
                              if (rows.agents.isNotEmpty) caption(loc.t('mods.picker.agents')),
                              for (final id in rows.agents) row(id),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
