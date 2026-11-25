import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../engine/detect.dart';

/// 在主线程利用系统字体光栅化单张可平铺斜向水印瓷砖（供后台 Isolate 合成全中文/多语言水印）
Future<RgbaSource?> rasterizeWatermarkTile(String? rawText) async {
  final text = rawText?.trim() ?? '';
  if (text.isEmpty) return null;

  const size = 360;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
  );

  final paragraphBuilder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
    ),
  )
    ..pushStyle(
      ui.TextStyle(
        color: const Color(0xFF1E293B),
        fontSize: text.length > 14 ? 20.0 : 24.0,
        fontWeight: ui.FontWeight.w600,
      ),
    )
    ..addText(text);

  final paragraph = paragraphBuilder.build()
    ..layout(const ui.ParagraphConstraints(width: 310));

  canvas.save();
  canvas.translate(size / 2.0, size / 2.0);
  canvas.rotate(-math.pi / 6.0);
  canvas.drawParagraph(
    paragraph,
    Offset(-paragraph.width / 2.0, -paragraph.height / 2.0),
  );
  canvas.restore();

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (byteData == null) return null;
    final bytes = Uint8List.fromList(
      byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
    );
    return RgbaSource(data: bytes, width: size, height: size);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
