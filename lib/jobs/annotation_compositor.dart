import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../engine/detect.dart';
import '../engine/filters.dart';
import '../state/page_models.dart';

class SignatureStampData {
  const SignatureStampData({
    required this.placement,
    required this.rgba,
    required this.width,
    required this.height,
  });

  final SignaturePlacement placement;
  final Uint8List rgba;
  final int width;
  final int height;
}

Uint8List _ensureRgba(Uint8List data, int w, int h, int channels) {
  if (channels == 4) return Uint8List.fromList(data);
  final n = w * h;
  final out = Uint8List(n * 4);
  if (channels == 1) {
    for (var i = 0, q = 0; i < n; i++, q += 4) {
      final v = data[i];
      out[q] = v;
      out[q + 1] = v;
      out[q + 2] = v;
      out[q + 3] = 255;
    }
  } else if (channels == 3) {
    for (var i = 0, p = 0, q = 0; i < n; i++, p += 3, q += 4) {
      out[q] = data[p];
      out[q + 1] = data[p + 1];
      out[q + 2] = data[p + 2];
      out[q + 3] = 255;
    }
  }
  return out;
}

({int r, int g, int b, double alpha, bool multiply}) _strokeStyle(StrokeKind kind) {
  switch (kind) {
    case StrokeKind.eraseWhite:
      return (r: 255, g: 255, b: 255, alpha: 1.0, multiply: false);
    case StrokeKind.redactBlack:
      return (r: 16, g: 24, b: 40, alpha: 1.0, multiply: false);
    case StrokeKind.highlightYellow:
      return (r: 253, g: 224, b: 71, alpha: 0.42, multiply: true);
    case StrokeKind.highlightRed:
      return (r: 239, g: 68, b: 68, alpha: 0.36, multiply: false);
    case StrokeKind.highlightBlue:
      return (r: 59, g: 130, b: 246, alpha: 0.34, multiply: false);
  }
}

void _drawDiscMask(Uint8List mask, int w, int h, double cx, double cy, double r) {
  final x0 = math.max(0, (cx - r - 1).floor());
  final x1 = math.min(w - 1, (cx + r + 1).ceil());
  final y0 = math.max(0, (cy - r - 1).floor());
  final y1 = math.min(h - 1, (cy + r + 1).ceil());
  final rInner = math.max(0.0, r - 0.75);
  final rOuter = r + 0.75;
  final rInner2 = rInner * rInner;
  final rOuter2 = rOuter * rOuter;

  for (var y = y0; y <= y1; y++) {
    final dy = y - cy;
    final dy2 = dy * dy;
    final row = y * w;
    for (var x = x0; x <= x1; x++) {
      final dx = x - cx;
      final d2 = dx * dx + dy2;
      if (d2 >= rOuter2) continue;
      int cov;
      if (d2 <= rInner2) {
        cov = 255;
      } else {
        final d = math.sqrt(d2);
        cov = ((rOuter - d) / (rOuter - rInner) * 255.0).round().clamp(0, 255);
      }
      if (cov > mask[row + x]) {
        mask[row + x] = cov;
      }
    }
  }
}

void _drawCapsuleMask(
  Uint8List mask,
  int w,
  int h,
  double ax,
  double ay,
  double bx,
  double by,
  double radius,
) {
  final minX = math.max(0, (math.min(ax, bx) - radius - 1).floor());
  final maxX = math.min(w - 1, (math.max(ax, bx) + radius + 1).ceil());
  final minY = math.max(0, (math.min(ay, by) - radius - 1).floor());
  final maxY = math.min(h - 1, (math.max(ay, by) + radius + 1).ceil());

  final vx = bx - ax;
  final vy = by - ay;
  final len2 = vx * vx + vy * vy;
  if (len2 < 1e-4) {
    _drawDiscMask(mask, w, h, ax, ay, radius);
    return;
  }

  final rInner = math.max(0.0, radius - 0.75);
  final rOuter = radius + 0.75;
  final rInner2 = rInner * rInner;
  final rOuter2 = rOuter * rOuter;
  final invLen2 = 1.0 / len2;

  for (var y = minY; y <= maxY; y++) {
    final py = y - ay;
    final row = y * w;
    for (var x = minX; x <= maxX; x++) {
      final px = x - ax;
      var t = (px * vx + py * vy) * invLen2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final dx = px - vx * t;
      final dy = py - vy * t;
      final d2 = dx * dx + dy * dy;
      if (d2 >= rOuter2) continue;
      int cov;
      if (d2 <= rInner2) {
        cov = 255;
      } else {
        final d = math.sqrt(d2);
        cov = ((rOuter - d) / (rOuter - rInner) * 255.0).round().clamp(0, 255);
      }
      if (cov > mask[row + x]) {
        mask[row + x] = cov;
      }
    }
  }
}

void _applyStroke(Uint8List rgba, int w, int h, AnnotationStroke stroke) {
  if (stroke.points.isEmpty) return;
  final shortEdge = math.min(w, h).toDouble();
  final radius = math.max(1.5, stroke.width * shortEdge * 0.5);
  final mask = Uint8List(w * h);

  if (stroke.points.length == 1) {
    _drawDiscMask(
      mask,
      w,
      h,
      stroke.points.first.x * w,
      stroke.points.first.y * h,
      radius,
    );
  } else {
    for (var i = 0; i < stroke.points.length - 1; i++) {
      final a = stroke.points[i];
      final b = stroke.points[i + 1];
      _drawCapsuleMask(
        mask,
        w,
        h,
        a.x * w,
        a.y * h,
        b.x * w,
        b.y * h,
        radius,
      );
    }
  }

  final style = _strokeStyle(stroke.kind);
  final n = w * h;
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    final m = mask[i];
    if (m == 0) continue;
    final a = (m / 255.0) * style.alpha;
    final inv = 1.0 - a;
    if (style.multiply) {
      // 正片叠底高亮：保留底图黑字，白底变荧光黄
      final mr = (rgba[p] * style.r) / 255.0;
      final mg = (rgba[p + 1] * style.g) / 255.0;
      final mb = (rgba[p + 2] * style.b) / 255.0;
      rgba[p] = clamp255(rgba[p] * inv + mr * a);
      rgba[p + 1] = clamp255(rgba[p + 1] * inv + mg * a);
      rgba[p + 2] = clamp255(rgba[p + 2] * inv + mb * a);
    } else {
      rgba[p] = clamp255(rgba[p] * inv + style.r * a);
      rgba[p + 1] = clamp255(rgba[p + 1] * inv + style.g * a);
      rgba[p + 2] = clamp255(rgba[p + 2] * inv + style.b * a);
    }
  }
}

void _blendSignature(Uint8List rgba, int w, int h, SignatureStampData stamp) {
  final pl = stamp.placement;
  final sw = stamp.width;
  final sh = stamp.height;
  if (sw <= 0 || sh <= 0 || stamp.rgba.length < sw * sh * 4) return;

  final dstW = math.max(8.0, pl.widthRatio * w);
  final dstH = math.max(8.0, dstW * pl.aspectRatio);
  final cx = pl.cx * w;
  final cy = pl.cy * h;
  final cosA = math.cos(-pl.angle);
  final sinA = math.sin(-pl.angle);

  final boundR = 0.5 * math.sqrt(dstW * dstW + dstH * dstH) + 2.0;
  final x0 = math.max(0, (cx - boundR).floor());
  final x1 = math.min(w - 1, (cx + boundR).ceil());
  final y0 = math.max(0, (cy - boundR).floor());
  final y1 = math.min(h - 1, (cy + boundR).ceil());

  final src = stamp.rgba;
  for (var y = y0; y <= y1; y++) {
    final dy = y + 0.5 - cy;
    for (var x = x0; x <= x1; x++) {
      final dx = x + 0.5 - cx;
      final lx = dx * cosA - dy * sinA;
      final ly = dx * sinA + dy * cosA;
      final u = (lx / dstW) + 0.5;
      final v = (ly / dstH) + 0.5;
      if (u < 0.0 || u >= 1.0 || v < 0.0 || v >= 1.0) continue;

      final fx = (u * (sw - 1)).clamp(0.0, (sw - 1).toDouble());
      final fy = (v * (sh - 1)).clamp(0.0, (sh - 1).toDouble());
      final ix0 = fx.toInt();
      final iy0 = fy.toInt();
      final ix1 = ix0 + 1 < sw ? ix0 + 1 : ix0;
      final iy1 = iy0 + 1 < sh ? iy0 + 1 : iy0;
      final ax = fx - ix0;
      final ay = fy - iy0;

      final i00 = (iy0 * sw + ix0) * 4;
      final i01 = (iy0 * sw + ix1) * 4;
      final i10 = (iy1 * sw + ix0) * 4;
      final i11 = (iy1 * sw + ix1) * 4;
      final w00 = (1.0 - ax) * (1.0 - ay);
      final w01 = ax * (1.0 - ay);
      final w10 = (1.0 - ax) * ay;
      final w11 = ax * ay;

      final sa = (src[i00 + 3] * w00 +
              src[i01 + 3] * w01 +
              src[i10 + 3] * w10 +
              src[i11 + 3] * w11) /
          255.0;
      if (sa <= 0.01) continue;
      final sr = src[i00] * w00 + src[i01] * w01 + src[i10] * w10 + src[i11] * w11;
      final sg = src[i00 + 1] * w00 +
          src[i01 + 1] * w01 +
          src[i10 + 1] * w10 +
          src[i11 + 1] * w11;
      final sb = src[i00 + 2] * w00 +
          src[i01 + 2] * w01 +
          src[i10 + 2] * w10 +
          src[i11 + 2] * w11;

      final dstP = (y * w + x) * 4;
      final inv = 1.0 - sa;
      rgba[dstP] = clamp255(rgba[dstP] * inv + sr * sa);
      rgba[dstP + 1] = clamp255(rgba[dstP + 1] * inv + sg * sa);
      rgba[dstP + 2] = clamp255(rgba[dstP + 2] * inv + sb * sa);
    }
  }
}

void _applyWatermarkTile(
  Uint8List rgba,
  int w,
  int h,
  RgbaSource tile,
  double opacity,
) {
  final tw = tile.width;
  final th = tile.height;
  if (tw <= 0 || th <= 0 || tile.data.length < tw * th * 4) return;
  final op = opacity.clamp(0.02, 0.75);
  final tData = tile.data;

  // 平铺对齐：按输出短边比例缩放水印瓷砖，使不同分辨率下视觉密度一致
  final targetTilePx = math.max(220.0, math.min(w, h) * 0.42);
  final scale = tw / targetTilePx;

  for (var y = 0; y < h; y++) {
    final ty = ((y * scale).floor()) % th;
    final tRow = ty * tw;
    var p = y * w * 4;
    for (var x = 0; x < w; x++, p += 4) {
      final tx = ((x * scale).floor()) % tw;
      final tp = (tRow + tx) * 4;
      final ta = tData[tp + 3];
      if (ta == 0) continue;
      final a = (ta / 255.0) * op;
      final inv = 1.0 - a;
      rgba[p] = clamp255(rgba[p] * inv + tData[tp] * a);
      rgba[p + 1] = clamp255(rgba[p + 1] * inv + tData[tp + 1] * a);
      rgba[p + 2] = clamp255(rgba[p + 2] * inv + tData[tp + 2] * a);
    }
  }
}

/// 在后台 Isolate 将批注（涂白/打码/高亮/电子签名）及斜向防盗用水印合成到渲染结果上
({Uint8List data, int channels}) compositePageOverlays({
  required Uint8List data,
  required int width,
  required int height,
  required int channels,
  required PageAnnotations annotations,
  required List<SignatureStampData> signatures,
  RgbaSource? watermarkTile,
  double watermarkOpacity = 0.20,
}) {
  final hasOverlays =
      annotations.isNotEmpty || signatures.isNotEmpty || watermarkTile != null;
  if (!hasOverlays) {
    return (data: data, channels: channels);
  }

  final rgba = _ensureRgba(data, width, height, channels);
  for (final stroke in annotations.strokes) {
    _applyStroke(rgba, width, height, stroke);
  }
  for (final sig in signatures) {
    _blendSignature(rgba, width, height, sig);
  }
  if (watermarkTile != null) {
    _applyWatermarkTile(rgba, width, height, watermarkTile, watermarkOpacity);
  }
  return (data: rgba, channels: 4);
}

/// 将 PNG 签名字节解码为 RGBA 数据供 Isolate 合成
({Uint8List rgba, int width, int height})? decodeSignaturePngRgba(Uint8List pngBytes) {
  final decoded = img.decodePng(pngBytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) return null;
  final conv = decoded.numChannels == 4 && decoded.format == img.Format.uint8
      ? decoded
      : decoded.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  final bytes = conv.getBytes(order: img.ChannelOrder.rgba);
  final need = conv.width * conv.height * 4;
  if (bytes.length < need) return null;
  return (
    rgba: bytes.length == need ? bytes : Uint8List.sublistView(bytes, 0, need),
    width: conv.width,
    height: conv.height,
  );
}
