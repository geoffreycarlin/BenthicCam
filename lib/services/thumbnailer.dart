import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Makes a small JPEG thumbnail (default 400 px wide) of a photo for the KMZ.
/// The full-size GoPro photo is decoded at reduced size by the platform's
/// image decoder (fast, low memory), then re-encoded as a ~30 KB JPEG.
Future<Uint8List?> makeThumbnail(Uint8List jpeg, {int width = 400}) async {
  try {
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: width);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width, h = image.height;
    image.dispose();
    codec.dispose();
    if (rgba == null) return null;
    final pic = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodeJpg(pic, quality: 80);
  } catch (_) {
    return null;
  }
}
