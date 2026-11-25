import 'dart:collection';

/// 扫描色彩模式
enum ScanMode {
  bw('bw'),
  bwStamp('bw_stamp'),
  gray('gray'),
  color('color');

  const ScanMode(this.value);
  final String value;

  static ScanMode tryParse(Object? raw, {ScanMode fallback = ScanMode.bw}) {
    if (raw is ScanMode) return raw;
    if (raw is String) {
      for (final m in values) {
        if (m.value == raw) return m;
      }
    }
    return fallback;
  }
}

/// 纸张底色（仅灰度 / 彩色模式生效）
enum PaperTone {
  white('white'),
  warm('warm'),
  gray('gray');

  const PaperTone(this.value);
  final String value;

  static PaperTone tryParse(Object? raw, {PaperTone fallback = PaperTone.white}) {
    if (raw is PaperTone) return raw;
    if (raw is String) {
      for (final p in values) {
        if (p.value == raw) return p;
      }
    }
    return fallback;
  }
}

/// 归一化角点（0..1，图像左上角为原点）
class CornerPoint {
  const CornerPoint(this.x, this.y);

  final double x;
  final double y;

  List<double> toJson() => <double>[x, y];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CornerPoint && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'CornerPoint($x, $y)';
}

/// 扫描参数配置（不可变值对象，与桌面版 / Expo 版 ScanOptions 契约完全一致）
class ScanOptions {
  const ScanOptions({
    this.mode = ScanMode.bw,
    this.paper = PaperTone.white,
    this.contrast = 50,
    this.brightness = 0,
    this.gamma = 100,
    this.shadow = 60,
    this.threshold = 50,
    this.sharpen = 40,
    this.denoise = 20,
    this.corners,
    this.rotate = 0,
    this.deskew = false,
    this.descreen = false,
    this.maxDim = 2400,
    this.invert = false,
  });

  static const ScanOptions defaults = ScanOptions();

  final ScanMode mode;
  final PaperTone paper;
  final int contrast;
  final int brightness;
  final int gamma;
  final int shadow;
  final int threshold;
  final int sharpen;
  final int denoise;
  final List<CornerPoint>? corners; // null 或长度 4：TL, TR, BR, BL
  final int rotate; // 0 | 90 | 180 | 270
  final bool deskew;
  final bool descreen;
  final int maxDim; // 600..6000
  final bool invert;

  ScanOptions copyWith({
    ScanMode? mode,
    PaperTone? paper,
    int? contrast,
    int? brightness,
    int? gamma,
    int? shadow,
    int? threshold,
    int? sharpen,
    int? denoise,
    List<CornerPoint>? corners,
    bool clearCorners = false,
    int? rotate,
    bool? deskew,
    bool? descreen,
    int? maxDim,
    bool? invert,
  }) {
    return normalizeOptions(<String, Object?>{
      'mode': (mode ?? this.mode).value,
      'paper': (paper ?? this.paper).value,
      'contrast': contrast ?? this.contrast,
      'brightness': brightness ?? this.brightness,
      'gamma': gamma ?? this.gamma,
      'shadow': shadow ?? this.shadow,
      'threshold': threshold ?? this.threshold,
      'sharpen': sharpen ?? this.sharpen,
      'denoise': denoise ?? this.denoise,
      'corners': clearCorners ? null : (corners ?? this.corners),
      'rotate': rotate ?? this.rotate,
      'deskew': deskew ?? this.deskew,
      'descreen': descreen ?? this.descreen,
      'maxDim': maxDim ?? this.maxDim,
      'invert': invert ?? this.invert,
    });
  }

  /// 仅复制影调 / 细节 / 输出参数（保留逐页几何 corners 与 rotate）
  Map<String, Object?> toStylePatch() => <String, Object?>{
        'mode': mode.value,
        'paper': paper.value,
        'contrast': contrast,
        'brightness': brightness,
        'gamma': gamma,
        'shadow': shadow,
        'threshold': threshold,
        'sharpen': sharpen,
        'denoise': denoise,
        'maxDim': maxDim,
        'deskew': deskew,
        'descreen': descreen,
        'invert': invert,
      };

  ScanOptions applyStylePatch(Map<String, Object?> patch) {
    final next = toJson();
    for (final entry in patch.entries) {
      next[entry.key] = entry.value;
    }
    return normalizeOptions(next);
  }

  /// 按固定键序输出 JSON（保证指纹缓存稳定）
  Map<String, Object?> toJson() => LinkedHashMap<String, Object?>.of(<String, Object?>{
        'mode': mode.value,
        'paper': paper.value,
        'contrast': contrast,
        'brightness': brightness,
        'gamma': gamma,
        'shadow': shadow,
        'threshold': threshold,
        'sharpen': sharpen,
        'denoise': denoise,
        'corners': corners?.map((p) => p.toJson()).toList(growable: false),
        'rotate': rotate,
        'deskew': deskew,
        'descreen': descreen,
        'maxDim': maxDim,
        'invert': invert,
      });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ScanOptions) return false;
    if (mode != other.mode ||
        paper != other.paper ||
        contrast != other.contrast ||
        brightness != other.brightness ||
        gamma != other.gamma ||
        shadow != other.shadow ||
        threshold != other.threshold ||
        sharpen != other.sharpen ||
        denoise != other.denoise ||
        rotate != other.rotate ||
        deskew != other.deskew ||
        descreen != other.descreen ||
        maxDim != other.maxDim ||
        invert != other.invert) {
      return false;
    }
    if (corners == null && other.corners == null) return true;
    if (corners == null || other.corners == null) return false;
    if (corners!.length != other.corners!.length) return false;
    for (var i = 0; i < corners!.length; i++) {
      if (corners![i] != other.corners![i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        mode,
        paper,
        contrast,
        brightness,
        gamma,
        shadow,
        threshold,
        sharpen,
        denoise,
        corners == null ? null : Object.hashAll(corners!),
        rotate,
        deskew,
        descreen,
        maxDim,
        invert,
      );
}

double? _toNumber(Object? v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }
  if (v is String) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return null;
    final parsed = double.tryParse(trimmed);
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return null;
}

int _clampNum(double v, int lo, int hi) {
  final r = v.round();
  if (r < lo) return lo;
  if (r > hi) return hi;
  return r;
}

bool _toBool(Object? v) {
  return v == true || v == 1 || v == '1' || v == 'true' || v == 'on';
}

/// 校验四角是否构成非退化、非内凹、非自相交的凸四边形
bool isValidConvexQuad(List<CornerPoint> pts, {double minArea = 0.01}) {
  if (pts.length != 4) return false;
  for (final p in pts) {
    if (!p.x.isFinite || !p.y.isFinite) return false;
  }
  for (var i = 0; i < 4; i++) {
    for (var j = i + 1; j < 4; j++) {
      final dx = pts[i].x - pts[j].x;
      final dy = pts[i].y - pts[j].y;
      if (dx * dx + dy * dy < 1e-6) return false;
    }
  }
  var area2 = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = pts[i];
    final b = pts[(i + 1) % 4];
    area2 += a.x * b.y - b.x * a.y;
  }
  if (area2.abs() / 2.0 < minArea) return false;

  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = pts[i];
    final b = pts[(i + 1) % 4];
    final c = pts[(i + 2) % 4];
    final cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (cr.abs() <= 1e-6) return false;
    final s = cr > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// 规范化四角：必须 4 个点，坐标 clamp 到 0..1；非凸、自相交或面积过小（< 0.01）视为退化并返回 null
List<CornerPoint>? normalizeCorners(Object? raw) {
  if (raw is! List || raw.length != 4) return null;
  final pts = <CornerPoint>[];
  for (var i = 0; i < 4; i++) {
    final p = raw[i];
    double? x;
    double? y;
    if (p is CornerPoint) {
      x = p.x.isFinite ? p.x : null;
      y = p.y.isFinite ? p.y : null;
    } else if (p is List && p.length >= 2) {
      x = _toNumber(p[0]);
      y = _toNumber(p[1]);
    } else if (p is Map) {
      x = _toNumber(p['x']);
      y = _toNumber(p['y']);
    } else {
      return null;
    }
    if (x == null || y == null) return null;
    final cx = x < 0 ? 0.0 : (x > 1 ? 1.0 : x);
    final cy = y < 0 ? 0.0 : (y > 1 ? 1.0 : y);
    pts.add(CornerPoint(cx, cy));
  }
  if (!isValidConvexQuad(pts, minArea: 0.01)) return null;
  return List<CornerPoint>.unmodifiable(pts);
}

/// 补齐默认值 + clamp + 过滤非法字段（永不抛错）
ScanOptions normalizeOptions(Object? partial) {
  try {
    if (partial is ScanOptions) {
      return ScanOptions(
        mode: partial.mode,
        paper: partial.paper,
        contrast: partial.contrast.clamp(0, 100),
        brightness: partial.brightness.clamp(-50, 50),
        gamma: partial.gamma.clamp(50, 200),
        shadow: partial.shadow.clamp(0, 100),
        threshold: partial.threshold.clamp(0, 100),
        sharpen: partial.sharpen.clamp(0, 100),
        denoise: partial.denoise.clamp(0, 100),
        corners: normalizeCorners(partial.corners),
        rotate: (((partial.rotate / 90).round() * 90) % 360 + 360) % 360,
        deskew: partial.deskew,
        descreen: partial.descreen,
        maxDim: partial.maxDim.clamp(600, 6000),
        invert: partial.invert,
      );
    }
    if (partial is! Map) return ScanOptions.defaults;

    final mode = ScanMode.tryParse(partial['mode']);
    final paper = PaperTone.tryParse(partial['paper']);

    var contrast = ScanOptions.defaults.contrast;
    final nContrast = _toNumber(partial['contrast']);
    if (nContrast != null) contrast = _clampNum(nContrast, 0, 100);

    var brightness = ScanOptions.defaults.brightness;
    final nBrightness = _toNumber(partial['brightness']);
    if (nBrightness != null) brightness = _clampNum(nBrightness, -50, 50);

    var gamma = ScanOptions.defaults.gamma;
    final nGamma = _toNumber(partial['gamma']);
    if (nGamma != null) gamma = _clampNum(nGamma, 50, 200);

    var shadow = ScanOptions.defaults.shadow;
    final nShadow = _toNumber(partial['shadow']);
    if (nShadow != null) shadow = _clampNum(nShadow, 0, 100);

    var threshold = ScanOptions.defaults.threshold;
    final nThreshold = _toNumber(partial['threshold']);
    if (nThreshold != null) threshold = _clampNum(nThreshold, 0, 100);

    var sharpen = ScanOptions.defaults.sharpen;
    final nSharpen = _toNumber(partial['sharpen']);
    if (nSharpen != null) sharpen = _clampNum(nSharpen, 0, 100);

    var denoise = ScanOptions.defaults.denoise;
    final nDenoise = _toNumber(partial['denoise']);
    if (nDenoise != null) denoise = _clampNum(nDenoise, 0, 100);

    var maxDim = ScanOptions.defaults.maxDim;
    final nMaxDim = _toNumber(partial['maxDim']);
    if (nMaxDim != null) maxDim = _clampNum(nMaxDim, 600, 6000);

    final corners = normalizeCorners(partial['corners']);

    var rotate = ScanOptions.defaults.rotate;
    final nRotate = _toNumber(partial['rotate']);
    if (nRotate != null) {
      final q = (nRotate / 90).round() * 90;
      rotate = ((q % 360) + 360) % 360;
    }

    final rawDeskew = partial['deskew'];
    final deskew =
        rawDeskew == null ? ScanOptions.defaults.deskew : _toBool(rawDeskew);

    final rawDescreen = partial['descreen'];
    final descreen =
        rawDescreen == null ? ScanOptions.defaults.descreen : _toBool(rawDescreen);

    final rawInvert = partial['invert'];
    final invert =
        rawInvert == null ? ScanOptions.defaults.invert : _toBool(rawInvert);

    return ScanOptions(
      mode: mode,
      paper: paper,
      contrast: contrast,
      brightness: brightness,
      gamma: gamma,
      shadow: shadow,
      threshold: threshold,
      sharpen: sharpen,
      denoise: denoise,
      corners: corners,
      rotate: rotate,
      deskew: deskew,
      descreen: descreen,
      maxDim: maxDim,
      invert: invert,
    );
  } catch (_) {
    return ScanOptions.defaults;
  }
}
