import 'dart:math' as math;
import 'dart:typed_data';

import 'detect.dart';
import 'filters.dart';
import 'geometry.dart';
import 'options.dart';
import 'resize.dart';

class RenderOutcome {
  const RenderOutcome({
    required this.data,
    required this.width,
    required this.height,
    required this.channels,
    required this.format,
  });

  final Uint8List data;
  final int width;
  final int height;
  final int channels; // 1 | 4
  final String format; // 'png' | 'jpeg'
}

final RegExp _knownMessage = RegExp(r'^(图片|手机|透视|处理已取消)');

Uint8List _invertData(Uint8List data, int channels) {
  if (channels == 1) return invertGray(data);
  if (channels == 3) {
    for (var i = 0; i < data.length; i += 3) {
      data[i] = 255 - data[i];
      data[i + 1] = 255 - data[i + 1];
      data[i + 2] = 255 - data[i + 2];
    }
    return data;
  }
  return invertRgba(data);
}

Uint8List _rethreshold(Uint8List src, int w, int h, int channels) {
  final n = w * h;
  final out = Uint8List(n);
  if (channels == 1) {
    for (var i = 0; i < n; i++) {
      out[i] = src[i] > 128 ? 255 : 0;
    }
  } else {
    for (var i = 0, p = 0; i < n; i++, p += channels) {
      out[i] = src[p] > 128 ? 255 : 0;
    }
  }
  return out;
}

Uint8List _grayToOpaqueRgba(Uint8List rgb, int n) {
  final out = Uint8List(n * 4);
  for (var i = 0, p = 0, q = 0; i < n; i++, p += 3, q += 4) {
    out[q] = rgb[p];
    out[q + 1] = rgb[p + 1];
    out[q + 2] = rgb[p + 2];
    out[q + 3] = 255;
  }
  return out;
}

({int width, int height}) _fitLongEdge(int w, int h, int target) {
  if (w >= h) {
    return (width: target, height: math.max(1, ((h * target) / w).round()));
  }
  return (width: math.max(1, ((w * target) / h).round()), height: target);
}

({
  ScanOptions opts,
  Uint8List srcData,
  int srcW,
  int srcH,
  List<List<double>>? quadFull,
  int outFullW,
  int outFullH,
  int procLong,
}) _prepareGeometry(RgbaSource? source, Object? options) {
  final opts = normalizeOptions(options);
  if (source == null || source.data.isEmpty) {
    throw StateError('图片数据为空或无法读取');
  }
  final srcData = source.data;
  final srcW = source.width;
  final srcH = source.height;
  if (srcW <= 0 || srcH <= 0) {
    throw StateError('图片尺寸非法：宽高必须大于 0');
  }
  if (srcData.length < srcW * srcH * 4) {
    throw StateError('图片数据不完整：像素数量与宽高不符');
  }
  final srcLong = math.max(srcW, srcH);

  List<List<double>>? quadFull;
  var outFullW = srcW;
  var outFullH = srcH;
  if (opts.corners != null) {
    quadFull = cornersToPixels(opts.corners!, srcW, srcH);
    final est = estimateOutputSize(quadFull);
    outFullW = est.width;
    outFullH = est.height;
  }
  final outFullLong = math.max(outFullW, outFullH);
  final outTargetLong = math.max(1, math.min(outFullLong, opts.maxDim));
  int procLong;
  if (quadFull != null) {
    procLong = ((srcLong * outTargetLong) / outFullLong).ceil();
    if (procLong > srcLong) procLong = srcLong;
    if (procLong < 1) procLong = 1;
  } else {
    procLong = math.min(srcLong, opts.maxDim);
  }

  return (
    opts: opts,
    srcData: srcData,
    srcW: srcW,
    srcH: srcH,
    quadFull: quadFull,
    outFullW: outFullW,
    outFullH: outFullH,
    procLong: procLong,
  );
}

({Uint8List data, int width, int height, int channels}) _runColorStage(
  Uint8List rgba,
  Uint8List srcData,
  int w,
  int h,
  ScanOptions opts,
  Uint8List lut,
) {
  var workRgba = compositeWhiteRgba(rgba, w * h);
  if (identical(workRgba, srcData)) {
    workRgba = Uint8List.fromList(srcData);
  }
  final gray = toGray(workRgba, w, h);
  if (opts.denoise > 0) {
    final den = denoiseGray(gray, w, h, opts.denoise);
    applyLumaDeltaRgba(workRgba, gray, den, w * h);
    gray.setAll(0, den);
  }
  final bg = opts.shadow > 0 ? makeBackgroundField(gray, w, h, opts.shadow) : null;
  final wb = bg != null ? estimateWhiteBalance(workRgba, gray, w, h) : <double>[1.0, 1.0, 1.0];
  var outData = enhanceColor(
    workRgba,
    w,
    h,
    bg?.data,
    bg?.strength ?? 0.0,
    wb,
    lut,
  );
  if (opts.sharpen > 0) {
    final g2 = toGray(outData, w, h);
    final gs = sharpenGray(g2, w, h, opts.sharpen);
    applyLumaDeltaRgba(outData, g2, gs, w * h);
  }
  var curW = w;
  var curH = h;
  if (opts.deskew) {
    final angle = detectSkewAngle(gray, w, h);
    if (angle != 0.0) {
      final r = deskewRotate(outData, w, h, 4, angle);
      outData = r.data;
      curW = r.width;
      curH = r.height;
    }
  }
  return (data: outData, width: curW, height: curH, channels: 4);
}

({Uint8List data, int width, int height}) _runMonoPreprocessStage(
  Uint8List rgba,
  int w,
  int h,
  ScanOptions opts,
  Uint8List lut,
) {
  var gray = toGray(rgba, w, h);
  if (opts.shadow > 0) {
    final bg = makeBackgroundField(gray, w, h, opts.shadow);
    if (bg != null) {
      gray = removeShadowGray(gray, bg.data, bg.strength);
    }
  }
  if (opts.denoise > 0) {
    gray = denoiseGray(gray, w, h, opts.denoise);
  }
  applyLutGray(gray, lut);
  final angle = opts.deskew ? detectSkewAngle(gray, w, h) : 0.0;
  if (opts.sharpen > 0) {
    gray = sharpenGray(gray, w, h, opts.sharpen);
  }
  var curW = w;
  var curH = h;
  if (angle != 0.0) {
    final r = deskewRotate(gray, w, h, 1, angle);
    gray = r.data;
    curW = r.width;
    curH = r.height;
  }
  return (data: gray, width: curW, height: curH);
}

RenderOutcome _finalizeOutput(
  Uint8List finalData,
  int fw,
  int fh,
  int finalCh,
  Uint8List srcData,
  ScanOptions opts,
) {
  // 5. 灰度 / 彩色纸色映射
  if (opts.paper != PaperTone.white) {
    if (opts.mode == ScanMode.gray) {
      final rgb = paperToneRgb(finalData, fw, fh, opts.paper);
      finalData = _grayToOpaqueRgba(rgb, fw * fh);
      finalCh = 4;
    } else if (opts.mode == ScanMode.color) {
      if (identical(finalData, srcData)) {
        finalData = Uint8List.fromList(finalData);
      }
      paperToneRgba(finalData, fw * fh, opts.paper);
    }
  }

  // 6. 反相
  if (opts.invert) {
    if (identical(finalData, srcData)) {
      finalData = Uint8List.fromList(finalData);
    }
    finalData = _invertData(finalData, finalCh);
  }

  // 7. 90° 旋转
  final rot = (((opts.rotate / 90.0).round() * 90) % 360 + 360) % 360;
  if (rot != 0) {
    final r = rotateImage(finalData, fw, fh, finalCh, rot);
    finalData = r.data;
    fw = r.width;
    fh = r.height;
  }

  final format = opts.mode == ScanMode.bw ? 'png' : 'jpeg';
  return RenderOutcome(
    data: finalData,
    width: fw,
    height: fh,
    channels: finalCh,
    format: format,
  );
}

bool _isKnownRenderError(Object err) {
  if (err is StateError && _knownMessage.hasMatch(err.message)) return true;
  if (err is ArgumentError && _knownMessage.hasMatch('${err.message}')) return true;
  return false;
}

/// 主渲染管线：输入 RGBA 源像素，返回处理后像素（纯同步算法，可在 Isolate 中运行）
RenderOutcome renderPage(RgbaSource? source, [Object? options]) {
  try {
    return _renderPageImpl(source, options);
  } catch (err) {
    if (_isKnownRenderError(err)) rethrow;
    throw StateError('图片处理失败：请换一张图片重试');
  }
}

RenderOutcome _renderPageImpl(RgbaSource? source, Object? options) {
  final prep = _prepareGeometry(source, options);
  final opts = prep.opts;
  final srcData = prep.srcData;
  final srcW = prep.srcW;
  final srcH = prep.srcH;
  final srcLong = math.max(srcW, srcH);

  // 2. 预缩放
  var w = srcW;
  var h = srcH;
  Uint8List rgba;
  if (prep.procLong < srcLong) {
    final fit = _fitLongEdge(srcW, srcH, prep.procLong);
    rgba = resizeImage(srcData, srcW, srcH, 4, fit.width, fit.height).data;
    w = fit.width;
    h = fit.height;
  } else {
    rgba = srcData;
  }

  // 3. 透视矫正
  final quadFull = prep.quadFull;
  if (opts.corners != null && quadFull != null) {
    final sx = w / srcW;
    final sy = h / srcH;
    final quad = quadFull
        .map((p) => <double>[p[0] * sx, p[1] * sy])
        .toList(growable: false);
    final ow = math.max(8, (prep.outFullW * sx).round());
    final oh = math.max(8, (prep.outFullH * sy).round());
    rgba = perspectiveTransform(rgba, w, h, quad, ow, oh);
    w = ow;
    h = oh;
  }

  final lut = buildToneLut(opts.contrast, opts.brightness, opts.gamma);
  late Uint8List outData;
  late int channels;
  if (opts.mode == ScanMode.color) {
    final stage = _runColorStage(rgba, srcData, w, h, opts, lut);
    outData = stage.data;
    w = stage.width;
    h = stage.height;
    channels = stage.channels;
  } else {
    final mono = _runMonoPreprocessStage(rgba, w, h, opts, lut);
    final gray = mono.data;
    w = mono.width;
    h = mono.height;
    if (opts.mode == ScanMode.bw) {
      var bin = binarizeGray(
        gray,
        w,
        h,
        opts.threshold,
        suppressFlatBackground: opts.shadow > 0,
      );
      bin = despeckleBinary(bin, w, h);
      outData = bin;
      channels = 1;
    } else {
      outData = gray;
      channels = 1;
    }
  }

  // 4. 限长边：只缩不放
  final w0 = w;
  final h0 = h;
  var fw = w0;
  var fh = h0;
  final curLong = math.max(w0, h0);
  if (curLong > opts.maxDim) {
    final fit = _fitLongEdge(w0, h0, opts.maxDim);
    fw = fit.width;
    fh = fit.height;
  }

  var finalData = outData;
  var finalCh = channels;
  if (fw != w0 || fh != h0) {
    final r = resizeImage(outData, w0, h0, channels, fw, fh);
    finalData = r.data;
    finalCh = r.channels;
    if (opts.mode == ScanMode.bw) {
      finalData = _rethreshold(finalData, fw, fh, finalCh);
      finalCh = 1;
    }
  }

  return _finalizeOutput(finalData, fw, fh, finalCh, srcData, opts);
}

/// 自动检测纸张四角（始终返回合法四角，只有图片本身非法才抛中文 Error）
DetectCornersResult detectCorners(RgbaSource? source) {
  try {
    return detectCornersFromRgba(source);
  } catch (err) {
    if (_isKnownRenderError(err)) rethrow;
    final w = source != null && source.width > 0 ? source.width : 0;
    final h = source != null && source.height > 0 ? source.height : 0;
    return DetectCornersResult(
      corners: fullCorners,
      width: w,
      height: h,
      confidence: 0.1,
    );
  }
}
