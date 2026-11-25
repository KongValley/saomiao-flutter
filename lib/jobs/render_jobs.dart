import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../engine/detect.dart';
import '../engine/options.dart';
import '../engine/pdf.dart';
import '../engine/pipeline.dart';
import '../engine/resize.dart';
import '../io/app_storage.dart';
import '../io/pixel_io.dart';
import '../state/page_models.dart';

const String kAbortMessage = '处理已取消';
const int _cacheKeep = 30;
const String _cacheVersion = '2';

class RenderedPageResult {
  const RenderedPageResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.format,
    this.thumbBytes,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String format; // 'png' | 'jpeg'
  final Uint8List? thumbBytes;
}

class ExportPdfOutcome {
  const ExportPdfOutcome({
    required this.bytes,
    required this.pageCount,
  });

  final Uint8List bytes;
  final int pageCount;
}

const List<int> _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr32(int x, int n) => ((x & 0xffffffff) >>> n) | ((x << (32 - n)) & 0xffffffff);

/// 跨平台纯 Dart SHA-256（避免 JS 53-bit double 乘法丢精度及 32-bit 哈希碰撞）
String sha256Hex(List<int> input) {
  final bitLen = input.length * 8;
  final padLen = ((input.length + 9 + 63) ~/ 64) * 64;
  final msg = Uint8List(padLen);
  msg.setAll(0, input);
  msg[input.length] = 0x80;
  final hi = (bitLen ~/ 0x100000000) & 0xffffffff;
  final lo = bitLen & 0xffffffff;
  msg[padLen - 8] = (hi >>> 24) & 0xff;
  msg[padLen - 7] = (hi >>> 16) & 0xff;
  msg[padLen - 6] = (hi >>> 8) & 0xff;
  msg[padLen - 5] = hi & 0xff;
  msg[padLen - 4] = (lo >>> 24) & 0xff;
  msg[padLen - 3] = (lo >>> 16) & 0xff;
  msg[padLen - 2] = (lo >>> 8) & 0xff;
  msg[padLen - 1] = lo & 0xff;

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final w = Uint32List(64);
  for (var offset = 0; offset < padLen; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final p = offset + i * 4;
      w[i] = ((msg[p] << 24) | (msg[p + 1] << 16) | (msg[p + 2] << 8) | msg[p + 3]) & 0xffffffff;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final sum1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + sum1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final sum0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = StringBuffer();
  for (final v in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
    out.write((v & 0xffffffff).toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}

Uint8List? _encodeThumb(RenderOutcome rendered) {
  final longEdge = math.max(rendered.width, rendered.height);
  if (longEdge <= 240) return null;
  final scale = 180.0 / longEdge;
  final tw = math.max(1, (rendered.width * scale).round());
  final th = math.max(1, (rendered.height * scale).round());
  final thumbImg = resizeImage(
    rendered.data,
    rendered.width,
    rendered.height,
    rendered.channels,
    tw,
    th,
  );
  return encodePixels(
    data: thumbImg.data,
    width: thumbImg.width,
    height: thumbImg.height,
    channels: thumbImg.channels,
    mime: 'image/jpeg',
    quality: 0.75,
  );
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
    this.thumbBytes,
    this.width = 0,
    this.height = 0,
    this.format = 'png',
  });

  final bool needsFallbackDecode;
  final Uint8List? bytes;
  final Uint8List? thumbBytes;
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
    source = decodeBytesPureDart(raw, maxPixels: kMaxSourcePixels);
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
  final thumbBytes = _encodeThumb(rendered);
  return _WorkerRenderResponse(
    needsFallbackDecode: false,
    bytes: outBytes,
    thumbBytes: thumbBytes,
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
  int origW;
  int origH;
  if (source == null) {
    final raw = req.sourceBytes;
    if (raw == null) {
      throw StateError('页面数据缺失：找不到原图');
    }
    final probed = probeSizeSync(raw);
    source = decodeBytesPureDart(raw, maxPixels: 1200 * 1200);
    if (source == null) {
      return const _WorkerDetectResponse(needsFallbackDecode: true);
    }
    origW = probed?.width ?? source.width;
    origH = probed?.height ?? source.height;
  } else {
    origW = source.width;
    origH = source.height;
  }
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

String computeRenderFingerprint(
  PageItem page,
  ScanOptions options,
  String mime,
  double quality,
) {
  final effective = normalizeOptions(options);
  final text =
      '$_cacheVersion|${page.id}|${page.sourceUri}|${page.sourceW}x${page.sourceH}|$mime|${quality.toStringAsFixed(4)}|${jsonEncode(effective.toJson())}';
  return sha256Hex(utf8.encode(text));
}

class RenderJobs {
  RenderJobs({required this.storage});

  final AppStorage storage;
  bool _pruning = false;
  bool _pruneAgain = false;

  Future<void> _pruneCoalesced() async {
    if (_pruning) {
      _pruneAgain = true;
      return;
    }
    _pruning = true;
    try {
      do {
        _pruneAgain = false;
        await storage.pruneCached(_cacheKeep);
      } while (_pruneAgain);
    } catch (_) {
      // Cache prune failures never block render/export.
    } finally {
      _pruning = false;
    }
  }

  Future<RenderedPageResult> renderPageTask(
    PageItem page,
    ScanOptions options, {
    void Function(String stage)? onStage,
    bool Function()? shouldAbort,
    double quality = 0.92,
  }) async {
    final effective = normalizeOptions(options);
    final mime = effective.mode == ScanMode.bw ? 'image/png' : 'image/jpeg';
    final key = computeRenderFingerprint(page, effective, mime, quality);

    try {
      final cached = await storage.findCached(key);
      if (cached != null) {
        return RenderedPageResult(
          bytes: cached.bytes,
          width: cached.width,
          height: cached.height,
          format: cached.format,
        );
      }
    } catch (_) {
      // Treat cache read errors as misses.
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
    try {
      await storage.writeCached(key, result.bytes, ext, result.width, result.height);
      await _pruneCoalesced();
    } catch (_) {
      // Cache write failure should not spoil an already-rendered result.
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

    if (kIsWeb) {
      final sw = Stopwatch()..start();
      Future<void> maybeYield() async {
        checkAbort();
        if (sw.elapsedMilliseconds >= 12) {
          await Future<void>.delayed(Duration.zero);
          sw.reset();
          checkAbort();
        }
      }

      await Future<void>.delayed(Duration.zero);
      checkAbort();
      final decoded = await decodeImageBytes(sourceBytes, maxPixels: kMaxSourcePixels);
      checkAbort();
      onStage?.call('处理');
      await Future<void>.delayed(Duration.zero);
      checkAbort();
      final rendered = await renderPageCooperative(
        decoded,
        effective,
        maybeYield: maybeYield,
      );
      checkAbort();
      final outBytes = encodePixels(
        data: rendered.data,
        width: rendered.width,
        height: rendered.height,
        channels: rendered.channels,
        mime: mime,
        quality: quality,
      );
      checkAbort();
      final thumbBytes = _encodeThumb(rendered);
      return RenderedPageResult(
        bytes: outBytes,
        thumbBytes: thumbBytes,
        width: rendered.width,
        height: rendered.height,
        format: mime == 'image/png' ? 'png' : 'jpeg',
      );
    }

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
      final decoded = await decodeImageBytes(sourceBytes, maxPixels: kMaxSourcePixels);
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
      thumbBytes: response.thumbBytes,
      width: response.width,
      height: response.height,
      format: response.format,
    );
  }

  Future<DetectCornersResult> detectCornersTask(PageItem page) async {
    final sourceBytes = await storage.readSourceBytes(page.sourceUri);
    if (kIsWeb) {
      await Future<void>.delayed(Duration.zero);
      final probed = probeSizeSync(sourceBytes);
      final decoded = await decodeImageBytes(sourceBytes, maxPixels: 1200 * 1200);
      await Future<void>.delayed(Duration.zero);
      final small = downscaleMaxEdge(decoded, 1200);
      final detected = detectCorners(small);
      return DetectCornersResult(
        corners: detected.corners,
        width: probed?.width ?? decoded.width,
        height: probed?.height ?? decoded.height,
        confidence: detected.confidence,
      );
    }

    var response = await compute(
      _detectWorker,
      _WorkerDetectRequest(sourceBytes: sourceBytes),
    );
    if (response.needsFallbackDecode) {
      final probed = await probePlatformSizeFallbackOrNull(sourceBytes);
      final decoded = await decodeImageBytes(sourceBytes, maxPixels: 1200 * 1200);
      response = await compute(
        _detectWorker,
        _WorkerDetectRequest(decodedSource: decoded),
      );
      final fallbackResult = response.result;
      if (fallbackResult != null && probed != null) {
        return DetectCornersResult(
          corners: fallbackResult.corners,
          width: probed.width,
          height: probed.height,
          confidence: fallbackResult.confidence,
        );
      }
    }
    final result = response.result;
    if (result == null) {
      throw StateError('四角检测失败：请手动拖动四角或换一张图片');
    }
    return result;
  }

  Future<({int width, int height})?> probePlatformSizeFallbackOrNull(
    Uint8List sourceBytes,
  ) async {
    try {
      return await probeImageSize(sourceBytes);
    } catch (_) {
      return null;
    }
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
      try {
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
      } catch (err) {
        final detail = err is StateError ? err.message : '图片处理失败';
        if (detail == kAbortMessage) rethrow;
        throw StateError('第 ${i + 1} 页「${page.name}」导出失败：$detail');
      }
      onProgress?.call(i + 1, pages.length);
    }
    if (kIsWeb) {
      await Future<void>.delayed(Duration.zero);
      final pdfBytes = buildPdf(inputs, pdfOptions);
      return ExportPdfOutcome(bytes: pdfBytes, pageCount: pages.length);
    }
    final pdfBytes = await compute(
      _buildPdfWorker,
      _WorkerPdfRequest(pages: inputs, options: pdfOptions),
    );
    return ExportPdfOutcome(bytes: pdfBytes, pageCount: pages.length);
  }
}
