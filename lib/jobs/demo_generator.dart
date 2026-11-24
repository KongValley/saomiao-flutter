import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../io/image_acquisition.dart';

/// 在后台 Isolate 生成模拟拍摄的文档照片（含倾斜、阴影、深色桌面背景，供桌面/Web 端快速体验或截图验证）
Future<List<PickedImageInput>> generateDemoDocuments([int count = 2]) {
  return compute(_generateDemoSync, count.clamp(1, 6));
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

Uint8List _renderSingleDemoJpeg(int index) {
  const width = 900;
  const height = 1200;
  final im = img.Image(width: width, height: height, numChannels: 3);

  // 深色桌面背景 + 略倾斜白纸 + 对角光照渐变（方便自动四角检测 & 去阴影演示）
  final tilt = (index % 2 == 0 ? -1.0 : 1.0) * 0.028;
  final cos = math.cos(tilt);
  final sin = math.sin(tilt);
  const cx = width / 2.0;
  const cy = height / 2.0;
  const halfW = width * 0.40;
  const halfH = height * 0.42;

  for (var y = 0; y < height; y++) {
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
        // 深蓝灰桌面
        r = (48 * shade).round().clamp(0, 255);
        g = (56 * shade).round().clamp(0, 255);
        b = (70 * shade).round().clamp(0, 255);
      } else {
        // 纸张内部坐标（0..1）
        final px = (rx + halfW) / (2 * halfW);
        final py = (ry + halfH) / (2 * halfH);
        final base = (248 * shade).round();
        r = base;
        g = (base * 0.99).round();
        b = (base * 0.96).round();

        // 标题大色块 + 分隔线 + 多行模拟文字条 + 右下角蓝色印章圆圈
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

        // 蓝色印章圆环
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
  return img.encodeJpg(im, quality: 90);
}
