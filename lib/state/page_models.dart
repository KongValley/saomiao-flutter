import 'dart:math' as math;

import '../engine/options.dart';
import '../engine/pdf.dart';

class PageItem {
  const PageItem({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sourceUri,
    required this.sourceW,
    required this.sourceH,
    required this.options,
  });

  final String id;
  final String name;
  final int createdAt;
  final String sourceUri;
  final int sourceW;
  final int sourceH;
  final ScanOptions options;

  PageItem copyWith({
    String? id,
    String? name,
    int? createdAt,
    String? sourceUri,
    int? sourceW,
    int? sourceH,
    ScanOptions? options,
  }) {
    return PageItem(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      sourceUri: sourceUri ?? this.sourceUri,
      sourceW: sourceW ?? this.sourceW,
      sourceH: sourceH ?? this.sourceH,
      options: options ?? this.options,
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
    );
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
