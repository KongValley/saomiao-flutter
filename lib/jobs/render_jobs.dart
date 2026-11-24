import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/detect.dart';
import '../engine/options.dart';
import '../engine/pdf.dart';
import '../engine/pipeline.dart';
import '../io/app_storage.dart';
import '../io/pixel_io.dart';
import '../state/page_models.dart';

const String kAbortMessage = '处理已取消';
const int _cacheKeep = 30;
const String _cacheVersion = '1';

class RenderedPageResult {
  const RenderedPageResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.format,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String format; // 'png' | 'jpeg'
}

class ExportPdfOutcome {
  const ExportPdfOutcome({
    required this.bytes,
    required this.pageCount,
  });

  final Uint8List bytes;
  final int pageCount;
}

class _WorkerRenderRequest {
  const _WorkerRenderRequest({
    required this.sourceBytes,
    required this.decodedSource,
    required this.optionsJson,
    required this.mime,
    required this.quality,
  });

  final Uint8List? sourceBytes;
  final RgbaSource? decodedSource;
  final Map<String, Object?> optionsJson;
  final String mime;
  final double quality;
}

class _WorkerRenderResponse {
  const _WorkerRenderResponse({
    required this.needsFallbackDecode,
    this.bytes,
    this.width = 0,
    this.height = 0,
    this.format = 'png',
  });

  final bool needsFallbackDecode;
  final Uint8List? bytes;
  final int width;
  final int height;
  final String format;
}

_WorkerRenderResponse _renderWorker(_WorkerRenderRequest req) {
  RgbaSource? source = req.decodedSource;
  if (source == null) {
    final raw = req.sourceBytes;
    if (raw == null) {
      throw StateError('页面数据缺失：找不到原图');
    }
    source = decodeBytesPureDart(raw);
    if (source == null) {
      return const _WorkerRenderResponse(needsFallbackDecode: true);
    }
  }

  source = downscaleIfNeeded(source, kMaxSourcePixels);
  final opts = normalizeOptions(req.optionsJson);
  final rendered = renderPage(source, opts);
  final outBytes = encodePixels(
    data: rendered.data,
    width: rendered.width,
    height: rendered.height,
    channels: rendered.channels,
    mime: req.mime,
    quality: req.quality,
  );
  return _WorkerRenderResponse(
    needsFallbackDecode: false,
    bytes: outBytes,
    width: rendered.width,
    height: rendered.height,
    format: req.mime == 'image/png' ? 'png' : 'jpeg',
  );
}

class _WorkerDetectRequest {
  const _WorkerDetectRequest({
    this.sourceBytes,
    this.decodedSource,
  });

  final Uint8List? sourceBytes;
  final RgbaSource? decodedSource;
}

class _WorkerDetectResponse {
  const _WorkerDetectResponse({
    required this.needsFallbackDecode,
    this.result,
  });

  final bool needsFallbackDecode;
  final DetectCornersResult? result;
}

_WorkerDetectResponse _detectWorker(_WorkerDetectRequest req) {
  RgbaSource? source = req.decodedSource;
  if (source == null) {
    final raw = req.sourceBytes;
    if (raw == null) {
      throw StateError('页面数据缺失：找不到原图');
    }
    source = decodeBytesPureDart(raw);
    if (source == null) {
      return const _WorkerDetectResponse(needsFallbackDecode: true);
    }
  }
  final origW = source.width;
  final origH = source.height;
  final small = downscaleMaxEdge(source, 1200);
  final detected = detectCorners(small);
  return _WorkerDetectResponse(
    needsFallbackDecode: false,
    result: DetectCornersResult(
      corners: detected.corners,
      width: origW,
      height: origH,
      confidence: detected.confidence,
    ),
  );
}

class _WorkerPdfRequest {
  const _WorkerPdfRequest({
    required this.pages,
    required this.options,
  });

  final List<PdfPageInput> pages;
  final PdfOptions options;
}

Uint8List _buildPdfWorker(_WorkerPdfRequest req) {
  return buildPdf(req.pages, req.options);
}

String _fingerprint(
  PageItem page,
  ScanOptions options,
  String mime,
  double quality,
) {
  final text =
      '$_cacheVersion|${page.sourceUri}|$mime|$quality|${jsonEncode(options.toJson())}';
  var hash = 0x811c9dc5;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class RenderJobs {
  RenderJobs({required this.storage});

  final AppStorage storage;
  bool _pruned = false;

  Future<RenderedPageResult> renderPageTask(
    PageItem page,
    ScanOptions options, {
    void Function(String stage)? onStage,
    bool Function()? shouldAbort,
    double quality = 0.92,
  }) async {
    final effective = normalizeOptions(options);
    final mime = effective.mode == ScanMode.bw ? 'image/png' : 'image/jpeg';
    final key = _fingerprint(page, effective, mime, quality);

    final cached = await storage.findCached(key);
    if (cached != null) {
      return RenderedPageResult(
        bytes: cached.bytes,
        width: cached.width,
        height: cached.height,
        format: cached.format,
      );
    }

    final result = await _renderToBytes(
      page,
      effective,
      mime: mime,
      quality: quality,
      onStage: onStage,
      shouldAbort: shouldAbort,
    );

    final ext = result.format == 'png' ? 'png' : 'jpg';
    await storage.writeCached(key, result.bytes, ext, result.width, result.height);
    if (!_pruned) {
      _pruned = true;
      // 后台异步裁剪缓存
      Future<void>.microtask(() => storage.pruneCached(_cacheKeep));
    }
    return result;
  }

  Future<RenderedPageResult> _renderToBytes(
    PageItem page,
    ScanOptions effective, {
    required String mime,
    required double quality,
    void Function(String stage)? onStage,
    bool Function()? shouldAbort,
  }) async {
    void checkAbort() {
      if (shouldAbort != null && shouldAbort()) {
        throw StateError(kAbortMessage);
      }
    }

    onStage?.call('解码');
    checkAbort();
    final sourceBytes = await storage.readSourceBytes(page.sourceUri);
    checkAbort();

    onStage?.call('处理');
    var response = await compute(
      _renderWorker,
      _WorkerRenderRequest(
        sourceBytes: sourceBytes,
        decodedSource: null,
        optionsJson: effective.toJson(),
        mime: mime,
        quality: quality,
      ),
    );
    checkAbort();

    if (response.needsFallbackDecode) {
      final decoded = await decodeImageBytes(sourceBytes);
      checkAbort();
      response = await compute(
        _renderWorker,
        _WorkerRenderRequest(
          sourceBytes: null,
          decodedSource: decoded,
          optionsJson: effective.toJson(),
          mime: mime,
          quality: quality,
        ),
      );
      checkAbort();
    }

    final outBytes = response.bytes;
    if (outBytes == null || outBytes.isEmpty) {
      throw StateError('编码失败：生成结果为空');
    }
    return RenderedPageResult(
      bytes: outBytes,
      width: response.width,
      height: response.height,
      format: response.format,
    );
  }

  Future<DetectCornersResult> detectCornersTask(PageItem page) async {
    final sourceBytes = await storage.readSourceBytes(page.sourceUri);
    var response = await compute(
      _detectWorker,
      _WorkerDetectRequest(sourceBytes: sourceBytes),
    );
    if (response.needsFallbackDecode) {
      final decoded = await decodeImageBytes(sourceBytes);
      response = await compute(
        _detectWorker,
        _WorkerDetectRequest(decodedSource: decoded),
      );
    }
    final result = response.result;
    if (result == null) {
      throw StateError('四角检测失败：请手动拖动四角或换一张图片');
    }
    return result;
  }

  Future<RenderedPageResult> exportImageTask(
    PageItem page,
    ScanOptions options,
  ) {
    return renderPageTask(page, options);
  }

  Future<ExportPdfOutcome> exportPdfTask(
    List<PageItem> pages,
    PdfOptions pdfOptions, {
    void Function(int completed, int total)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw StateError('导出失败：没有可导出的页面');
    }
    final inputs = <PdfPageInput>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final rendered = await _renderToBytes(
        page,
        page.options,
        mime: 'image/jpeg',
        quality: 0.92,
      );
      inputs.add(
        PdfPageInput(
          jpegBytes: rendered.bytes,
          width: rendered.width,
          height: rendered.height,
        ),
      );
      onProgress?.call(i + 1, pages.length);
    }
    final pdfBytes = await compute(
      _buildPdfWorker,
      _WorkerPdfRequest(pages: inputs, options: pdfOptions),
    );
    return ExportPdfOutcome(bytes: pdfBytes, pageCount: pages.length);
  }
}
