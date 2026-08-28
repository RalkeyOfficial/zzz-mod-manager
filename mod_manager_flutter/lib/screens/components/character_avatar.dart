import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../utils/zzz_characters.dart';

/// How a portrait is clipped.
enum CharacterAvatarShape {
  /// The sidebar and picker shape.
  circle,

  /// The 4px square the mod dialogs use.
  rounded,
}

/// A character's portrait, at a size, in a shape.
///
/// **The one place `assets/characters/<name>.png` is spelled.** The path is
/// otherwise built by hand at each call site, and every one of those can miss
/// the roster's `asset:` override on its own — `billy` lives in
/// `billy_herinkton.png`.
///
/// [assetPathFor] is the other half of that, and the more important half: it
/// answers **"is there a portrait for this id at all"**, which has to be asked
/// *before* an [Image] is built. [getCharacterAssetName] falls back to the id
/// itself, so a mod filed under a built-in category would resolve to
/// `assets/characters/cat_misc.png` and reach `errorBuilder` on every render.
/// That is the common case, not an edge one.
class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({
    super.key,
    required this.characterId,
    required this.size,
    this.shape = CharacterAvatarShape.circle,
    this.background,
    this.ring,
    this.ringGap = 0,
    this.fallback,
  });

  /// May be null, empty, [unknownCharacterId], or an id that is not a character
  /// at all. All four render [fallback].
  final String? characterId;

  /// The full outer footprint, including [ring] and [ringGap].
  final double size;

  final CharacterAvatarShape shape;

  /// Painted under the portrait. The bundled PNGs are **cut-outs with a
  /// transparent background**, so without this the artwork floats on whatever
  /// happens to be behind the avatar — and there is nothing to look at while a
  /// cold asset decodes.
  final Color? background;

  /// A ring around the outside, drawn inside [size] rather than beyond it.
  final BorderSide? ring;

  /// Bare space between [ring] and the artwork, so the ring's contrast is
  /// against the surface behind it rather than against whichever pixels this
  /// particular character's silhouette has at the clip edge.
  final double ringGap;

  /// Shown for an unassigned id, an id with no roster entry, and a roster entry
  /// whose file is missing. Defaults to a muted person glyph.
  final Widget? fallback;

  /// The bundled portrait for [id], or **null when there is no portrait to
  /// show** — null, empty, [unknownCharacterId], or an id the roster does not
  /// know (a built-in category, or one left behind by a rename).
  static String? assetPathFor(String? id) {
    if (isUnassignedCharacterId(id)) return null;
    final character = characterById(id!);
    if (character == null) return null;
    return '${AppConstants.assetsCharactersPath}${character.assetName}.png';
  }

  @override
  Widget build(BuildContext context) {
    final path = assetPathFor(characterId);
    final isCircle = shape == CharacterAvatarShape.circle;
    final inset = (ring?.width ?? 0) + ringGap;
    final inner = size - inset * 2;

    final placeholder = fallback ??
        Icon(
          Icons.person_rounded,
          size: inner * 0.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

    Widget content = Container(
      width: inner,
      height: inner,
      color: background,
      alignment: Alignment.center,
      child: path == null
          ? placeholder
          : Image.asset(
              path,
              width: inner,
              height: inner,
              fit: BoxFit.cover,
              // Holds the previous portrait while a new one decodes, for the
              // notification card that can change character in place.
              gaplessPlayback: true,
              // No `cacheWidth`: it would build a `ResizeImage`, which is a
              // different `ImageCache` key from the bare `AssetImage` the
              // sidebar and picker use — so this would miss their warm entry
              // and pay a fresh decode. These are 250px bundled assets, already
              // smaller than any slot's 2x; there is nothing to reclaim.
              errorBuilder: (_, __, ___) => placeholder,
            ),
    );

    content = isCircle
        ? ClipOval(child: content)
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: content,
          );

    if (ring == null && ringGap == 0) {
      return SizedBox.square(dimension: size, child: content);
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        // Concentric: the outer radius follows the inner one plus the inset.
        borderRadius: isCircle ? null : BorderRadius.circular(4 + inset),
        border: ring == null ? null : Border.fromBorderSide(ring!),
      ),
      child: content,
    );
  }
}
