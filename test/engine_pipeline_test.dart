import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/detect.dart';
import 'package:saomiao_flutter/engine/options.dart';
import 'package:saomiao_flutter/engine/pipeline.dart';

class _FakeDoc {
  const _FakeDoc({
    required this.source,
    required this.barTop,
    required this.barBottom,
    required this.barX0,
    required this.barX1,
  });

  final RgbaSource source;
  final int barTop;
  final int barBottom;
  final int barX0;
  final int barX1;

  bool isBar(int x, int y) =>
      x >= barX0 && x < barX1 && y >= barTop && y < barBottom && (y - barTop) % 100 < 30;
}

_FakeDoc _makeFakeDoc(int width, int height, {int barTop = 160, int? barBottom}) {
  var s = 42;
  double rng() {
    s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
    return s / 4294967296.0;
  }

  final bb = barBottom ?? height - 160;
  final bx0 = (width * 0.125).round();
  final bx1 = (width * 0.875).round();
  final data = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final fy = y / height;
    for (var x = 0; x < width; x++) {
      final fx = x / width;
      final shade = 1.0 - 0.4 * (0.55 * fx + 0.45 * fy);
      final paper = (248 * shade).round();
      final noise = ((rng() - 0.5) * 8).round();
      final isBar = x >= bx0 && x < bx1 && y >= barTop && y < bb && (y - barTop) % 100 < 30;
      final v = (isBar ? (18 * shade).round().clamp(0, 255) + noise : paper + noise).clamp(0, 255);
      final p = (y * width + x) * 4;
      data[p] = v;
      data[p + 1] = v;
      data[p + 2] = v;
      data[p + 3] = 255;
    }
  }
  return _FakeDoc(
    source: RgbaSource(data: data, width: width, height: height),
    barTop: barTop,
    barBottom: bb,
    barX0: bx0,
    barX1: bx1,
  );
}

void main() {
  test('renderPage：600×800 假文档三种模式（尺寸 / 通道 / 格式 / 效果）', () {
    final doc = _makeFakeDoc(600, 800, barTop: 80, barBottom: 720);
    final bw = renderPage(doc.source, const {'mode': 'bw', 'maxDim': 2400});
    final gray = renderPage(doc.source, const {'mode': 'gray', 'maxDim': 2400});
    final color = renderPage(doc.source, const {'mode': 'color', 'maxDim': 2400});

    expect(bw.width, 600);
    expect(bw.height, 800);
    expect(bw.channels, 1);
    expect(bw.format, 'png');
    expect(gray.channels, 1);
    expect(gray.format, 'jpeg');
    expect(color.channels, 4);
    expect(color.format, 'jpeg');

    for (final v in bw.data) {
      expect(v == 0 || v == 255, isTrue);
    }

    var paperSum = 0;
    var paperCnt = 0;
    var barSum = 0;
    var barCnt = 0;
    for (var y = 0; y < 800; y++) {
      for (var x = 0; x < 600; x++) {
        final v = bw.data[y * 600 + x];
        if (doc.isBar(x, y)) {
          barSum += v;
          barCnt++;
        } else {
          paperSum += v;
          paperCnt++;
        }
      }
    }
    expect(paperSum / paperCnt > 230, isTrue);
    expect(barSum / barCnt < 40, isTrue);
  });

  test('renderPage：maxDim 限长边（只缩不放）与透视裁切尺寸', () {
    final doc = _makeFakeDoc(600, 800, barTop: 80, barBottom: 720);
    final small = renderPage(doc.source, const {'mode': 'bw', 'maxDim': 600});
    expect(small.height, 600);
    expect(small.width, 450);

    final kept = renderPage(doc.source, const {'mode': 'gray', 'maxDim': 5000});
    expect(kept.width, 600);
    expect(kept.height, 800);

    final cropped = renderPage(doc.source, const {
      'mode': 'gray',
      'corners': [
        [0.1, 0.1],
        [0.9, 0.1],
        [0.9, 0.9],
        [0.1, 0.9],
      ],
    });
    expect(cropped.width, 480);
    expect(cropped.height, 640);
  });

  test('renderPage：gray 纸色染色、rotate、invert、不污染源像素', () {
    final doc = _makeFakeDoc(300, 400, barTop: 40, barBottom: 360);
    final snapshot = Uint8List.fromList(doc.source.data);

    final warm = renderPage(doc.source, const {'mode': 'gray', 'paper': 'warm'});
    expect(warm.channels, 4);
    final idx = (200 * 300 + 200) * 4;
    expect(warm.data[idx] > warm.data[idx + 2], isTrue);

    final r90 = renderPage(doc.source, const {'mode': 'gray', 'rotate': 90});
    expect(r90.width, 400);
    expect(r90.height, 300);

    final inv = renderPage(doc.source, const {'mode': 'bw', 'invert': true});
    for (final v in inv.data) {
      expect(v == 0 || v == 255, isTrue);
    }

    renderPage(doc.source, const {'mode': 'color', 'denoise': 60, 'sharpen': 60, 'shadow': 80});
    expect(doc.source.data, snapshot);
  });

  test('renderPage：非法输入抛中文错误，脏 options 容错', () {
    expect(
      () => renderPage(null),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('图片数据为空'))),
    );
    expect(
      () => renderPage(RgbaSource(data: Uint8List(10), width: 100, height: 100)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('图片数据不完整'))),
    );
    final doc = _makeFakeDoc(120, 160, barTop: 10, barBottom: 150);
    final out = renderPage(doc.source, const {
      'mode': '???',
      'contrast': 'xxx',
      'corners': [
        [0, 0],
        [1, 1],
      ],
      'rotate': 1234,
      'maxDim': -1,
    });
    expect(out.format, 'png');
    expect(out.width > 0 && out.height > 0, isTrue);
  });

  test('detectCorners：深色桌面上的一张纸，四角接近真实边界', () {
    const width = 400;
    const height = 560;
    final data = Uint8List(width * height * 4);
    final x0 = (width * 0.12).round();
    final x1 = (width * 0.88).round();
    final y0 = (height * 0.08).round();
    final y1 = (height * 0.92).round();
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final inPaper = x >= x0 && x <= x1 && y >= y0 && y <= y1;
        final isText = inPaper && (y - y0) % 60 < 12 && x > x0 + 20 && x < x1 - 20;
        final v = !inPaper ? 60 : (isText ? 40 : 240);
        final p = (y * width + x) * 4;
        data[p] = v;
        data[p + 1] = v;
        data[p + 2] = v;
        data[p + 3] = 255;
      }
    }
    final res = detectCorners(RgbaSource(data: data, width: width, height: height));
    expect(res.corners.length, 4);
    final tl = res.corners[0];
    final tr = res.corners[1];
    final br = res.corners[2];
    final bl = res.corners[3];
    expect((tl.x - x0 / width).abs() < 0.06, isTrue);
    expect((tl.y - y0 / height).abs() < 0.06, isTrue);
    expect((tr.x - x1 / width).abs() < 0.06, isTrue);
    expect((br.y - y1 / height).abs() < 0.06, isTrue);
    expect((bl.x - x0 / width).abs() < 0.06, isTrue);
    expect(res.confidence > 0.3, isTrue);
    expect(normalizeOptions(null).maxDim, 2400);
  });
}
