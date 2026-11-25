import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saomiao_flutter/engine/resize.dart';

void main() {
  test('areaAverage：4 倍下采样 = 每 4×4 块的平均', () {
    const w = 16;
    const h = 16;
    final src = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src[y * w + x] = ((x >> 1) + (y >> 1)) % 2 == 0 ? 0 : 200;
      }
    }
    final out = areaAverage(src, w, h, 1, 4, 4);
    expect(out.length, 16);
    for (final v in out) {
      expect(v, 100);
    }
  });

  test('areaAverage：非整数比例与多通道隔离', () {
    const w = 101;
    const h = 77;
    final src = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 180);
    final out = areaAverage(src, w, h, 4, 33, 25);
    expect(out.length, 33 * 25 * 4);
    for (final v in out) {
      expect((v - 180).abs() <= 1, isTrue);
    }
  });

  test('bilinear 与 resizeImage', () {
    final src = Uint8List(5 * 3 * 3)..fillRange(0, 5 * 3 * 3, 120);
    final out = bilinear(src, 5, 3, 3, 17, 11);
    expect(out.length, 17 * 11 * 3);
    for (final v in out) {
      expect((v - 120).abs() <= 1, isTrue);
    }

    final same = resizeImage(src, 5, 3, 3, 5, 3);
    expect(identical(same.data, src), isTrue);

    final ch5 = Uint8List(4 * 4 * 5)..fillRange(0, 4 * 4 * 5, 90);
    final out5 = resizeImage(ch5, 4, 4, 5, 2, 2);
    expect(out5.data.length, 2 * 2 * 5);
    expect(out5.data[4], 90);
  });

  test('rotateImage：90/180/270 与转四次复原', () {
    final src = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
    final r90 = rotateImage(src, 3, 2, 1, 90);
    expect(r90.width, 2);
    expect(r90.height, 3);
    expect(r90.data, [40, 10, 50, 20, 60, 30]);

    final r180 = rotateImage(src, 3, 2, 1, 180);
    expect(r180.data, [60, 50, 40, 30, 20, 10]);

    final r270 = rotateImage(src, 3, 2, 1, 270);
    expect(r270.data, [30, 60, 20, 50, 10, 40]);

    final multi = Uint8List(7 * 5 * 4);
    for (var i = 0; i < multi.length; i++) {
      multi[i] = (i * 37) % 256;
    }
    var cur = rotateImage(multi, 7, 5, 4, 0);
    for (var i = 0; i < 4; i++) {
      cur = rotateImage(cur.data, cur.width, cur.height, 4, 90);
    }
    expect(cur.width, 7);
    expect(cur.height, 5);
    expect(cur.data, multi);
  });
}
