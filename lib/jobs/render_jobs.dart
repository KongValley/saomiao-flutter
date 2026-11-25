import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../engine/detect.dart';
import '../engine/geometry.dart';
import '../engine/options.dart';
import '../engine/pdf.dart';
import '../engine/pipeline.dart';
import '../engine/resize.dart';
import '../io/app_storage.dart';
import '../io/pixel_io.dart';
import '../state/page_models.dart';
import 'annotation_compositor.dart';
import 'watermark_rasterizer.dart';

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

class ExportArchiveOutcome {
  const ExportArchiveOutcome({
    required this.bytes,
    required this.pageCount,
    required this.files,
  });

  final Uint8List bytes;
  final int pageCount;
  final List<({String fileName, Uint8List bytes})> files;
}

enum IdCardTemplate {
  idCard('id_card', '身份证正反面', '按 85.6×54mm 标准比例上下居中'),
  bankCard('bank_card', '银行卡 / 驾照', '标准卡证比例上下居中排版'),
  twoUp('two_up', '双页合并 A4', '两页内容等宽上下排进一页 A4');

  const IdCardTemplate(this.id, this.label, this.desc);
  final String id;
  final String label;
  final String desc;
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
    this.annotations = PageAnnotations.empty,
    this.signatures = const <SignatureStampData>[],
    this.watermarkTile,
    this.watermarkOpacity = 0.20,
  });

  final Uint8List? sourceBytes;
  final RgbaSource? decodedSource;
  final Map<String, Object?> optionsJson;
  final String mime;
  final double quality;
  final PageAnnotations annotations;
  final List<SignatureStampData> signatures;
  final RgbaSource? watermarkTile;
  final double watermarkOpacity;
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
  final composited = compositePageOverlays(
    data: rendered.data,
    width: rendered.width,
    height: rendered.height,
    channels: rendered.channels,
    annotations: req.annotations,
    signatures: req.signatures,
    watermarkTile: req.watermarkTile,
    watermarkOpacity: req.watermarkOpacity,
  );
  final outBytes = encodePixels(
    data: composited.data,
    width: rendered.width,
    height: rendered.height,
    channels: composited.channels,
    mime: req.mime,
    quality: req.quality,
  );
  final thumbBase = RenderOutcome(
    data: composited.data,
    width: rendered.width,
    height: rendered.height,
    channels: composited.channels,
    format: rendered.format,
  );
  final thumbBytes = _encodeThumb(thumbBase);
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
  final annPart = page.annotations.isEmpty
      ? ''
      : '|ann:${jsonEncode(page.annotations.toJson())}';
  final text =
      '$_cacheVersion|${page.id}|${page.sourceUri}|${page.sourceW}x${page.sourceH}|$mime|${quality.toStringAsFixed(4)}|${jsonEncode(effective.toJson())}$annPart';
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

  Future<List<SignatureStampData>> _loadSignatureStamps(
    PageAnnotations annotations,
    List<SavedSignature> librarySigs,
  ) async {
    if (annotations.signatures.isEmpty) return const <SignatureStampData>[];
    final byId = <String, SavedSignature>{for (final s in librarySigs) s.id: s};
    final out = <SignatureStampData>[];
    for (final pl in annotations.signatures) {
      final meta = byId[pl.signatureId];
      if (meta == null) continue;
      final png = await storage.readSignatureBytes(meta.uri);
      if (png == null || png.isEmpty) continue;
      final decoded = decodeSignaturePngRgba(png);
      if (decoded == null) continue;
      out.add(
        SignatureStampData(
          placement: pl,
          rgba: decoded.rgba,
          width: decoded.width,
          height: decoded.height,
        ),
      );
    }
    return out;
  }

  Future<RenderedPageResult> renderPageTask(
    PageItem page,
    ScanOptions options, {
    List<SavedSignature> signatures = const <SavedSignature>[],
    void Function(String stage)? onStage,
    bool Function()? shouldAbort,
    double quality = 0.92,
  }) async {
    final effective = normalizeOptions(options);
    final mime = (effective.mode == ScanMode.bw || effective.mode == ScanMode.bwStamp)
        ? 'image/png'
        : 'image/jpeg';
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
      signatures: signatures,
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
    List<SavedSignature> signatures = const <SavedSignature>[],
    RgbaSource? watermarkTile,
    double watermarkOpacity = 0.20,
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
    final stamps = await _loadSignatureStamps(page.annotations, signatures);
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
        annotations: page.annotations,
        signatures: stamps,
        watermarkTile: watermarkTile,
        watermarkOpacity: watermarkOpacity,
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
          annotations: page.annotations,
          signatures: stamps,
          watermarkTile: watermarkTile,
          watermarkOpacity: watermarkOpacity,
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
    ScanOptions options, {
    List<SavedSignature> signatures = const <SavedSignature>[],
    String? watermarkText,
    double watermarkOpacity = 0.20,
    double quality = 0.92,
  }) async {
    final watermarkTile = await rasterizeWatermarkTile(watermarkText);
    if (watermarkTile == null) {
      return renderPageTask(
        page,
        options,
        signatures: signatures,
        quality: quality,
      );
    }
    final effective = normalizeOptions(options);
    final mime = (effective.mode == ScanMode.bw || effective.mode == ScanMode.bwStamp)
        ? 'image/png'
        : 'image/jpeg';
    return _renderToBytes(
      page,
      effective,
      mime: mime,
      quality: quality,
      signatures: signatures,
      watermarkTile: watermarkTile,
      watermarkOpacity: watermarkOpacity,
    );
  }

  Future<ExportPdfOutcome> exportPdfTask(
    List<PageItem> pages,
    PdfOptions pdfOptions, {
    List<SavedSignature> signatures = const <SavedSignature>[],
    void Function(int completed, int total)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw StateError('导出失败：没有可导出的页面');
    }
    final quality = pdfOptions.jpegQuality.clamp(0.4, 0.98);
    final watermarkTile = await rasterizeWatermarkTile(pdfOptions.watermarkText);
    final inputs = <PdfPageInput>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      try {
        final rendered = await _renderToBytes(
          page,
          page.options,
          mime: 'image/jpeg',
          quality: quality,
          signatures: signatures,
          watermarkTile: watermarkTile,
          watermarkOpacity: pdfOptions.watermarkOpacity,
        );
        inputs.add(
          PdfPageInput(
            jpegBytes: rendered.bytes,
            width: rendered.width,
            height: rendered.height,
            ocrLines: pdfOptions.embedOcrText ? page.ocr?.lines : null,
          ),
        );
      } catch (err) {
        final detail = err is StateError ? err.message : '图片处理失败';
        if (detail == kAbortMessage) rethrow;
        throw StateError('第 ${i + 1} 页「${page.name}」导出失败：$detail');
      }
      onProgress?.call(i + 1, pages.length);
    }
    final pdfBytes = await compute(
      _buildPdfWorker,
      _WorkerPdfRequest(pages: inputs, options: pdfOptions),
    );
    return ExportPdfOutcome(bytes: pdfBytes, pageCount: pages.length);
  }

  Future<ExportArchiveOutcome> exportAllImagesZipTask(
    List<PageItem> pages, {
    List<SavedSignature> signatures = const <SavedSignature>[],
    String? watermarkText,
    double watermarkOpacity = 0.20,
    double quality = 0.92,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw StateError('导出失败：没有可导出的页面');
    }
    final watermarkTile = await rasterizeWatermarkTile(watermarkText);
    final archive = Archive();
    final files = <({String fileName, Uint8List bytes})>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final effective = normalizeOptions(page.options);
      final mime = (effective.mode == ScanMode.bw || effective.mode == ScanMode.bwStamp)
          ? 'image/png'
          : 'image/jpeg';
      final ext = mime == 'image/png' ? 'png' : 'jpg';
      final rendered = await _renderToBytes(
        page,
        effective,
        mime: mime,
        quality: quality,
        signatures: signatures,
        watermarkTile: watermarkTile,
        watermarkOpacity: watermarkOpacity,
      );
      final idxStr = (i + 1).toString().padLeft(2, '0');
      final fileName = 'page_$idxStr.$ext';
      archive.addFile(ArchiveFile(fileName, rendered.bytes.length, rendered.bytes));
      files.add((fileName: fileName, bytes: rendered.bytes));
      onProgress?.call(i + 1, pages.length);
    }
    final encoded = await compute(_encodeZipWorker, archive);
    return ExportArchiveOutcome(
      bytes: encoded,
      pageCount: pages.length,
      files: files,
    );
  }

  Future<double> detectBookGutterTask(PageItem page) async {
    final sourceBytes = await storage.readSourceBytes(page.sourceUri);
    var src = decodeBytesPureDart(sourceBytes, maxPixels: 900 * 900);
    src ??= await decodeImageBytes(sourceBytes, maxPixels: 900 * 900);
    return compute(_detectGutterWorker, src);
  }

  Future<({Uint8List leftBytes, int leftW, int leftH, Uint8List rightBytes, int rightW, int rightH})>
      splitDoublePageTask(PageItem page, double splitX) async {
    final sourceBytes = await storage.readSourceBytes(page.sourceUri);
    var src = decodeBytesPureDart(sourceBytes, maxPixels: kMaxSourcePixels);
    src ??= await decodeImageBytes(sourceBytes, maxPixels: kMaxSourcePixels);
    return compute(
      _splitDoublePageWorker,
      _SplitDoublePageReq(source: src, splitX: splitX, rotate: page.options.rotate),
    );
  }

  Future<Uint8List> composeIdCardTask({
    required Uint8List frontBytes,
    required ScanOptions frontOptions,
    required Uint8List backBytes,
    required ScanOptions backOptions,
    required IdCardTemplate template,
    String? watermarkText,
    double watermarkOpacity = 0.20,
  }) async {
    var frontSrc = decodeBytesPureDart(frontBytes, maxPixels: kMaxSourcePixels);
    frontSrc ??= await decodeImageBytes(frontBytes, maxPixels: kMaxSourcePixels);
    var backSrc = decodeBytesPureDart(backBytes, maxPixels: kMaxSourcePixels);
    backSrc ??= await decodeImageBytes(backBytes, maxPixels: kMaxSourcePixels);
    final watermarkTile = await rasterizeWatermarkTile(watermarkText);
    return compute(
      _composeIdCardWorker,
      _ComposeIdCardReq(
        frontSrc: frontSrc,
        frontOptions: frontOptions.toJson(),
        backSrc: backSrc,
        backOptions: backOptions.toJson(),
        template: template,
        watermarkTile: watermarkTile,
        watermarkOpacity: watermarkOpacity,
      ),
    );
  }
}

Uint8List _encodeZipWorker(Archive archive) {
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

double _detectGutterWorker(RgbaSource src) {
  final small = downscaleMaxEdge(src, 420);
  return detectBookGutterX(small.data, small.width, small.height);
}

class _SplitDoublePageReq {
  const _SplitDoublePageReq({
    required this.source,
    required this.splitX,
    required this.rotate,
  });

  final RgbaSource source;
  final double splitX;
  final int rotate;
}

({Uint8List leftBytes, int leftW, int leftH, Uint8List rightBytes, int rightW, int rightH})
    _splitDoublePageWorker(_SplitDoublePageReq req) {
  var work = req.source;
  if (req.rotate != 0) {
    final rot = rotateImage(work.data, work.width, work.height, 4, req.rotate);
    work = RgbaSource(data: rot.data, width: rot.width, height: rot.height);
  }
  final s = req.splitX.clamp(0.15, 0.85);
  final left = cropNormalizedRect(work.data, work.width, work.height, 0.0, 0.0, s, 1.0);
  final right = cropNormalizedRect(work.data, work.width, work.height, s, 0.0, 1.0, 1.0);
  final leftBytes = encodePixels(
    data: left.data,
    width: left.width,
    height: left.height,
    channels: 4,
    mime: 'image/jpeg',
    quality: 0.94,
  );
  final rightBytes = encodePixels(
    data: right.data,
    width: right.width,
    height: right.height,
    channels: 4,
    mime: 'image/jpeg',
    quality: 0.94,
  );
  return (
    leftBytes: leftBytes,
    leftW: left.width,
    leftH: left.height,
    rightBytes: rightBytes,
    rightW: right.width,
    rightH: right.height,
  );
}

class _ComposeIdCardReq {
  const _ComposeIdCardReq({
    required this.frontSrc,
    required this.frontOptions,
    required this.backSrc,
    required this.backOptions,
    required this.template,
    this.watermarkTile,
    this.watermarkOpacity = 0.20,
  });

  final RgbaSource frontSrc;
  final Map<String, Object?> frontOptions;
  final RgbaSource backSrc;
  final Map<String, Object?> backOptions;
  final IdCardTemplate template;
  final RgbaSource? watermarkTile;
  final double watermarkOpacity;
}

Uint8List _composeIdCardWorker(_ComposeIdCardReq req) {
  const outW = 1654; // A4 @ 200 DPI
  const outH = 2339;
  final canvas = img.Image(width: outW, height: outH, numChannels: 4);
  img.fill(canvas, color: img.ColorRgba8(255, 255, 255, 255));

  img.Image toImg(RenderOutcome r) {
    final rgba = Uint8List(r.width * r.height * 4);
    if (r.channels == 1) {
      for (var i = 0, q = 0; i < r.width * r.height; i++, q += 4) {
        final v = r.data[i];
        rgba[q] = v;
        rgba[q + 1] = v;
        rgba[q + 2] = v;
        rgba[q + 3] = 255;
      }
    } else {
      rgba.setAll(0, r.data.sublist(0, r.width * r.height * 4));
    }
    return img.Image.fromBytes(
      width: r.width,
      height: r.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  final frontRendered = renderPage(req.frontSrc, req.frontOptions);
  final backRendered = renderPage(req.backSrc, req.backOptions);
  final frontImg = toImg(frontRendered);
  final backImg = toImg(backRendered);

  final int slotMaxW;
  final int slotMaxH;
  final bool forceCardRatio;
  switch (req.template) {
    case IdCardTemplate.idCard:
    case IdCardTemplate.bankCard:
      // 85.6 / 210 ≈ 0.408 (略放大至 56% 纸宽更易阅读打印)
      slotMaxW = (outW * 0.56).round();
      slotMaxH = (slotMaxW * (54.0 / 85.6)).round();
      forceCardRatio = true;
    case IdCardTemplate.twoUp:
      slotMaxW = (outW * 0.84).round();
      slotMaxH = (outH * 0.40).round();
      forceCardRatio = false;
  }

  void placeSlot(img.Image src, int centerY) {
    int targetW;
    int targetH;
    if (forceCardRatio) {
      targetW = slotMaxW;
      targetH = slotMaxH;
    } else {
      final scale = math.min(slotMaxW / src.width, slotMaxH / src.height);
      targetW = math.max(1, (src.width * scale).round());
      targetH = math.max(1, (src.height * scale).round());
    }
    final resized = img.copyResize(
      src,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.linear,
    );
    final dstX = ((outW - targetW) / 2.0).round();
    final dstY = (centerY - targetH / 2.0).round();
    // 细边框方便剪裁对齐
    img.drawRect(
      canvas,
      x1: dstX - 1,
      y1: dstY - 1,
      x2: dstX + targetW,
      y2: dstY + targetH,
      color: img.ColorRgba8(215, 222, 232, 255),
      thickness: 2,
    );
    img.compositeImage(canvas, resized, dstX: dstX, dstY: dstY);
  }

  placeSlot(frontImg, (outH * 0.30).round());
  placeSlot(backImg, (outH * 0.70).round());

  var raw = canvas.getBytes(order: img.ChannelOrder.rgba);
  if (req.watermarkTile != null) {
    final composited = compositePageOverlays(
      data: raw,
      width: outW,
      height: outH,
      channels: 4,
      annotations: PageAnnotations.empty,
      signatures: const <SignatureStampData>[],
      watermarkTile: req.watermarkTile,
      watermarkOpacity: req.watermarkOpacity,
    );
    raw = composited.data;
  }
  return encodePixels(
    data: raw,
    width: outW,
    height: outH,
    channels: 4,
    mime: 'image/jpeg',
    quality: 0.94,
  );
}
