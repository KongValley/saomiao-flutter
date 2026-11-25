import 'dart:typed_data';

import '../engine/detect.dart';

Future<RgbaSource?> decodePlatformImageFallback(
  Uint8List bytes, {
  int? maxPixels,
}) async {
  return null;
}

Future<({int width, int height})?> probePlatformSizeFallback(Uint8List bytes) async {
  return null;
}
