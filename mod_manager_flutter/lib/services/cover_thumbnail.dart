import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

import '../core/constants.dart';

/// A cover's card-sized copy, written once at import and read by every card.
///
/// `cacheWidth` on the card bounds **memory** only: the file on disk is still
/// the screenshot (measured: 3.8 MB PNGs, 2560px wide), so every cold load
/// reads and decodes the whole thing to fill a 320px card. A copy at the decode
/// width beside the original is what takes that cost off the scan.
///
/// The copy is derived state. Losing it costs nothing but the next cold load,
/// so it is never listed in the sidecar's `images`, is written best-effort, and
/// a reader falls back to the original whenever it is missing.

/// Where the thumbnail for an imported gallery image lives, or null for an
/// image that never gets one.
///
/// `<mod>/.zzz-mod-manager/images/01.png` maps to
/// `<mod>/.zzz-mod-manager/thumbnails/01.png`. Only a managed image maps: a
/// shipped `Preview.png` sits at the mod root, and this app writes nothing
/// beside a mod author's own files.
String? thumbnailPathFor(String imagePath) {
  final imagesDir = path.dirname(imagePath);
  final sidecarDir = path.dirname(imagesDir);
  if (path.basename(imagesDir) != AppConstants.modMetadataImagesDirName ||
      path.basename(sidecarDir) != AppConstants.modMetadataDirName) {
    return null;
  }
  return path.join(
    sidecarDir,
    AppConstants.modMetadataThumbnailsDirName,
    '${path.basenameWithoutExtension(imagePath)}.png',
  );
}

/// The file a card decodes for [imagePath]: the thumbnail when one has been
/// written, else the image itself, or null when neither is on disk.
///
/// Synchronous, one or two `stat`s: the card already checked the cover existed
/// before building an `Image`, and this is that check.
File? coverFileFor(String imagePath) {
  final thumbnail = thumbnailPathFor(imagePath);
  if (thumbnail != null) {
    final file = File(thumbnail);
    if (file.existsSync()) return file;
  }
  final original = File(imagePath);
  return original.existsSync() ? original : null;
}

/// Whether an image with this extension gets a thumbnail: a still image does,
/// an animated one would lose every frame but the first.
bool wantsThumbnail(String extension) => switch (extension.toLowerCase()) {
      'png' || 'jpg' || 'jpeg' => true,
      _ => false,
    };

/// The thumbnail's bytes for [source], or null when there is nothing to gain:
/// the image is no wider than the card decodes at, or it does not decode.
///
/// Runs in its own isolate. Decoding a 2560px screenshot in pure Dart takes
/// long enough to drop frames, and an import runs behind a dialog the user is
/// watching.
Future<Uint8List?> encodeThumbnail(Uint8List source) =>
    Isolate.run(() => _encode(source));

Uint8List? _encode(Uint8List source) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } on Object {
    // A truncated or mislabelled file: the decoder throws rather than
    // answering null, and it is the same "does not decode" outcome.
    return null;
  }
  if (decoded == null) return null;
  // Flutter honours the EXIF orientation when it decodes the original, so the
  // copy has to be upright on its own or the card would show a rotated cover
  // for a photo the gallery viewer shows the right way up.
  final upright = img.bakeOrientation(decoded);
  if (upright.width <= AppConstants.modCardDecodeWidth) return null;
  final resized = img.copyResize(
    upright,
    width: AppConstants.modCardDecodeWidth,
    interpolation: img.Interpolation.average,
  );
  return img.encodePng(resized);
}
