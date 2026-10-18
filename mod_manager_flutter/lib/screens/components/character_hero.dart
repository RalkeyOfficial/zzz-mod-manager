import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/byte_format.dart';
import '../../utils/categories.dart';
import '../../utils/state_providers.dart';
import '../../utils/zzz_characters.dart';
import 'character_tile.dart';
import 'zenith_controls.dart';

/// The header above a character's mods, on their element's dotted ground: portrait, attribute, faction and
/// role, name, and what the library holds for them.
class CharacterHero extends ConsumerWidget {
  const CharacterHero({super.key, required this.groupId, required this.onFindMods, required this.onAddMod});

  final String groupId;
  final VoidCallback onFindMods;
  final VoidCallback onAddMod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final text = Theme.of(context).textTheme;
    final type = ZenithType.of(context);
    final tone = elementToneOf(groupId);
    final ground = palette.groundFor(tone);
    final character = characterById(groupId);

    return ClipRect(
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.divider))),
        child: DottedGround(
          ground: ground,
          spacing: 10,
          child: Stack(
            children: [
              Positioned(
                right: -10,
                top: -34,
                child: OutlinedInitials(groupInitials(groupId), style: type.watermarkLarge, color: ground.stroke),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 20,
                  runSpacing: 16,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      spacing: 20,
                      children: [
                        CharacterTile(
                          groupId: groupId,
                          size: 96,
                          radius: 16,
                          shadow: true,
                          initialsStyle: text.displaySmall,
                        ),
                        // Flexible, so a long name in a narrow header shrinks to fit rather than overflowing:
                        // "SOLDIER 0 - ANBY DEMARA" is 700px at full size.
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 8,
                            children: [
                              _Identity(groupId: groupId, character: character),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  libraryGroupName(groupId, loc).toUpperCase(),
                                  maxLines: 1,
                                  style: text.displayMedium?.copyWith(color: palette.text),
                                ),
                              ),
                              _Summary(groupId: groupId),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // A Wrap, so the second button goes under the first on a page too narrow for both.
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: onFindMods,
                          icon: const Icon(Icons.explore_outlined),
                          label: Text(loc.t('library.hero.find_mods')),
                        ),
                        OutlinedButton.icon(
                          onPressed: onAddMod,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(loc.t('library.hero.add_mod')),
                        ),
                      ],
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

/// The attribute badge and "faction · role", or what kind of row a category is.
class _Identity extends StatelessWidget {
  const _Identity({required this.groupId, required this.character});

  final String groupId;
  final CharacterData? character;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final caption = Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text2);
    final c = character;

    if (c == null) {
      return Text(
        loc.t(isBuiltInCategory(groupId) ? 'library.hero.category' : 'library.hero.unassigned'),
        style: caption,
      );
    }

    final attribute = c.attribute;
    final specialty = c.specialty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        ZenithBadge(
          label: loc.t(attribute == null ? 'library.hero.protagonist' : 'library.attribute.${attribute.name}'),
          tone: palette.element(elementToneOf(groupId)),
        ),
        Flexible(
          child: Text(
            [?c.faction, if (specialty != null) loc.t('library.specialty.${specialty.name}')].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: caption,
          ),
        ),
      ],
    );
  }
}

/// "4 mods · 1 active · 412 MB". The size joins once every mod on screen has been measured.
class _Summary extends ConsumerWidget {
  const _Summary({required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final mods = ref.watch(currentCharacterSkinsProvider);
    final active = mods.where((m) => m.isActive).length;

    int? total = 0;
    for (final mod in mods) {
      final size = ref.watch(modSizeProvider(mod.id)).valueOrNull;
      total = size == null || total == null ? null : total + size.bytes;
    }

    return Text(
      [
        mods.isEmpty
            ? loc.t('library.list.no_mods')
            : loc.plural('library.list.mods', mods.length, params: {'count': '${mods.length}'}),
        if (active > 0) loc.t('library.list.active_count', params: {'count': '$active'}),
        if (mods.isNotEmpty && total != null) formatBytes(total),
      ].join(' · '),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.text2),
    );
  }
}
