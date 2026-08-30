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
    this.placeholderMinWidth,
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

  /// Show the variant at this width first, then cross-fade to the [minWidth] one
  /// when it arrives. Null disables it — appropriate wherever the requested size is
  /// already small enough to appear immediately.
  ///
  /// **Set this to exactly the width another visible widget already requested**, so
  /// the placeholder is a cache hit rather than a second download. The mod detail
  /// view is the worked example: its thumbnail strip renders every gallery image at
  /// 100px, so passing 100 here means switching preview images shows the small copy
  /// instantly instead of an empty frame while the 800px version downloads.
  final int? placeholderMinWidth;

  @override
  Widget build(BuildContext context) {
    final blurred = treatment == ContentTreatment.blur && !revealed;
    final url = image?.urlAtLeast(minWidth);

    // Bounded because `urlAtLeast` can legitimately hand back the **full-size**
    // image: only `_sFile` and `_sFile100` are guaranteed to exist, so a gallery
    // image missing the 220/530/800 variants falls back to the original. Without
    // this, one such mod in the grid decodes a multi-megapixel bitmap for a 245px
    // card — the same ImageCache flooding the local mod covers were causing.
    final lowRes = _lowResUrl(url);

    Widget child;
    if (url == null) {
      child = _placeholder(context);
    } else if (lowRes == null) {
      child = Image.network(
        url,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: minWidth,
        // No loading spinner per tile: a grid of them flickering is worse than
        // tiles that simply fill in. The container behind is already the right size
        // and colour, so nothing reflows.
        errorBuilder: (context, _, __) => _placeholder(context),
      );
    } else {
      // Two layers, no cross-fade: the small copy sits underneath and the large one
      // paints straight over it the moment it decodes.
      //
      // Hand-rolled rather than `FadeInImage`, which is wrong twice over here. It
      // cross-fades (unwanted), and it hard-codes `gaplessPlayback: true` while
      // never resetting its internal `targetLoaded` flag — so on a provider change
      // its documented behaviour is to keep showing the *previously loaded* image.
      // That is not "blank while loading" but "the **wrong image** while loading",
      // with the selected thumbnail and the preview disagreeing.
      //
      // A plain `Image` defaults to `gaplessPlayback: false`, which is exactly what
      // is wanted here: on a new url it paints nothing until the new frame is ready,
      // so the layer beneath shows through and no key juggling is needed.
      child = Stack(
        fit: StackFit.expand,
        children: [
          // Softened, because this layer is a ~100px image filling an 800px frame and
          // nearest-neighbour blocks read as "broken" where a slightly out-of-focus
          // image reads as "still loading".
          ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: _upscaleBlurSigma,
              sigmaY: _upscaleBlurSigma,
            ),
            // `ResizeImage(NetworkImage(...))` is precisely what `cacheWidth` builds
            // internally, so this shares a cache key with the strip that already
            // fetched it — a lookup, not a request.
            child: Image.network(
              lowRes,
              fit: fit,
              cacheWidth: placeholderMinWidth,
              errorBuilder: (context, _, __) => _placeholder(context),
            ),
          ),
          Image.network(
            url,
            fit: fit,
            cacheWidth: minWidth,
            // Nothing on error, so the small copy underneath stays visible. Falling
            // back to the "no image" icon here would replace a usable preview with
            // an error state.
            errorBuilder: (context, _, __) => const SizedBox.shrink(),
          ),
        ],
      );
    }

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

  /// Blur applied to the stand-in layer, scaled to how far it is being stretched.
  ///
  /// Derived rather than fixed because the stretch varies: 100px into an 800px frame
  /// is eight source pixels per displayed block and wants real softening, while
  /// 220px into 530px is barely more than one and would look smeared if given the
  /// same treatment. Half a block is enough to hide the edges without erasing the
  /// detail that makes the stand-in useful in the first place.
  ///
  /// Both widths are known up front, so no layout pass is needed — the displayed
  /// size is whatever [minWidth] was chosen for.
  double get _upscaleBlurSigma {
    final target = placeholderMinWidth;
    if (target == null || target <= 0) return 0;
    return (minWidth / target / 2).clamp(1.5, 6.0);
  }

  /// The small stand-in url, or null when there is nothing useful to stand in.
  ///
  /// Returns null when it would resolve to the *same* file as [url]: that happens
  /// whenever the image publishes no variant below the requested size, and fading an
  /// image into itself would only add a download and a needless animation.
  String? _lowResUrl(String? url) {
    final target = placeholderMinWidth;
    if (target == null || url == null || image == null) return null;
    if (target >= minWidth) return null;
    final candidate = image!.urlAtLeast(target);
    return candidate == url ? null : candidate;
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
