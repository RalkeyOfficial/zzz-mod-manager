import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../models/character_info.dart';
import '../../services/cover_thumbnail.dart';
import 'character_tile.dart';
import 'zenith_controls.dart';

/// A mod's cover at list-row size, or its character's dotted ground when it has none.
class ModThumb extends StatefulWidget {
  const ModThumb({
    super.key,
    required this.mod,
    this.width = 44,
    this.height = 28,
    this.radius = 5,
    this.spacing = 6,
    this.bordered = false,
  });

  final ModInfo mod;
  final double width;
  final double height;
  final double radius;

  /// The gap between the dots of the ground a mod with no cover gets.
  final double spacing;

  /// Draws the 1px outline the large thumbnails of a dialog's header carry.
  final bool bordered;

  @override
  State<ModThumb> createState() => _ModThumbState();
}

class _ModThumbState extends State<ModThumb> {
  File? _cover;

  @override
  void initState() {
    super.initState();
    _cover = _find();
  }

  @override
  void didUpdateWidget(ModThumb old) {
    super.didUpdateWidget(old);
    if (old.mod.imagePath != widget.mod.imagePath) _cover = _find();
  }

  File? _find() {
    final path = widget.mod.imagePath;
    return path == null ? null : coverFileFor(path);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final empty = DottedGround(ground: palette.groundFor(elementToneOf(widget.mod.characterId)), spacing: widget.spacing);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final radius = BorderRadius.circular(widget.radius);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: widget.bordered ? Border.all(color: palette.outline) : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: _cover == null
              ? empty
              : Image.file(
                  _cover!,
                  fit: BoxFit.cover,
                  cacheWidth: (widget.width * dpr).round(),
                  errorBuilder: (_, _, _) => empty,
                ),
        ),
      ),
    );
  }
}
