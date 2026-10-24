import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/type_scale.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/categories.dart';
import '../../utils/zzz_characters.dart';
import 'character_avatar.dart';

/// The element tile for a row of the character list: the agent's attribute, or [ElementTone.neutral] for a
/// category, the Proxies, an agent whose attribute is not announced yet and unassigned mods.
ElementTone elementToneOf(String groupId) => switch (characterById(groupId)?.attribute) {
  AgentAttribute.physical => ElementTone.physical,
  AgentAttribute.fire => ElementTone.fire,
  AgentAttribute.ice => ElementTone.ice,
  AgentAttribute.electric => ElementTone.electric,
  AgentAttribute.ether => ElementTone.ether,
  AgentAttribute.wind => ElementTone.wind,
  AgentAttribute.lumiflux => ElementTone.lumiflux,
  null => ElementTone.neutral,
};

const Map<String, String> _groupInitials = {
  'cat_ui': 'UI',
  'cat_texture': 'TX',
  'cat_audio': 'AU',
  'cat_misc': 'MI',
  unknownCharacterId: '?',
};

/// What a tile with no portrait shows for [groupId].
String groupInitials(String groupId) {
  final fixed = _groupInitials[groupId];
  if (fixed != null) return fixed;
  final character = characterById(groupId);
  return nameInitials(character?.fullName ?? groupId);
}

/// A character's portrait on its element's tile, or their initials when there is no portrait.
///
/// The portrait is a cut-out, so the tile shows through it; a 2px bar in the element's colour runs along the
/// bottom. Initials carry a slanted stripe down the right edge instead.
class CharacterTile extends StatelessWidget {
  const CharacterTile({
    super.key,
    required this.groupId,
    this.size = 36,
    this.radius = 9,
    this.initialsStyle,
    this.shadow = false,
  });

  /// A roster id, a built-in category id, or [unknownCharacterId].
  final String groupId;
  final double size;
  final double radius;

  /// Defaults to [ZenithType.initials], sized for the 36px tile.
  final TextStyle? initialsStyle;

  /// The drop shadow a large tile casts over the dotted ground behind a character's header.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final tone = palette.element(elementToneOf(groupId));
    final portrait = CharacterAvatar.assetPathFor(groupId);

    final Widget content;
    if (portrait != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            portrait,
            fit: BoxFit.cover,
            // The face sits in the top half of every portrait.
            alignment: const Alignment(0, -0.5),
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          Positioned(left: 0, right: 0, bottom: 0, height: 2, child: ColoredBox(color: tone.foreground)),
        ],
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Text(
              groupInitials(groupId),
              style: (initialsStyle ?? ZenithType.of(context).initials).copyWith(color: tone.foreground),
            ),
          ),
          Positioned(
            right: -size * 0.14,
            top: 0,
            bottom: 0,
            width: size / 4,
            child: Transform(
              transform: Matrix4.skewX(-18 * math.pi / 180),
              alignment: Alignment.center,
              child: ColoredBox(color: tone.foreground.withValues(alpha: 0.55)),
            ),
          ),
        ],
      );
    }

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow
            ? [BoxShadow(color: palette.overlay, blurRadius: 30, offset: const Offset(0, 10))]
            : null,
      ),
      child: content,
    );
  }
}

/// The name the character list and a character's header show for [groupId].
String libraryGroupName(String groupId, AppLocalizations loc) {
  if (groupId == unknownCharacterId) return loc.t('library.list.unassigned');
  return characterById(groupId)?.fullName ?? categoryDisplayName(groupId, loc);
}

/// Whether [groupId] is one of the rows under "Other types".
bool isOtherType(String groupId) => isBuiltInCategory(groupId) || groupId == unknownCharacterId;
