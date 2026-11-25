import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../engine/detect.dart';
import 'pixel_io.dart';

/// 兜底解码：利用 Flutter 平台编解码器（如 Android/iOS 的 HEIC）解成直通 RGBA
Future<RgbaSource?> decodePlatformImageFallback(
  Uint8List bytes, {
  int? maxPixels,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    if (!kIsWeb) {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final origW = descriptor.width;
      final origH = descriptor.height;
      if (origW <= 0 || origH <= 0) return null;
      if (origW * origH > kHardLimitPixels) {
        throw StateError('图片过大：请先压缩后再导入');
      }
      int? targetW;
      int? targetH;
      if (maxPixels != null && origW * origH > maxPixels) {
        final fit = fitMaxPixelsSize(origW, origH, maxPixels);
        targetW = fit.width;
        targetH = fit.height;
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: targetW,
        targetHeight: targetH,
      );
    } else {
      codec = await ui.instantiateImageCodec(bytes);
    }

    frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;
    if (width * height > kHardLimitPixels) {
      throw StateError('图片过大：请先压缩后再导入');
    }
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (byteData == null) return null;
    final data = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return RgbaSource(data: Uint8List.fromList(data), width: width, height: height);
  } on StateError {
    rethrow;
  } catch (_) {
    return null;
  } finally {
    frame?.image.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<({int width, int height})?> probePlatformSizeFallback(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    if (!kIsWeb) {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      if (w <= 0 || h <= 0) return null;
      return (width: w, height: h);
    }
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
    descriptor?.dispose();
    buffer?.dispose();
  }
}
