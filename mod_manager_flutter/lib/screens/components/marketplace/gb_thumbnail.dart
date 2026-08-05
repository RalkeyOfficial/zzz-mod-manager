import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../models/gamebanana/gb_image.dart';
import '../../../services/gamebanana/content_filter.dart';

/// A remote GameBanana image with the content treatment applied.
///
/// `Image.network` rather than a caching package: Flutter's own `ImageCache`
/// already de-duplicates and holds decoded frames in memory for the session,
/// which is what a grid of thumbnails needs, and M1 has no requirement that
/// survives a restart. Adding a dependency for that is a cost with no measured
/// benefit here.
class GbThumbnail extends StatelessWidget {
  const GbThumbnail({
    super.key,
    required this.image,
    required this.treatment,
    this.width,
    this.height,
    this.minWidth = 220,
    this.fit = BoxFit.cover,
    this.revealed = false,
  });

  /// Null renders the placeholder — a mod with no gallery is normal.
  final GbImage? image;

  final ContentTreatment treatment;
  final double? width;
  final double? height;

  /// Requested variant width; the smallest published variant at least this wide
  /// is used, falling back to the original rather than inventing a filename.
  final int minWidth;

  final BoxFit fit;

  /// Whether the user has clicked through a blur. Only meaningful when
  /// [treatment] is [ContentTreatment.blur].
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final blurred = treatment == ContentTreatment.blur && !revealed;
    final url = image?.urlAtLeast(minWidth);

    Widget child = url == null
        ? _placeholder(context)
        : Image.network(
            url,
            width: width,
            height: height,
            fit: fit,
            // No loading spinner per tile: a grid of them flickering is worse
            // than tiles that simply fill in. The container behind is already
            // the right size and colour, so nothing reflows.
            errorBuilder: (context, _, __) => _placeholder(context),
          );

    if (blurred) {
      // ImageFiltered blurs the decoded image rather than compositing a
      // backdrop, so the pixels underneath are never painted unblurred for a
      // frame — which a BackdropFilter over a visible child would do.
      child = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: child,
      );
    }

    return SizedBox(width: width, height: height, child: child);
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 28,
        color: scheme.onSurface.withValues(alpha: 0.3),
      ),
    );
  }
}
