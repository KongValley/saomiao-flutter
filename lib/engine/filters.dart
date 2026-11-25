import 'dart:math' as math;
import 'dart:typed_data';

import 'options.dart';

/// 裁剪到 0..255 的整数
int clamp255(num v) {
  if (v <= 0) return 0;
  if (v >= 255) return 255;
  return v.toInt();
}

/// 将透明/半透明 RGBA 像素按白底预合成（全部不透明时直接原样返回）
Uint8List compositeWhiteRgba(Uint8List rgba, int n) {
  var hasAlpha = false;
  for (var i = 0, p = 3; i < n; i++, p += 4) {
    if (rgba[p] != 255) {
      hasAlpha = true;
      break;
    }
  }
  if (!hasAlpha) return rgba;
  final out = Uint8List(n * 4);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    final a = rgba[p + 3];
    if (a == 255) {
      out[p] = rgba[p];
      out[p + 1] = rgba[p + 1];
      out[p + 2] = rgba[p + 2];
      out[p + 3] = 255;
    } else {
      final inv = 255 - a;
      out[p] = (rgba[p] * a + 255 * inv + 127) ~/ 255;
      out[p + 1] = (rgba[p + 1] * a + 255 * inv + 127) ~/ 255;
      out[p + 2] = (rgba[p + 2] * a + 255 * inv + 127) ~/ 255;
      out[p + 3] = 255;
    }
  }
  return out;
}

/// RGBA → 灰度（BT.601 定点权重：77/150/29，透明像素按白底合成）
Uint8List toGray(Uint8List rgba, int w, int h) {
  final n = w * h;
  final gray = Uint8List(n);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    final a = rgba[p + 3];
    if (a == 255) {
      gray[i] = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2] + 128) >> 8;
    } else {
      final inv = 255 - a;
      final r = (rgba[p] * a + 255 * inv + 127) ~/ 255;
      final g = (rgba[p + 1] * a + 255 * inv + 127) ~/ 255;
      final b = (rgba[p + 2] * a + 255 * inv + 127) ~/ 255;
      gray[i] = (77 * r + 150 * g + 29 * b + 128) >> 8;
    }
  }
  return gray;
}

/// 灰度直方图（256 bin）
Uint32List histogram(Uint8List gray) {
  final hist = Uint32List(256);
  for (var i = 0; i < gray.length; i++) {
    hist[gray[i]]++;
  }
  return hist;
}

/// 大津法（Otsu）全局阈值（并列最大类间方差时取区间中点）
int otsuThreshold(Uint32List hist) {
  var total = 0;
  var sum = 0;
  for (var i = 0; i < 256; i++) {
    total += hist[i];
    sum += i * hist[i];
  }
  if (total == 0) return 128;
  var sumB = 0;
  var wB = 0;
  var firstBest = 128;
  var lastBest = 128;
  var maxVar = -1.0;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final d = mB - mF;
    final between = wB * wF * d * d;
    if (between > maxVar + 1e-6) {
      maxVar = between;
      firstBest = t;
      lastBest = t;
    } else if (maxVar >= 0 && (between - maxVar).abs() <= 1e-6) {
      lastBest = t;
    }
  }
  if (maxVar < 0) return 128;
  return (firstBest + lastBest) >> 1;
}

class FloatGrid {
  const FloatGrid({
    required this.data,
    required this.width,
    required this.height,
  });

  final Float32List data;
  final int width;
  final int height;
}

/// 平均池化降采样（用于背景场估计 / 倾角检测）
FloatGrid downsampleGrid(Uint8List gray, int w, int h, num factor) {
  final dw = math.max(1, (w / factor).round());
  final dh = math.max(1, (h / factor).round());
  final out = Float32List(dw * dh);
  for (var y = 0; y < dh; y++) {
    final y0 = (y * h) ~/ dh;
    final y1 = math.min(h, math.max(y0 + 1, ((y + 1) * h) ~/ dh));
    for (var x = 0; x < dw; x++) {
      final x0 = (x * w) ~/ dw;
      final x1 = math.min(w, math.max(x0 + 1, ((x + 1) * w) ~/ dw));
      var sum = 0;
      var cnt = 0;
      for (var yy = y0; yy < y1; yy++) {
        final base = yy * w;
        for (var xx = x0; xx < x1; xx++) {
          sum += gray[base + xx];
          cnt++;
        }
      }
      out[y * dw + x] = cnt > 0 ? sum / cnt : 0.0;
    }
  }
  return FloatGrid(data: out, width: dw, height: dh);
}

/// 最大值滤波（形态学膨胀）
Float32List maxFilter(Float32List src, int w, int h, int radius) {
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = y - radius < 0 ? 0 : y - radius;
    final y1 = y + radius >= h ? h - 1 : y + radius;
    for (var x = 0; x < w; x++) {
      final x0 = x - radius < 0 ? 0 : x - radius;
      final x1 = x + radius >= w ? w - 1 : x + radius;
      var m = 0.0;
      for (var yy = y0; yy <= y1; yy++) {
        final base = yy * w;
        for (var xx = x0; xx <= x1; xx++) {
          final v = src[base + xx];
          if (v > m) m = v;
        }
      }
      out[y * w + x] = m;
    }
  }
  return out;
}

/// 可分离盒式模糊（滑动窗口，O(n)，边缘按复制处理）
Float32List boxBlurFloat(List<num> src, int w, int h, int radius, [int passes = 1]) {
  final r = math.max(1, radius);
  final win = r * 2 + 1;
  final inv = 1.0 / win;
  final srcFloat = Float32List(w * h);
  if (src is Float32List) {
    srcFloat.setAll(0, src);
  } else {
    for (var i = 0; i < w * h; i++) {
      srcFloat[i] = src[i].toDouble();
    }
  }
  var cur = srcFloat;
  final buf = Float32List(w * h);
  final out = Float32List(w * h);
  for (var p = 0; p < passes; p++) {
    // 水平
    for (var y = 0; y < h; y++) {
      final row = y * w;
      var sum = 0.0;
      for (var k = -r; k <= r; k++) {
        sum += cur[row + (k < 0 ? 0 : (k >= w ? w - 1 : k))];
      }
      buf[row] = sum * inv;
      for (var x = 1; x < w; x++) {
        final ai = x + r;
        final si = x - r - 1;
        sum += cur[row + (ai >= w ? w - 1 : ai)] - cur[row + (si < 0 ? 0 : si)];
        buf[row + x] = sum * inv;
      }
    }
    // 垂直
    for (var x = 0; x < w; x++) {
      var sum = 0.0;
      for (var k = -r; k <= r; k++) {
        sum += buf[(k < 0 ? 0 : (k >= h ? h - 1 : k)) * w + x];
      }
      out[x] = sum * inv;
      for (var y = 1; y < h; y++) {
        final ai = y + r;
        final si = y - r - 1;
        sum += buf[(ai >= h ? h - 1 : ai) * w + x] - buf[(si < 0 ? 0 : si) * w + x];
        out[y * w + x] = sum * inv;
      }
    }
    cur = out;
  }
  return cur;
}

class BackgroundField {
  const BackgroundField({
    required this.data,
    required this.strength,
    required this.factor,
  });

  final Uint8List data;
  final double strength;
  final int factor;
}

/// 估计纸面背景照度场
BackgroundField? makeBackgroundField(Uint8List gray, int w, int h, num shadow) {
  final strength = (shadow.toDouble() / 100.0).clamp(0.0, 1.0);
  if (strength <= 0) return null;
  final factor = (8 + strength * 6).round();
  final small = downsampleGrid(gray, w, h, factor);
  final sw = small.width;
  final sh = small.height;
  var dilated = small.data;
  for (var p = 0; p < 2; p++) {
    dilated = maxFilter(dilated, sw, sh, 2);
  }
  final radius = math.max(2, (math.min(sw, sh) / 32).round());
  final smooth = boxBlurFloat(dilated, sw, sh, radius, 2);

  // 双线性放大到原图尺寸
  final field = Uint8List(w * h);
  final fx = sw / w;
  final fy = sh / h;
  for (var y = 0; y < h; y++) {
    var sy = (y + 0.5) * fy - 0.5;
    if (sy < 0) {
      sy = 0;
    } else if (sy > sh - 1) {
      sy = (sh - 1).toDouble();
    }
    final y0 = sy.toInt();
    final wy = sy - y0;
    final y1 = y0 + 1 < sh ? y0 + 1 : y0;
    final row0 = y0 * sw;
    final row1 = y1 * sw;
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var sx = (x + 0.5) * fx - 0.5;
      if (sx < 0) {
        sx = 0;
      } else if (sx > sw - 1) {
        sx = (sw - 1).toDouble();
      }
      final x0 = sx.toInt();
      final wx = sx - x0;
      final x1 = x0 + 1 < sw ? x0 + 1 : x0;
      final top = smooth[row0 + x0] * (1 - wx) + smooth[row0 + x1] * wx;
      final bot = smooth[row1 + x0] * (1 - wx) + smooth[row1 + x1] * wx;
      final v = top * (1 - wy) + bot * wy;
      field[row + x] = v <= 1 ? 1 : (v >= 255 ? 255 : v.toInt());
    }
  }
  return BackgroundField(data: field, strength: strength, factor: factor);
}

/// 背景除法压白：v' = v / bg * 255，再按 strength 与原始像素混合
Uint8List removeShadowGray(Uint8List gray, Uint8List bg, double strength) {
  final n = gray.length;
  final out = Uint8List(n);
  final s = strength.clamp(0.0, 1.0);
  final eff = 1.0 - math.pow(1.0 - s, 3);
  final hist = Uint32List(256);
  for (var i = 0; i < n; i++) {
    hist[gray[i]]++;
  }
  final topN = math.max(1, (n * 0.05).round());
  var acc = 0;
  var t = 255;
  for (; t > 0; t--) {
    acc += hist[t];
    if (acc >= topN) break;
  }
  var sumTop = 0;
  var cntTop = 0;
  for (var v = t; v < 256; v++) {
    sumTop += v * hist[v];
    cntTop += hist[v];
  }
  final paperLevel = cntTop > 0 ? sumTop / cntTop : 200.0;
  final darkGate = paperLevel * 0.5;
  for (var i = 0; i < n; i++) {
    var b = bg[i];
    if (b < 10) b = 10;
    final maxGain = b >= 60 ? 2.8 : 1.2 + (b / 60.0) * 1.6;
    var gain = 255.0 / b;
    if (gain > maxGain) gain = maxGain;
    final f = 1.0 + eff * (gain - 1.0);
    final v = gray[i];
    var o = v * f;
    if (v < darkGate) {
      final liftCap = v * 1.3 + 4.0;
      if (o > liftCap) o = liftCap;
    }
    out[i] = clamp255(o);
  }
  return out;
}

/// 估计白平衡增益：取最亮 2% 像素的平均 RGB 作为「纸色」
List<double> estimateWhiteBalance(Uint8List rgba, Uint8List gray, int w, int h) {
  final n = w * h;
  final hist = histogram(gray);
  final topN = math.max(1, (n * 0.02).round());
  var acc = 0;
  var t = 255;
  for (; t > 0; t--) {
    acc += hist[t];
    if (acc >= topN) break;
  }
  var sr = 0;
  var sg = 0;
  var sb = 0;
  var cnt = 0;
  final stride = math.max(1, n ~/ 500000);
  for (var i = 0; i < n; i += stride) {
    if (gray[i] < t) continue;
    final p = i * 4;
    sr += rgba[p];
    sg += rgba[p + 1];
    sb += rgba[p + 2];
    cnt++;
  }
  if (cnt == 0) return <double>[1.0, 1.0, 1.0];
  final ar = sr / cnt;
  final ag = sg / cnt;
  final ab = sb / cnt;
  final target = math.max(math.max(ar, ag), math.max(ab, 1.0));
  double gain(double x) {
    if (x < 1.0) return 1.0;
    final g = target / x;
    return g > 1.7 ? 1.7 : (g < 0.9 ? 0.9 : g);
  }

  return <double>[gain(ar), gain(ag), gain(ab)];
}

const double _defaultSatBoost = 1.18;

/// 彩色增强（单遍完成）：背景除法 → 白平衡 → 饱和度提升 → 曲线 LUT
Uint8List enhanceColor(
  Uint8List rgba,
  int w,
  int h,
  Uint8List? bg,
  double strength,
  List<double> wb,
  Uint8List lut, [
  double sat = _defaultSatBoost,
]) {
  final n = w * h;
  final out = Uint8List(n * 4);
  final s = strength.clamp(0.0, 1.0);
  final eff = bg != null ? 1.0 - math.pow(1.0 - s, 3) : 0.0;
  final wr = wb[0];
  final wg = wb[1];
  final wb2 = wb[2];
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    var r = rgba[p].toDouble();
    var g = rgba[p + 1].toDouble();
    var b = rgba[p + 2].toDouble();
    if (bg != null) {
      var bv = bg[i];
      if (bv < 10) bv = 10;
      final maxGain = bv >= 60 ? 2.8 : 1.2 + (bv / 60.0) * 1.6;
      var gain = 255.0 / bv;
      if (gain > maxGain) gain = maxGain;
      final f = 1.0 + eff * (gain - 1.0);
      r *= f;
      g *= f;
      b *= f;
    }
    r *= wr;
    g *= wg;
    b *= wb2;
    final y = (77 * r + 150 * g + 29 * b) * (1.0 / 256.0);
    r = y + (r - y) * sat;
    g = y + (g - y) * sat;
    b = y + (b - y) * sat;
    out[p] = lut[r <= 0 ? 0 : (r >= 255 ? 255 : r.toInt())];
    out[p + 1] = lut[g <= 0 ? 0 : (g >= 255 ? 255 : g.toInt())];
    out[p + 2] = lut[b <= 0 ? 0 : (b >= 255 ? 255 : b.toInt())];
    out[p + 3] = rgba[p + 3];
  }
  return out;
}

/// 5 值中值（十字窗口）+ 权重混合；9 比较器排序网络
Uint8List _medianCross(Uint8List src, int w, int h, double weight) {
  final out = Uint8List.fromList(src);
  final keep = 1.0 - weight;
  final wm = weight;
  for (var y = 1; y < h - 1; y++) {
    final row = y * w;
    for (var x = 1; x < w - 1; x++) {
      final i = row + x;
      var a = src[i - 1];
      var b = src[i + 1];
      var c = src[i - w];
      var d = src[i + w];
      final center = src[i];
      var e = center;
      int t;
      if (a > b) { t = a; a = b; b = t; }
      if (d > e) { t = d; d = e; e = t; }
      if (c > e) { t = c; c = e; e = t; }
      if (c > d) { t = c; c = d; d = t; }
      if (a > d) { t = a; a = d; d = t; }
      if (a > c) { t = a; a = c; c = t; }
      if (b > e) { t = b; b = e; e = t; }
      if (b > d) { t = b; b = d; d = t; }
      if (b > c) { t = b; b = c; c = t; }
      out[i] = clamp255(c * wm + center * keep + 0.5);
    }
  }
  return out;
}

/// 降噪：十字窗口中值 + 权重混合
Uint8List denoiseGray(Uint8List gray, int w, int h, num denoise) {
  final d = denoise.toDouble();
  if (d <= 0 || w < 3 || h < 3) return gray;
  final passes = d >= 70 ? 2 : 1;
  final weight = d >= 70 ? 1.0 : math.min(0.9, d / 90.0);
  var cur = gray;
  for (var p = 0; p < passes; p++) {
    cur = _medianCross(cur, w, h, weight);
  }
  return cur;
}

/// 曲线 LUT：亮度 → gamma → 对比度（S 形围绕 128）
Uint8List buildToneLut(num contrast, num brightness, num gamma) {
  final lut = Uint8List(256);
  final g = gamma.toDouble().clamp(50.0, 200.0) / 100.0;
  final exp = 1.0 / g;
  final c = contrast.toDouble().clamp(0.0, 100.0) / 100.0;
  final k = math.tan((c * 0.5 + 0.25) * math.pi * 0.5);
  final br = brightness.toDouble().clamp(-50.0, 50.0);
  for (var v = 0; v < 256; v++) {
    var x = v / 255.0;
    x = math.pow(x, exp).toDouble();
    x = (x - 0.5) * k + 0.5;
    lut[v] = clamp255((x * 255.0 + br).round());
  }
  return lut;
}

/// 灰度套 LUT（原地）
Uint8List applyLutGray(Uint8List gray, Uint8List lut) {
  for (var i = 0; i < gray.length; i++) {
    gray[i] = lut[gray[i]];
  }
  return gray;
}

/// 3x3 高斯（[1,2,1]/4 可分离）
Uint8List _gauss3(Uint8List src, int w, int h) {
  final n = w * h;
  final tmp = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    tmp[row] = (src[row] * 3 + src[row + 1] + 2) >> 2;
    final last = row + w - 1;
    tmp[last] = (src[last - 1] + src[last] * 3 + 2) >> 2;
    for (var x = 1; x < w - 1; x++) {
      tmp[row + x] = (src[row + x - 1] + 2 * src[row + x] + src[row + x + 1] + 2) >> 2;
    }
  }
  final out = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final up = (y > 0 ? y - 1 : 0) * w;
    final row = y * w;
    final dn = (y < h - 1 ? y + 1 : h - 1) * w;
    for (var x = 0; x < w; x++) {
      out[row + x] = (tmp[up + x] + 2 * tmp[row + x] + tmp[dn + x] + 2) >> 2;
    }
  }
  return out;
}

/// 5x5 高斯（[1,4,6,4,1]/16 可分离）
Uint8List _gauss5(Uint8List src, int w, int h) {
  final n = w * h;
  final tmp = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final xm2 = x > 1 ? x - 2 : 0;
      final xm1 = x > 0 ? x - 1 : 0;
      final xp1 = x < w - 1 ? x + 1 : w - 1;
      final xp2 = x < w - 2 ? x + 2 : w - 1;
      tmp[row + x] =
          (src[row + xm2] + 4 * src[row + xm1] + 6 * src[row + x] + 4 * src[row + xp1] + src[row + xp2] + 8) >> 4;
    }
  }
  final out = Uint8List(n);
  for (var y = 0; y < h; y++) {
    final ym2 = (y > 1 ? y - 2 : 0) * w;
    final ym1 = (y > 0 ? y - 1 : 0) * w;
    final row = y * w;
    final yp1 = (y < h - 1 ? y + 1 : h - 1) * w;
    final yp2 = (y < h - 2 ? y + 2 : h - 1) * w;
    for (var x = 0; x < w; x++) {
      out[row + x] =
          (tmp[ym2 + x] + 4 * tmp[ym1 + x] + 6 * tmp[row + x] + 4 * tmp[yp1 + x] + tmp[yp2 + x] + 8) >> 4;
    }
  }
  return out;
}

/// unsharp mask 锐化（灰度）
Uint8List sharpenGray(Uint8List gray, int w, int h, num sharpen) {
  final amt = (sharpen.toDouble() / 100.0).clamp(0.0, 1.0);
  if (amt <= 0 || w < 3 || h < 3) return gray;
  final amount = amt * 1.6;
  final blur = sharpen >= 55 ? _gauss5(gray, w, h) : _gauss3(gray, w, h);
  final n = w * h;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final v = gray[i];
    out[i] = clamp255(v + amount * (v - blur[i]));
  }
  return out;
}

/// 二值化：Sauvola 局部阈值（O(w) 滑动列和窗口，避免整图双 64 位积分图爆内存）与大津法融合，输出纯 0 / 255
Uint8List binarizeGray(
  Uint8List gray,
  int w,
  int h,
  num thresholdParam, {
  bool suppressFlatBackground = false,
}) {
  final out = Uint8List(w * h);
  final state = _BinarizeState(
    gray: gray,
    w: w,
    h: h,
    thresholdParam: thresholdParam,
    suppressFlatBackground: suppressFlatBackground,
    out: out,
  );
  for (var y = 0; y < h; y++) {
    state.processRow(y);
  }
  return out;
}

class _BinarizeState {
  _BinarizeState({
    required this.gray,
    required this.w,
    required this.h,
    required num thresholdParam,
    required this.suppressFlatBackground,
    required this.out,
  })  : r = (math.min(w, h) / 26).round().clamp(10, 48),
        shift = (50.0 - thresholdParam.toDouble().clamp(0.0, 100.0)) * 0.9,
        colSum = Int32List(w),
        colSumSq = Int32List(w) {
    final n = w * h;
    final hist = histogram(gray);
    var sumAll = 0;
    for (var i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    final meanGlobal = sumAll / n;
    var otsuVal = otsuThreshold(hist);
    if (otsuVal > meanGlobal * 0.9) {
      otsuVal = math.max(0, (meanGlobal * 0.78).round());
    }
    if (otsuVal < 1) otsuVal = 1;
    otsu = otsuVal;

    _prevY0 = 0;
    _prevY1 = math.min(h - 1, r);
    for (var yy = 0; yy <= _prevY1; yy++) {
      final rowBase = yy * w;
      for (var x = 0; x < w; x++) {
        final v = gray[rowBase + x];
        colSum[x] += v;
        colSumSq[x] += v * v;
      }
    }
  }

  final Uint8List gray;
  final int w;
  final int h;
  final int r;
  final double shift;
  final bool suppressFlatBackground;
  final Uint8List out;
  final Int32List colSum;
  final Int32List colSumSq;
  late final int otsu;
  late int _prevY0;
  late int _prevY1;

  void processRow(int y) {
    final y0 = y - r < 0 ? 0 : y - r;
    final y1 = y + r >= h ? h - 1 : y + r;
    if (y > 0) {
      if (y0 > _prevY0) {
        final rmBase = _prevY0 * w;
        for (var x = 0; x < w; x++) {
          final v = gray[rmBase + x];
          colSum[x] -= v;
          colSumSq[x] -= v * v;
        }
      }
      if (y1 > _prevY1) {
        final addBase = y1 * w;
        for (var x = 0; x < w; x++) {
          final v = gray[addBase + x];
          colSum[x] += v;
          colSumSq[x] += v * v;
        }
      }
      _prevY0 = y0;
      _prevY1 = y1;
    }

    final winH = y1 - y0 + 1;
    var prevX0 = 0;
    var prevX1 = math.min(w - 1, r);
    var s = 0;
    var sq = 0;
    for (var x = 0; x <= prevX1; x++) {
      s += colSum[x];
      sq += colSumSq[x];
    }

    const k = 0.18;
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = x - r < 0 ? 0 : x - r;
      final x1 = x + r >= w ? w - 1 : x + r;
      if (x > 0) {
        if (x0 > prevX0) {
          s -= colSum[prevX0];
          sq -= colSumSq[prevX0];
        }
        if (x1 > prevX1) {
          s += colSum[x1];
          sq += colSumSq[x1];
        }
        prevX0 = x0;
        prevX1 = x1;
      }

      final area = (x1 - x0 + 1) * winH;
      final mean = s / area;
      var variance = sq / area - mean * mean;
      if (variance < 0) variance = 0;
      final std = math.sqrt(variance);
      if (suppressFlatBackground && mean < 215 && std < 40) {
        out[row + x] = 0;
        continue;
      }
      var t = mean * (1.0 + k * (std / 128.0 - 1.0));
      t = 0.7 * t + 0.3 * otsu;
      final cap = mean * 0.97 + 14.0;
      if (t > cap) t = cap;
      t += shift;
      out[row + x] = gray[row + x] > t ? 255 : 0;
    }
  }
}

/// 二值图清理（抗纸面杂点，保留细笔画）
Uint8List despeckleBinary(Uint8List bin, int w, int h) {
  final out = Uint8List.fromList(bin);
  for (var y = 1; y < h - 1; y++) {
    final row = y * w;
    for (var x = 1; x < w - 1; x++) {
      final i = row + x;
      final v = bin[i];
      if (v == 0) {
        if (bin[i - 1] != 0 &&
            bin[i + 1] != 0 &&
            bin[i - w] != 0 &&
            bin[i + w] != 0 &&
            bin[i - w - 1] != 0 &&
            bin[i - w + 1] != 0 &&
            bin[i + w - 1] != 0 &&
            bin[i + w + 1] != 0) {
          out[i] = 255;
        }
      } else if (v == 255) {
        var blackNb = 0;
        if (bin[i - 1] == 0) blackNb++;
        if (bin[i + 1] == 0) blackNb++;
        if (bin[i - w] == 0) blackNb++;
        if (bin[i + w] == 0) blackNb++;
        if (bin[i - w - 1] == 0) blackNb++;
        if (bin[i - w + 1] == 0) blackNb++;
        if (bin[i + w - 1] == 0) blackNb++;
        if (bin[i + w + 1] == 0) blackNb++;
        if (blackNb >= 6) out[i] = 0;
      }
    }
  }
  return out;
}

({double gr, double gg, double gb, double ar, double ag, double ab}) _paperToneCoeff(
  PaperTone paper,
) {
  if (paper == PaperTone.warm) {
    return (gr: 1.02, gg: 0.995, gb: 0.9, ar: 6.0, ag: 2.0, ab: 0.0);
  }
  if (paper == PaperTone.gray) {
    return (gr: 0.945, gg: 0.955, gb: 0.975, ar: 0.0, ag: 0.0, ab: 0.0);
  }
  return (gr: 1.0, gg: 1.0, gb: 1.0, ar: 0.0, ag: 0.0, ab: 0.0);
}

/// 纸色映射：单通道灰度 → RGB 三通道
Uint8List paperToneRgb(Uint8List gray, int w, int h, PaperTone paper) {
  final n = w * h;
  final out = Uint8List(n * 3);
  final c = _paperToneCoeff(paper);
  for (var i = 0, p = 0; i < n; i++, p += 3) {
    final v = gray[i];
    out[p] = clamp255(v * c.gr + c.ar);
    out[p + 1] = clamp255(v * c.gg + c.ag);
    out[p + 2] = clamp255(v * c.gb + c.ab);
  }
  return out;
}

/// 纸色映射（原地）：彩色模式 RGBA
Uint8List paperToneRgba(Uint8List rgba, int n, PaperTone paper) {
  if (paper == PaperTone.white) return rgba;
  final c = _paperToneCoeff(paper);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    rgba[p] = clamp255(rgba[p] * c.gr + c.ar);
    rgba[p + 1] = clamp255(rgba[p + 1] * c.gg + c.ag);
    rgba[p + 2] = clamp255(rgba[p + 2] * c.gb + c.ab);
  }
  return rgba;
}

/// 反相（原地）
Uint8List invertGray(Uint8List gray) {
  for (var i = 0; i < gray.length; i++) {
    gray[i] = 255 - gray[i];
  }
  return gray;
}

/// RGBA 反相（原地，保留 alpha）
Uint8List invertRgba(Uint8List rgba) {
  for (var p = 0; p < rgba.length; p += 4) {
    rgba[p] = 255 - rgba[p];
    rgba[p + 1] = 255 - rgba[p + 1];
    rgba[p + 2] = 255 - rgba[p + 2];
  }
  return rgba;
}

/// 把亮度增量应用到 RGBA（彩色模式下只对亮度做降噪/锐化）
Uint8List applyLumaDeltaRgba(
  Uint8List rgba,
  Uint8List baseGray,
  Uint8List newGray,
  int n,
) {
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    final d = newGray[i] - baseGray[i];
    if (d == 0) continue;
    rgba[p] = clamp255(rgba[p] + d);
    rgba[p + 1] = clamp255(rgba[p + 1] + d);
    rgba[p + 2] = clamp255(rgba[p + 2] + d);
  }
  return rgba;
}
