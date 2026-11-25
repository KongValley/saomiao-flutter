import 'dart:math' as math;
import 'dart:typed_data';

import 'filters.dart';
import 'options.dart';

const double _degToRad = math.pi / 180.0;

class PixelImage {
  const PixelImage({
    required this.data,
    required this.width,
    required this.height,
    required this.channels,
  });

  final Uint8List data;
  final int width;
  final int height;
  final int channels;
}

/// 部分主元高斯消元解 8 元线性方程组 A·h = b
Float64List? _solveLinear8(Float64List a, Float64List b) {
  final m = Float64List(8 * 9);
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      m[r * 9 + c] = a[r * 8 + c];
    }
    m[r * 9 + 8] = b[r];
  }
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    var maxAbs = m[col * 9 + col].abs();
    for (var r = col + 1; r < 8; r++) {
      final v = m[r * 9 + col].abs();
      if (v > maxAbs) {
        maxAbs = v;
        pivot = r;
      }
    }
    if (!(maxAbs > 1e-12)) return null;
    if (pivot != col) {
      for (var c = col; c < 9; c++) {
        final t = m[col * 9 + c];
        m[col * 9 + c] = m[pivot * 9 + c];
        m[pivot * 9 + c] = t;
      }
    }
    final pv = m[col * 9 + col];
    for (var r = col + 1; r < 8; r++) {
      final f = m[r * 9 + col] / pv;
      if (f == 0) continue;
      for (var c = col; c < 9; c++) {
        m[r * 9 + c] -= f * m[col * 9 + c];
      }
    }
  }
  final h = Float64List(9);
  for (var r = 7; r >= 0; r--) {
    var s = m[r * 9 + 8];
    for (var c = r + 1; c < 8; c++) {
      s -= m[r * 9 + c] * h[c];
    }
    final d = m[r * 9 + r];
    if (d.abs() < 1e-12) return null;
    h[r] = s / d;
  }
  h[8] = 1.0;
  return h;
}

/// 求单应性矩阵 H，使 to ≈ H · from
Float64List? solveHomography(List<List<double>> from, List<List<double>> to) {
  final a = Float64List(64);
  final b = Float64List(8);
  for (var i = 0; i < 4; i++) {
    final x = from[i][0];
    final y = from[i][1];
    final u = to[i][0];
    final v = to[i][1];
    final r0 = i * 16;
    final r1 = r0 + 8;
    a[r0] = x;
    a[r0 + 1] = y;
    a[r0 + 2] = 1.0;
    a[r0 + 6] = -u * x;
    a[r0 + 7] = -u * y;
    b[i * 2] = u;
    a[r1 + 3] = x;
    a[r1 + 4] = y;
    a[r1 + 5] = 1.0;
    a[r1 + 6] = -v * x;
    a[r1 + 7] = -v * y;
    b[i * 2 + 1] = v;
  }
  return _solveLinear8(a, b);
}

/// 归一化四角（0..1，TL,TR,BR,BL）→ 像素坐标
List<List<double>> cornersToPixels(List<CornerPoint> corners, int w, int h) {
  return List<List<double>>.generate(
    4,
    (i) => <double>[corners[i].x * w, corners[i].y * h],
    growable: false,
  );
}

/// 透视输出尺寸估计：宽 = (上边 + 下边) / 2，高 = (左边 + 右边) / 2
({int width, int height}) estimateOutputSize(List<List<double>> quad) {
  double dist(List<double> a, List<double> b) {
    final dx = b[0] - a[0];
    final dy = b[1] - a[1];
    return math.sqrt(dx * dx + dy * dy);
  }

  final wTop = dist(quad[0], quad[1]);
  final wBottom = dist(quad[3], quad[2]);
  final hLeft = dist(quad[0], quad[3]);
  final hRight = dist(quad[1], quad[2]);
  var width = ((wTop + wBottom) * 0.5).round();
  var height = ((hLeft + hRight) * 0.5).round();
  if (!(width > 0) || !(height > 0)) return (width: 8, height: 8);
  width = width.clamp(8, 20000);
  height = height.clamp(8, 20000);
  return (width: width, height: height);
}

bool _isConvexPixelQuad(List<List<double>> quad) {
  if (quad.length != 4) return false;
  for (final p in quad) {
    if (p.length < 2 || !p[0].isFinite || !p[1].isFinite) return false;
  }
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    final c = quad[(i + 2) % 4];
    final cr = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cr.abs() <= 1e-4) return false;
    final s = cr > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// 透视变换：输出像素网格逆映射回源图四角四边形，双线性插值采样
Uint8List perspectiveTransform(
  Uint8List data,
  int w,
  int h,
  List<List<double>> quad,
  int outW,
  int outH,
) {
  if (!_isConvexPixelQuad(quad)) {
    throw StateError('透视矫正失败：四个角点需构成凸四边形，请重新框选');
  }
  final dst = <List<double>>[
    <double>[0, 0],
    <double>[outW.toDouble(), 0],
    <double>[outW.toDouble(), outH.toDouble()],
    <double>[0, outH.toDouble()],
  ];
  final H = solveHomography(dst, quad);
  if (H == null) {
    throw StateError('透视矫正失败：四个角点退化，请重新框选');
  }

  final out = Uint8List(outW * outH * 4);
  final h0 = H[0];
  final h1 = H[1];
  final h2 = H[2];
  final h3 = H[3];
  final h4 = H[4];
  final h5 = H[5];
  final h6 = H[6];
  final h7 = H[7];
  final maxX = w - 1;
  final maxY = h - 1;
  for (var y = 0; y < outH; y++) {
    final cy = y + 0.5;
    final baseY = h1 * cy + h2;
    final baseSy = h4 * cy + h5;
    final baseDen = h7 * cy + 1.0;
    var sxNum = h0 * 0.5 + baseY;
    var syNum = h3 * 0.5 + baseSy;
    var den = h6 * 0.5 + baseDen;
    var p = y * outW * 4;
    for (var x = 0; x < outW; x++, p += 4) {
      final inv = 1.0 / den;
      var fx = sxNum * inv - 0.5;
      var fy = syNum * inv - 0.5;
      fx = fx < 0 ? 0.0 : (fx > maxX ? maxX.toDouble() : fx);
      fy = fy < 0 ? 0.0 : (fy > maxY ? maxY.toDouble() : fy);
      final x0 = fx.toInt();
      final y0 = fy.toInt();
      final ax = fx - x0;
      final ay = fy - y0;
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final i00 = (y0 * w + x0) * 4;
      final i01 = (y0 * w + x1) * 4;
      final i10 = (y1 * w + x0) * 4;
      final i11 = (y1 * w + x1) * 4;
      final w00 = (1.0 - ax) * (1.0 - ay);
      final w01 = ax * (1.0 - ay);
      final w10 = (1.0 - ax) * ay;
      final w11 = ax * ay;
      out[p] = clamp255(data[i00] * w00 + data[i01] * w01 + data[i10] * w10 + data[i11] * w11);
      out[p + 1] = clamp255(data[i00 + 1] * w00 + data[i01 + 1] * w01 + data[i10 + 1] * w10 + data[i11 + 1] * w11);
      out[p + 2] = clamp255(data[i00 + 2] * w00 + data[i01 + 2] * w01 + data[i10 + 2] * w10 + data[i11 + 2] * w11);
      out[p + 3] = clamp255(data[i00 + 3] * w00 + data[i01 + 3] * w01 + data[i10 + 3] * w10 + data[i11 + 3] * w11);
      sxNum += h0;
      syNum += h3;
      den += h6;
    }
  }
  return out;
}

/// deskew 旋转：绕中心旋转 angle 弧度，并裁掉旋转后露白边（内接矩形保守裁剪）
PixelImage deskewRotate(
  Uint8List src,
  int w,
  int h,
  int channels,
  double angle,
) {
  if (angle.abs() < 0.0009 || w < 8 || h < 8 || channels < 1) {
    return PixelImage(data: src, width: w, height: h, channels: channels);
  }
  final sin = math.sin(angle);
  final cos = math.cos(angle);
  final absSin = sin.abs();
  final insetX = ((h / 2.0) * absSin).ceil() + 1;
  final insetY = ((w / 2.0) * absSin).ceil() + 1;
  final nw = w - 2 * insetX;
  final nh = h - 2 * insetY;
  if (nw < w * 0.5 || nh < h * 0.5) {
    return PixelImage(data: src, width: w, height: h, channels: channels);
  }
  final out = Uint8List(nw * nh * channels);
  final ccx = w / 2.0;
  final ccy = h / 2.0;
  final ocx = nw / 2.0;
  final ocy = nh / 2.0;
  final maxX = w - 1;
  final maxY = h - 1;
  for (var y = 0; y < nh; y++) {
    final dy = y + 0.5 - ocy;
    var p = y * nw * channels;
    for (var x = 0; x < nw; x++, p += channels) {
      final dx = x + 0.5 - ocx;
      var fx = ccx + dx * cos + dy * sin - 0.5;
      var fy = ccy - dx * sin + dy * cos - 0.5;
      fx = fx < 0 ? 0.0 : (fx > maxX ? maxX.toDouble() : fx);
      fy = fy < 0 ? 0.0 : (fy > maxY ? maxY.toDouble() : fy);
      final x0 = fx.toInt();
      final y0 = fy.toInt();
      final ax = fx - x0;
      final ay = fy - y0;
      final x1 = x0 < maxX ? x0 + 1 : x0;
      final y1 = y0 < maxY ? y0 + 1 : y0;
      final i00 = (y0 * w + x0) * channels;
      final i01 = (y0 * w + x1) * channels;
      final i10 = (y1 * w + x0) * channels;
      final i11 = (y1 * w + x1) * channels;
      final w00 = (1.0 - ax) * (1.0 - ay);
      final w01 = ax * (1.0 - ay);
      final w10 = (1.0 - ax) * ay;
      final w11 = ax * ay;
      for (var c = 0; c < channels; c++) {
        out[p + c] = clamp255(
          src[i00 + c] * w00 + src[i01 + c] * w01 + src[i10 + c] * w10 + src[i11 + c] * w11,
        );
      }
    }
  }
  return PixelImage(data: out, width: nw, height: nh, channels: channels);
}

/// 倾斜角检测：将暗像素投影到行方向，找使行投影方差最大的旋转角（弧度）
double detectSkewAngle(Uint8List gray, int w, int h) {
  final long = math.max(w, h);
  if (long < 80) return 0.0;
  final factor = math.max(1, (long / 900.0).round());
  Float32List blurred;
  int sw;
  int sh;
  if (factor > 1) {
    final d = downsampleGrid(gray, w, h, factor);
    sw = d.width;
    sh = d.height;
    blurred = boxBlurFloat(d.data, sw, sh, 1, 1);
  } else {
    sw = w;
    sh = h;
    blurred = Float32List(w * h);
    for (var i = 0; i < w * h; i++) {
      blurred[i] = gray[i].toDouble();
    }
  }

  final hist = Uint32List(256);
  for (var i = 0; i < sw * sh; i++) {
    final v = blurred[i];
    hist[v <= 0 ? 0 : (v >= 255 ? 255 : v.toInt())]++;
  }
  final thr = otsuThreshold(hist);
  final total = sw * sh;
  final xs = Float32List(total);
  final ys = Float32List(total);
  var cnt = 0;
  for (var i = 0; i < total; i++) {
    if (blurred[i] <= thr) {
      xs[cnt] = (i % sw).toDouble();
      ys[cnt] = (i ~/ sw).toDouble();
      cnt++;
    }
  }
  if (cnt < 200 || cnt > (total * 0.85).round()) return 0.0;

  final cx = sw / 2.0;
  final cy = sh / 2.0;
  final histSize = sw + sh + 8;
  final offset = ((sw + sh) >> 1) + 4;
  final rowHist = Int32List(histSize);

  double varianceAt(double theta, int step) {
    final sin = math.sin(theta);
    final cos = math.cos(theta);
    rowHist.fillRange(0, histSize, 0);
    var count = 0;
    for (var i = 0; i < cnt; i += step) {
      final dx = xs[i] - cx;
      final dy = ys[i] - cy;
      var idx = (dx * sin + dy * cos).round() + offset;
      if (idx < 0) {
        idx = 0;
      } else if (idx >= histSize) {
        idx = histSize - 1;
      }
      rowHist[idx]++;
      count++;
    }
    if (count < 50) return -1.0;
    var sum = 0.0;
    var sumSq = 0.0;
    for (var i = 0; i < histSize; i++) {
      final v = rowHist[i];
      if (v != 0) {
        sum += v;
        sumSq += v * v;
      }
    }
    final mean = sum / count;
    return sumSq / count - mean * mean;
  }

  final coarseStep = math.max(1, (cnt / 40000.0).ceil());
  var bestDeg = 0.0;
  var bestVar = -1.0;
  for (var deg = -15; deg <= 15; deg++) {
    final v = varianceAt(deg * _degToRad, coarseStep);
    if (v > bestVar) {
      bestVar = v;
      bestDeg = deg.toDouble();
    }
  }
  if (bestVar < 0 || bestDeg.abs() < 0.2) return 0.0;

  final fineStep = math.max(1, (cnt / 200000.0).ceil());
  var refined = bestDeg;
  for (var pass = 0; pass < 2; pass++) {
    final span = pass == 0 ? 1.0 : 0.2;
    final stepDeg = pass == 0 ? 0.2 : 0.05;
    var localBest = refined;
    var localVar = -1.0;
    for (var deg = refined - span; deg <= refined + span + 1e-9; deg += stepDeg) {
      final v = varianceAt(deg * _degToRad, fineStep);
      if (v > localVar) {
        localVar = v;
        localBest = deg;
      }
    }
    refined = localBest;
  }
  if (refined.abs() < 0.15 || refined.abs() > 15.0) return 0.0;
  return refined * _degToRad;
}

/// 自动检测对开书页中缝 X 位置（归一化 0.35..0.65，未找到明显阴影谷底时返回 0.5）
double detectBookGutterX(Uint8List rgba, int w, int h) {
  if (w < 40 || h < 20 || rgba.length < w * h * 4) return 0.5;
  final gray = toGray(rgba, w, h);
  final y0 = (h * 0.08).round();
  final y1 = (h * 0.92).round();
  final spanY = math.max(1, y1 - y0);

  final colAvg = Float64List(w);
  for (var x = 0; x < w; x++) {
    var sum = 0;
    for (var y = y0; y < y1; y++) {
      sum += gray[y * w + x];
    }
    colAvg[x] = sum / spanY;
  }

  final xStart = (w * 0.35).round().clamp(1, w - 2);
  final xEnd = (w * 0.65).round().clamp(xStart + 1, w - 1);
  final radius = math.max(1, (w * 0.008).round());

  var bestX = w ~/ 2;
  var minScore = double.infinity;
  var sumRange = 0.0;
  var countRange = 0;
  for (var x = xStart; x <= xEnd; x++) {
    var localSum = 0.0;
    var cnt = 0;
    final l = math.max(0, x - radius);
    final r = math.min(w - 1, x + radius);
    for (var k = l; k <= r; k++) {
      localSum += colAvg[k];
      cnt++;
    }
    final avg = localSum / cnt;
    sumRange += avg;
    countRange++;
    // 略微偏好靠近中心，避免边缘文字密集列干扰
    final centerDist = ((x / w) - 0.5).abs();
    final score = avg + centerDist * 35.0;
    if (score < minScore) {
      minScore = score;
      bestX = x;
    }
  }

  final meanRange = countRange > 0 ? sumRange / countRange : 255.0;
  if (meanRange - colAvg[bestX] < 4.0) {
    return 0.5;
  }
  return (bestX / w).clamp(0.35, 0.65);
}

/// 按归一化矩形裁剪 RGBA 图像
PixelImage cropNormalizedRect(
  Uint8List rgba,
  int w,
  int h,
  double left,
  double top,
  double right,
  double bottom,
) {
  final l = (left.clamp(0.0, 1.0) * w).round().clamp(0, w - 1);
  final r = (right.clamp(0.0, 1.0) * w).round().clamp(l + 1, w);
  final t = (top.clamp(0.0, 1.0) * h).round().clamp(0, h - 1);
  final b = (bottom.clamp(0.0, 1.0) * h).round().clamp(t + 1, h);
  final cw = r - l;
  final ch = b - t;
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    final srcRow = ((t + y) * w + l) * 4;
    final dstRow = y * cw * 4;
    out.setRange(dstRow, dstRow + cw * 4, rgba, srcRow);
  }
  return PixelImage(data: out, width: cw, height: ch, channels: 4);
}
