import 'dart:async';

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

  final Map<String, RenderedPageResult> _renders = <String, RenderedPageResult>{};
  final Map<String, String> _renderErrors = <String, String>{};
  RenderedPageResult? renderOf(String id) => _renders[id];
  String? errorOf(String id) => _renderErrors[id];
  RenderedPageResult? get currentRender =>
      currentPage != null ? _renders[currentPage!.id] : null;
  String? get currentError =>
      currentPage != null ? _renderErrors[currentPage!.id] : null;

  bool _busy = false;
  String _busyLabel = '正在处理…';
  bool get isBusy => _busy;
  String get busyLabel => _busyLabel;

  bool _exporting = false;
  bool get isExporting => _exporting;

  bool get supportsCamera => _acquisition.supportsCamera;

  Map<String, ScanOptions>? _undoSnapshot;
  bool get canUndoBatch => _undoSnapshot != null;

  final StreamController<ToastMessage> _toastController =
      StreamController<ToastMessage>.broadcast();
  Stream<ToastMessage> get toasts => _toastController.stream;

  int _renderSeq = 0;
  Timer? _debounceTimer;
  Timer? _persistTimer;
  bool _disposed = false;

  void _emitToast(String text, [ToastKind kind = ToastKind.info]) {
    if (_disposed || text.trim().isEmpty) return;
    _toastController.add(ToastMessage(text.trim(), kind));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init({List<PageItem>? demoPages}) async {
    try {
      final stored = await _storage.loadPages();
      if (_disposed) return;
      final initial = stored.isNotEmpty ? stored : (demoPages ?? const <PageItem>[]);
      if (initial.isNotEmpty) {
        _state = _state.replaceAll(initial);
        _notify();
        unawaited(_runRender(initial.first));
      }
    } catch (err) {
      _emitToast(_readableError(err, '本地页面读取失败'), ToastKind.error);
    } finally {
      _hydrated = true;
      _notify();
    }
  }

  void _schedulePersist() {
    if (!_hydrated || !_storage.isPersistent) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      _storage.savePages(_state.pages).catchError((Object err) {
        _emitToast(_readableError(err, '保存页面失败'), ToastKind.error);
      });
    });
  }

  Future<void> _runRender(PageItem page) async {
    final seq = ++_renderSeq;
    _busy = true;
    _busyLabel = '正在处理…';
    _notify();
    try {
      final result = await _jobs.renderPageTask(
        page,
        page.options,
        onStage: (stage) {
          if (seq == _renderSeq && !_disposed) {
            _busy = true;
            _busyLabel = '正在$stage…';
            _notify();
          }
        },
        shouldAbort: () => seq != _renderSeq || _disposed,
      );
      if (seq != _renderSeq || _disposed) return;
      _renders[page.id] = result;
      _renderErrors.remove(page.id);
    } catch (err) {
      if (seq != _renderSeq || _disposed) return;
      final msg = _readableError(err, '处理失败，请重试');
      if (msg == kAbortMessage) return;
      _renderErrors[page.id] = msg;
      _emitToast(msg, ToastKind.error);
    } finally {
      if (seq == _renderSeq && !_disposed) {
        _busy = false;
        _busyLabel = '正在处理…';
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
      unawaited(_runRender(page));
    });
  }

  Future<void> takePhoto() async {
    try {
      final picked = await _acquisition.takePhoto();
      if (picked == null) return;
      await importPickedImages(<PickedImageInput>[picked]);
    } catch (err) {
      _emitToast(_readableError(err, '打开相机失败，请重试'), ToastKind.error);
    }
  }

  Future<void> pickFromGallery() async {
    try {
      final picked = await _acquisition.pickFromGallery();
      if (picked.isEmpty) return;
      await importPickedImages(picked);
    } catch (err) {
      _emitToast(_readableError(err, '打开相册失败，请重试'), ToastKind.error);
    }
  }

  Future<void> loadDemoPages([int count = 2]) async {
    if (_busy) return;
    _busy = true;
    _busyLabel = '正在生成示例文档…';
    _notify();
    try {
      final demos = await generateDemoDocuments(count);
      await importPickedImages(demos);
    } catch (err) {
      _emitToast(_readableError(err, '示例文档生成失败'), ToastKind.error);
    } finally {
      if (!_disposed && _busyLabel == '正在生成示例文档…') {
        _busy = false;
        _notify();
      }
    }
  }

  Future<void> importPickedImages(List<PickedImageInput> inputs) async {
    if (inputs.isEmpty) return;
    final added = <PageItem>[];
    for (final input in inputs) {
      try {
        if (input.bytes.length > 60 * 1024 * 1024) {
          _emitToast('「${input.name}」超过 60MB，请压缩后再试', ToastKind.warn);
          continue;
        }
        final size = await probeImageSize(input.bytes);
        final pageId = createPageId();
        final sourceUri = await _storage.saveSourceBytes(
          input.bytes,
          pageId,
          input.name,
        );
        final page = createPage(
          id: pageId,
          name: input.name.isNotEmpty
              ? input.name
              : '扫描页_${_state.pages.length + 1}',
          sourceUri: sourceUri,
          sourceW: size?.width ?? 1200,
          sourceH: size?.height ?? 1600,
          options: ScanOptions.defaults,
        );
        added.add(page);
        _state = _state.addPage(page);
      } catch (err) {
        _emitToast(_readableError(err, '导入失败，请重试'), ToastKind.error);
      }
    }
    if (added.isNotEmpty) {
      _schedulePersist();
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
    _state = _state.selectIndex(index);
    _notify();
    final page = _state.currentPage;
    if (page != null && !_renders.containsKey(page.id)) {
      unawaited(_runRender(page));
    }
  }

  void removePage(PageItem page) {
    final index = _state.pages.indexWhere((p) => p.id == page.id);
    if (index < 0) return;
    final wasCurrent = currentPage?.id == page.id;
    _renders.remove(page.id);
    _renderErrors.remove(page.id);
    _state = _state.removePage(page.id);
    _schedulePersist();
    _notify();
    unawaited(_storage.deleteSource(page.sourceUri));
    _emitToast('已删除这一页', ToastKind.info);
    if (wasCurrent && _state.currentPage != null && !_renders.containsKey(_state.currentPage!.id)) {
      _scheduleRender(_state.currentPage!);
    }
  }

  void rotatePage(PageItem page) {
    _state = _state.rotatePage(page.id);
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
    _undoSnapshot = <String, ScanOptions>{
      for (final p in _state.pages) p.id: p.options,
    };
    final patch = page.options.toStylePatch();
    _renders.clear();
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
    _state = _state.restoreOptions(snapshot);
    _undoSnapshot = null;
    _renders.clear();
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
    final items = allPages ? _state.pages : <PageItem>[page];
    _exporting = true;
    _busy = true;
    _busyLabel = '正在生成 PDF…';
    _notify();
    try {
      final outcome = await _jobs.exportPdfTask(
        items,
        pdfOptions,
        onProgress: (done, total) {
          if (!_disposed) {
            _busyLabel = '正在生成 PDF（$done/$total）…';
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
      _exporting = false;
      _busy = false;
      _busyLabel = '正在处理…';
      _notify();
    }
  }

  Future<void> exportCurrentImage({
    required ExportDestination destination,
  }) async {
    final page = currentPage;
    if (page == null || _exporting) return;
    _exporting = true;
    _busy = true;
    _busyLabel = '正在导出图片…';
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
      _exporting = false;
      _busy = false;
      _busyLabel = '正在处理…';
      _notify();
    }
  }

  String _timestampName(String prefix, String ext) {
    final now = DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${prefix}_${now.year}${pad(now.month)}${pad(now.day)}_${pad(now.hour)}${pad(now.minute)}.$ext';
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
    _persistTimer?.cancel();
    _toastController.close();
    super.dispose();
  }
}
