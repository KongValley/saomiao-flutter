import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../io/image_acquisition.dart';

/// 在后台 Isolate 生成模拟拍摄的文档照片
Future<List<PickedImageInput>> generateDemoDocuments([int count = 2]) {
  final n = count.clamp(1, 6);
  return compute(_generateDemoSync, n);
}

List<PickedImageInput> _generateDemoSync(int count) {
  final out = <PickedImageInput>[];
  for (var i = 0; i < count; i++) {
    out.add(
      PickedImageInput(
        name: '示例文档_${i + 1}.jpg',
        bytes: _renderSingleDemoJpeg(i),
      ),
    );
  }
  return out;
}

void _renderDemoRow(img.Image im, int index, int y, int width, int height) {
  final tilt = (index % 2 == 0 ? -1.0 : 1.0) * 0.028;
  final cos = math.cos(tilt);
  final sin = math.sin(tilt);
  final cx = width / 2.0;
  final cy = height / 2.0;
  final halfW = width * 0.40;
  final halfH = height * 0.42;
  final dy = y - cy;
  final fxY = y / height;

  for (var x = 0; x < width; x++) {
    final dx = x - cx;
    final rx = dx * cos + dy * sin;
    final ry = -dx * sin + dy * cos;

    final inPaper = rx.abs() <= halfW && ry.abs() <= halfH;
    final shade = 1.0 - 0.24 * (0.6 * (x / width) + 0.4 * fxY);

    int r;
    int g;
    int b;
    if (!inPaper) {
      r = (48 * shade).round().clamp(0, 255);
      g = (56 * shade).round().clamp(0, 255);
      b = (70 * shade).round().clamp(0, 255);
    } else {
      final px = (rx + halfW) / (2 * halfW);
      final py = (ry + halfH) / (2 * halfH);
      final base = (248 * shade).round();
      r = base;
      g = (base * 0.99).round();
      b = (base * 0.96).round();

      final isHeader = py >= 0.08 && py <= 0.125 && px >= 0.1 && px <= 0.56;
      final isSub = py >= 0.145 && py <= 0.165 && px >= 0.1 && px <= 0.38;
      final isRule = py >= 0.195 && py <= 0.200 && px >= 0.1 && px <= 0.9;

      var isTextLine = false;
      if (py >= 0.24 && py <= 0.80 && px >= 0.1) {
        final band = ((py - 0.24) / 0.048).floor();
        final within = ((py - 0.24) / 0.048) - band;
        final lineWidth = 0.56 + ((band * 29 + index * 13) % 24) / 100.0;
        if (within < 0.26 && px <= 0.1 + math.min(0.8, lineWidth)) {
          isTextLine = true;
        }
      }

      final stampDx = (px - 0.78) * halfW * 2;
      final stampDy = (py - 0.84) * halfH * 2;
      final dist = math.sqrt(stampDx * stampDx + stampDy * stampDy);
      final isStamp = dist >= 44 && dist <= 52;

      if (isHeader) {
        r = (28 * shade).round();
        g = (38 * shade).round();
        b = (56 * shade).round();
      } else if (isSub || isTextLine) {
        final ink = isSub ? 78 : 52;
        r = (ink * shade).round();
        g = ((ink + 6) * shade).round();
        b = ((ink + 14) * shade).round();
      } else if (isRule) {
        r = (195 * shade).round();
        g = (205 * shade).round();
        b = (220 * shade).round();
      } else if (isStamp) {
        r = (37 * shade).round();
        g = (99 * shade).round();
        b = (235 * shade).round();
      }
    }
    im.setPixelRgb(x, y, r, g, b);
  }
}

Uint8List _renderSingleDemoJpeg(int index) {
  const width = 900;
  const height = 1200;
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    _renderDemoRow(im, index, y, width, height);
  }
  return img.encodeJpg(im, quality: 90);
}
