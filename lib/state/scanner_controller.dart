import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/detect.dart';
import '../engine/options.dart';
import '../engine/pdf.dart';
import '../io/app_storage.dart';
import '../io/file_export.dart';
import '../io/image_acquisition.dart';
import '../io/ocr_service.dart';
import '../io/pdf_import.dart';
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

class _HistoryEntry {
  const _HistoryEntry({
    required this.docId,
    required this.state,
  });

  final String docId;
  final PagesState state;
}

class ScannerController extends ChangeNotifier {
  ScannerController({
    AppStorage? storage,
    RenderJobs? jobs,
    ImageAcquisition? acquisition,
    FileExporter? exporter,
    OcrService? ocr,
  })  : _storage = storage ?? createAppStorage(),
        _acquisition = acquisition ?? ImageAcquisition(),
        _exporter = exporter ?? const FileExporter(),
        _ocr = ocr ?? OcrService() {
    _jobs = jobs ?? RenderJobs(storage: _storage);
  }

  static const int _maxMemoryRenders = 12;
  static const int _maxMemoryRenderBytes = 32 * 1024 * 1024;
  static const int _maxHistoryEntries = 30;

  final AppStorage _storage;
  late final RenderJobs _jobs;
  final ImageAcquisition _acquisition;
  final FileExporter _exporter;
  final OcrService _ocr;

  DocumentLibrary _library = _createInitialLibrary();
  AppPreferences _preferences = const AppPreferences();
  List<CustomPreset> _customPresets = const <CustomPreset>[];
  List<SavedSignature> _signatures = const <SavedSignature>[];

  static DocumentLibrary _createInitialLibrary() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final doc = ScanDocument(
      id: 'doc_default',
      title: '默认文档',
      folder: '默认',
      createdAt: now,
      updatedAt: now,
    );
    return DocumentLibrary(documents: <ScanDocument>[doc], activeId: doc.id);
  }

  DocumentLibrary get library => _library;
  List<ScanDocument> get documents => _library.documents;
  ScanDocument get currentDocument => _library.activeDocument;
  List<String> get folders => _library.allFolders;
  AppPreferences get preferences => _preferences;
  List<CustomPreset> get customPresets => _customPresets;
  List<SavedSignature> get signatures => _signatures;

  PagesState get _state {
    final doc = currentDocument;
    return PagesState(pages: doc.pages, currentIndex: doc.currentIndex);
  }

  set _state(PagesState next) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final activeId = currentDocument.id;
    final nextDocs = _library.documents
        .map(
          (d) => d.id == activeId
              ? d.copyWith(
                  pages: next.pages,
                  currentIndex: next.currentIndex,
                  updatedAt: now,
                )
              : d,
        )
        .toList(growable: false);
    _library = DocumentLibrary(
      documents: List<ScanDocument>.unmodifiable(nextDocs),
      activeId: activeId,
      customFolders: _library.customFolders,
    );
  }

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
  final Set<String> _pendingDeleteSourceUris = <String>{};
  final Map<String, Uint8List> _signatureCache = <String, Uint8List>{};

  RenderedPageResult? renderOf(String id) {
    final hit = _renders[id];
    if (hit != null) {
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
  bool _batchWorking = false;
  String _batchLabel = '正在处理…';

  bool get isBusy => _rendering || _generatingDemo || _exporting || _batchWorking;
  bool get isExporting => _exporting;
  String get busyLabel {
    if (_exporting) return _exportLabel;
    if (_batchWorking) return _batchLabel;
    if (_generatingDemo) return '正在生成示例文档…';
    return _renderLabel;
  }

  bool get supportsCamera => _acquisition.supportsCamera;

  Map<String, Map<String, Object?>>? _undoSnapshot;
  bool get canUndoBatch => _undoSnapshot != null;

  final List<_HistoryEntry> _undoStack = <_HistoryEntry>[];
  final List<_HistoryEntry> _redoStack = <_HistoryEntry>[];
  int _lastSliderHistoryMs = 0;
  String? _lastSliderHistoryPageId;

  bool get canUndo => _undoStack.any((e) => e.docId == currentDocument.id);
  bool get canRedo => _redoStack.any((e) => e.docId == currentDocument.id);

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

  void _pushHistory({bool coalesceSlider = false, String? pageId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (coalesceSlider &&
        pageId != null &&
        _lastSliderHistoryPageId == pageId &&
        now - _lastSliderHistoryMs < 750 &&
        _undoStack.isNotEmpty) {
      _lastSliderHistoryMs = now;
      return;
    }
    if (coalesceSlider) {
      _lastSliderHistoryMs = now;
      _lastSliderHistoryPageId = pageId;
    } else {
      _lastSliderHistoryMs = 0;
      _lastSliderHistoryPageId = null;
    }

    _undoStack.add(_HistoryEntry(docId: currentDocument.id, state: _state));
    if (_undoStack.length > _maxHistoryEntries) {
      _undoStack.removeAt(0);
    }
    _redoStack.removeWhere((e) => e.docId == currentDocument.id);
    _gcPendingDeletes();
  }

  bool _isSourceReferenced(String uri) {
    for (final doc in _library.documents) {
      if (doc.pages.any((p) => p.sourceUri == uri)) return true;
    }
    for (final h in _undoStack) {
      if (h.state.pages.any((p) => p.sourceUri == uri)) return true;
    }
    for (final h in _redoStack) {
      if (h.state.pages.any((p) => p.sourceUri == uri)) return true;
    }
    return false;
  }

  void _gcPendingDeletes() {
    if (_pendingDeleteSourceUris.isEmpty) return;
    final victims = _pendingDeleteSourceUris
        .where((uri) => !_isSourceReferenced(uri) && !_pinnedSourceUris.contains(uri))
        .toList(growable: false);
    for (final uri in victims) {
      _pendingDeleteSourceUris.remove(uri);
      unawaited(_storage.deleteSource(uri));
    }
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
      final results = await Future.wait<Object?>([
        _storage.loadLibrary(),
        _storage.loadPreferences(),
        _storage.loadCustomPresets(),
        _storage.loadSignatures(),
      ]);
      if (_disposed) return;

      final loadedLib = results[0] as DocumentLibrary?;
      _preferences = results[1] as AppPreferences;
      _customPresets = results[2] as List<CustomPreset>;
      _signatures = results[3] as List<SavedSignature>;

      for (final sig in _signatures) {
        final bytes = await _storage.readSignatureBytes(sig.uri);
        if (bytes != null) _signatureCache[sig.id] = bytes;
      }

      List<PickedImageEntry> lost = const <PickedImageEntry>[];
      try {
        lost = await _acquisition.retrieveLostEntries();
      } catch (err) {
        _emitToast(_readableError(err, '恢复上次选图失败，请重试'), ToastKind.error);
      }
      if (_disposed) return;

      if (loadedLib != null && loadedLib.documents.isNotEmpty) {
        _library = loadedLib;
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
      _storage.saveLibrary(_library).catchError((Object err) {
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
    final snapshot = _library;
    try {
      await _storage.saveLibrary(snapshot);
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
        signatures: _signatures,
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

  double _quadAreaNorm(List<CornerPoint> pts) {
    if (pts.length != 4) return 1.0;
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2.0;
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

  Future<void> pickAndImportPdfs() async {
    if (isBusy) return;
    try {
      final paths = await _acquisition.pickPdfFilePaths();
      if (paths.isEmpty) return;
      await importPdfPaths(paths);
    } catch (err) {
      _emitToast(_readableError(err, '导入 PDF 失败，请重试'), ToastKind.error);
    }
  }

  Future<void> importPdfPaths(List<String> pdfPaths) async {
    if (pdfPaths.isEmpty || _exporting) return;
    _batchWorking = true;
    _batchLabel = '正在解析 PDF 页面…';
    _notify();
    try {
      final allEntries = <PickedImageEntry>[];
      for (final path in pdfPaths) {
        final entries = await PdfImportService.renderPdfToEntries(
          path,
          onProgress: (done, total) {
            if (!_disposed) {
              _batchLabel = '正在导入 PDF（$done/$total 页）…';
              _notify();
            }
          },
        );
        allEntries.addAll(entries);
      }
      _batchWorking = false;
      if (allEntries.isNotEmpty) {
        await importPickedEntries(allEntries, skipAutoDetect: true);
        _emitToast('已从 PDF 导入 ${allEntries.length} 页', ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, 'PDF 解析导入失败'), ToastKind.error);
    } finally {
      if (!_disposed) {
        _batchWorking = false;
        _batchLabel = '正在处理…';
        _notify();
      }
    }
  }

  Future<void> importDroppedPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final split = _acquisition.classifyFilePaths(paths);
    if (split.images.isEmpty && split.pdfPaths.isEmpty) {
      _emitToast('仅支持拖拽图片或 PDF 文件', ToastKind.warn);
      return;
    }
    if (split.images.isNotEmpty) {
      await importPickedEntries(split.images);
    }
    if (split.pdfPaths.isNotEmpty) {
      await importPdfPaths(split.pdfPaths);
    }
  }

  Future<void> pasteFromClipboard() async {
    final res = await _acquisition.readFromClipboard();
    if (res.images.isEmpty && res.pdfPaths.isEmpty) {
      _emitToast('剪贴板中没有可用的图片或文件', ToastKind.info);
      return;
    }
    if (res.images.isNotEmpty) {
      await importPickedEntries(res.images);
    }
    if (res.pdfPaths.isNotEmpty) {
      await importPdfPaths(res.pdfPaths);
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

  Future<void> importPickedImages(
    List<PickedImageInput> inputs, {
    bool skipAutoDetect = false,
  }) {
    if (inputs.isEmpty) return Future<void>.value();
    return importPickedEntries(
      inputs.map(PickedImageEntry.fromInput).toList(growable: false),
      skipAutoDetect: skipAutoDetect,
    );
  }

  Future<void> importPickedEntries(
    List<PickedImageEntry> entries, {
    bool skipAutoDetect = false,
  }) async {
    if (entries.isEmpty) return;
    if (_initFuture != null && !_hydrated) {
      await _initFuture;
    }
    if (_disposed) return;
    await _importEntriesInternal(
      entries,
      persistImmediately: true,
      skipAutoDetect: skipAutoDetect,
    );
  }

  Future<void> _importEntriesInternal(
    List<PickedImageEntry> entries, {
    required bool persistImmediately,
    bool skipAutoDetect = false,
  }) async {
    final added = <PageItem>[];
    var autoCroppedCount = 0;
    final hadHistorySnapshot = _hydrated;
    final beforeState = _state;

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
        var page = createPage(
          id: pageId,
          name: entry.name.isNotEmpty
              ? entry.name
              : '扫描页_${_state.pages.length + 1}',
          sourceUri: sourceUri,
          sourceW: size.width,
          sourceH: size.height,
          options: ScanOptions.defaults,
        );

        // 导入后自动检测纸张边缘（仅高置信度且存在有效裁边余量时自动启用）
        if (!skipAutoDetect &&
            _preferences.autoDetectOnImport &&
            math.max(size.width, size.height) >= 400) {
          try {
            final detected = await _jobs.detectCornersTask(page);
            final area = _quadAreaNorm(detected.corners);
            if (detected.confidence >= 0.42 && area >= 0.12 && area < 0.95) {
              page = page.copyWith(
                options: page.options.copyWith(corners: detected.corners),
              );
              autoCroppedCount++;
            }
          } catch (_) {
            // 自动检测异常不影响正常导入
          }
        }

        added.add(page);
        _state = _state.addPage(page);
      } catch (err) {
        _emitToast(_readableError(err, '导入失败，请重试'), ToastKind.error);
      }
    }

    if (added.isNotEmpty && !_disposed) {
      if (hadHistorySnapshot) {
        _undoStack.add(_HistoryEntry(docId: currentDocument.id, state: beforeState));
        if (_undoStack.length > _maxHistoryEntries) _undoStack.removeAt(0);
        _redoStack.removeWhere((e) => e.docId == currentDocument.id);
      }
      if (persistImmediately) {
        _schedulePersist();
      } else {
        _persistDirty = true;
      }
      _notify();
      await _runRender(added.last);
      if (added.length > 1) {
        final extra = autoCroppedCount > 0 ? '（自动裁边 $autoCroppedCount 页）' : '';
        _emitToast('已导入 ${added.length} 张图片$extra', ToastKind.success);
      } else if (autoCroppedCount > 0) {
        _emitToast('已自动识别并校正纸张边缘', ToastKind.success);
      }
    }
  }

  Future<void> importComposedCardPage({
    required Uint8List jpegBytes,
    required String name,
  }) async {
    if (jpegBytes.isEmpty) return;
    _pushHistory();
    final size = await probeImageSize(jpegBytes);
    final pageId = createPageId();
    final uri = await _storage.saveSourceBytes(jpegBytes, pageId, name);
    final page = createPage(
      id: pageId,
      name: name,
      sourceUri: uri,
      sourceW: size?.width ?? 1654,
      sourceH: size?.height ?? 2339,
      options: const ScanOptions(
        mode: ScanMode.color,
        shadow: 0,
        contrast: 50,
        sharpen: 10,
        denoise: 0,
      ),
    );
    _state = _state.addPage(page);
    _schedulePersist();
    _notify();
    await _runRender(page);
    _emitToast('已生成拼版页并添加到当前文档', ToastKind.success);
  }

  Future<Uint8List> readSourceBytes(PageItem page) {
    return _storage.readSourceBytes(page.sourceUri);
  }

  Future<Uint8List?> readSignatureBytes(String signatureId) async {
    final cached = _signatureCache[signatureId];
    if (cached != null) return cached;
    for (final s in _signatures) {
      if (s.id == signatureId) {
        final bytes = await _storage.readSignatureBytes(s.uri);
        if (bytes != null) _signatureCache[s.id] = bytes;
        return bytes;
      }
    }
    return null;
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
    _pushHistory();
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
    _pendingDeleteSourceUris.add(page.sourceUri);
    _gcPendingDeletes();
    _schedulePersist();
    _notify();
    _emitToast('已删除这一页（可撤销）', ToastKind.info);
    if (wasCurrent &&
        _state.currentPage != null &&
        (!_renders.containsKey(_state.currentPage!.id) ||
            _stalePages.contains(_state.currentPage!.id))) {
      _scheduleRender(_state.currentPage!);
    }
  }

  void clearCurrentDocumentPages() {
    if (_state.pages.isEmpty || _exporting) return;
    _pushHistory();
    _debounceTimer?.cancel();
    _renderSeq++;
    _rendering = false;
    for (final p in _state.pages) {
      _renders.remove(p.id);
      _thumbnails.remove(p.id);
      _renderErrors.remove(p.id);
      _stalePages.remove(p.id);
      _pendingDeleteSourceUris.add(p.sourceUri);
    }
    _state = PagesState.empty;
    _gcPendingDeletes();
    _schedulePersist();
    _notify();
    _emitToast('已清空当前文档全部页面（可撤销）', ToastKind.info);
  }

  void rotatePage(PageItem page) {
    _pushHistory();
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
    _pushHistory();
    _state = _state.movePage(index, index + offset);
    _schedulePersist();
    _notify();
  }

  void reorderPage(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _state.pages.length) return;
    _pushHistory();
    _state = _state.movePage(oldIndex, newIndex);
    _schedulePersist();
    _notify();
  }

  void applyOptions(Map<String, Object?> patch, {bool immediate = false}) {
    final page = currentPage;
    if (page == null) return;
    _pushHistory(coalesceSlider: !immediate, pageId: page.id);
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
    _pushHistory();
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
    _pushHistory();
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

  void undo() {
    final docId = currentDocument.id;
    final idx = _undoStack.lastIndexWhere((e) => e.docId == docId);
    if (idx < 0) return;
    final entry = _undoStack.removeAt(idx);
    _redoStack.add(_HistoryEntry(docId: docId, state: _state));
    _debounceTimer?.cancel();
    _renderSeq++;
    _rendering = false;
    _state = entry.state;
    _renders.clear();
    _stalePages.addAll(_state.pages.map((p) => p.id));
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('已撤销上一步操作', ToastKind.info);
  }

  void redo() {
    final docId = currentDocument.id;
    final idx = _redoStack.lastIndexWhere((e) => e.docId == docId);
    if (idx < 0) return;
    final entry = _redoStack.removeAt(idx);
    _undoStack.add(_HistoryEntry(docId: docId, state: _state));
    _debounceTimer?.cancel();
    _renderSeq++;
    _rendering = false;
    _state = entry.state;
    _renders.clear();
    _stalePages.addAll(_state.pages.map((p) => p.id));
    _schedulePersist();
    _notify();
    if (_state.currentPage != null) {
      _scheduleRender(_state.currentPage!);
    }
    _emitToast('已重做', ToastKind.info);
  }

  Future<DetectCornersResult> autoDetectCorners(PageItem page) {
    return _jobs.detectCornersTask(page);
  }

  Future<void> autoDetectAllCorners() async {
    if (_state.pages.isEmpty || _exporting || _batchWorking) return;
    _pushHistory();
    _batchWorking = true;
    _batchLabel = '正在批量识别边缘…';
    _notify();
    var updated = 0;
    try {
      final list = List<PageItem>.of(_state.pages);
      for (var i = 0; i < list.length; i++) {
        _batchLabel = '正在自动裁边（${i + 1}/${list.length}）…';
        _notify();
        final page = list[i];
        try {
          final detected = await _jobs.detectCornersTask(page);
          final area = _quadAreaNorm(detected.corners);
          if (detected.confidence >= 0.35 && area >= 0.08 && area < 0.97) {
            list[i] = page.copyWith(
              options: page.options.copyWith(corners: detected.corners),
            );
            _stalePages.add(page.id);
            _renders.remove(page.id);
            _thumbnails.remove(page.id);
            updated++;
          }
        } catch (_) {}
      }
      _state = _state.replaceAll(list, currentIndex: _state.currentIndex);
      _schedulePersist();
      _emitToast(
        updated > 0 ? '已自动校正 $updated 页纸张边缘' : '未检测到需要裁剪的边缘',
        updated > 0 ? ToastKind.success : ToastKind.info,
      );
    } finally {
      _batchWorking = false;
      _batchLabel = '正在处理…';
      _notify();
      if (_state.currentPage != null) {
        unawaited(_runRender(_state.currentPage!));
      }
    }
  }

  void applyCorners(List<CornerPoint> corners) {
    final page = currentPage;
    if (page == null) return;
    _pushHistory();
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

  void updatePageAnnotations(String pageId, PageAnnotations next) {
    final page = _state.pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null) return;
    _pushHistory();
    _state = _state.updatePage(pageId, (p) => p.copyWith(annotations: next));
    _stalePages.add(pageId);
    _renders.remove(pageId);
    _thumbnails.remove(pageId);
    _schedulePersist();
    _notify();
    final updated = _state.pages.where((p) => p.id == pageId).firstOrNull;
    if (updated != null && currentPage?.id == pageId) {
      _scheduleRender(updated);
    }
    _emitToast('已保存页面批注', ToastKind.success);
  }

  Future<SavedSignature> saveNewSignature({
    required String name,
    required Uint8List pngBytes,
    required int width,
    required int height,
  }) async {
    final id = createEntityId('sig');
    final uri = await _storage.saveSignatureBytes(pngBytes, id);
    final item = SavedSignature(
      id: id,
      name: name.trim().isEmpty ? '我的签名' : name.trim(),
      uri: uri,
      width: width,
      height: height,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _signatureCache[id] = pngBytes;
    _signatures = List<SavedSignature>.unmodifiable(<SavedSignature>[..._signatures, item]);
    await _storage.saveSignatures(_signatures);
    _notify();
    _emitToast('已保存签名「${item.name}」', ToastKind.success);
    return item;
  }

  Future<void> deleteSignature(String id) async {
    final target = _signatures.where((s) => s.id == id).firstOrNull;
    if (target == null) return;
    _signatures = List<SavedSignature>.unmodifiable(
      _signatures.where((s) => s.id != id),
    );
    _signatureCache.remove(id);
    await _storage.deleteSignatureBytes(target.uri);
    await _storage.saveSignatures(_signatures);
    _notify();
    _emitToast('已删除签名', ToastKind.info);
  }

  Future<double> detectBookGutter(PageItem page) {
    return _jobs.detectBookGutterTask(page);
  }

  Future<void> splitDoublePage(
    PageItem page,
    double splitX, {
    required bool keepOriginal,
  }) async {
    if (_exporting || _batchWorking) return;
    _pushHistory();
    _batchWorking = true;
    _batchLabel = '正在拆分双页…';
    _notify();
    try {
      final split = await _jobs.splitDoublePageTask(page, splitX);
      final leftId = createPageId();
      final rightId = createPageId();
      final baseName = page.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final leftUri = await _storage.saveSourceBytes(
        split.leftBytes,
        leftId,
        '${baseName}_左页.jpg',
      );
      final rightUri = await _storage.saveSourceBytes(
        split.rightBytes,
        rightId,
        '${baseName}_右页.jpg',
      );
      final cleanOpts = page.options.copyWith(clearCorners: true, rotate: 0);
      final leftPage = createPage(
        id: leftId,
        name: '${baseName}_左页',
        sourceUri: leftUri,
        sourceW: split.leftW,
        sourceH: split.leftH,
        options: cleanOpts,
      );
      final rightPage = createPage(
        id: rightId,
        name: '${baseName}_右页',
        sourceUri: rightUri,
        sourceW: split.rightW,
        sourceH: split.rightH,
        options: cleanOpts,
      );
      if (!keepOriginal) {
        _renders.remove(page.id);
        _thumbnails.remove(page.id);
        _pendingDeleteSourceUris.add(page.sourceUri);
      }
      _state = _state.replacePageWithMultiple(
        page.id,
        <PageItem>[leftPage, rightPage],
        keepOriginal: keepOriginal,
      );
      _gcPendingDeletes();
      _schedulePersist();
      _emitToast('已拆分为左右两页', ToastKind.success);
    } catch (err) {
      _emitToast(_readableError(err, '双页拆分失败'), ToastKind.error);
    } finally {
      _batchWorking = false;
      _batchLabel = '正在处理…';
      _notify();
      if (_state.currentPage != null) {
        unawaited(_runRender(_state.currentPage!));
      }
    }
  }

  Future<OcrPageResult?> recognizePageOcr(PageItem page) async {
    if (_exporting || _batchWorking) return null;
    _batchWorking = true;
    _batchLabel = '正在离线识别文字…';
    _notify();
    try {
      final rendered = await _jobs.renderPageTask(
        page,
        page.options,
        signatures: _signatures,
      );
      final ocrRes = await _ocr.recognizeImage(
        imageBytes: rendered.bytes,
        width: rendered.width,
        height: rendered.height,
      );
      _state = _state.updatePage(page.id, (p) => p.copyWith(ocr: ocrRes));
      _schedulePersist();
      _notify();
      return ocrRes;
    } catch (err) {
      _emitToast(_readableError(err, '离线文字识别失败'), ToastKind.error);
      return null;
    } finally {
      if (!_disposed) {
        _batchWorking = false;
        _batchLabel = '正在处理…';
        _notify();
      }
    }
  }

  Future<void> recognizeAllPagesOcr() async {
    if (_state.pages.isEmpty || _exporting || _batchWorking) return;
    _batchWorking = true;
    _batchLabel = '正在识别全部页面文字…';
    _notify();
    try {
      final list = List<PageItem>.of(_state.pages);
      for (var i = 0; i < list.length; i++) {
        _batchLabel = '正在识别文字（${i + 1}/${list.length}）…';
        _notify();
        final p = list[i];
        final rendered = await _jobs.renderPageTask(
          p,
          p.options,
          signatures: _signatures,
        );
        final ocrRes = await _ocr.recognizeImage(
          imageBytes: rendered.bytes,
          width: rendered.width,
          height: rendered.height,
        );
        list[i] = p.copyWith(ocr: ocrRes);
      }
      _state = _state.replaceAll(list, currentIndex: _state.currentIndex);
      _schedulePersist();
      _emitToast('已完成全部 ${list.length} 页文字识别', ToastKind.success);
    } catch (err) {
      _emitToast(_readableError(err, '批量文字识别失败'), ToastKind.error);
    } finally {
      if (!_disposed) {
        _batchWorking = false;
        _batchLabel = '正在处理…';
        _notify();
      }
    }
  }

  void updatePageOcrText(String pageId, String editedText) {
    final page = _state.pages.where((p) => p.id == pageId).firstOrNull;
    if (page == null) return;
    final clean = editedText.trim();
    final existing = page.ocr;
    final nextLines = <PdfOcrLine>[];
    if (clean.isNotEmpty) {
      final rawLines = clean.split(RegExp(r'\r?\n'));
      for (var i = 0; i < rawLines.length; i++) {
        final lineStr = rawLines[i].trim();
        if (lineStr.isEmpty) continue;
        if (existing != null && i < existing.lines.length) {
          final orig = existing.lines[i];
          nextLines.add(PdfOcrLine(
            text: lineStr,
            left: orig.left,
            top: orig.top,
            right: orig.right,
            bottom: orig.bottom,
          ));
        } else {
          final top = (0.06 + (i * 0.04)).clamp(0.02, 0.90);
          nextLines.add(PdfOcrLine(
            text: lineStr,
            left: 0.06,
            top: top,
            right: 0.94,
            bottom: (top + 0.032).clamp(0.04, 0.96),
          ));
        }
      }
    }
    _state = _state.updatePage(
      pageId,
      (p) => p.copyWith(
        ocr: OcrPageResult(
          text: clean,
          lines: List<PdfOcrLine>.unmodifiable(nextLines),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
    _schedulePersist();
    _notify();
  }

  Future<void> exportOcrText({
    required bool allPages,
    required ExportDestination destination,
    String? baseName,
  }) async {
    final page = currentPage;
    if (page == null || _exporting) return;
    final targets = allPages ? _state.pages : <PageItem>[page];
    final buf = StringBuffer();
    for (var i = 0; i < targets.length; i++) {
      final text = targets[i].ocr?.text.trim() ?? '';
      if (allPages) {
        buf.writeln('=== 第 ${i + 1} 页 ===');
      }
      buf.writeln(text);
      if (allPages && i < targets.length - 1) buf.writeln();
    }
    final payload = buf.toString().trim();
    if (payload.isEmpty) {
      _emitToast('暂无识别文字可导出，请先运行文字识别', ToastKind.warn);
      return;
    }
    _exporting = true;
    _exportLabel = '正在导出 TXT…';
    _notify();
    try {
      final bytes = Uint8List.fromList(utf8.encode(payload));
      final name = _buildFileName(baseName ?? currentDocument.title, 'txt');
      final feedback = await _exporter.deliver(
        storage: _storage,
        bytes: bytes,
        fileName: name,
        mimeType: 'text/plain',
        destination: destination,
      );
      if (feedback.isNotEmpty) {
        _emitToast(feedback, ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, 'TXT 导出失败'), ToastKind.error);
    } finally {
      _exporting = false;
      _exportLabel = '正在导出…';
      _notify();
    }
  }

  // --- 文档库与偏好管理 ---

  Future<void> switchDocument(String docId) async {
    if (docId == currentDocument.id || _exporting || _batchWorking) return;
    if (!_library.documents.any((d) => d.id == docId)) return;
    _debounceTimer?.cancel();
    _renderSeq++;
    _rendering = false;
    _undoSnapshot = null;
    _renders.clear();
    _thumbnails.clear();
    _renderErrors.clear();
    _stalePages.clear();
    _library = DocumentLibrary(
      documents: _library.documents,
      activeId: docId,
      customFolders: _library.customFolders,
    );
    _schedulePersist();
    _notify();
    if (currentPage != null) {
      unawaited(_runRender(currentPage!));
    }
  }

  Future<void> createDocument({String? title, String folder = '默认'}) async {
    if (_exporting || _batchWorking) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final count = _library.documents.length + 1;
    final cleanTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : '扫描文档 $count';
    final cleanFolder = folder.trim().isNotEmpty ? folder.trim() : '默认';
    final doc = ScanDocument(
      id: createEntityId('doc'),
      title: cleanTitle,
      folder: cleanFolder,
      createdAt: now,
      updatedAt: now,
    );
    _debounceTimer?.cancel();
    _renderSeq++;
    _rendering = false;
    _undoSnapshot = null;
    _renders.clear();
    _thumbnails.clear();
    _renderErrors.clear();
    _stalePages.clear();
    _library = DocumentLibrary(
      documents: List<ScanDocument>.unmodifiable(<ScanDocument>[doc, ..._library.documents]),
      activeId: doc.id,
      customFolders: _library.customFolders,
    );
    _schedulePersist();
    _notify();
    _emitToast('已新建「$cleanTitle」', ToastKind.success);
  }

  void renameDocument(String docId, String newTitle, {String? folder}) {
    final clean = newTitle.trim();
    if (clean.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextDocs = _library.documents
        .map(
          (d) => d.id == docId
              ? d.copyWith(
                  title: clean,
                  folder: folder?.trim().isNotEmpty == true ? folder!.trim() : d.folder,
                  updatedAt: now,
                )
              : d,
        )
        .toList(growable: false);
    _library = DocumentLibrary(
      documents: List<ScanDocument>.unmodifiable(nextDocs),
      activeId: _library.activeId,
      customFolders: _library.customFolders,
    );
    _schedulePersist();
    _notify();
  }

  void addCustomFolder(String folderName) {
    final clean = folderName.trim();
    if (clean.isEmpty || folders.contains(clean)) return;
    _library = DocumentLibrary(
      documents: _library.documents,
      activeId: _library.activeId,
      customFolders: List<String>.unmodifiable(<String>[..._library.customFolders, clean]),
    );
    _schedulePersist();
    _notify();
  }

  void deleteDocument(String docId) {
    if (_exporting) {
      _emitToast('正在导出，请稍后再删除文档', ToastKind.warn);
      return;
    }
    final target = _library.documents.where((d) => d.id == docId).firstOrNull;
    if (target == null) return;
    for (final p in target.pages) {
      _pendingDeleteSourceUris.add(p.sourceUri);
    }
    _undoStack.removeWhere((e) => e.docId == docId);
    _redoStack.removeWhere((e) => e.docId == docId);

    final remaining = _library.documents.where((d) => d.id != docId).toList();
    if (remaining.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      remaining.add(
        ScanDocument(
          id: createEntityId('doc'),
          title: '默认文档',
          folder: '默认',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final wasActive = docId == currentDocument.id;
    final nextActive = wasActive ? remaining.first.id : _library.activeId;
    _library = DocumentLibrary(
      documents: List<ScanDocument>.unmodifiable(remaining),
      activeId: nextActive,
      customFolders: _library.customFolders,
    );
    if (wasActive) {
      _debounceTimer?.cancel();
      _renderSeq++;
      _rendering = false;
      _renders.clear();
      _thumbnails.clear();
      _renderErrors.clear();
      _stalePages.clear();
    }
    _gcPendingDeletes();
    _schedulePersist();
    _notify();
    if (wasActive && currentPage != null) {
      unawaited(_runRender(currentPage!));
    }
    _emitToast('已删除文档「${target.title}」', ToastKind.info);
  }

  void mergeDocumentIntoCurrent(String sourceDocId) {
    if (sourceDocId == currentDocument.id) return;
    final sourceDoc = _library.documents.where((d) => d.id == sourceDocId).firstOrNull;
    if (sourceDoc == null || sourceDoc.pages.isEmpty) return;
    _pushHistory();
    final cloned = sourceDoc.pages
        .map((p) => p.copyWith(id: createPageId()))
        .toList(growable: false);
    final merged = <PageItem>[..._state.pages, ...cloned];
    _state = _state.replaceAll(merged, currentIndex: _state.currentIndex);
    _schedulePersist();
    _notify();
    _emitToast('已合并「${sourceDoc.title}」的 ${cloned.length} 页', ToastKind.success);
  }

  Future<void> updatePreferences(AppPreferences next) async {
    _preferences = next;
    _notify();
    try {
      await _storage.savePreferences(next);
    } catch (_) {}
  }

  Future<void> saveCurrentAsPreset(String name) async {
    final page = currentPage;
    final clean = name.trim();
    if (page == null || clean.isEmpty) return;
    final preset = CustomPreset(
      id: createEntityId('preset'),
      name: clean,
      patch: page.options.toStylePatch(),
    );
    _customPresets = List<CustomPreset>.unmodifiable(<CustomPreset>[..._customPresets, preset]);
    await _storage.saveCustomPresets(_customPresets);
    _notify();
    _emitToast('已保存预设「$clean」', ToastKind.success);
  }

  Future<void> deleteCustomPreset(String id) async {
    _customPresets = List<CustomPreset>.unmodifiable(
      _customPresets.where((p) => p.id != id),
    );
    await _storage.saveCustomPresets(_customPresets);
    _notify();
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
    String? customFileName,
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
      final docTitle = (pdfOptions.title?.trim().isNotEmpty == true)
          ? pdfOptions.title!.trim()
          : currentDocument.title;
      final effectivePdfOpts = pdfOptions.copyWith(title: docTitle);
      final outcome = await _jobs.exportPdfTask(
        items,
        effectivePdfOpts,
        signatures: _signatures,
        onProgress: (done, total) {
          if (!_disposed) {
            _exportLabel = '正在生成 PDF（$done/$total）…';
            _notify();
          }
        },
      );
      final name = _buildFileName(customFileName ?? docTitle, 'pdf');
      final feedback = await _exporter.deliver(
        storage: _storage,
        bytes: outcome.bytes,
        fileName: name,
        mimeType: 'application/pdf',
        destination: destination,
      );
      if (feedback.isNotEmpty) {
        final kb = (outcome.bytes.length / 1024).round();
        final sizeLabel = kb >= 1024
            ? '${(kb / 1024).toStringAsFixed(1)} MB'
            : '$kb KB';
        _emitToast('$feedback（$sizeLabel）', ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, 'PDF 导出失败，请重试'), ToastKind.error);
    } finally {
      _pinnedSourceUris.removeAll(pinned);
      _exporting = false;
      _exportLabel = '正在导出…';
      _gcPendingDeletes();
      _notify();
    }
  }

  Future<void> exportCurrentImage({
    required ExportDestination destination,
    String? customFileName,
    String? watermarkText,
    double watermarkOpacity = 0.20,
    double quality = 0.92,
  }) async {
    final page = currentPage;
    if (page == null || _exporting) return;
    _pinnedSourceUris.add(page.sourceUri);
    _exporting = true;
    _exportLabel = '正在导出图片…';
    _notify();
    try {
      final outcome = await _jobs.exportImageTask(
        page,
        page.options,
        signatures: _signatures,
        watermarkText: watermarkText,
        watermarkOpacity: watermarkOpacity,
        quality: quality,
      );
      final ext = outcome.format == 'png' ? 'png' : 'jpg';
      final mime = outcome.format == 'png' ? 'image/png' : 'image/jpeg';
      final name = _buildFileName(customFileName ?? currentDocument.title, ext);
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
      _gcPendingDeletes();
      _notify();
    }
  }

  Future<void> exportAllImagesZip({
    required ExportDestination destination,
    String? customFileName,
    String? watermarkText,
    double watermarkOpacity = 0.20,
    double quality = 0.92,
    bool saveToFolder = false,
  }) async {
    if (_state.pages.isEmpty || _exporting) return;
    final items = List<PageItem>.unmodifiable(_state.pages);
    final pinned = items.map((p) => p.sourceUri).toList(growable: false);
    _pinnedSourceUris.addAll(pinned);
    _exporting = true;
    _exportLabel = '正在批量导出图片…';
    _notify();
    try {
      final outcome = await _jobs.exportAllImagesZipTask(
        items,
        signatures: _signatures,
        watermarkText: watermarkText,
        watermarkOpacity: watermarkOpacity,
        quality: quality,
        onProgress: (done, total) {
          if (!_disposed) {
            _exportLabel = '正在渲染图片（$done/$total）…';
            _notify();
          }
        },
      );
      final String feedback;
      if (saveToFolder) {
        feedback = await _exporter.deliverBatchToDirectory(files: outcome.files);
      } else {
        final name = _buildFileName(customFileName ?? currentDocument.title, 'zip');
        feedback = await _exporter.deliver(
          storage: _storage,
          bytes: outcome.bytes,
          fileName: name,
          mimeType: 'application/zip',
          destination: destination,
        );
      }
      if (feedback.isNotEmpty) {
        _emitToast(feedback, ToastKind.success);
      }
    } catch (err) {
      _emitToast(_readableError(err, '批量图片导出失败，请重试'), ToastKind.error);
    } finally {
      _pinnedSourceUris.removeAll(pinned);
      _exporting = false;
      _exportLabel = '正在导出…';
      _gcPendingDeletes();
      _notify();
    }
  }

  String _buildFileName(String rawPrefix, String ext) {
    final sanitized = rawPrefix
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    final prefix = sanitized.isNotEmpty ? sanitized : '扫描件';
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
    _undoStack.clear();
    _redoStack.clear();
    _gcPendingDeletes();
    if (_persistDirty && _hydrated && _storage.isPersistent) {
      _persistTimer?.cancel();
      _persistDirty = false;
      final snapshot = _library;
      unawaited(_storage.saveLibrary(snapshot).catchError((_) {}));
    } else {
      _persistTimer?.cancel();
    }
    _toastController.close();
    super.dispose();
  }
}
