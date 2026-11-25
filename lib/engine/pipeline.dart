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

({Uint8List workRgba, Uint8List gray}) _initColorStage(
  Uint8List rgba,
  Uint8List srcData,
  int w,
  int h,
) {
  var workRgba = compositeWhiteRgba(rgba, w * h);
  if (identical(workRgba, srcData)) {
    workRgba = Uint8List.fromList(srcData);
  }
  final gray = toGray(workRgba, w, h);
  return (workRgba: workRgba, gray: gray);
}

List<double> _colorWhiteBalance(
  Uint8List workRgba,
  Uint8List gray,
  int w,
  int h,
  BackgroundField? bg,
) {
  return bg != null
      ? estimateWhiteBalance(workRgba, gray, w, h)
      : <double>[1.0, 1.0, 1.0];
}

List<List<double>> _scaledQuad(
  List<List<double>> quadFull,
  int w,
  int h,
  int srcW,
  int srcH,
) {
  final sx = w / srcW;
  final sy = h / srcH;
  return quadFull
      .map((p) => <double>[p[0] * sx, p[1] * sy])
      .toList(growable: false);
}

({int ow, int oh, List<List<double>> quad}) _perspectiveTargetForWorkingSize(
  List<List<double>> quadFull,
  int outFullW,
  int outFullH,
  int w,
  int h,
  int srcW,
  int srcH,
) {
  final sx = w / srcW;
  final sy = h / srcH;
  return (
    ow: math.max(8, (outFullW * sx).round()),
    oh: math.max(8, (outFullH * sy).round()),
    quad: _scaledQuad(quadFull, w, h, srcW, srcH),
  );
}

({int fw, int fh}) _clampMaxEdge(int w0, int h0, int maxDim) {
  final curLong = math.max(w0, h0);
  if (curLong <= maxDim) return (fw: w0, fh: h0);
  final fit = _fitLongEdge(w0, h0, maxDim);
  return (fw: fit.width, fh: fit.height);
}

({Uint8List data, int channels}) _applyPaperToneAndInvert(
  Uint8List finalData,
  int fw,
  int fh,
  int finalCh,
  Uint8List srcData,
  ScanOptions opts,
) {
  var data = finalData;
  var ch = finalCh;
  if (opts.paper != PaperTone.white) {
    if (opts.mode == ScanMode.gray) {
      final rgb = paperToneRgb(data, fw, fh, opts.paper);
      data = _grayToOpaqueRgba(rgb, fw * fh);
      ch = 4;
    } else if (opts.mode == ScanMode.color) {
      if (identical(data, srcData)) {
        data = Uint8List.fromList(data);
      }
      paperToneRgba(data, fw * fh, opts.paper);
    }
  }
  if (opts.invert) {
    if (identical(data, srcData)) {
      data = Uint8List.fromList(data);
    }
    data = _invertData(data, ch);
  }
  return (data: data, channels: ch);
}

int _rotationQuarterDegrees(num rotate) =>
    (((rotate / 90.0).round() * 90) % 360 + 360) % 360;

RenderOutcome _buildOutcome(
  Uint8List data,
  int width,
  int height,
  int channels,
  ScanOptions opts,
) {
  final format = opts.mode == ScanMode.bw ? 'png' : 'jpeg';
  return RenderOutcome(
    data: data,
    width: width,
    height: height,
    channels: channels,
    format: format,
  );
}

bool _isKnownRenderError(Object err) {
  if (err is StateError && _knownMessage.hasMatch(err.message)) return true;
  if (err is ArgumentError && _knownMessage.hasMatch('${err.message}')) return true;
  return false;
}

({Uint8List data, int width, int height, int channels}) _runColorStage(
  Uint8List rgba,
  Uint8List srcData,
  int w,
  int h,
  ScanOptions opts,
  Uint8List lut,
) {
  final init = _initColorStage(rgba, srcData, w, h);
  final workRgba = init.workRgba;
  final gray = init.gray;
  if (opts.denoise > 0) {
    final den = denoiseGray(gray, w, h, opts.denoise);
    applyLumaDeltaRgba(workRgba, gray, den, w * h);
    gray.setAll(0, den);
  }
  final bg = opts.shadow > 0 ? makeBackgroundField(gray, w, h, opts.shadow) : null;
  final wb = _colorWhiteBalance(workRgba, gray, w, h, bg);
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

Future<({Uint8List data, int width, int height, int channels})> _runColorStageAsync(
  Uint8List rgba,
  Uint8List srcData,
  int w,
  int h,
  ScanOptions opts,
  Uint8List lut,
  Future<void> Function() maybeYield,
) async {
  final init = _initColorStage(rgba, srcData, w, h);
  final workRgba = init.workRgba;
  final gray = init.gray;
  await maybeYield();
  if (opts.denoise > 0) {
    final den = await denoiseGrayAsync(gray, w, h, opts.denoise, maybeYield: maybeYield);
    applyLumaDeltaRgba(workRgba, gray, den, w * h);
    gray.setAll(0, den);
    await maybeYield();
  }
  final bg = opts.shadow > 0
      ? await makeBackgroundFieldAsync(gray, w, h, opts.shadow, maybeYield: maybeYield)
      : null;
  final wb = _colorWhiteBalance(workRgba, gray, w, h, bg);
  await maybeYield();
  var outData = await enhanceColorAsync(
    workRgba,
    w,
    h,
    bg?.data,
    bg?.strength ?? 0.0,
    wb,
    lut,
    maybeYield: maybeYield,
  );
  await maybeYield();
  if (opts.sharpen > 0) {
    final g2 = toGray(outData, w, h);
    await maybeYield();
    final gs = await sharpenGrayAsync(g2, w, h, opts.sharpen, maybeYield: maybeYield);
    applyLumaDeltaRgba(outData, g2, gs, w * h);
    await maybeYield();
  }
  var curW = w;
  var curH = h;
  if (opts.deskew) {
    final angle = await detectSkewAngleAsync(gray, w, h, maybeYield: maybeYield);
    if (angle != 0.0) {
      final r = await deskewRotateAsync(outData, w, h, 4, angle, maybeYield: maybeYield);
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

Future<({Uint8List data, int width, int height})> _runMonoPreprocessStageAsync(
  Uint8List rgba,
  int w,
  int h,
  ScanOptions opts,
  Uint8List lut,
  Future<void> Function() maybeYield,
) async {
  var gray = toGray(rgba, w, h);
  await maybeYield();
  if (opts.shadow > 0) {
    final bg = await makeBackgroundFieldAsync(gray, w, h, opts.shadow, maybeYield: maybeYield);
    if (bg != null) {
      gray = await removeShadowGrayAsync(gray, bg.data, bg.strength, maybeYield: maybeYield);
    }
    await maybeYield();
  }
  if (opts.denoise > 0) {
    gray = await denoiseGrayAsync(gray, w, h, opts.denoise, maybeYield: maybeYield);
    await maybeYield();
  }
  applyLutGray(gray, lut);
  await maybeYield();
  final angle = opts.deskew
      ? await detectSkewAngleAsync(gray, w, h, maybeYield: maybeYield)
      : 0.0;
  if (opts.sharpen > 0) {
    gray = await sharpenGrayAsync(gray, w, h, opts.sharpen, maybeYield: maybeYield);
    await maybeYield();
  }
  var curW = w;
  var curH = h;
  if (angle != 0.0) {
    final r = await deskewRotateAsync(gray, w, h, 1, angle, maybeYield: maybeYield);
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
  final toned = _applyPaperToneAndInvert(finalData, fw, fh, finalCh, srcData, opts);
  var outData = toned.data;
  final outCh = toned.channels;
  final rot = _rotationQuarterDegrees(opts.rotate);
  if (rot != 0) {
    final r = rotateImage(outData, fw, fh, outCh, rot);
    outData = r.data;
    fw = r.width;
    fh = r.height;
  }
  return _buildOutcome(outData, fw, fh, outCh, opts);
}

Future<RenderOutcome> _finalizeOutputAsync(
  Uint8List finalData,
  int fw,
  int fh,
  int finalCh,
  Uint8List srcData,
  ScanOptions opts,
  Future<void> Function() maybeYield,
) async {
  final toned = _applyPaperToneAndInvert(finalData, fw, fh, finalCh, srcData, opts);
  await maybeYield();
  var outData = toned.data;
  final outCh = toned.channels;
  final rot = _rotationQuarterDegrees(opts.rotate);
  if (rot != 0) {
    final r = await rotateImageAsync(outData, fw, fh, outCh, rot, maybeYield: maybeYield);
    outData = r.data;
    fw = r.width;
    fh = r.height;
  }
  return _buildOutcome(outData, fw, fh, outCh, opts);
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
    final target = _perspectiveTargetForWorkingSize(
      quadFull,
      prep.outFullW,
      prep.outFullH,
      w,
      h,
      srcW,
      srcH,
    );
    rgba = perspectiveTransform(rgba, w, h, target.quad, target.ow, target.oh);
    w = target.ow;
    h = target.oh;
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
  final targetDim = _clampMaxEdge(w0, h0, opts.maxDim);
  final fw = targetDim.fw;
  final fh = targetDim.fh;

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

/// 协作式异步渲染管线（用于 Web 主线程防卡顿与实时取消）
Future<RenderOutcome> renderPageCooperative(
  RgbaSource? source,
  Object? options, {
  required Future<void> Function() maybeYield,
}) async {
  try {
    final prep = _prepareGeometry(source, options);
    final opts = prep.opts;
    final srcData = prep.srcData;
    final srcW = prep.srcW;
    final srcH = prep.srcH;
    final srcLong = math.max(srcW, srcH);

    var w = srcW;
    var h = srcH;
    Uint8List rgba;
    if (prep.procLong < srcLong) {
      final fit = _fitLongEdge(srcW, srcH, prep.procLong);
      rgba = (await resizeImageAsync(
        srcData,
        srcW,
        srcH,
        4,
        fit.width,
        fit.height,
        maybeYield: maybeYield,
      ))
          .data;
      w = fit.width;
      h = fit.height;
    } else {
      rgba = srcData;
    }
    await maybeYield();

    final quadFull = prep.quadFull;
    if (opts.corners != null && quadFull != null) {
      final target = _perspectiveTargetForWorkingSize(
        quadFull,
        prep.outFullW,
        prep.outFullH,
        w,
        h,
        srcW,
        srcH,
      );
      rgba = await perspectiveTransformAsync(
        rgba,
        w,
        h,
        target.quad,
        target.ow,
        target.oh,
        maybeYield: maybeYield,
      );
      w = target.ow;
      h = target.oh;
    }
    await maybeYield();

    final lut = buildToneLut(opts.contrast, opts.brightness, opts.gamma);
    late Uint8List outData;
    late int channels;
    if (opts.mode == ScanMode.color) {
      final stage = await _runColorStageAsync(rgba, srcData, w, h, opts, lut, maybeYield);
      outData = stage.data;
      w = stage.width;
      h = stage.height;
      channels = stage.channels;
    } else {
      final mono = await _runMonoPreprocessStageAsync(rgba, w, h, opts, lut, maybeYield);
      await maybeYield();
      final gray = mono.data;
      w = mono.width;
      h = mono.height;
      if (opts.mode == ScanMode.bw) {
        var bin = await binarizeGrayAsync(
          gray,
          w,
          h,
          opts.threshold,
          suppressFlatBackground: opts.shadow > 0,
          maybeYield: maybeYield,
        );
        await maybeYield();
        bin = await despeckleBinaryAsync(bin, w, h, maybeYield: maybeYield);
        outData = bin;
        channels = 1;
      } else {
        outData = gray;
        channels = 1;
      }
    }
    await maybeYield();

    final w0 = w;
    final h0 = h;
    final targetDim = _clampMaxEdge(w0, h0, opts.maxDim);
    final fw = targetDim.fw;
    final fh = targetDim.fh;

    var finalData = outData;
    var finalCh = channels;
    if (fw != w0 || fh != h0) {
      final r = await resizeImageAsync(
        outData,
        w0,
        h0,
        channels,
        fw,
        fh,
        maybeYield: maybeYield,
      );
      finalData = r.data;
      finalCh = r.channels;
      if (opts.mode == ScanMode.bw) {
        finalData = _rethreshold(finalData, fw, fh, finalCh);
        finalCh = 1;
      }
    }
    await maybeYield();

    return await _finalizeOutputAsync(finalData, fw, fh, finalCh, srcData, opts, maybeYield);
  } catch (err) {
    if (_isKnownRenderError(err)) rethrow;
    throw StateError('图片处理失败：请换一张图片重试');
  }
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
