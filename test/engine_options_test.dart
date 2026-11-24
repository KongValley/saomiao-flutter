import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/options.dart';

void main() {
  test('ScanOptions.defaults 与契约默认值一致', () {
    const d = ScanOptions.defaults;
    expect(d.mode, ScanMode.bw);
    expect(d.paper, PaperTone.white);
    expect(d.contrast, 50);
    expect(d.brightness, 0);
    expect(d.gamma, 100);
    expect(d.shadow, 60);
    expect(d.threshold, 50);
    expect(d.sharpen, 40);
    expect(d.denoise, 20);
    expect(d.corners, isNull);
    expect(d.rotate, 0);
    expect(d.deskew, false);
    expect(d.maxDim, 2400);
    expect(d.invert, false);
  });

  test('normalizeOptions：空或非法输入回退默认值', () {
    for (final input in [null, 0, 42, 'x', [], true]) {
      final out = normalizeOptions(input);
      expect(out, ScanOptions.defaults);
    }
  });

  test('normalizeOptions：非法枚举值与类型错误字段被忽略', () {
    final out = normalizeOptions(<String, Object?>{
      'mode': 'rainbow',
      'paper': 'pink',
      'contrast': <String, int>{'a': 1},
      'brightness': double.nan,
      'gamma': null,
      'rotate': 'abc',
    });
    expect(out.mode, ScanMode.bw);
    expect(out.paper, PaperTone.white);
    expect(out.contrast, 50);
    expect(out.brightness, 0);
    expect(out.gamma, 100);
    expect(out.rotate, 0);
  });

  test('normalizeOptions：数值 clamp 到各自区间并四舍五入', () {
    expect(normalizeOptions(<String, Object?>{'contrast': 200}).contrast, 100);
    expect(normalizeOptions(<String, Object?>{'contrast': -5}).contrast, 0);
    expect(normalizeOptions(<String, Object?>{'brightness': -100}).brightness, -50);
    expect(normalizeOptions(<String, Object?>{'brightness': 51.6}).brightness, 50);
    expect(normalizeOptions(<String, Object?>{'gamma': 10}).gamma, 50);
    expect(normalizeOptions(<String, Object?>{'gamma': 999}).gamma, 200);
    expect(normalizeOptions(<String, Object?>{'shadow': 101}).shadow, 100);
    expect(normalizeOptions(<String, Object?>{'threshold': -1}).threshold, 0);
    expect(normalizeOptions(<String, Object?>{'sharpen': 140}).sharpen, 100);
    expect(normalizeOptions(<String, Object?>{'denoise': 3.4}).denoise, 3);
    expect(normalizeOptions(<String, Object?>{'maxDim': 100}).maxDim, 600);
    expect(normalizeOptions(<String, Object?>{'maxDim': 99999}).maxDim, 6000);
  });

  test('normalizeOptions：数字字符串与 rotate 吸附', () {
    final out = normalizeOptions(<String, Object?>{
      'contrast': '30',
      'gamma': '120',
      'maxDim': '1800',
    });
    expect(out.contrast, 30);
    expect(out.gamma, 120);
    expect(out.maxDim, 1800);

    expect(normalizeOptions(<String, Object?>{'rotate': 89}).rotate, 90);
    expect(normalizeOptions(<String, Object?>{'rotate': 450}).rotate, 90);
    expect(normalizeOptions(<String, Object?>{'rotate': -90}).rotate, 270);
    expect(normalizeOptions(<String, Object?>{'rotate': 720}).rotate, 0);
  });

  test('normalizeOptions：宽松布尔', () {
    for (final v in [true, 1, '1', 'true', 'on']) {
      expect(normalizeOptions(<String, Object?>{'deskew': v}).deskew, true);
      expect(normalizeOptions(<String, Object?>{'invert': v}).invert, true);
    }
    for (final v in [false, 0, '0', 'off', '', [], <String, Object?>{}]) {
      expect(normalizeOptions(<String, Object?>{'deskew': v}).deskew, false);
    }
  });

  test('normalizeOptions：合法角点 clamp、{x,y} 容错与退化归 null', () {
    final clamped = normalizeOptions(<String, Object?>{
      'corners': [
        [-0.2, 0.1],
        [1.4, 0.1],
        [1.2, 1.3],
        [0.1, 0.9],
      ],
    });
    expect(clamped.corners, const [
      CornerPoint(0, 0.1),
      CornerPoint(1, 0.1),
      CornerPoint(1, 1),
      CornerPoint(0.1, 0.9),
    ]);

    final objCorners = normalizeOptions(<String, Object?>{
      'corners': [
        {'x': 0.1, 'y': 0.2},
        {'x': 0.9, 'y': 0.2},
        {'x': 0.9, 'y': 0.8},
        {'x': 0.1, 'y': 0.8},
      ],
    });
    expect(objCorners.corners, const [
      CornerPoint(0.1, 0.2),
      CornerPoint(0.9, 0.2),
      CornerPoint(0.9, 0.8),
      CornerPoint(0.1, 0.8),
    ]);

    expect(normalizeOptions(<String, Object?>{'corners': null}).corners, isNull);
    expect(normalizeOptions(<String, Object?>{'corners': []}).corners, isNull);
    expect(
      normalizeOptions(<String, Object?>{
        'corners': [
          [0.5, 0.5],
          [0.505, 0.5],
          [0.505, 0.505],
          [0.5, 0.505],
        ],
      }).corners,
      isNull,
    );
  });
}
