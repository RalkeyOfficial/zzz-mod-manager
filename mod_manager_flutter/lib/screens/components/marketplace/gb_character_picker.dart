import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/gamebanana/gamebanana.dart';
import '../../../services/gamebanana/remote_mod_metadata.dart';
import '../../../utils/marketplace_providers.dart';
import '../../../utils/state_providers.dart';
import '../../../utils/zzz_characters.dart';
import '../../shell/keycap.dart';
import '../character_avatar.dart';
import '../character_tile.dart' show elementToneOf;

/// The popover's size when the window has room for it.
const double _popoverWidth = 720;
const double _popoverHeight = 440;

/// Between the chip and the popover, and the least room left between the popover and the window's edges.
const double _anchorGap = 6;
const double _rightGutter = 32;
const double _bottomMargin = 16;

const double _tileGap = 2;
const double _minTileWidth = 76;
const int _maxColumns = 8;

const String _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// One child of GameBanana's Character Skins category, and the roster agent it maps to, if any: the mapping an
/// install files a mod under.
class _Agent {
  _Agent(this.node) : name = node.name ?? '#${node.idRow}', rosterId = _rosterIdFor(node.name);

  final GbCategoryNode node;
  final String name;
  final String? rosterId;

  String get letter => name.isEmpty ? '' : name[0].toUpperCase();

  MarketplaceCharacter get character => MarketplaceCharacter(node.idRow, name);
}

String? _rosterIdFor(String? categoryName) {
  final id = RemoteModMetadata.characterIdForCategory(categoryName);
  return id == null ? null : characterById(id)?.id;
}

/// The Browse page's character filter: a chip that shows the picked character, and a popover of every agent as a
/// grid of faces, with the user's own characters on top, a name search and an A–Z rail.
///
/// Picking a character turns the Character chip on; the × clears the character and leaves Character on.
class GbCharacterPicker extends ConsumerStatefulWidget {
  const GbCharacterPicker({super.key, required this.query, required this.onChanged});

  final MarketplaceQuery query;
  final ValueChanged<MarketplaceQuery> onChanged;

  @override
  ConsumerState<GbCharacterPicker> createState() => _GbCharacterPickerState();
}

class _GbCharacterPickerState extends ConsumerState<GbCharacterPicker> {
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _chipKey = GlobalKey();
  final FocusNode _chipFocus = FocusNode();
  final TextEditingController _search = TextEditingController();
  final ScrollController _body = ScrollController();
  final Object _tapGroup = Object();

  String _text = '';
  String? _letter;
  ScrollPosition? _pageScroll;

  bool get _open => _portal.isShowing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The popover is placed against where the chip was, so it closes when the page scrolls the chip away.
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _pageScroll) {
      _pageScroll?.removeListener(_closeOnScroll);
      _pageScroll = position?..addListener(_closeOnScroll);
    }
  }

  @override
  void dispose() {
    _pageScroll?.removeListener(_closeOnScroll);
    _chipFocus.dispose();
    _search.dispose();
    _body.dispose();
    super.dispose();
  }

  void _closeOnScroll() {
    if (_open) _close();
  }

  void _openPopover() {
    _search.clear();
    setState(() {
      _text = '';
      _letter = null;
    });
    _portal.show();
  }

  void _close({bool refocus = false}) {
    if (!_open) return;
    setState(_portal.hide);
    if (refocus) _chipFocus.requestFocus();
  }

  void _toggle() => _open ? _close() : _openPopover();

  // Closed before the query changes, since the change scrolls the page and the scroll would close it first, without
  // handing focus back to the chip.
  void _pick(_Agent agent) {
    _close(refocus: true);
    widget.onChanged(widget.query.withCharacter(agent.character));
  }

  void _clear() => widget.onChanged(widget.query.withCharacter(null));

  /// The picked tile clears the pick; any other picks its agent.
  void _press(_Agent agent) {
    if (widget.query.character?.id == agent.node.idRow) {
      _close(refocus: true);
      _clear();
    } else {
      _pick(agent);
    }
  }

  void _toTop() {
    if (_body.hasClients) _body.jumpTo(0);
  }

  void _onText(String value) {
    setState(() {
      _text = value;
      _letter = null;
    });
    _toTop();
  }

  void _onLetter(String letter) {
    _search.clear();
    setState(() {
      _text = '';
      _letter = _letter == letter ? null : letter;
    });
    _toTop();
  }

  @override
  Widget build(BuildContext context) {
    final children = ref.watch(categoryChildrenProvider(kCharacterSkinsCategoryId));
    final counts = ref.watch(libraryGroupCountsProvider);
    final agents = [for (final node in children.valueOrNull ?? const <GbCategoryNode>[]) _Agent(node)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final mine = [
      for (final agent in agents)
        if ((counts[agent.rosterId]?.mods ?? 0) > 0) agent,
    ];

    return TapRegion(
      groupId: _tapGroup,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) => _placed(
              context,
              constraints.biggest,
              _PickerPanel(
                state: children,
                agents: agents,
                mine: mine,
                picked: widget.query.character?.id,
                search: _search,
                body: _body,
                text: _text,
                letter: _letter,
                onText: _onText,
                onLetter: _onLetter,
                onPress: _press,
                onPick: _pick,
                onDismiss: () => _close(refocus: true),
              ),
            ),
          ),
        ),
        child: _Chip(
          key: _chipKey,
          character: widget.query.character,
          open: _open,
          focusNode: _chipFocus,
          onTap: _toggle,
          onClear: _clear,
        ),
      ),
    );
  }

  /// The popover under the chip and left-aligned with it, narrowed to the room left of the page's right gutter and
  /// shortened to the room below the chip, or opened above it when there is more room there.
  Widget _placed(BuildContext context, Size overlay, Widget panel) {
    final chip = _chipKey.currentContext?.findRenderObject() as RenderBox?;
    final theater = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (chip == null || theater == null || !chip.attached || !chip.hasSize) return const SizedBox.shrink();
    final anchor = chip.localToGlobal(Offset.zero, ancestor: theater) & chip.size;

    final width = math.max(0.0, math.min(_popoverWidth, overlay.width - _rightGutter - anchor.left));
    final below = overlay.height - anchor.bottom - _anchorGap - _bottomMargin;
    final above = anchor.top - _anchorGap - _bottomMargin;
    final opensBelow = below >= _popoverHeight || below >= above;
    final height = math.max(0.0, math.min(_popoverHeight, opensBelow ? below : above));
    final top = opensBelow ? anchor.bottom + _anchorGap : anchor.top - _anchorGap - height;

    return Stack(
      children: [
        Positioned(
          left: anchor.left,
          top: top,
          width: width,
          height: height,
          child: TapRegion(groupId: _tapGroup, onTapOutside: (_) => _close(), child: panel),
        ),
      ],
    );
  }
}

/// A target that is a button to the pointer, the keyboard and a screen reader, telling its [builder] whether it is
/// under the pointer and whether it has keyboard focus. Inert when [onPressed] is null.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.label,
    required this.onPressed,
    required this.builder,
    this.focusNode,
    this.selected,
    this.expanded,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final FocusNode? focusNode;
  final bool? selected;
  final bool? expanded;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    // The semantics inside the focus widget, so the node keeps its focusable flag.
    return FocusableActionDetector(
      enabled: onPressed != null,
      focusNode: widget.focusNode,
      mouseCursor: onPressed == null ? MouseCursor.defer : SystemMouseCursors.click,
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onPressed?.call())},
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        selected: widget.selected,
        expanded: widget.expanded,
        label: widget.label,
        excludeSemantics: true,
        onTap: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: widget.builder(context, _hovered && onPressed != null, _focused),
        ),
      ),
    );
  }
}

/// The accent ring a focused target draws over itself.
BoxDecoration? _focusRing(BuildContext context, bool focused, BorderRadius radius) => focused
    ? BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: ZenithPalette.of(context).accent, width: 2),
      )
    : null;

/// The 200px chip: a face, "Any character" or the picked name, and a chevron that turns over while the popover is
/// open. With a character picked, an × of its own at the right end.
class _Chip extends StatefulWidget {
  const _Chip({
    super.key,
    required this.character,
    required this.open,
    required this.focusNode,
    required this.onTap,
    required this.onClear,
  });

  final MarketplaceCharacter? character;
  final bool open;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final character = widget.character;
    final on = character != null;
    final foreground = on ? palette.selected.foreground : (_hovered ? palette.text : palette.text2);
    final label = character?.name ?? loc.t('marketplace.any_character');
    const pill = BorderRadius.all(Radius.circular(999));

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        width: 200,
        height: 30,
        decoration: BoxDecoration(
          color: on ? palette.selected.background : palette.chip,
          borderRadius: pill,
          border: Border.all(color: on ? palette.selected.border! : (_hovered ? palette.edge : palette.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: _Pressable(
                label: label,
                focusNode: widget.focusNode,
                expanded: widget.open,
                onPressed: widget.onTap,
                builder: (context, _, focused) => DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: _focusRing(context, focused, pill) ?? const BoxDecoration(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(3, 0, 4, 0),
                    child: Row(
                      spacing: 8,
                      children: [
                        _ChipFace(character: character),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium!.copyWith(color: foreground),
                          ),
                        ),
                        AnimatedRotation(
                          turns: widget.open ? 0.5 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(Icons.expand_more_rounded, size: 13, color: foreground),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (on)
              Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Tooltip(
                  message: loc.t('marketplace.clear_character'),
                  child: _Pressable(
                    label: loc.t('marketplace.clear_character'),
                    onPressed: widget.onClear,
                    builder: (context, hovered, focused) => Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hovered
                            ? Color.lerp(palette.selected.background, palette.selected.foreground, 0.2)
                            : null,
                        border: focused ? Border.all(color: palette.accent, width: 2) : null,
                      ),
                      child: Icon(Icons.close_rounded, size: 12, color: hovered ? palette.text : foreground),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The chip's 22px round face: the picked agent's portrait, else their initials on their element tile, else for no
/// pick a person on a grey disc.
class _ChipFace extends StatelessWidget {
  const _ChipFace({required this.character});

  final MarketplaceCharacter? character;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final character = this.character;
    const size = 22.0;
    if (character == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: palette.track, shape: BoxShape.circle),
        child: Icon(Icons.person_outline_rounded, size: 13, color: palette.text2),
      );
    }
    final rosterId = _rosterIdFor(character.name);
    final tone = palette.element(rosterId == null ? ElementTone.neutral : elementToneOf(rosterId));
    final portrait = CharacterAvatar.assetPathFor(rosterId);
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tone.background, shape: BoxShape.circle),
      child: portrait != null
          ? Image.asset(
              portrait,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.5),
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            )
          : Text(
              nameInitials(character.name),
              style: ZenithType.of(context).initialsSmall.copyWith(color: tone.foreground),
            ),
    );
  }
}

/// The popover itself: the search row, the scrolling grids, and the A–Z rail.
class _PickerPanel extends StatelessWidget {
  const _PickerPanel({
    required this.state,
    required this.agents,
    required this.mine,
    required this.picked,
    required this.search,
    required this.body,
    required this.text,
    required this.letter,
    required this.onText,
    required this.onLetter,
    required this.onPress,
    required this.onPick,
    required this.onDismiss,
  });

  final AsyncValue<List<GbCategoryNode>> state;
  final List<_Agent> agents;

  /// The agents with at least one mod in the library.
  final List<_Agent> mine;

  /// The picked character's category id.
  final int? picked;

  final TextEditingController search;
  final ScrollController body;
  final String text;
  final String? letter;
  final ValueChanged<String> onText;
  final ValueChanged<String> onLetter;
  final ValueChanged<_Agent> onPress;
  final ValueChanged<_Agent> onPick;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final textTheme = Theme.of(context).textTheme;

    final query = text.trim().toLowerCase();
    // A substring match covers a word that starts with the text too.
    final shown = [
      for (final agent in agents)
        if (query.isNotEmpty ? agent.name.toLowerCase().contains(query) : (letter == null || agent.letter == letter))
          agent,
    ];
    final showMine = query.isEmpty && letter == null && mine.isNotEmpty;
    final heading = query.isNotEmpty
        ? loc.plural('marketplace.picker_found', shown.length, params: {'count': '${shown.length}'})
        : letter != null
        ? loc.t('marketplace.picker_letter', params: {'letter': letter!})
        : loc.t('marketplace.picker_all');

    void pickFirst() {
      final first = [if (showMine) ...mine, ...shown].firstOrNull;
      if (first != null) onPick(first);
    }

    const fieldHeight = 40.0;
    final line = textTheme.bodyMedium!.fontSize! * textTheme.bodyMedium!.height!;
    final accentBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: palette.accent),
    );

    final field = TextField(
      controller: search,
      autofocus: true,
      onChanged: onText,
      onSubmitted: (_) => pickFirst(),
      style: textTheme.bodyMedium!.copyWith(color: palette.text),
      decoration: InputDecoration(
        constraints: const BoxConstraints.tightFor(height: fieldHeight),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: (fieldHeight - line) / 2),
        prefixIconConstraints: const BoxConstraints(minWidth: fieldHeight, minHeight: fieldHeight),
        prefixIcon: const Icon(Icons.search_rounded, size: 16),
        hintText: loc.t('marketplace.picker_search_hint'),
        border: accentBorder,
        enabledBorder: accentBorder,
        focusedBorder: accentBorder,
      ),
    );

    final hint = Text.rich(
      TextSpan(children: keycapSentence(context, loc.t('marketplace.picker_enter_hint'), 'Enter')),
      style: textTheme.labelSmall!.copyWith(color: palette.text3, fontWeight: FontWeight.w400, letterSpacing: 0),
    );

    final Widget grids;
    if (state.isLoading && !state.hasValue) {
      grids = _Note(loc.t('marketplace.loading'));
    } else if (state.hasError && !state.hasValue) {
      grids = _Note(loc.t('marketplace.characters_unavailable'));
    } else {
      grids = Scrollbar(
        controller: body,
        child: SingleChildScrollView(
          controller: body,
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth + _tileGap) / (_minTileWidth + _tileGap)).floor().clamp(
                1,
                _maxColumns,
              );
              // A hair under the exact share, so rounding never pushes the last tile of a row onto the next.
              final tileWidth = (constraints.maxWidth - _tileGap * (columns - 1)) / columns - 0.01;

              Widget section(String title, List<_Agent> list) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: [
                  Text(title, style: textTheme.labelMedium!.copyWith(color: palette.text3)),
                  if (list.isNotEmpty)
                    Wrap(
                      spacing: _tileGap,
                      runSpacing: _tileGap,
                      children: [
                        for (final agent in list)
                          SizedBox(
                            width: tileWidth,
                            child: _AgentTile(
                              agent: agent,
                              picked: agent.node.idRow == picked,
                              onPressed: () => onPress(agent),
                            ),
                          ),
                      ],
                    ),
                ],
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 14,
                children: [
                  if (showMine) section(loc.t('marketplace.picker_yours'), mine),
                  section(heading, shown),
                  if (shown.isEmpty && query.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: Text(
                        loc.t('marketplace.picker_no_match', params: {'text': text.trim()}),
                        style: textTheme.bodyMedium!.copyWith(color: palette.text2),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    }

    final present = {for (final agent in agents) agent.letter};

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: loc.t('marketplace.picker_title'),
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              onDismiss();
              return null;
            },
          ),
        },
        child: FocusScope(
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: palette.menu,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: palette.menuBorder),
                boxShadow: [BoxShadow(color: palette.notificationShadow, blurRadius: 80, offset: const Offset(0, 30))],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                      child: Row(
                        spacing: 10,
                        children: [
                          Expanded(
                            child: FocusTraversalOrder(order: const NumericFocusOrder(1), child: field),
                          ),
                          Flexible(child: hint),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: FocusTraversalOrder(
                              order: const NumericFocusOrder(2),
                              child: FocusTraversalGroup(child: grids),
                            ),
                          ),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: FocusTraversalGroup(
                              child: _LetterRail(present: present, letter: letter, onLetter: onLetter),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grey line in place of the grids, while the roster loads or when it could not be.
class _Note extends StatelessWidget {
  const _Note(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: ZenithPalette.of(context).text2),
    ),
  );
}

/// One agent: a 60px face on their element tile with a bar in the element's colour, and their name under it. The
/// picked one carries the accent ring and an accent name.
class _AgentTile extends StatelessWidget {
  const _AgentTile({required this.agent, required this.picked, required this.onPressed});

  final _Agent agent;
  final bool picked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final rosterId = agent.rosterId;
    final elementTone = rosterId == null ? ElementTone.neutral : elementToneOf(rosterId);
    final tone = palette.element(elementTone);
    final portrait = CharacterAvatar.assetPathFor(rosterId);
    const faceRadius = BorderRadius.all(Radius.circular(14));
    const tileRadius = BorderRadius.all(Radius.circular(12));
    final nameStyle = text.labelSmall!.copyWith(fontWeight: FontWeight.w400, height: 1.25, letterSpacing: 0);

    return _Pressable(
      label: agent.name,
      selected: picked,
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
        decoration: BoxDecoration(color: hovered ? palette.hover : null, borderRadius: tileRadius),
        foregroundDecoration: _focusRing(context, focused, tileRadius),
        child: Column(
          spacing: 6,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: faceRadius,
                boxShadow: picked
                    ? [
                        BoxShadow(color: palette.accent, spreadRadius: 4),
                        BoxShadow(color: palette.ground, spreadRadius: 2),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: faceRadius,
                child: ColoredBox(
                  color: tone.background,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (portrait != null)
                        Image.asset(
                          portrait,
                          fit: BoxFit.cover,
                          // The face sits in the top half of every portrait.
                          alignment: const Alignment(0, -0.5),
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        )
                      else
                        Center(
                          child: Text(
                            nameInitials(agent.name),
                            style: ZenithType.of(context).initialsLarge.copyWith(color: tone.foreground),
                          ),
                        ),
                      if (elementTone != ElementTone.neutral)
                        Positioned(left: 0, right: 0, bottom: 0, height: 3, child: ColoredBox(color: tone.foreground)),
                    ],
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _minTileWidth),
              child: Text(
                agent.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: picked
                    ? nameStyle.copyWith(color: palette.link, fontWeight: FontWeight.w600)
                    : nameStyle.copyWith(color: hovered ? palette.text : palette.textProse),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The A–Z rail. A letter no agent's name starts with is dimmed and does nothing; the picked one is filled with
/// the accent. The letters shrink to fit a short popover, and scroll once they would be too small to press.
class _LetterRail extends StatelessWidget {
  const _LetterRail({required this.present, required this.letter, required this.onLetter});

  final Set<String> present;
  final String? letter;
  final ValueChanged<String> onLetter;

  static const double _height = 19;
  static const double _minHeight = 11;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final mono = ZenithType.of(context).monoSmall;
    const radius = BorderRadius.all(Radius.circular(5));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: palette.outline)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const count = 26;
          final fitted = (constraints.maxHeight - (count - 1)) / count;
          final height = fitted.clamp(_minHeight, _height);
          final column = Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 1,
            children: [
              for (final ch in _letters.split(''))
                _Pressable(
                  label: loc.t('marketplace.picker_letter_label', params: {'letter': ch}),
                  selected: letter == ch,
                  onPressed: present.contains(ch) ? () => onLetter(ch) : null,
                  builder: (context, hovered, focused) {
                    final on = letter == ch;
                    final available = present.contains(ch);
                    return Container(
                      width: 22,
                      height: height,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? palette.accent : (hovered ? palette.hover : null),
                        borderRadius: radius,
                      ),
                      foregroundDecoration: _focusRing(context, focused, radius),
                      child: Text(
                        ch,
                        style: mono.copyWith(
                          color: on
                              ? palette.onAccent
                              : !available
                              ? palette.edge
                              : (hovered ? palette.text : palette.text2),
                          fontWeight: on ? FontWeight.w700 : null,
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
          return fitted < _minHeight ? SingleChildScrollView(child: column) : column;
        },
      ),
    );
  }
}
