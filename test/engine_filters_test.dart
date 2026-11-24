import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/filters.dart';
import 'package:saomiao_flutter/engine/options.dart';

Uint8List _makeRgba(int w, int h, List<int> Function(int x, int y) fn) {
  final data = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = (y * w + x) * 4;
      final rgb = fn(x, y);
      data[p] = rgb[0];
      data[p + 1] = rgb[1];
      data[p + 2] = rgb[2];
      data[p + 3] = 255;
    }
  }
  return data;
}

Uint8List _makeGray(int w, int h, int Function(int x, int y) fn) {
  final gray = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      gray[y * w + x] = fn(x, y);
    }
  }
  return gray;
}

void main() {
  test('toGray：BT.601 定点权重（77/150/29）', () {
    final rgba = Uint8List.fromList([
      255, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255,
    ]);
    final gray = toGray(rgba, 3, 1);
    expect(gray, [77, 149, 29]);
    for (final v in [0, 64, 128, 200, 255]) {
      final out = toGray(Uint8List.fromList([v, v, v, 255]), 1, 1)[0];
      expect((out - v).abs() <= 1, isTrue);
    }
    expect(toGray(Uint8List.fromList([255, 255, 255, 255]), 1, 1)[0], 255);
  });

  test('histogram 与 otsuThreshold', () {
    final gray = Uint8List.fromList([0, 0, 1, 200, 255]);
    final hist = histogram(gray);
    expect(hist[0], 2);
    expect(hist[1], 1);
    expect(hist[200], 1);
    expect(hist[255], 1);

    final bimodal = Uint8List(1000);
    bimodal.fillRange(0, 500, 20);
    bimodal.fillRange(500, 1000, 220);
    final t = otsuThreshold(histogram(bimodal));
    expect(t >= 20 && t < 220, isTrue);
    expect(otsuThreshold(Uint32List(256)), 128);
  });

  test('downsampleGrid / maxFilter / boxBlurFloat', () {
    final gray = _makeGray(8, 8, (_, _) => 100);
    final d = downsampleGrid(gray, 8, 8, 4);
    expect(d.width, 2);
    expect(d.height, 2);
    expect(d.data[0], 100.0);

    final src = Float32List(25)..fillRange(0, 25, 50.0);
    src[2 * 5 + 2] = 200.0;
    final mf = maxFilter(src, 5, 5, 1);
    expect(mf[2 * 5 + 2], 200.0);
    expect(mf[1 * 5 + 1], 200.0);
    expect(mf[0], 50.0);

    final c = Float32List(16 * 12)..fillRange(0, 16 * 12, 123.0);
    final blurred = boxBlurFloat(c, 16, 12, 3, 2);
    for (final v in blurred) {
      expect((v - 123.0).abs() < 1e-3, isTrue);
    }
  });

  test('makeBackgroundField 与 removeShadowGray', () {
    const w = 120;
    const h = 100;
    bool isText(int x, int y) => y > 40 && y < 48 && x > 10 && x < 110;
    final gray = _makeGray(
      w,
      h,
      (x, y) => isText(x, y) ? 30 : (255 - (x / w) * 95).round(),
    );
    expect(makeBackgroundField(gray, w, h, 0), isNull);
    final bg = makeBackgroundField(gray, w, h, 60)!;
    final out = removeShadowGray(gray, bg.data, bg.strength);
    final rx = w - 5;
    const ry = 10;
    expect(out[ry * w + rx] > gray[ry * w + rx] + 20, isTrue);
    expect(out[44 * w + 50] < 100, isTrue);
  });

  test('estimateWhiteBalance 与 enhanceColor', () {
    const w = 60;
    const h = 40;
    final rgba = _makeRgba(w, h, (_, _) => [200, 190, 160]);
    final gray = toGray(rgba, w, h);
    final bg = makeBackgroundField(gray, w, h, 60)!;
    final wb = estimateWhiteBalance(rgba, gray, w, h);
    expect(wb[2] > wb[1] && wb[1] >= wb[0], isTrue);
    final lut = buildToneLut(50, 0, 100);
    final out = enhanceColor(rgba, w, h, bg.data, bg.strength, wb, lut);
    expect(out.length, w * h * 4);
    expect(out[3], 255);
    expect((out[0] - out[2]).abs() < (rgba[0] - rgba[2]).abs(), isTrue);
  });

  test('buildToneLut / denoiseGray / sharpenGray / binarizeGray / despeckleBinary', () {
    final neutral = buildToneLut(50, 0, 100);
    for (var v = 0; v < 256; v++) {
      expect((neutral[v] - v).abs() <= 2, isTrue);
    }

    final gray = _makeGray(20, 20, (_, _) => 240);
    gray[10 * 20 + 10] = 0;
    for (var y = 2; y < 8; y++) {
      for (var x = 2; x < 8; x++) {
        gray[y * 20 + x] = 0;
      }
    }
    final den = denoiseGray(gray, 20, 20, 100);
    expect(den[10 * 20 + 10] > 100, isTrue);
    expect(den[5 * 20 + 5] < 100, isTrue);

    final edge = _makeGray(30, 10, (x, _) => x < 15 ? 80 : 180);
    final sharp = sharpenGray(edge, 30, 10, 80);
    expect(sharp[5 * 30 + 14] <= edge[14], isTrue);
    expect(sharp[5 * 30 + 15] >= edge[15], isTrue);

    final doc = _makeGray(
      400,
      300,
      (x, y) => y >= 100 && y < 110 && x > 40 && x < 360 ? 20 : 235,
    );
    final bin = binarizeGray(doc, 400, 300, 50);
    expect(bin[50 * 400 + 200], 255);
    expect(bin[105 * 400 + 200], 0);
    for (final v in bin) {
      expect(v == 0 || v == 255, isTrue);
    }

    final binNoise = Uint8List(20 * 20)..fillRange(0, 400, 255);
    binNoise[10 * 20 + 10] = 0;
    for (var x = 2; x < 12; x++) {
      binNoise[3 * 20 + x] = 0;
    }
    final clean = despeckleBinary(binNoise, 20, 20);
    expect(clean[10 * 20 + 10], 255);
    expect(clean[3 * 20 + 6], 0);
  });

  test('paperToneRgb / invert / applyLumaDeltaRgba', () {
    final g = Uint8List(4)..fillRange(0, 4, 200);
    final warm = paperToneRgb(g, 2, 2, PaperTone.warm);
    expect(warm[0] > warm[2], isTrue);
    final cool = paperToneRgb(g, 2, 2, PaperTone.gray);
    expect(cool[2] > cool[0], isTrue);

    expect(invertGray(Uint8List.fromList([0, 128, 255])), [255, 127, 0]);
    final rgba = Uint8List.fromList([10, 20, 30, 255]);
    invertRgba(rgba);
    expect(rgba, [245, 235, 225, 255]);
  });
}
