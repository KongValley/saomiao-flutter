import 'package:flutter/services.dart';

import '../engine/pdf.dart';
import '../state/page_models.dart';

typedef OcrPlatformHandler = Future<OcrPageResult> Function(
  Uint8List imageBytes,
  int width,
  int height,
);

class OcrService {
  OcrService({this.handler});

  static const MethodChannel _channel = MethodChannel('com.saomiao.saomiao_flutter/ocr');

  final OcrPlatformHandler? handler;

  Future<OcrPageResult> recognizeImage({
    required Uint8List imageBytes,
    required int width,
    required int height,
  }) async {
    if (handler != null) {
      return handler!(imageBytes, width, height);
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'recognizeText',
        <String, Object?>{
          'bytes': imageBytes,
          'width': width,
          'height': height,
        },
      );
      if (raw == null) {
        return OcrPageResult(
          text: '',
          lines: const <PdfOcrLine>[],
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      final rawText = raw['text'];
      final text = rawText is String ? rawText.trim() : '';
      final rawLines = raw['lines'];
      final lines = <PdfOcrLine>[];
      if (rawLines is List) {
        for (final item in rawLines) {
          final parsed = PdfOcrLine.tryFromJson(item);
          if (parsed != null && parsed.text.trim().isNotEmpty) {
            lines.add(parsed);
          }
        }
      }
      final finalText = text.isNotEmpty
          ? text
          : lines.map((l) => l.text).join('\n').trim();
      return OcrPageResult(
        text: finalText,
        lines: List<PdfOcrLine>.unmodifiable(lines),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } on MissingPluginException {
      throw StateError('当前平台暂不支持本地离线文字识别');
    } on PlatformException catch (err) {
      final msg = err.message?.trim();
      throw StateError(
        (msg != null && msg.isNotEmpty) ? msg : '本地文字识别失败，请重试',
      );
    }
  }
}
