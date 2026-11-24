import 'dart:typed_data';
import 'dart:ui' as ui;

import '../engine/detect.dart';

/// 兜底解码：利用 Flutter 平台编解码器（如 Android/iOS 的 HEIC）解成直通 RGBA
Future<RgbaSource?> decodePlatformImageFallback(Uint8List bytes) async {
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (byteData == null) return null;
    final data = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return RgbaSource(data: Uint8List.fromList(data), width: width, height: height);
  } catch (_) {
    return null;
  } finally {
    frame?.image.dispose();
    codec?.dispose();
  }
}

Future<({int width, int height})?> probePlatformSizeFallback(Uint8List bytes) async {
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    if (w <= 0 || h <= 0) return null;
    return (width: w, height: h);
  } catch (_) {
    return null;
  } finally {
    frame?.image.dispose();
    codec?.dispose();
  }
}
