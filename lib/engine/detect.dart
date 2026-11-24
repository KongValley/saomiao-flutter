import 'dart:math' as math;
import 'dart:typed_data';

import 'filters.dart';
import 'options.dart';
import 'resize.dart';

/// 整图四角（归一化：TL, TR, BR, BL）
const List<CornerPoint> fullCorners = <CornerPoint>[
  CornerPoint(0.0, 0.0),
  CornerPoint(1.0, 0.0),
  CornerPoint(1.0, 1.0),
  CornerPoint(0.0, 1.0),
];

class DetectCornersResult {
  const DetectCornersResult({
    required this.corners,
    required this.width,
    required this.height,
    required this.confidence,
  });

  final List<CornerPoint> corners;
  final int width;
  final int height;
  final double confidence;
}

class RgbaSource {
  const RgbaSource({
    required this.data,
    required this.width,
    required this.height,
  });

  final Uint8List data;
  final int width;
  final int height;
}

double _distToLine(double a, double b, double c, double x, double y) {
  return (a * x + b * y + c).abs();
}

/// 用最小二乘（PCA 主轴）拟合直线，返回归一化 a, b, c
List<double>? _fitLine(List<List<double>> pts) {
  final n = pts.length;
  if (n < 2) return null;
  var mx = 0.0;
  var my = 0.0;
  for (var i = 0; i < n; i++) {
    mx += pts[i][0];
    my += pts[i][1];
  }
  mx /= n;
  my /= n;
  var sxx = 0.0;
  var syy = 0.0;
  var sxy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = pts[i][0] - mx;
    final dy = pts[i][1] - my;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final theta = 0.5 * math.atan2(2.0 * sxy, sxx - syy);
  final dx = math.cos(theta);
  final dy = math.sin(theta);
  final a = -dy;
  final b = dx;
  final c = -(a * mx + b * my);
  return <double>[a, b, c];
}

List<double>? _intersectLines(List<double> l1, List<double> l2) {
  final a1 = l1[0], b1 = l1[1], c1 = l1[2];
  final a2 = l2[0], b2 = l2[1], c2 = l2[2];
  final det = a1 * b2 - a2 * b1;
  if (det.abs() < 1e-9) return null;
  return <double>[
    (b1 * c2 - b2 * c1) / det,
    (c1 * a2 - c2 * a1) / det,
  ];
}

List<List<double>> _convexHull(List<int> xs, List<int> ys) {
  final count = xs.length;
  final pts = List<List<double>>.generate(
    count,
    (i) => <double>[xs[i].toDouble(), ys[i].toDouble()],
    growable: false,
  );
  pts.sort((p, q) {
    final cmp = p[0].compareTo(q[0]);
    return cmp != 0 ? cmp : p[1].compareTo(q[1]);
  });
  final uniq = <List<double>>[];
  for (final p in pts) {
    if (uniq.isEmpty || uniq.last[0] != p[0] || uniq.last[1] != p[1]) {
      uniq.add(p);
    }
  }
  if (uniq.length <= 3) return uniq;

  double cross(List<double> o, List<double> a, List<double> b) =>
      (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);

  final lower = <List<double>>[];
  for (final p in uniq) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <List<double>>[];
  for (var i = uniq.length - 1; i >= 0; i--) {
    final p = uniq[i];
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return <List<double>>[...lower, ...upper];
}

double _shoelace(List<List<double>> quad) {
  var s = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    s += a[0] * b[1] - b[0] * a[1];
  }
  return s.abs() / 2.0;
}

bool _isConvex(List<List<double>> quad) {
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    final c = quad[(i + 2) % 4];
    final cr = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cr.abs() < 1e-6) continue;
    final s = cr > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

({List<CornerPoint> corners, double confidence})? _fitQuadFromMask(
  Uint8List mask,
  int w,
  int h,
) {
  final n = w * h;
  final labels = Int32List(n);
  final stack = Int32List(n);
  var label = 0;
  var bestLabel = 0;
  var bestSize = 0;

  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final i = row + x;
      if (mask[i] == 0 || labels[i] != 0) continue;
      label++;
      var top = 0;
      stack[top++] = i;
      labels[i] = label;
      var size = 0;
      while (top > 0) {
        final cur = stack[--top];
        size++;
        final cx = cur % w;
        if (cx > 0) {
          final nb = cur - 1;
          if (mask[nb] != 0 && labels[nb] == 0) {
            labels[nb] = label;
            stack[top++] = nb;
          }
        }
        if (cx < w - 1) {
          final nb = cur + 1;
          if (mask[nb] != 0 && labels[nb] == 0) {
            labels[nb] = label;
            stack[top++] = nb;
          }
        }
        if (cur >= w) {
          final nb = cur - w;
          if (mask[nb] != 0 && labels[nb] == 0) {
            labels[nb] = label;
            stack[top++] = nb;
          }
        }
        if (cur + w < n) {
          final nb = cur + w;
          if (mask[nb] != 0 && labels[nb] == 0) {
            labels[nb] = label;
            stack[top++] = nb;
          }
        }
      }
      if (size > bestSize) {
        bestSize = size;
        bestLabel = label;
      }
    }
  }
  if (bestLabel == 0 || bestSize < n * 0.05) return null;

  final xs = <int>[];
  final ys = <int>[];
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final i = row + x;
      if (labels[i] != bestLabel) continue;
      final edge = x == 0 ||
          y == 0 ||
          x == w - 1 ||
          y == h - 1 ||
          labels[i - 1] != bestLabel ||
          labels[i + 1] != bestLabel ||
          labels[i - w] != bestLabel ||
          labels[i + w] != bestLabel;
      if (edge) {
        xs.add(x);
        ys.add(y);
      }
    }
  }
  if (xs.length < 20) return null;
  final hull = _convexHull(xs, ys);
  if (hull.length < 4) return null;

  var iTL = 0;
  var iBR = 0;
  var iTR = 0;
  var iBL = 0;
  var minSum = double.infinity;
  var maxSum = double.negativeInfinity;
  var maxDiff = double.negativeInfinity;
  var minDiff = double.infinity;
  for (var i = 0; i < hull.length; i++) {
    final s = hull[i][0] + hull[i][1];
    final d = hull[i][0] - hull[i][1];
    if (s < minSum) {
      minSum = s;
      iTL = i;
    }
    if (s > maxSum) {
      maxSum = s;
      iBR = i;
    }
    if (d > maxDiff) {
      maxDiff = d;
      iTR = i;
    }
    if (d < minDiff) {
      minDiff = d;
      iBL = i;
    }
  }
  final uniqIdx = <int>{iTL, iTR, iBR, iBL};
  if (uniqIdx.length < 4) return null;
  var quad = <List<double>>[
    <double>[hull[iTL][0], hull[iTL][1]],
    <double>[hull[iTR][0], hull[iTR][1]],
    <double>[hull[iBR][0], hull[iBR][1]],
    <double>[hull[iBL][0], hull[iBL][1]],
  ];

  final diag = math.sqrt(w * w + h * h);
  final tol = math.max(2.5, diag * 0.045);
  final edges = <List<double>>[];
  for (var e = 0; e < 4; e++) {
    final p = quad[e];
    final q = quad[(e + 1) % 4];
    final ex = q[0] - p[0];
    final ey = q[1] - p[1];
    final len2 = ex * ex + ey * ey;
    if (len2 < 1.0) return null;
    final len = math.sqrt(len2);
    final a = -ey / len;
    final b = ex / len;
    final c = -(a * p[0] + b * p[1]);
    final inliers = <List<double>>[];
    for (var i = 0; i < hull.length; i++) {
      final hx = hull[i][0];
      final hy = hull[i][1];
      if (_distToLine(a, b, c, hx, hy) > tol) continue;
      final t = ((hx - p[0]) * ex + (hy - p[1]) * ey) / len2;
      if (t < -0.1 || t > 1.1) continue;
      inliers.add(hull[i]);
    }
    if (inliers.length >= 6) {
      final fitted = _fitLine(inliers);
      if (fitted != null) {
        edges.add(fitted);
      } else {
        edges.add(<double>[a, b, c]);
      }
    } else {
      edges.add(<double>[a, b, c]);
    }
  }

  final tl = _intersectLines(edges[0], edges[3]);
  final tr = _intersectLines(edges[0], edges[1]);
  final br = _intersectLines(edges[1], edges[2]);
  final bl = _intersectLines(edges[2], edges[3]);
  if (tl == null || tr == null || br == null || bl == null) return null;
  quad = <List<double>>[tl, tr, br, bl];

  for (var i = 0; i < 4; i++) {
    final x = quad[i][0];
    final y = quad[i][1];
    if (!x.isFinite || !y.isFinite) return null;
    if (x < -w * 0.05 || x > w * 1.05 || y < -h * 0.05 || y > h * 1.05) {
      return null;
    }
  }
  if (!_isConvex(quad)) return null;
  final area = _shoelace(quad);
  if (area < n * 0.08 || area > n * 1.3) return null;

  final areaFrac = bestSize / n;
  final pick = math.min(hull.length, 200);
  final stride = math.max(1, hull.length ~/ pick);
  var rs = 0.0;
  var rc = 0;
  for (var i = 0; i < hull.length; i += stride) {
    var best = double.infinity;
    for (var e = 0; e < 4; e++) {
      final p = quad[e];
      final q = quad[(e + 1) % 4];
      final ex = q[0] - p[0];
      final ey = q[1] - p[1];
      var len = math.sqrt(ex * ex + ey * ey);
      if (len == 0) len = 1.0;
      final d = ((ey / len) * (hull[i][0] - p[0]) - (ex / len) * (hull[i][1] - p[1])).abs();
      if (d < best) best = d;
    }
    rs += best;
    rc++;
  }
  final residual = rc > 0 ? rs / rc / diag : 0.0;
  var conf = 0.35 + 0.5 * math.min(1.0, areaFrac / 0.55) - math.min(0.35, residual * 30.0);
  if (bestSize / n > 0.92) conf -= 0.15;
  conf = conf.clamp(0.1, 0.92);

  final corners = quad
      .map(
        (p) => CornerPoint(
          ((p[0] / w).clamp(0.0, 1.0) * 10000).round() / 10000.0,
          ((p[1] / h).clamp(0.0, 1.0) * 10000).round() / 10000.0,
        ),
      )
      .toList(growable: false);

  if (_shoelace(corners.map((c) => <double>[c.x, c.y]).toList()) < 0.01) {
    return null;
  }
  return (corners: corners, confidence: conf);
}

Uint8List _rgbaToGrayDetect(Uint8List rgba, int n) {
  final gray = Uint8List(n);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    gray[i] = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2]) >> 8;
  }
  return gray;
}

/// 检测四角（返回原图归一化坐标）
DetectCornersResult detectCornersFromRgba(RgbaSource? source) {
  if (source == null || source.data.isEmpty) {
    throw StateError('图片数据为空或无法读取');
  }
  final srcW = source.width;
  final srcH = source.height;
  if (srcW <= 0 || srcH <= 0) {
    throw StateError('图片尺寸非法：宽高必须大于 0');
  }
  if (source.data.length < srcW * srcH * 4) {
    throw StateError('图片数据不完整：像素数量与宽高不符');
  }

  const maxEdge = 600;
  final scale = math.min(1.0, maxEdge / math.max(srcW, srcH));
  final w = math.max(1, (srcW * scale).round());
  final h = math.max(1, (srcH * scale).round());
  final n = w * h;

  final smallRgba = resizeImage(source.data, srcW, srcH, 4, w, h).data;
  final gray = _rgbaToGrayDetect(smallRgba, n);

  if (w < 24 || h < 24) {
    return DetectCornersResult(
      corners: fullCorners,
      width: srcW,
      height: srcH,
      confidence: 0.1,
    );
  }

  final blurred = boxBlurFloat(gray, w, h, 2, 1);
  final hist = Uint32List(256);
  for (var i = 0; i < n; i++) {
    final v = blurred[i];
    hist[v <= 0 ? 0 : (v >= 255 ? 255 : v.toInt())]++;
  }
  final otsu = otsuThreshold(hist);
  final mask = Uint8List(n);
  var bright = 0;
  for (var i = 0; i < n; i++) {
    if (blurred[i] > otsu) {
      mask[i] = 1;
      bright++;
    }
  }
  final frac = bright / n;

  if (frac > 0.95) {
    return DetectCornersResult(
      corners: fullCorners,
      width: srcW,
      height: srcH,
      confidence: 0.45,
    );
  }
  if (frac >= 0.06 && frac <= 0.95) {
    final fit = _fitQuadFromMask(mask, w, h);
    if (fit != null) {
      return DetectCornersResult(
        corners: fit.corners,
        width: srcW,
        height: srcH,
        confidence: fit.confidence,
      );
    }
  }

  // 兜底：用画面四周一圈亮度中位数，找与桌面明显不同的区域
  final border = <double>[];
  final inset = math.max(2, (math.min(w, h) * 0.02).round());
  for (var x = 0; x < w; x += 2) {
    border.add(blurred[x]);
    border.add(blurred[(h - 1) * w + x]);
  }
  for (var y = 0; y < h; y += 2) {
    border.add(blurred[y * w]);
    border.add(blurred[y * w + w - 1]);
  }
  border.sort();
  final borderMed = border.isNotEmpty ? border[border.length ~/ 2] : 0.0;
  final tol2 = math.max(22, inset * 4).toDouble();
  final mask2 = Uint8List(n);
  var cnt2 = 0;
  for (var i = 0; i < n; i++) {
    if ((blurred[i] - borderMed).abs() > tol2) {
      mask2[i] = 1;
      cnt2++;
    }
  }
  final frac2 = cnt2 / n;
  if (frac2 >= 0.06 && frac2 <= 0.95) {
    final fit2 = _fitQuadFromMask(mask2, w, h);
    if (fit2 != null) {
      return DetectCornersResult(
        corners: fit2.corners,
        width: srcW,
        height: srcH,
        confidence: math.max(0.1, fit2.confidence - 0.15),
      );
    }
  }

  return DetectCornersResult(
    corners: fullCorners,
    width: srcW,
    height: srcH,
    confidence: 0.15,
  );
}
