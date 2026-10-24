import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/button_feedback.dart';
import '../core/palette.dart';
import '../l10n/app_localizations.dart';
import '../utils/state_providers.dart';
import 'components/settings/about_card.dart';
import 'components/settings/about_section.dart';
import 'components/settings/appearance_section.dart';
import 'components/settings/folders_section.dart';
import 'components/settings/gamebanana_section.dart';
import 'components/settings/launch_section.dart';
import 'components/settings/mods_section.dart';
import 'components/settings/storage_section.dart';

/// The Settings page: a list of its sections beside the section in view.
///
/// Everything but Storage and About is one scrolling page that the list scrolls to, and follows as the page scrolls.
/// Storage and About each take the page's whole width in place of it. [settingsSectionProvider] names the section in
/// view and is how another screen asks for one.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// How wide each pane draws: the page and About at 820, Storage at 860.
  static const double _pageWidth = 820;
  static const double _storageWidth = 860;
  static const double _navWidth = 210;

  /// The width under which the list of sections sits above the page instead of beside it.
  static const double _narrow = 760;

  /// The sections that share the scrolling page, in the order it shows them.
  static const List<SettingsSection> _page = [
    SettingsSection.folders,
    SettingsSection.launching,
    SettingsSection.mods,
    SettingsSection.gamebanana,
    SettingsSection.appearance,
  ];

  final ScrollController _scroll = ScrollController();
  final Map<SettingsSection, GlobalKey> _keys = {for (final section in _page) section: GlobalKey()};

  /// Keeps the body's state, the scroll position included, when a resize moves it between the two layouts.
  final GlobalKey _bodyKey = GlobalKey();

  /// The section the scroll position just named, so the list following the page isn't taken for a request to scroll.
  /// The provider's listener takes it back as soon as it sees the change.
  SettingsSection? _followed;

  /// Whether a scroll to a section is under way, which the page's own scrolling must not be read as a new position.
  /// [_revealToken] tells a scroll that was overtaken by a later one.
  bool _scrolling = false;
  int _revealToken = 0;

  static bool _isPane(SettingsSection section) =>
      section == SettingsSection.storage || section == SettingsSection.about;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_follow);
    final requested = ref.read(settingsSectionProvider);
    if (!_isPane(requested) && requested != _page.first) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(requested, animate: false));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the page to [section]. Waits a frame when the page isn't built yet, as after leaving Storage or About.
  void _reveal(SettingsSection section, {required bool animate}) {
    if (!mounted) return;
    final context = _keys[section]?.currentContext;
    if (context == null || !_scroll.hasClients) return;
    final token = ++_revealToken;
    _scrolling = true;
    if (!animate) {
      Scrollable.ensureVisible(context, duration: Duration.zero);
      _scrolling = false;
      return;
    }
    unawaited(
      Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic)
          .whenComplete(() {
            if (token == _revealToken) _scrolling = false;
          }),
    );
  }

  /// A press on a section in the list. Pressing the one in view scrolls to its top again, which the provider can't
  /// say, since it holds the same value.
  void _pick(SettingsSection picked) {
    final notifier = ref.read(settingsSectionProvider.notifier);
    if (notifier.state != picked) {
      notifier.state = picked;
    } else if (!_isPane(picked)) {
      _reveal(picked, animate: true);
    }
  }

  /// Names the section at the top of the page as the one in view.
  void _follow() {
    if (_scrolling || !_scroll.hasClients) return;
    var current = _page.first;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 1) {
      current = _page.last;
    } else {
      for (final section in _page) {
        final box = _keys[section]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        final top = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
        if (top <= _scroll.position.pixels + 80) current = section;
      }
    }
    if (current == ref.read(settingsSectionProvider)) return;
    _followed = current;
    ref.read(settingsSectionProvider.notifier).state = current;
  }

  @override
  Widget build(BuildContext context) {
    final section = ref.watch(settingsSectionProvider);
    ref.listen(settingsSectionProvider, (previous, next) {
      final fromScroll = next == _followed;
      _followed = null;
      if (_isPane(next) || fromScroll) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(next, animate: !_isPane(previous ?? next)));
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrow;
        final list = _SectionList(selected: section, horizontal: narrow, onPick: _pick);
        final body = KeyedSubtree(key: _bodyKey, child: _isPane(section) ? _pane(section) : _preferences());
        if (narrow) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [list, Expanded(child: body)]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: _navWidth, child: list),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _preferences() {
    return SingleChildScrollView(
      controller: _scroll,
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _pageWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 28,
              children: [
                KeyedSubtree(key: _keys[SettingsSection.folders], child: const FoldersSection()),
                KeyedSubtree(key: _keys[SettingsSection.launching], child: const LaunchSettingsSection()),
                KeyedSubtree(key: _keys[SettingsSection.mods], child: const ModsSection()),
                KeyedSubtree(key: _keys[SettingsSection.gamebanana], child: const GameBananaSection()),
                KeyedSubtree(key: _keys[SettingsSection.appearance], child: const AppearanceSection()),
                const SettingsAboutCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pane(SettingsSection section) {
    return SingleChildScrollView(
      key: ValueKey(section),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: section == SettingsSection.storage ? _storageWidth : _pageWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
            child: section == SettingsSection.storage ? const StorageSection() : const AboutSection(),
          ),
        ),
      ),
    );
  }
}

/// The page title over the list of sections: a column beside the page, a row of words above it when narrow.
class _SectionList extends StatelessWidget {
  const _SectionList({required this.selected, required this.horizontal, required this.onPick});

  final SettingsSection selected;
  final bool horizontal;
  final ValueChanged<SettingsSection> onPick;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final items = [
      for (final section in SettingsSection.values)
        _SectionItem(
          label: loc.t('settings.nav.${section.name}'),
          selected: section == selected,
          onTap: () => onPick(section),
        ),
    ];
    final title = Text(loc.t('settings.title'), style: theme.textTheme.headlineMedium);

    if (horizontal) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            title,
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(spacing: 4, children: items)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 12, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), child: title),
          ...items,
        ],
      ),
    );
  }
}

class _SectionItem extends StatefulWidget {
  const _SectionItem({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SectionItem> createState() => _SectionItemState();
}

class _SectionItemState extends State<_SectionItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final palette = ZenithPalette.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(7));
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: label,
      child: KeyboardFocusRing(
        shape: shape,
        child: Material(
          color: selected ? palette.sectionSelected : Colors.transparent,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onHover: (hovered) => setState(() => _hovered = hovered),
            hoverColor: palette.sectionHover,
            child: Stack(
              children: [
                if (selected)
                  Positioned(left: 0, top: 0, bottom: 0, width: 2, child: ColoredBox(color: palette.accent)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: selected || _hovered ? palette.text : palette.text2,
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
