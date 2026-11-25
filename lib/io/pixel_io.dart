import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../engine/detect.dart';
import '../engine/resize.dart';
import 'pixel_io_fallback_stub.dart'
    if (dart.library.ui) 'pixel_io_fallback_flutter.dart';

const int kHardLimitPixels = 200000000; // 200MP
const int kMaxSourcePixels = 20000000; // 20MP

/// 仅探测头部宽高，避免大图直接 OOM
({int width, int height})? probeSizeSync(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final info = decoder.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    // 若有 EXIF 旋转 90/270 度，交换视觉宽高
    var w = info.width;
    var h = info.height;
    if (decoder is img.JpegDecoder) {
      final exif = img.decodeJpgExif(bytes);
      final orient = exif?.imageIfd.orientation;
      if (orient != null && orient >= 5 && orient <= 8) {
        final tmp = w;
        w = h;
        h = tmp;
      }
    }
    return (width: w, height: h);
  } catch (_) {
    return null;
  }
}

Future<({int width, int height})?> probeImageSize(Uint8List bytes) async {
  final sync = probeSizeSync(bytes);
  if (sync != null) return sync;
  return probePlatformSizeFallback(bytes);
}

({int width, int height}) fitMaxPixelsSize(int width, int height, int maxPixels) {
  final pixels = width * height;
  if (pixels <= maxPixels || width <= 0 || height <= 0) {
    return (width: width, height: height);
  }
  final longEdge = math.max(width, height);
  final targetLong = math.max(1, (longEdge * math.sqrt(maxPixels / pixels)).floor());
  final scale = targetLong / longEdge;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// 纯 Dart 解码（支持 JPEG/PNG/WebP/BMP/GIF/TIFF + EXIF 摆正），在 Isolate 中可安全运行
RgbaSource? decodeBytesPureDart(Uint8List bytes, {int? maxPixels}) {
  if (bytes.isEmpty) {
    throw StateError('图片数据为空或无法读取');
  }
  final info = probeSizeSync(bytes);
  if (info != null && info.width * info.height > kHardLimitPixels) {
    throw StateError('图片过大：请先压缩后再导入');
  }

  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) return null;
  final raw = decoder.decode(bytes);
  if (raw == null || raw.width <= 0 || raw.height <= 0) return null;
  if (raw.width * raw.height > kHardLimitPixels) {
    throw StateError('图片过大：请先压缩后再导入');
  }

  var oriented = img.bakeOrientation(raw);
  if (maxPixels != null && oriented.width * oriented.height > maxPixels) {
    final target = fitMaxPixelsSize(oriented.width, oriented.height, maxPixels);
    oriented = img.copyResize(
      oriented,
      width: target.width,
      height: target.height,
      interpolation: img.Interpolation.average,
    );
  }

  if (oriented.format != img.Format.uint8 || oriented.hasPalette || oriented.numChannels != 4) {
    oriented = oriented.convert(
      format: img.Format.uint8,
      numChannels: 4,
      alpha: 255,
    );
  }
  final rgba = oriented.getBytes(order: img.ChannelOrder.rgba, alpha: 255);
  final need = oriented.width * oriented.height * 4;
  if (rgba.length < need) {
    throw StateError('图片无法解析：像素数据不完整');
  }
  final tight = rgba.length == need ? rgba : Uint8List.sublistView(rgba, 0, need);
  return RgbaSource(data: tight, width: oriented.width, height: oriented.height);
}

/// 跨平台解码：优先纯 Dart（Isolate 可用），不支持格式（如 HEIC）回退到 Flutter 引擎编解码器
Future<RgbaSource> decodeImageBytes(
  Uint8List bytes, {
  int? maxPixels = kMaxSourcePixels,
}) async {
  final pure = decodeBytesPureDart(bytes, maxPixels: maxPixels);
  if (pure != null) return pure;

  final fallback = await decodePlatformImageFallback(bytes, maxPixels: maxPixels);
  if (fallback != null) {
    if (fallback.width * fallback.height > kHardLimitPixels) {
      throw StateError('图片过大：请先压缩后再导入');
    }
    return fallback;
  }
  throw StateError('图片无法解析：不支持的图片格式');
}

/// 超过 20MP 时按面积平均缩小
RgbaSource downscaleIfNeeded(RgbaSource src, int maxPixels) {
  final pixels = src.width * src.height;
  if (pixels <= maxPixels) return src;
  final target = fitMaxPixelsSize(src.width, src.height, maxPixels);
  final resized = resizeImage(src.data, src.width, src.height, 4, target.width, target.height);
  return RgbaSource(data: resized.data, width: resized.width, height: resized.height);
}

RgbaSource downscaleMaxEdge(RgbaSource src, int maxEdge) {
  final longEdge = math.max(src.width, src.height);
  if (longEdge <= maxEdge) return src;
  final scale = maxEdge / longEdge;
  final tw = math.max(1, (src.width * scale).round());
  final th = math.max(1, (src.height * scale).round());
  final resized = resizeImage(src.data, src.width, src.height, 4, tw, th);
  return RgbaSource(data: resized.data, width: resized.width, height: resized.height);
}

/// 将引擎输出的 1/4 通道裸像素编码为 PNG 或 JPEG
Uint8List encodePixels({
  required Uint8List data,
  required int width,
  required int height,
  required int channels,
  required String mime,
  double quality = 0.92,
}) {
  if (width <= 0 || height <= 0) {
    throw StateError('编码失败：图片尺寸非法');
  }
  final need = width * height * channels;
  if (data.length < need) {
    throw StateError('编码失败：像素数据不完整');
  }

  if (mime == 'image/png') {
    if (channels == 1) {
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: data.buffer,
        bytesOffset: data.offsetInBytes,
        numChannels: 1,
        order: img.ChannelOrder.red,
      );
      return img.encodePng(im);
    }
    final im = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: data.buffer,
      bytesOffset: data.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodePng(im);
  }

  // JPEG：转为 3 通道 RGB 以走 JpegEncoder 快速路径
  final n = width * height;
  final rgb = Uint8List(n * 3);
  if (channels == 1) {
    for (var i = 0, q = 0; i < n; i++, q += 3) {
      final v = data[i];
      rgb[q] = v;
      rgb[q + 1] = v;
      rgb[q + 2] = v;
    }
  } else {
    for (var i = 0, p = 0, q = 0; i < n; i++, p += 4, q += 3) {
      final a = data[p + 3];
      if (a == 255) {
        rgb[q] = data[p];
        rgb[q + 1] = data[p + 1];
        rgb[q + 2] = data[p + 2];
      } else {
        final inv = 255 - a;
        rgb[q] = (data[p] * a + 255 * inv) ~/ 255;
        rgb[q + 1] = (data[p + 1] * a + 255 * inv) ~/ 255;
        rgb[q + 2] = (data[p + 2] * a + 255 * inv) ~/ 255;
      }
    }
  }
  final im = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  final q = (quality.clamp(0.0, 1.0) * 100.0).round().clamp(1, 100);
  return img.encodeJpg(im, quality: q);
}
