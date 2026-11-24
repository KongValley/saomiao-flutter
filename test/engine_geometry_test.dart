import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/geometry.dart';
import 'package:saomiao_flutter/engine/options.dart';

List<double> _applyH(Float64List h, double x, double y) {
  final den = h[6] * x + h[7] * y + h[8];
  return [
    (h[0] * x + h[1] * y + h[2]) / den,
    (h[3] * x + h[4] * y + h[5]) / den,
  ];
}

Uint8List _makeRgba(int w, int h) {
  final data = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = (y * w + x) * 4;
      data[p] = (x * 7) % 256;
      data[p + 1] = (y * 13) % 256;
      data[p + 2] = (x * 3 + y * 5) % 256;
      data[p + 3] = 255;
    }
  }
  return data;
}

void main() {
  test('solveHomography：恒等映射与退化检测', () {
    final pts = [
      [0.0, 0.0],
      [8.0, 0.0],
      [8.0, 6.0],
      [0.0, 6.0],
    ];
    final h = solveHomography(pts, pts)!;
    expect(h[8], 1.0);
    for (final p in pts) {
      final mapped = _applyH(h, p[0], p[1]);
      expect((mapped[0] - p[0]).abs() < 1e-9, isTrue);
      expect((mapped[1] - p[1]).abs() < 1e-9, isTrue);
    }

    final colinear = [
      [0.0, 0.0],
      [1.0, 1.0],
      [2.0, 2.0],
      [3.0, 3.0],
    ];
    expect(solveHomography(colinear, colinear), isNull);
  });

  test('cornersToPixels 与 estimateOutputSize', () {
    final px = cornersToPixels(
      const [
        CornerPoint(0.1, 0.2),
        CornerPoint(0.9, 0.2),
        CornerPoint(0.9, 0.8),
        CornerPoint(0.1, 0.8),
      ],
      1200,
      1600,
    );
    expect(px[0], [120.0, 320.0]);
    expect(px[2], [1080.0, 1280.0]);

    expect(
      estimateOutputSize([
        [0, 0],
        [100, 0],
        [100, 50],
        [0, 50],
      ]),
      (width: 100, height: 50),
    );
    expect(
      estimateOutputSize([
        [0, 0],
        [0, 0],
        [0, 0],
        [0, 0],
      ]),
      (width: 8, height: 8),
    );
  });

  test('perspectiveTransform：恒等、放大与退化中文异常', () {
    const w = 16;
    const h = 12;
    final src = _makeRgba(w, h);
    final out = perspectiveTransform(
      src,
      w,
      h,
      [
        [0, 0],
        [w.toDouble(), 0],
        [w.toDouble(), h.toDouble()],
        [0, h.toDouble()],
      ],
      w,
      h,
    );
    for (var i = 0; i < src.length; i++) {
      expect((out[i] - src[i]).abs() <= 1, isTrue);
    }

    expect(
      () => perspectiveTransform(
        Uint8List(10 * 10 * 4),
        10,
        10,
        [
          [0, 0],
          [0, 0],
          [0, 0],
          [0, 0],
        ],
        10,
        10,
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('透视矫正失败'))),
    );
  });

  test('deskewRotate 与 detectSkewAngle', () {
    final src = Uint8List(200 * 100 * 4)..fillRange(0, 200 * 100 * 4, 128);
    final rot = deskewRotate(src, 200, 100, 4, 0.05);
    expect(rot.width < 200 && rot.height < 100, isTrue);
    expect(rot.data[0], 128);

    const w = 400;
    const h = 500;
    final gray = Uint8List(w * h)..fillRange(0, w * h, 240);
    for (var band = 0; band < 8; band++) {
      final y0 = 40 + band * 50;
      for (var y = y0; y < y0 + 18; y++) {
        for (var x = 60; x < w - 60; x++) {
          gray[y * w + x] = 20;
        }
      }
    }
    expect(detectSkewAngle(gray, w, h), 0.0);
  });
}
