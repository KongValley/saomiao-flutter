import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';

/// 面积平均降采样（带小数比例的 box filter）
Uint8List areaAverage(
  Uint8List src,
  int sw,
  int sh,
  int channels,
  int dw,
  int dh,
) {
  if (channels < 1) {
    throw ArgumentError('缩放参数非法：通道数必须 ≥ 1');
  }
  if (src.length < sw * sh * channels) {
    throw ArgumentError('缩放参数非法：像素数据不完整');
  }
  final out = Uint8List(dw * dh * channels);
  final acc = Float32List(channels);
  final xscale = sw / dw;
  final yscale = sh / dh;
  for (var oy = 0; oy < dh; oy++) {
    final sy0 = oy * yscale;
    final sy1 = (oy + 1) * yscale;
    final iy0 = sy0.floor();
    final iy1 = math.min(sh, sy1.ceil());
    for (var ox = 0; ox < dw; ox++) {
      final sx0 = ox * xscale;
      final sx1 = (ox + 1) * xscale;
      final ix0 = sx0.floor();
      final ix1 = math.min(sw, sx1.ceil());
      for (var c = 0; c < channels; c++) {
        acc[c] = 0.0;
      }
      var wsum = 0.0;
      for (var iy = iy0; iy < iy1; iy++) {
        final wy = (iy + 1 < sy1 ? iy + 1.0 : sy1) - (iy > sy0 ? iy.toDouble() : sy0);
        if (wy <= 0) continue;
        final rowBase = iy * sw * channels;
        for (var ix = ix0; ix < ix1; ix++) {
          final wx = (ix + 1 < sx1 ? ix + 1.0 : sx1) - (ix > sx0 ? ix.toDouble() : sx0);
          if (wx <= 0) continue;
          final wgt = wx * wy;
          wsum += wgt;
          final p = rowBase + ix * channels;
          for (var c = 0; c < channels; c++) {
            acc[c] += src[p + c] * wgt;
          }
        }
      }
      final inv = wsum > 0 ? 1.0 / wsum : 0.0;
      final q = (oy * dw + ox) * channels;
      for (var c = 0; c < channels; c++) {
        final v = acc[c] * inv + 0.5;
        out[q + c] = v >= 255 ? 255 : (v <= 0 ? 0 : v.toInt());
      }
    }
  }
  return out;
}

/// 双线性插值（任意比例，边界按复制处理）
Uint8List bilinear(
  Uint8List src,
  int sw,
  int sh,
  int channels,
  int dw,
  int dh,
) {
  final out = Uint8List(dw * dh * channels);
  final fx = sw / dw;
  final fy = sh / dh;
  final maxX = sw - 1;
  final maxY = sh - 1;
  for (var oy = 0; oy < dh; oy++) {
    var sy = (oy + 0.5) * fy - 0.5;
    if (sy < 0) {
      sy = 0.0;
    } else if (sy > maxY) {
      sy = maxY.toDouble();
    }
    final y0 = sy.toInt();
    final ay = sy - y0;
    final y1 = y0 < maxY ? y0 + 1 : y0;
    final row0 = y0 * sw * channels;
    final row1 = y1 * sw * channels;
    var q = oy * dw * channels;
    for (var ox = 0; ox < dw; ox++, q += channels) {
      var sx = (ox + 0.5) * fx - 0.5;
      if (sx < 0) {
        sx = 0.0;
      } else if (sx > maxX) {
        sx = maxX.toDouble();
      }
      final x0 = sx.toInt();
      final ax = sx - x0;
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final p00 = row0 + x0 * channels;
      final p01 = row0 + x1 * channels;
      final p10 = row1 + x0 * channels;
      final p11 = row1 + x1 * channels;
      final w00 = (1.0 - ax) * (1.0 - ay);
      final w01 = ax * (1.0 - ay);
      final w10 = (1.0 - ax) * ay;
      final w11 = ax * ay;
      for (var c = 0; c < channels; c++) {
        final v = src[p00 + c] * w00 +
            src[p01 + c] * w01 +
            src[p10 + c] * w10 +
            src[p11 + c] * w11 +
            0.5;
        out[q + c] = v >= 255 ? 255 : (v <= 0 ? 0 : v.toInt());
      }
    }
  }
  return out;
}

/// 通用缩放：目标比源小 → 面积平均；目标比源大 → 双线性
PixelImage resizeImage(
  Uint8List data,
  int sw,
  int sh,
  int channels,
  num dw,
  num dh,
) {
  if (channels < 1) {
    throw ArgumentError('缩放参数非法：通道数必须 ≥ 1');
  }
  final tw = math.max(1, dw.round());
  final th = math.max(1, dh.round());
  if (tw == sw && th == sh) {
    return PixelImage(data: data, width: sw, height: sh, channels: channels);
  }
  if (sw <= 0 || sh <= 0) {
    throw ArgumentError('图片尺寸非法');
  }
  final isDown = tw <= sw && th <= sh;
  final out = isDown
      ? areaAverage(data, sw, sh, channels, tw, th)
      : bilinear(data, sw, sh, channels, tw, th);
  return PixelImage(data: out, width: tw, height: th, channels: channels);
}

/// 旋转 90/180/270 度（顺时针）
PixelImage rotateImage(
  Uint8List data,
  int w,
  int h,
  int channels,
  num? rotate,
) {
  final q = (((rotate ?? 0) / 90.0).round() * 90);
  final deg = ((q % 360) + 360) % 360;
  if (deg == 0) {
    return PixelImage(data: data, width: w, height: h, channels: channels);
  }
  if (deg == 180) {
    final out = Uint8List(w * h * channels);
    final last = w * h - 1;
    for (var i = 0; i <= last; i++) {
      final p = i * channels;
      final qIdx = (last - i) * channels;
      for (var c = 0; c < channels; c++) {
        out[qIdx + c] = data[p + c];
      }
    }
    return PixelImage(data: out, width: w, height: h, channels: channels);
  }
  final nw = h;
  final nh = w;
  final out = Uint8List(nw * nh * channels);
  for (var dy = 0; dy < nh; dy++) {
    for (var dx = 0; dx < nw; dx++) {
      final sx = deg == 90 ? dy : w - 1 - dy;
      final sy = deg == 90 ? h - 1 - dx : dx;
      final p = (sy * w + sx) * channels;
      final qIdx = (dy * nw + dx) * channels;
      for (var c = 0; c < channels; c++) {
        out[qIdx + c] = data[p + c];
      }
    }
  }
  return PixelImage(data: out, width: nw, height: nh, channels: channels);
}
