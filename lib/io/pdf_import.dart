import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'image_acquisition.dart';

const int kMaxPdfImportPages = 50;

class PdfImportProgress {
  const PdfImportProgress({
    required this.completed,
    required this.total,
  });

  final int completed;
  final int total;
}

class _EncodeBgraReq {
  const _EncodeBgraReq({
    required this.bgra,
    required this.width,
    required this.height,
  });

  final Uint8List bgra;
  final int width;
  final int height;
}

Uint8List _encodeBgraToJpeg(_EncodeBgraReq req) {
  final n = req.width * req.height;
  final rgb = Uint8List(n * 3);
  final bgra = req.bgra;
  for (var i = 0, s = 0, d = 0; i < n; i++, s += 4, d += 3) {
    final a = bgra[s + 3];
    if (a == 255) {
      rgb[d] = bgra[s + 2];
      rgb[d + 1] = bgra[s + 1];
      rgb[d + 2] = bgra[s];
    } else {
      final inv = 255 - a;
      rgb[d] = (bgra[s + 2] * a + 255 * inv) ~/ 255;
      rgb[d + 1] = (bgra[s + 1] * a + 255 * inv) ~/ 255;
      rgb[d + 2] = (bgra[s] * a + 255 * inv) ~/ 255;
    }
  }
  final im = img.Image.fromBytes(
    width: req.width,
    height: req.height,
    bytes: rgb.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  return img.encodeJpg(im, quality: 92);
}

class PdfImportService {
  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    await pdfrxFlutterInitialize();
    _initialized = true;
  }

  /// 将现有 PDF 逐页光栅化为高分辨率 JPEG，送入扫描管线进行去阴影/二值化漂白重排
  static Future<List<PickedImageEntry>> renderPdfToEntries(
    String filePath, {
    int maxPages = kMaxPdfImportPages,
    int targetLongEdge = 2200,
    void Function(int done, int total)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('找不到 PDF 文件：$filePath');
    }
    await ensureInitialized();
    final doc = await PdfDocument.openFile(filePath);
    try {
      final totalPages = math.min(doc.pages.length, maxPages);
      if (totalPages <= 0) {
        throw StateError('PDF 文件内没有可导入的页面');
      }
      final baseName = p.basenameWithoutExtension(filePath);
      final out = <PickedImageEntry>[];
      for (var i = 0; i < totalPages; i++) {
        final page = doc.pages[i];
        final pw = math.max(1.0, page.width);
        final ph = math.max(1.0, page.height);
        final long = math.max(pw, ph);
        final scale = (targetLongEdge / long).clamp(1.0, 4.0);
        final fullW = math.max(1, (pw * scale).round());
        final fullH = math.max(1, (ph * scale).round());

        final rendered = await page.render(
          fullWidth: fullW.toDouble(),
          fullHeight: fullH.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );
        if (rendered == null) continue;
        late final Uint8List jpegBytes;
        try {
          jpegBytes = await compute(
            _encodeBgraToJpeg,
            _EncodeBgraReq(
              bgra: Uint8List.fromList(rendered.pixels),
              width: rendered.width,
              height: rendered.height,
            ),
          );
        } finally {
          rendered.dispose();
        }
        final pageName = '${baseName.isNotEmpty ? baseName : "PDF"}_第${i + 1}页.jpg';
        out.add(
          PickedImageEntry.fromInput(
            PickedImageInput(name: pageName, bytes: jpegBytes),
          ),
        );
        onProgress?.call(i + 1, totalPages);
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }
}
