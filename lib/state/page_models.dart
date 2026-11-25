import 'dart:math' as math;

import '../engine/options.dart';
import '../engine/pdf.dart';

enum StrokeKind {
  eraseWhite('erase_white'),
  redactBlack('redact_black'),
  highlightYellow('highlight_yellow'),
  highlightRed('highlight_red'),
  highlightBlue('highlight_blue');

  const StrokeKind(this.value);
  final String value;

  static StrokeKind tryParse(Object? raw) {
    if (raw is StrokeKind) return raw;
    if (raw is String) {
      for (final v in values) {
        if (v.value == raw) return v;
      }
    }
    return StrokeKind.eraseWhite;
  }
}

class AnnotationStroke {
  const AnnotationStroke({
    required this.kind,
    required this.width,
    required this.points,
  });

  final StrokeKind kind;
  final double width; // 归一化线宽（相对于画布短边，0.004..0.12）
  final List<CornerPoint> points;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.value,
        'width': width,
        'points': points.map((p) => p.toJson()).toList(growable: false),
      };

  static AnnotationStroke? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawPts = raw['points'];
    if (rawPts is! List || rawPts.isEmpty) return null;
    final pts = <CornerPoint>[];
    for (final p in rawPts) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
        pts.add(CornerPoint(
          (p[0] as num).toDouble().clamp(0.0, 1.0),
          (p[1] as num).toDouble().clamp(0.0, 1.0),
        ));
      } else if (p is Map && p['x'] is num && p['y'] is num) {
        pts.add(CornerPoint(
          (p['x'] as num).toDouble().clamp(0.0, 1.0),
          (p['y'] as num).toDouble().clamp(0.0, 1.0),
        ));
      }
    }
    if (pts.isEmpty) return null;
    final w = raw['width'];
    return AnnotationStroke(
      kind: StrokeKind.tryParse(raw['kind']),
      width: w is num ? w.toDouble().clamp(0.004, 0.12) : 0.024,
      points: List<CornerPoint>.unmodifiable(pts),
    );
  }
}

class SignaturePlacement {
  const SignaturePlacement({
    required this.signatureId,
    required this.cx,
    required this.cy,
    required this.widthRatio,
    required this.aspectRatio,
    this.angle = 0.0,
  });

  final String signatureId;
  final double cx;
  final double cy;
  final double widthRatio;
  final double aspectRatio;
  final double angle;

  SignaturePlacement copyWith({
    double? cx,
    double? cy,
    double? widthRatio,
    double? angle,
  }) {
    return SignaturePlacement(
      signatureId: signatureId,
      cx: (cx ?? this.cx).clamp(0.02, 0.98),
      cy: (cy ?? this.cy).clamp(0.02, 0.98),
      widthRatio: (widthRatio ?? this.widthRatio).clamp(0.06, 0.85),
      aspectRatio: aspectRatio,
      angle: angle ?? this.angle,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'signatureId': signatureId,
        'cx': cx,
        'cy': cy,
        'widthRatio': widthRatio,
        'aspectRatio': aspectRatio,
        'angle': angle,
      };

  static SignaturePlacement? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final sigId = raw['signatureId'];
    final cx = raw['cx'];
    final cy = raw['cy'];
    final wr = raw['widthRatio'];
    final ar = raw['aspectRatio'];
    if (sigId is! String ||
        sigId.isEmpty ||
        cx is! num ||
        cy is! num ||
        wr is! num ||
        ar is! num) {
      return null;
    }
    final ang = raw['angle'];
    return SignaturePlacement(
      signatureId: sigId,
      cx: cx.toDouble().clamp(0.02, 0.98),
      cy: cy.toDouble().clamp(0.02, 0.98),
      widthRatio: wr.toDouble().clamp(0.06, 0.85),
      aspectRatio: ar.toDouble().clamp(0.1, 10.0),
      angle: ang is num ? ang.toDouble() : 0.0,
    );
  }
}

class PageAnnotations {
  const PageAnnotations({
    this.strokes = const <AnnotationStroke>[],
    this.signatures = const <SignaturePlacement>[],
  });

  static const PageAnnotations empty = PageAnnotations();

  final List<AnnotationStroke> strokes;
  final List<SignaturePlacement> signatures;

  bool get isEmpty => strokes.isEmpty && signatures.isEmpty;
  bool get isNotEmpty => !isEmpty;

  PageAnnotations copyWith({
    List<AnnotationStroke>? strokes,
    List<SignaturePlacement>? signatures,
  }) {
    return PageAnnotations(
      strokes: List<AnnotationStroke>.unmodifiable(strokes ?? this.strokes),
      signatures: List<SignaturePlacement>.unmodifiable(signatures ?? this.signatures),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'strokes': strokes.map((s) => s.toJson()).toList(growable: false),
        'signatures': signatures.map((s) => s.toJson()).toList(growable: false),
      };

  static PageAnnotations tryFromJson(Object? raw) {
    if (raw is! Map) return PageAnnotations.empty;
    final rawStrokes = raw['strokes'];
    final rawSigs = raw['signatures'];
    final strokes = <AnnotationStroke>[];
    if (rawStrokes is List) {
      for (final s in rawStrokes) {
        final parsed = AnnotationStroke.tryFromJson(s);
        if (parsed != null) strokes.add(parsed);
      }
    }
    final sigs = <SignaturePlacement>[];
    if (rawSigs is List) {
      for (final s in rawSigs) {
        final parsed = SignaturePlacement.tryFromJson(s);
        if (parsed != null) sigs.add(parsed);
      }
    }
    if (strokes.isEmpty && sigs.isEmpty) return PageAnnotations.empty;
    return PageAnnotations(
      strokes: List<AnnotationStroke>.unmodifiable(strokes),
      signatures: List<SignaturePlacement>.unmodifiable(sigs),
    );
  }
}

class OcrPageResult {
  const OcrPageResult({
    required this.text,
    required this.lines,
    required this.updatedAt,
  });

  final String text;
  final List<PdfOcrLine> lines;
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'lines': lines.map((l) => l.toJson()).toList(growable: false),
        'updatedAt': updatedAt,
      };

  static OcrPageResult? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String) return null;
    final rawLines = raw['lines'];
    final lines = <PdfOcrLine>[];
    if (rawLines is List) {
      for (final l in rawLines) {
        final parsed = PdfOcrLine.tryFromJson(l);
        if (parsed != null) lines.add(parsed);
      }
    }
    final updatedAt = raw['updatedAt'];
    return OcrPageResult(
      text: text,
      lines: List<PdfOcrLine>.unmodifiable(lines),
      updatedAt: updatedAt is num ? updatedAt.round() : 0,
    );
  }
}

class SavedSignature {
  const SavedSignature({
    required this.id,
    required this.name,
    required this.uri,
    required this.width,
    required this.height,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String uri;
  final int width;
  final int height;
  final int createdAt;

  double get aspectRatio => width > 0 ? height / width : 0.4;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'uri': uri,
        'width': width,
        'height': height,
        'createdAt': createdAt,
      };

  static SavedSignature? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final uri = raw['uri'];
    final w = raw['width'];
    final h = raw['height'];
    if (id is! String ||
        name is! String ||
        uri is! String ||
        w is! num ||
        h is! num) {
      return null;
    }
    final createdAt = raw['createdAt'];
    return SavedSignature(
      id: id,
      name: name,
      uri: uri,
      width: math.max(1, w.round()),
      height: math.max(1, h.round()),
      createdAt: createdAt is num ? createdAt.round() : 0,
    );
  }
}

class CustomPreset {
  const CustomPreset({
    required this.id,
    required this.name,
    required this.patch,
  });

  final String id;
  final String name;
  final Map<String, Object?> patch;

  bool isActive(ScanOptions options) {
    final json = options.toJson();
    for (final entry in patch.entries) {
      if (json[entry.key] != entry.value) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'patch': patch,
      };

  static CustomPreset? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final patch = raw['patch'];
    if (id is! String || name is! String || patch is! Map) return null;
    final typedPatch = <String, Object?>{};
    for (final e in patch.entries) {
      if (e.key is String) typedPatch[e.key as String] = e.value;
    }
    return CustomPreset(id: id, name: name, patch: typedPatch);
  }
}

class AppPreferences {
  const AppPreferences({
    this.autoDetectOnImport = true,
    this.themeMode = 'system',
    this.pdfQuality = 0.92,
  });

  final bool autoDetectOnImport;
  final String themeMode; // 'system' | 'light' | 'dark'
  final double pdfQuality;

  AppPreferences copyWith({
    bool? autoDetectOnImport,
    String? themeMode,
    double? pdfQuality,
  }) {
    return AppPreferences(
      autoDetectOnImport: autoDetectOnImport ?? this.autoDetectOnImport,
      themeMode: themeMode ?? this.themeMode,
      pdfQuality: pdfQuality ?? this.pdfQuality,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'autoDetectOnImport': autoDetectOnImport,
        'themeMode': themeMode,
        'pdfQuality': pdfQuality,
      };

  static AppPreferences tryFromJson(Object? raw) {
    if (raw is! Map) return const AppPreferences();
    final auto = raw['autoDetectOnImport'];
    final theme = raw['themeMode'];
    final q = raw['pdfQuality'];
    return AppPreferences(
      autoDetectOnImport: auto is bool ? auto : true,
      themeMode: theme is String && const ['system', 'light', 'dark'].contains(theme)
          ? theme
          : 'system',
      pdfQuality: q is num ? q.toDouble().clamp(0.4, 0.98) : 0.92,
    );
  }
}

class PageItem {
  const PageItem({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sourceUri,
    required this.sourceW,
    required this.sourceH,
    required this.options,
    this.annotations = PageAnnotations.empty,
    this.ocr,
  });

  final String id;
  final String name;
  final int createdAt;
  final String sourceUri;
  final int sourceW;
  final int sourceH;
  final ScanOptions options;
  final PageAnnotations annotations;
  final OcrPageResult? ocr;

  PageItem copyWith({
    String? id,
    String? name,
    int? createdAt,
    String? sourceUri,
    int? sourceW,
    int? sourceH,
    ScanOptions? options,
    PageAnnotations? annotations,
    OcrPageResult? ocr,
    bool clearOcr = false,
  }) {
    return PageItem(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      sourceUri: sourceUri ?? this.sourceUri,
      sourceW: sourceW ?? this.sourceW,
      sourceH: sourceH ?? this.sourceH,
      options: options ?? this.options,
      annotations: annotations ?? this.annotations,
      ocr: clearOcr ? null : (ocr ?? this.ocr),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'sourceUri': sourceUri,
        'sourceW': sourceW,
        'sourceH': sourceH,
        'options': options.toJson(),
        if (annotations.isNotEmpty) 'annotations': annotations.toJson(),
        if (ocr != null) 'ocr': ocr!.toJson(),
      };

  static PageItem? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final sourceUri = raw['sourceUri'];
    final sourceW = raw['sourceW'];
    final sourceH = raw['sourceH'];
    if (id is! String ||
        name is! String ||
        sourceUri is! String ||
        sourceW is! num ||
        sourceH is! num) {
      return null;
    }
    final createdAt = raw['createdAt'];
    return PageItem(
      id: id,
      name: name,
      createdAt: createdAt is num
          ? createdAt.round()
          : DateTime.now().millisecondsSinceEpoch,
      sourceUri: sourceUri,
      sourceW: math.max(1, sourceW.round()),
      sourceH: math.max(1, sourceH.round()),
      options: normalizeOptions(raw['options']),
      annotations: PageAnnotations.tryFromJson(raw['annotations']),
      ocr: OcrPageResult.tryFromJson(raw['ocr']),
    );
  }
}

const List<String> kDefaultFolders = <String>['默认', '合同', '票据', '证件', '书籍'];

class ScanDocument {
  const ScanDocument({
    required this.id,
    required this.title,
    this.folder = '默认',
    required this.createdAt,
    required this.updatedAt,
    this.pages = const <PageItem>[],
    this.currentIndex = 0,
  });

  final String id;
  final String title;
  final String folder;
  final int createdAt;
  final int updatedAt;
  final List<PageItem> pages;
  final int currentIndex;

  ScanDocument copyWith({
    String? id,
    String? title,
    String? folder,
    int? createdAt,
    int? updatedAt,
    List<PageItem>? pages,
    int? currentIndex,
  }) {
    final nextPages = pages ?? this.pages;
    final clampedIdx = nextPages.isEmpty
        ? 0
        : (currentIndex ?? this.currentIndex).clamp(0, nextPages.length - 1);
    return ScanDocument(
      id: id ?? this.id,
      title: title ?? this.title,
      folder: folder ?? this.folder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pages: nextPages,
      currentIndex: clampedIdx,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'folder': folder,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'currentIndex': currentIndex,
        'pages': pages.map((p) => p.toJson()).toList(growable: false),
      };

  static ScanDocument? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || id.isEmpty || title is! String) return null;
    final folder = raw['folder'];
    final createdAt = raw['createdAt'];
    final updatedAt = raw['updatedAt'];
    final currentIndex = raw['currentIndex'];
    final rawPages = raw['pages'];
    final parsedPages = <PageItem>[];
    if (rawPages is List) {
      for (final row in rawPages) {
        final item = PageItem.tryFromJson(row);
        if (item != null) parsedPages.add(item);
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return ScanDocument(
      id: id,
      title: title.trim().isEmpty ? '未命名文档' : title.trim(),
      folder: folder is String && folder.trim().isNotEmpty ? folder.trim() : '默认',
      createdAt: createdAt is num ? createdAt.round() : now,
      updatedAt: updatedAt is num ? updatedAt.round() : now,
      pages: List<PageItem>.unmodifiable(parsedPages),
      currentIndex: parsedPages.isEmpty
          ? 0
          : (currentIndex is num ? currentIndex.round() : 0)
              .clamp(0, parsedPages.length - 1),
    );
  }
}

class DocumentLibrary {
  const DocumentLibrary({
    required this.documents,
    required this.activeId,
    this.customFolders = const <String>[],
  });

  final List<ScanDocument> documents;
  final String activeId;
  final List<String> customFolders;

  ScanDocument get activeDocument {
    for (final d in documents) {
      if (d.id == activeId) return d;
    }
    return documents.first;
  }

  List<String> get allFolders {
    final out = <String>[...kDefaultFolders];
    for (final f in customFolders) {
      if (!out.contains(f)) out.add(f);
    }
    for (final d in documents) {
      if (!out.contains(d.folder)) out.add(d.folder);
    }
    return out;
  }
}

class ModeOption {
  const ModeOption({
    required this.value,
    required this.label,
    required this.hint,
  });

  final ScanMode value;
  final String label;
  final String hint;
}

const List<ModeOption> kModeOptions = <ModeOption>[
  ModeOption(value: ScanMode.bw, label: '黑白', hint: '文档扫描'),
  ModeOption(value: ScanMode.bwStamp, label: '留红印章', hint: '保红蓝章'),
  ModeOption(value: ScanMode.gray, label: '灰度', hint: '保留层次'),
  ModeOption(value: ScanMode.color, label: '彩色', hint: '原始色彩'),
];

class PaperOption {
  const PaperOption({required this.value, required this.label});

  final PaperTone value;
  final String label;
}

const List<PaperOption> kPaperOptions = <PaperOption>[
  PaperOption(value: PaperTone.white, label: '白纸'),
  PaperOption(value: PaperTone.warm, label: '暖色'),
  PaperOption(value: PaperTone.gray, label: '灰底'),
];

class StylePreset {
  const StylePreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.patch,
  });

  final String id;
  final String name;
  final String desc;
  final Map<String, Object?> patch;

  bool isActive(ScanOptions options) {
    final json = options.toJson();
    for (final entry in patch.entries) {
      if (json[entry.key] != entry.value) return false;
    }
    return true;
  }
}

const List<StylePreset> kStylePresets = <StylePreset>[
  StylePreset(
    id: 'doc',
    name: '文档',
    desc: '白底黑字，适合合同与打印稿',
    patch: <String, Object?>{
      'mode': 'bw',
      'paper': 'white',
      'contrast': 56,
      'brightness': 2,
      'gamma': 100,
      'shadow': 62,
      'threshold': 52,
      'sharpen': 45,
      'denoise': 22,
    },
  ),
  StylePreset(
    id: 'receipt',
    name: '票据',
    desc: '小字更锐利，细线不断',
    patch: <String, Object?>{
      'mode': 'bw',
      'paper': 'white',
      'contrast': 62,
      'brightness': 0,
      'gamma': 96,
      'shadow': 54,
      'threshold': 60,
      'sharpen': 58,
      'denoise': 26,
    },
  ),
  StylePreset(
    id: 'book',
    name: '书籍',
    desc: '暖色纸张，长时间阅读不刺眼',
    patch: <String, Object?>{
      'mode': 'gray',
      'paper': 'warm',
      'contrast': 48,
      'brightness': 3,
      'gamma': 108,
      'shadow': 58,
      'threshold': 50,
      'sharpen': 32,
      'denoise': 20,
    },
  ),
  StylePreset(
    id: 'photo',
    name: '照片增强',
    desc: '保留色彩，提升对比与清晰度',
    patch: <String, Object?>{
      'mode': 'color',
      'paper': 'white',
      'contrast': 55,
      'brightness': 2,
      'gamma': 100,
      'shadow': 42,
      'threshold': 50,
      'sharpen': 52,
      'denoise': 18,
      'descreen': false,
    },
  ),
  StylePreset(
    id: 'stamp',
    name: '合同留红',
    desc: '白底黑字，自动保留红章与蓝签',
    patch: <String, Object?>{
      'mode': 'bw_stamp',
      'paper': 'white',
      'contrast': 56,
      'brightness': 2,
      'gamma': 100,
      'shadow': 62,
      'threshold': 52,
      'sharpen': 45,
      'denoise': 22,
      'descreen': false,
    },
  ),
  StylePreset(
    id: 'screen',
    name: '拍屏幕',
    desc: '抑制显示器网格彩纹与摩尔纹',
    patch: <String, Object?>{
      'mode': 'color',
      'paper': 'white',
      'contrast': 54,
      'brightness': 2,
      'gamma': 100,
      'shadow': 38,
      'threshold': 50,
      'sharpen': 30,
      'denoise': 36,
      'descreen': true,
    },
  ),
];

enum ParamKey {
  contrast,
  brightness,
  gamma,
  shadow,
  threshold,
  sharpen,
  denoise,
  maxDim,
}

class ParamRowMeta {
  const ParamRowMeta({
    required this.key,
    required this.fieldName,
    required this.label,
    required this.min,
    required this.max,
    required this.step,
    this.unit = '',
    this.onlyMode,
  });

  final ParamKey key;
  final String fieldName;
  final String label;
  final int min;
  final int max;
  final int step;
  final String unit;
  final ScanMode? onlyMode;

  int readFrom(ScanOptions options) {
    switch (key) {
      case ParamKey.contrast:
        return options.contrast;
      case ParamKey.brightness:
        return options.brightness;
      case ParamKey.gamma:
        return options.gamma;
      case ParamKey.shadow:
        return options.shadow;
      case ParamKey.threshold:
        return options.threshold;
      case ParamKey.sharpen:
        return options.sharpen;
      case ParamKey.denoise:
        return options.denoise;
      case ParamKey.maxDim:
        return options.maxDim;
    }
  }
}

const List<ParamRowMeta> kParamRows = <ParamRowMeta>[
  ParamRowMeta(key: ParamKey.contrast, fieldName: 'contrast', label: '对比度', min: 0, max: 100, step: 1),
  ParamRowMeta(key: ParamKey.brightness, fieldName: 'brightness', label: '亮度', min: -50, max: 50, step: 1),
  ParamRowMeta(key: ParamKey.gamma, fieldName: 'gamma', label: 'Gamma', min: 50, max: 200, step: 1),
  ParamRowMeta(key: ParamKey.shadow, fieldName: 'shadow', label: '去阴影', min: 0, max: 100, step: 1),
  ParamRowMeta(
    key: ParamKey.threshold,
    fieldName: 'threshold',
    label: '阈值',
    min: 0,
    max: 100,
    step: 1,
    onlyMode: ScanMode.bw,
  ),
  ParamRowMeta(key: ParamKey.sharpen, fieldName: 'sharpen', label: '锐化', min: 0, max: 100, step: 1),
  ParamRowMeta(key: ParamKey.denoise, fieldName: 'denoise', label: '降噪', min: 0, max: 100, step: 1),
  ParamRowMeta(
    key: ParamKey.maxDim,
    fieldName: 'maxDim',
    label: '输出长边',
    min: 1000,
    max: 4000,
    step: 200,
    unit: 'px',
  ),
];

const PdfOptions kDefaultPdfOptions = PdfOptions(
  pageSize: PdfPageSize.a4,
  orientation: PdfOrientation.auto,
  marginMm: 10,
);

int _randSeed = 0;

String createPageId([DateTime? now]) {
  _randSeed = (_randSeed + 1) % 0xFFFFFF;
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36);
  final r = ((math.Random().nextInt(0xFFFFF) ^ _randSeed) & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(5, '0');
  return 'pg_$t$r';
}

String createEntityId(String prefix, [DateTime? now]) {
  _randSeed = (_randSeed + 1) % 0xFFFFFF;
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36);
  final r = ((math.Random().nextInt(0xFFFFF) ^ _randSeed) & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(5, '0');
  return '${prefix}_$t$r';
}

PageItem createPage({
  String? id,
  required String name,
  required String sourceUri,
  required int sourceW,
  required int sourceH,
  ScanOptions? options,
}) {
  return PageItem(
    id: id ?? createPageId(),
    name: name,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    sourceUri: sourceUri,
    sourceW: math.max(1, sourceW),
    sourceH: math.max(1, sourceH),
    options: normalizeOptions(options),
  );
}

int _clampIndex(int index, int length) {
  if (length <= 0) return 0;
  return index.clamp(0, length - 1);
}

class PagesState {
  const PagesState({
    this.pages = const <PageItem>[],
    this.currentIndex = 0,
  });

  static const PagesState empty = PagesState();

  final List<PageItem> pages;
  final int currentIndex;

  PageItem? get currentPage =>
      pages.isEmpty ? null : pages[_clampIndex(currentIndex, pages.length)];

  String formatPageCounter() {
    final total = pages.length;
    final current = total > 0 ? math.min(currentIndex + 1, total) : 0;
    return '第 $current / 共 $total 页';
  }

  PagesState replaceAll(List<PageItem> nextPages, {int currentIndex = 0}) {
    final normalized = nextPages
        .map((p) => p.copyWith(options: normalizeOptions(p.options)))
        .toList(growable: false);
    return PagesState(
      pages: normalized,
      currentIndex: _clampIndex(currentIndex, normalized.length),
    );
  }

  PagesState addPage(PageItem page) {
    final next = <PageItem>[...pages, page];
    return PagesState(pages: next, currentIndex: next.length - 1);
  }

  PagesState removePage(String id) {
    final index = pages.indexWhere((p) => p.id == id);
    if (index < 0) return this;
    final next = pages.where((p) => p.id != id).toList(growable: false);
    if (next.isEmpty) return const PagesState();
    final currentId = currentPage?.id;
    int nextIndex;
    if (currentId != null && currentId != id) {
      nextIndex = next.indexWhere((p) => p.id == currentId);
    } else {
      nextIndex = math.min(index, next.length - 1);
    }
    return PagesState(
      pages: next,
      currentIndex: _clampIndex(nextIndex, next.length),
    );
  }

  PagesState selectIndex(int index) {
    return PagesState(
      pages: pages,
      currentIndex: _clampIndex(index, pages.length),
    );
  }

  PagesState selectId(String id) {
    final idx = pages.indexWhere((p) => p.id == id);
    return idx >= 0 ? PagesState(pages: pages, currentIndex: idx) : this;
  }

  PagesState updateOptions(String id, Map<String, Object?> patch) {
    final next = pages
        .map(
          (p) => p.id == id
              ? p.copyWith(options: p.options.applyStylePatchWithGeometry(patch))
              : p,
        )
        .toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState updateAllOptions(Map<String, Object?> patch) {
    final next = pages
        .map((p) => p.copyWith(options: p.options.applyStylePatch(patch)))
        .toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState restoreOptions(Map<String, ScanOptions> optionsById) {
    final next = pages.map((p) {
      final saved = optionsById[p.id];
      return saved != null ? p.copyWith(options: normalizeOptions(saved)) : p;
    }).toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState restoreStylePatches(Map<String, Map<String, Object?>> styleById) {
    final next = pages.map((p) {
      final patch = styleById[p.id];
      return patch != null ? p.copyWith(options: p.options.applyStylePatch(patch)) : p;
    }).toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState rotatePage(String id) {
    final next = pages.map((p) {
      if (p.id != id) return p;
      final rot = (p.options.rotate + 90) % 360;
      return p.copyWith(options: p.options.copyWith(rotate: rot));
    }).toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState movePage(int from, int to) {
    if (pages.isEmpty) return this;
    final f = _clampIndex(from, pages.length);
    var t = _clampIndex(to, pages.length);
    if (f == t) return this;
    final currentId = currentPage?.id;
    final mutable = List<PageItem>.of(pages);
    final item = mutable.removeAt(f);
    mutable.insert(t, item);
    final nextIndex = currentId != null ? mutable.indexWhere((p) => p.id == currentId) : 0;
    return PagesState(
      pages: List<PageItem>.unmodifiable(mutable),
      currentIndex: _clampIndex(nextIndex, mutable.length),
    );
  }

  PagesState reorderPages(List<PageItem> reordered) {
    return PagesState(
      pages: List<PageItem>.unmodifiable(reordered),
      currentIndex: _clampIndex(currentIndex, reordered.length),
    );
  }

  PagesState updatePage(String id, PageItem Function(PageItem) transform) {
    final next = pages
        .map((p) => p.id == id ? transform(p) : p)
        .toList(growable: false);
    return PagesState(pages: next, currentIndex: currentIndex);
  }

  PagesState replacePageWithMultiple(
    String id,
    List<PageItem> replacements, {
    required bool keepOriginal,
  }) {
    final idx = pages.indexWhere((p) => p.id == id);
    if (idx < 0 || replacements.isEmpty) return this;
    final mutable = List<PageItem>.of(pages);
    if (keepOriginal) {
      mutable.insertAll(idx + 1, replacements);
      return PagesState(
        pages: List<PageItem>.unmodifiable(mutable),
        currentIndex: idx + 1,
      );
    } else {
      mutable.replaceRange(idx, idx + 1, replacements);
      return PagesState(
        pages: List<PageItem>.unmodifiable(mutable),
        currentIndex: idx,
      );
    }
  }
}

extension _OptionsPatchExt on ScanOptions {
  ScanOptions applyStylePatchWithGeometry(Map<String, Object?> patch) {
    final next = toJson();
    for (final entry in patch.entries) {
      next[entry.key] = entry.value;
    }
    return normalizeOptions(next);
  }
}

int dragTargetIndex(int from, double dx, double step, int count) {
  if (count <= 0 || step <= 0) return from;
  final target = from + (dx / step).round();
  return target.clamp(0, count - 1);
}
