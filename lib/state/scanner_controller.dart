import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../engine/detect.dart';
import '../engine/options.dart';
import '../engine/pdf.dart';
import '../io/app_storage.dart';
import '../io/file_export.dart';
import '../io/image_acquisition.dart';
import '../io/pixel_io.dart';
import '../jobs/demo_generator.dart';
import '../jobs/render_jobs.dart';
import 'page_models.dart';

enum ToastKind { info, success, warn, error }

class ToastMessage {
  const ToastMessage(this.text, [this.kind = ToastKind.info]);

  final String text;
  final ToastKind kind;
}

class ScannerController extends ChangeNotifier {
  ScannerController({
    AppStorage? storage,
    RenderJobs? jobs,
    ImageAcquisition? acquisition,
    FileExporter? exporter,
  })  : _storage = storage ?? createAppStorage(),
        _acquisition = acquisition ?? ImageAcquisition(),
        _exporter = exporter ?? const FileExporter() {
    _jobs = jobs ?? RenderJobs(storage: _storage);
  }

  static const int _maxMemoryRenders = 12;
  static const int _maxMemoryRenderBytes = 32 * 1024 * 1024;

  final AppStorage _storage;
  late final RenderJobs _jobs;
  final ImageAcquisition _acquisition;
  final FileExporter _exporter;

  PagesState _state = PagesState.empty;
  PagesState get state => _state;
  List<PageItem> get pages => _state.pages;
  int get currentIndex => _state.currentIndex;
  PageItem? get currentPage => _state.currentPage;
  bool get hasPages => _state.pages.isNotEmpty;

  bool _hydrated = false;
  bool get hydrated => _hydrated;
  Future<void>? _initFuture;

  final LinkedHashMap<String, RenderedPageResult> _renders =
      LinkedHashMap<String, RenderedPageResult>();
  final Map<String, Uint8List> _thumbnails = <String, Uint8List>{};
  final Map<String, String> _renderErrors = <String, String>{};
  final Set<String> _stalePages = <String>{};
  final Set<String> _pinnedSourceUris = <String>{};

  RenderedPageResult? renderOf(String id) {
    final hit = _renders[id];
    if (hit != null) {
      // Touch LRU order.
      _renders.remove(id);
      _renders[id] = hit;
    }
    return hit;
  }

  Uint8List? thumbnailOf(String id) => _thumbnails[id] ?? _renders[id]?.bytes;
  String? errorOf(String id) => _renderErrors[id];
  RenderedPageResult? get currentRender =>
      currentPage != null ? renderOf(currentPage!.id) : null;
  String? get currentError =>
      currentPage != null ? _renderErrors[currentPage!.id] : null;

  bool _rendering = false;
  String _renderLabel = '正在处理…';
  bool _generatingDemo = false;
  bool _exporting = false;
  String _exportLabel = '正在导出…';

  bool get isBusy => _rendering || _generatingDemo || _exporting;
  bool get isExporting => _exporting;
  String get busyLabel {
    if (_exporting) return _exportLabel;
    if (_generatingDemo) return '正在生成示例文档…';
    return _renderLabel;
  }

  bool get supportsCamera => _acquisition.supportsCamera;

  Map<String, Map<String, Object?>>? _undoSnapshot;
  bool get canUndoBatch => _undoSnapshot != null;

  final StreamController<ToastMessage> _toastController =
      StreamController<ToastMessage>.broadcast();
  Stream<ToastMessage> get toasts => _toastController.stream;

  int _renderSeq = 0;
  Timer? _debounceTimer;
  Timer? _persistTimer;
  bool _persistDirty = false;
  bool _disposed = false;

  void _emitToast(String text, [ToastKind kind = ToastKind.info]) {
    if (_disposed || text.trim().isEmpty) return;
    _toastController.add(ToastMessage(text.trim(), kind));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _putRenderInMemory(String pageId, RenderedPageResult result) {
    _renders.remove(pageId);
    _renders[pageId] = result;
    _thumbnails[pageId] = result.thumbBytes ?? result.bytes;
    _evictMemoryRenders();
  }

  void _evictMemoryRenders() {
    int totalBytes() {
      var sum = 0;
      for (final entry in _renders.values) {
        sum += entry.bytes.length;
      }
      return sum;
    }

    final keepId = currentPage?.id;
    while (_renders.length > _maxMemoryRenders ||
        (_renders.length > 1 && totalBytes() > _maxMemoryRenderBytes)) {
      String? victim;
      for (final id in _renders.keys) {
        if (id != keepId) {
          victim = id;
          break;
        }
      }
      if (victim == null) break;
      _renders.remove(victim);
    }
  }

  Future<void> init({List<PageItem>? demoPages}) {
    if (_initFuture != null) return _initFuture!;
    final future = _runInit(demoPages: demoPages);
    _initFuture = future;
    return future;
  }

  Future<void> _runInit({List<PageItem>? demoPages}) async {
    try {
      final stored = await _storage.loadPages();
      if (_disposed) return;

      List<PickedImageEntry> lost = const <PickedImageEntry>[];
      try {
        lost = await _acquisition.retrieveLostEntries();
      } catch (err) {
        _emitToast(_readableError(err, '恢复上次选图失败，请重试'), ToastKind.error);
      }
      if (_disposed) return;

      if (stored.isNotEmpty) {
        _state = _state.replaceAll(stored);
      } else if (lost.isEmpty && demoPages != null && demoPages.isNotEmpty) {
        _state = _state.replaceAll(demoPages);
      }

      if (lost.isNotEmpty) {
        await _importEntriesInternal(lost, persistImmediately: false);
      } else if (_state.pages.isNotEmpty) {
        _notify();
        unawaited(_runRender(_state.currentPage ?? _state.pages.first));
      }
    } catch (err) {
      _emitToast(_readableError(err, '本地页面读取失败'), ToastKind.error);
    } finally {
      _hydrated = true;
      if (!_disposed && _persistDirty && _storage.isPersistent) {
        unawaited(flushPersist());
      } else if (!_disposed && _state.pages.isNotEmpty && _storage.isPersistent) {
        // Ensure recovered lost pages from Android startup are persisted once hydrated.
        _schedulePersist();
      }
      _notify();
    }
  }

  void _schedulePersist() {
    if (!_storage.isPersistent) return;
    _persistDirty = true;
    if (!_hydrated) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      _persistDirty = false;
      _storage.savePages(_state.pages).catchError((Object err) {
        _persistDirty = true;
        _emitToast(_readableError(err, '保存页面失败'), ToastKind.error);
      });
    });
  }

  Future<void> flushPersist() async {
    if (!_storage.isPersistent || !_hydrated || !_persistDirty) return;
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistDirty = false;
    final snapshot = List<PageItem>.unmodifiable(_state.pages);
    try {
      await _storage.savePages(snapshot);
    } catch (err) {
      _persistDirty = true;
      _emitToast(_readableError(err, '保存页面失败'), ToastKind.error);
    }
  }

  Future<void> _runRender(PageItem page) async {
    final seq = ++_renderSeq;
    _rendering = true;
    _renderLabel = '正在处理…';
    _notify();
    try {
      final result = await _jobs.renderPageTask(
        page,
        page.options,
        onStage: (stage) {
          if (seq == _renderSeq && !_disposed) {
            _rendering = true;
            _renderLabel = '正在$stage…';
            _notify();
          }
        },
        shouldAbort: () => seq != _renderSeq || _disposed,
      );
      if (seq != _renderSeq || _disposed) return;
      final latestIndex = _state.pages.indexWhere((p) => p.id == page.id);
      if (latestIndex < 0) return;
      _putRenderInMemory(page.id, result);
      _renderErrors.remove(page.id);
      if (_state.pages[latestIndex].options == page.options) {
        _stalePages.remove(page.id);
      }
    } catch (err) {
      if (seq != _renderSeq || _disposed) return;
      if (!_state.pages.any((p) => p.id == page.id)) return;
      final msg = _readableError(err, '处理失败，请重试');
      if (msg == kAbortMessage) return;
      _renderErrors[page.id] = msg;
      _emitToast(msg, ToastKind.error);
    } finally {
      if (seq == _renderSeq && !_disposed) {
        _rendering = false;
        _renderLabel = '正在处理…';
        _notify();
      }
    }
  }

  void _scheduleRender(PageItem page, {int delayMs = 0}) {
    _debounceTimer?.cancel();
    if (delayMs <= 0) {
      unawaited(_runRender(page));
      return;
    }
    _debounceTimer = Timer(Duration(milliseconds: delayMs), () {
      final current = currentPage;
      if (_disposed || current == null || current.id != page.id) return;
      unawaited(_runRender(current));
    });
  }

  Future<void> takePhoto() async {
    try {
      final entry = await _acquisition.takePhotoEntry();
      if (entry == null) return;
      await importPickedEntries(<PickedImageEntry>[entry]);
    } catch (err) {
      _emitToast(_readableError(err, '打开相机失败，请重试'), ToastKind.error);
    }
  }

  Future<void> pickFromGallery() async {
    try {
      final entries = await _acquisition.pickFromGalleryEntries();
      if (entries.isEmpty) return;
      await importPickedEntries(entries);
    } catch (err) {
      _emitToast(_readableError(err, '打开相册失败，请重试'), ToastKind.error);
    }
  }

  Future<void> loadDemoPages([int count = 2]) async {
    if (_generatingDemo || _exporting) return;
    _generatingDemo = true;
    _notify();
    try {
      final demos = await generateDemoDocuments(count);
      await importPickedImages(demos);
    } catch (err) {
      _emitToast(_readableError(err, '示例文档生成失败'), ToastKind.error);
    } finally {
      if (!_disposed) {
        _generatingDemo = false;
        _notify();
      }
    }
  }

  Future<void> importPickedImages(List<PickedImageInput> inputs) {
    if (inputs.isEmpty) return Future<void>.value();
    return importPickedEntries(
      inputs.map(PickedImageEntry.fromInput).toList(growable: false),
    );
  }

  Future<void> importPickedEntries(List<PickedImageEntry> entries) async {
    if (entries.isEmpty) return;
    if (_initFuture != null && !_hydrated) {
      await _initFuture;
    }
    if (_disposed) return;
    await _importEntriesInternal(entries, persistImmediately: true);
  }

  Future<void> _importEntriesInternal(
    List<PickedImageEntry> entries, {
    required bool persistImmediately,
  }) async {
    final added = <PageItem>[];
    for (final entry in entries) {
      try {
        final byteLength = await entry.length();
        if (byteLength > kMaxImportFileBytes) {
          _emitToast('「${entry.name}」超过 60MB，请压缩后再试', ToastKind.warn);
          continue;
        }
        final bytes = await entry.readAsBytes();
        if (bytes.isEmpty) {
          _emitToast('「${entry.name}」内容为空，已跳过', ToastKind.error);
          continue;
        }
        if (bytes.length > kMaxImportFileBytes) {
          _emitToast('「${entry.name}」超过 60MB，请压缩后再试', ToastKind.warn);
          continue;
        }
        final size = await probeImageSize(bytes);
        if (size == null || size.width <= 0 || size.height <= 0) {
          _emitToast('「${entry.name}」无法解析，已跳过', ToastKind.error);
          continue;
        }
        if (size.width * size.height > kHardLimitPixels) {
          _emitToast('「${entry.name}」分辨率过高，请先压缩后再导入', ToastKind.warn);
          continue;
        }

        final pageId = createPageId();
        final sourceUri = await _storage.saveSourceBytes(
          bytes,
          pageId,
          entry.name,
        );
        final page = createPage(
          id: pageId,
          name: entry.name.isNotEmpty
              ? entry.name
              : '扫描页_${_state.pages.length + 1}',
          sourceUri: sourceUri,
          sourceW: size.width,
          sourceH: size.height,
          options: ScanOptions.defaults,
        );
        added.add(page);
        _state = _state.addPage(page);
      } catch (err) {
        _emitToast(_readableError(err, '导入失败，请重试'), ToastKind.error);
      }
    }
    if (added.isNotEmpty && !_disposed) {
      if (persistImmediately) {
        _schedulePersist();
      } else {
        _persistDirty = true;
      }
      _notify();
      await _runRender(added.last);
      if (added.length > 1) {
        _emitToast('已导入 ${added.length} 张图片', ToastKind.success);
      }
    }
  }

  Future<Uint8List> readSourceBytes(PageItem page) {
    return _storage.readSourceBytes(page.sourceUri);
  }

  void selectPage(int index) {
    if (index < 0 || index >= _state.pages.length) return;
    final prevId = currentPage?.id;
    _debounceTimer?.cancel();
    _state = _state.selectIndex(index);
    final page = _state.currentPage;
    if (prevId != null && prevId != page?.id && _rendering) {
      _renderSeq++;
      _rendering = false;
      _renderLabel = '正在处理…';
    }
    _notify();
    if (page != null && (!_renders.containsKey(page.id) || _stalePages.contains(page.id))) {
      unawaited(_runRender(page));
    }
  }

  void removePage(PageItem page) {
    if (_exporting || _pinnedSourceUris.contains(page.sourceUri)) {
      _emitToast('正在导出，请稍后再删除页面', ToastKind.warn);
      return;
    }
    final index = _state.pages.indexWhere((p) => p.id == page.id);
    if (index < 0) return;
    final wasCurrent = currentPage?.id == page.id;
    if (wasCurrent) {
      _debounceTimer?.cancel();
      _renderSeq++;
      _rendering = false;
      _renderLabel = '正在处理…';
    }
    _renders.remove(page.id);
    _thumbnails.remove(page.id);
    _renderErrors.remove(page.id);
    _stalePages.remove(page.id);
    _state = _state.removePage(page.id);
    _schedulePersist();
    _notify();
    unawaited(_storage.deleteSource(page.sourceUri));
    _emitToast('已删除这一页', ToastKind.info);
    if (wasCurrent &&
        _state.currentPage != null &&
        (!_renders.containsKey(_state.currentPage!.id) ||
            _stalePages.contains(_state.currentPage!.id))) {
      _scheduleRender(_state.currentPage!);
    }
  }

  void rotatePage(PageItem page) {
    _state = _state.rotatePage(page.id);
    _stalePages.add(page.id);
    _schedulePersist();
    _notify();
    final updated = _state.pages.firstWhere(
      (p) => p.id == page.id,
      orElse: () => page,
    );
    if (currentPage?.id == page.id) {
      _scheduleRender(updated);
    } else {
      _renders.remove(page.id);
      _thumbnails.remove(page.id);
    }
    _emitToast('已旋转 ${updated.options.rotate}°', ToastKind.success);
  }

  void movePage(PageItem page, int offset) {
    final index = _state.pages.indexWhere((p) => p.id == page.id);
    if (index < 0) return;
    _state = _state.movePage(index, index + offset);
    _schedulePersist();
    _notify();
  }

  void reorderPage(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _state.pages.length) return;
    _state = _state.movePage(oldIndex, newIndex);
    _schedulePersist();
    _notify();
  }

  void applyOptions(Map<String, Object?> patch, {bool immediate = false}) {
    final page = currentPage;
    if (page == null) return;
    _state = _state.updateOptions(page.id, patch);
    _stalePages.add(page.id);
    _schedulePersist();
    _notify();
    final nextPage = _state.currentPage;
    if (nextPage != null) {
      _scheduleRender(nextPage, delayMs: immediate ? 0 : 200);
    }
  }

  void resetOptions() {
    final page = currentPage;
    if (page == null) return;
    final reset = ScanOptions.defaults.copyWith(
      corners: page.options.corners,
      rotate: page.options.rotate,
    );
    _state = _state.updateOptions(page.id, reset.toJson());
    _stalePages.add(page.id);
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('参数已恢复默认', ToastKind.success);
  }

  void applyOptionsToAll() {
    final page = currentPage;
    if (page == null || _state.pages.length < 2) return;
    _undoSnapshot = <String, Map<String, Object?>>{
      for (final p in _state.pages) p.id: p.options.toStylePatch(),
    };
    final patch = page.options.toStylePatch();
    _renders.clear();
    _thumbnails.clear();
    _stalePages.addAll(_state.pages.map((p) => p.id));
    _state = _state.updateAllOptions(patch);
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('已应用到全部 ${_state.pages.length} 页', ToastKind.success);
  }

  void undoApplyAll() {
    final snapshot = _undoSnapshot;
    if (snapshot == null) return;
    _state = _state.restoreStylePatches(snapshot);
    _undoSnapshot = null;
    _renders.clear();
    _thumbnails.clear();
    _stalePages.addAll(_state.pages.map((p) => p.id));
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('已撤销', ToastKind.info);
  }

  Future<DetectCornersResult> autoDetectCorners(PageItem page) {
    return _jobs.detectCornersTask(page);
  }

  void applyCorners(List<CornerPoint> corners) {
    final page = currentPage;
    if (page == null) return;
    _state = _state.updateOptions(page.id, <String, Object?>{
      'corners': corners.map((c) => c.toJson()).toList(growable: false),
    });
    _stalePages.add(page.id);
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('已应用四角校正', ToastKind.success);
  }

  void retryCurrentRender() {
    final page = currentPage;
    if (page != null) {
      unawaited(_runRender(page));
    }
  }

  Future<void> exportPdf({
    required PdfOptions pdfOptions,
    required bool allPages,
    required ExportDestination destination,
  }) async {
    final page = currentPage;
    if (page == null || _exporting) return;
    final items = List<PageItem>.unmodifiable(allPages ? _state.pages : <PageItem>[page]);
    final pinned = items.map((p) => p.sourceUri).toList(growable: false);
    _pinnedSourceUris.addAll(pinned);
    _exporting = true;
    _exportLabel = '正在生成 PDF…';
    _notify();
    try {
      final outcome = await _jobs.exportPdfTask(
        items,
        pdfOptions,
        onProgress: (done, total) {
          if (!_disposed) {
            _exportLabel = '正在生成 PDF（$done/$total）…';
            _notify();
          }
        },
      );
      final name = _timestampName('扫描件', 'pdf');
      final feedback = await _exporter.deliver(
        storage: _storage,
        bytes: outcome.bytes,
        fileName: name,
        mimeType: 'application/pdf',
        destination: destination,
      );
      if (feedback.isNotEmpty) {
        _emitToast(feedback, ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, 'PDF 导出失败，请重试'), ToastKind.error);
    } finally {
      _pinnedSourceUris.removeAll(pinned);
      _exporting = false;
      _exportLabel = '正在导出…';
      _notify();
    }
  }

  Future<void> exportCurrentImage({
    required ExportDestination destination,
  }) async {
    final page = currentPage;
    if (page == null || _exporting) return;
    _pinnedSourceUris.add(page.sourceUri);
    _exporting = true;
    _exportLabel = '正在导出图片…';
    _notify();
    try {
      final outcome = await _jobs.exportImageTask(page, page.options);
      final ext = outcome.format == 'png' ? 'png' : 'jpg';
      final mime = outcome.format == 'png' ? 'image/png' : 'image/jpeg';
      final name = _timestampName('扫描件', ext);
      final feedback = await _exporter.deliver(
        storage: _storage,
        bytes: outcome.bytes,
        fileName: name,
        mimeType: mime,
        destination: destination,
      );
      if (feedback.isNotEmpty) {
        _emitToast(feedback, ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, '图片导出失败，请重试'), ToastKind.error);
    } finally {
      _pinnedSourceUris.remove(page.sourceUri);
      _exporting = false;
      _exportLabel = '正在导出…';
      _notify();
    }
  }

  String _timestampName(String prefix, String ext) {
    final now = DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${prefix}_${now.year}${pad(now.month)}${pad(now.day)}_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}.$ext';
  }

  String _readableError(Object err, String fallback) {
    if (err is StateError) return err.message;
    if (err is ArgumentError && err.message != null) return '${err.message}';
    final text = err.toString();
    if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(text)) {
      return text.replaceFirst(RegExp(r'^(Bad state|Exception|StateError):\s*'), '');
    }
    return fallback;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    if (_persistDirty && _hydrated && _storage.isPersistent) {
      _persistTimer?.cancel();
      _persistDirty = false;
      final snapshot = List<PageItem>.unmodifiable(_state.pages);
      unawaited(_storage.savePages(snapshot).catchError((_) {}));
    } else {
      _persistTimer?.cancel();
    }
    _toastController.close();
    super.dispose();
  }
}
