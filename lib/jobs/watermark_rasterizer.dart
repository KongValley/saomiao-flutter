import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../engine/detect.dart';

/// 在主线程利用系统字体光栅化单张可平铺斜向水印瓷砖（供后台 Isolate 合成全中文/多语言水印）
Future<RgbaSource?> rasterizeWatermarkTile(String? rawText) async {
  final text = rawText?.trim() ?? '';
  if (text.isEmpty) return null;

  final fontSize = text.length > 22
      ? 18.0
      : (text.length > 14 ? 20.0 : 22.0);
  final paragraphBuilder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
    ),
  )
    ..pushStyle(
      ui.TextStyle(
        color: const Color(0xFF1E293B),
        fontSize: fontSize,
        fontWeight: ui.FontWeight.w600,
      ),
    )
    ..addText(text);

  final paragraph = paragraphBuilder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));

  final lineW = paragraph.maxIntrinsicWidth.clamp(120.0, 520.0);
  paragraph.layout(ui.ParagraphConstraints(width: lineW + 8));

  const angle = -math.pi / 6.0;
  final cosA = math.cos(angle).abs();
  final sinA = math.sin(angle).abs();
  final rotW = lineW * cosA + paragraph.height * sinA;
  final rotH = lineW * sinA + paragraph.height * cosA;
  final tileW = (rotW + 64).ceil().clamp(320, 600);
  final tileH = (rotH + 72).ceil().clamp(260, 480);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, tileW.toDouble(), tileH.toDouble()),
  );

  canvas.save();
  canvas.translate(tileW / 2.0, tileH / 2.0);
  canvas.rotate(angle);
  canvas.drawParagraph(
    paragraph,
    Offset(-paragraph.width / 2.0, -paragraph.height / 2.0),
  );
  canvas.restore();

  final picture = recorder.endRecording();
  final image = await picture.toImage(tileW, tileH);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (byteData == null) return null;
    final bytes = Uint8List.fromList(
      byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
    );
    return RgbaSource(data: bytes, width: tileW, height: tileH);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
