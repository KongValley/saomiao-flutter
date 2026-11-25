import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/app_storage.dart';
import '../../io/image_acquisition.dart';
import '../../jobs/render_jobs.dart';
import '../../state/page_models.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';
import '../widgets/annotate_overlay.dart';
import '../widgets/book_split_dialog.dart';
import '../widgets/burst_camera_screen.dart';
import '../widgets/corners_overlay.dart';
import '../widgets/document_library_sheet.dart';
import '../widgets/export_sheet.dart';
import '../widgets/id_card_composer_sheet.dart';
import '../widgets/ocr_sheet.dart';
import '../widgets/page_strip.dart';
import '../widgets/params_sheet.dart';
import '../widgets/processing_banner.dart';
import '../widgets/style_sheet.dart';
import '../widgets/top_bar.dart';

enum _InspectorTab { style, params, export }

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.controller,
    this.demoPages,
  });

  final ScannerController controller;
  final List<PageItem>? demoPages;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WidgetsBindingObserver {
  final TransformationController _zoomController = TransformationController();
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'EditorShortcuts');
  StreamSubscription<ToastMessage>? _toastSub;
  _InspectorTab _desktopTab = _InspectorTab.style;
  int? _activeMobileTool;
  bool _zoomed2x = false;

  bool _draggingOver = false;
  int _modalDepth = 0;

  // 原图对比态
  bool _comparingOriginal = false;
  String? _compareSourcePageId;
  Uint8List? _compareSourceBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _toastSub = widget.controller.toasts.listen(_showSnack);
    widget.controller.addListener(_onControllerChanged);
    unawaited(widget.controller.init(demoPages: widget.demoPages));
  }

  void _onControllerChanged() {
    final cur = widget.controller.currentPage;
    if (cur == null || cur.id != _compareSourcePageId) {
      _compareSourcePageId = null;
      _compareSourceBytes = null;
      if (_comparingOriginal && mounted) {
        setState(() => _comparingOriginal = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.controller.flushPersist());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    _toastSub?.cancel();
    _zoomController.dispose();
    _shortcutFocus.dispose();
    super.dispose();
  }

  void _showSnack(ToastMessage toast) {
    if (!mounted) return;
    final pal = AppColors.of(context);
    final Color bg;
    final IconData icon;
    switch (toast.kind) {
      case ToastKind.success:
        bg = const Color(0xFF0E6D4E);
        icon = Icons.check_circle_outline_rounded;
      case ToastKind.warn:
        bg = const Color(0xFF8C5F18);
        icon = Icons.warning_amber_rounded;
      case ToastKind.error:
        bg = const Color(0xFFB3261E);
        icon = Icons.error_outline_rounded;
      case ToastKind.info:
        bg = pal.surfaceContainer == AppColors.surfaceContainer
            ? AppColors.ink
            : const Color(0xFF1E293B);
        icon = Icons.info_outline_rounded;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: bg,
          duration: Duration(milliseconds: toast.kind == ToastKind.error ? 3400 : 2400),
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(toast.text)),
            ],
          ),
        ),
      );
  }

  void _toggleDoubleTapZoom() {
    setState(() {
      _zoomed2x = !_zoomed2x;
      _zoomController.value = _zoomed2x
          ? (Matrix4.identity()..scaleByDouble(2.0, 2.0, 1.0, 1.0))
          : Matrix4.identity();
    });
  }

  void _resetZoom() {
    if (_zoomed2x || _zoomController.value != Matrix4.identity()) {
      _zoomed2x = false;
      _zoomController.value = Matrix4.identity();
    }
  }

  Future<void> _setCompareOriginal(bool active) async {
    final page = widget.controller.currentPage;
    if (!active || page == null) {
      if (_comparingOriginal && mounted) {
        setState(() => _comparingOriginal = false);
      }
      return;
    }
    if (_compareSourcePageId == page.id && _compareSourceBytes != null) {
      if (mounted) setState(() => _comparingOriginal = true);
      return;
    }
    try {
      final bytes = await widget.controller.readSourceBytes(page);
      if (!mounted || widget.controller.currentPage?.id != page.id) return;
      setState(() {
        _compareSourcePageId = page.id;
        _compareSourceBytes = bytes;
        _comparingOriginal = true;
      });
    } catch (_) {}
  }

  bool _isTypingInTextField() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) return false;
    final w = focus.context!.widget;
    if (w is EditableText) return true;
    return focus.context!.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_modalDepth > 0) return KeyEventResult.ignored;

    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final typing = _isTypingInTextField();

    if (event is KeyDownEvent) {
      if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV && !typing) {
        unawaited(widget.controller.pasteFromClipboard());
        return KeyEventResult.handled;
      }
      if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyZ && !typing) {
        if (isShift) {
          widget.controller.redo();
        } else {
          widget.controller.undo();
        }
        return KeyEventResult.handled;
      }
      if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyY && !typing) {
        widget.controller.redo();
        return KeyEventResult.handled;
      }
      if (isCtrl &&
          (event.logicalKey == LogicalKeyboardKey.keyS ||
              event.logicalKey == LogicalKeyboardKey.keyE)) {
        if (widget.controller.hasPages) {
          if (MediaQuery.sizeOf(context).width >= 840) {
            setState(() => _desktopTab = _InspectorTab.export);
          } else {
            _openMobileSheet(_InspectorTab.export);
          }
          return KeyEventResult.handled;
        }
      }

      if (typing) return KeyEventResult.ignored;

      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (widget.controller.currentIndex > 0) {
          _resetZoom();
          widget.controller.selectPage(widget.controller.currentIndex - 1);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (widget.controller.currentIndex < widget.controller.pages.length - 1) {
          _resetZoom();
          widget.controller.selectPage(widget.controller.currentIndex + 1);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.keyR && !isCtrl) {
        final p = widget.controller.currentPage;
        if (p != null) {
          widget.controller.rotatePage(p);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.delete && !isCtrl) {
        final p = widget.controller.currentPage;
        if (p != null && !widget.controller.isExporting) {
          widget.controller.removePage(p);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.space && !isCtrl) {
        if (widget.controller.hasPages) {
          unawaited(_setCompareOriginal(true));
          return KeyEventResult.handled;
        }
      }
    } else if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space && _comparingOriginal) {
        unawaited(_setCompareOriginal(false));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<T?> _pushModalRoute<T>(Route<T> route) async {
    setState(() => _modalDepth++);
    try {
      return await Navigator.of(context).push<T>(route);
    } finally {
      if (mounted) setState(() => _modalDepth--);
    }
  }

  Future<void> _openCornersOverlay(PageItem page) async {
    await _pushModalRoute<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => CornersOverlay(
          page: page,
          sourceBytesFuture: widget.controller.readSourceBytes(page),
          onCancel: () => Navigator.of(routeContext).pop(),
          onApply: (corners) {
            Navigator.of(routeContext).pop();
            widget.controller.applyCorners(corners);
          },
          onAutoDetect: () => widget.controller.autoDetectCorners(page),
          onToast: (msg, {warn = false, error = false}) {
            _showSnack(
              ToastMessage(
                msg,
                error ? ToastKind.error : (warn ? ToastKind.warn : ToastKind.success),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openAnnotateOverlay(PageItem page) async {
    Future<({Uint8List bytes, int width, int height})> loadCleanBase() async {
      final sourceBytes = await widget.controller.readSourceBytes(page);
      final tempStorage = MemoryAppStorage();
      await tempStorage.saveSourceBytes(sourceBytes, page.id, page.name);
      final cleanPage = page.copyWith(
        sourceUri: 'mem://${page.id}',
        annotations: PageAnnotations.empty,
      );
      final jobs = RenderJobs(storage: tempStorage);
      final res = await jobs.renderPageTask(cleanPage, cleanPage.options);
      return (bytes: res.bytes, width: res.width, height: res.height);
    }

    final next = await _pushModalRoute<PageAnnotations>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AnnotateOverlay(
          page: page,
          baseImageFuture: loadCleanBase(),
          controller: widget.controller,
        ),
      ),
    );
    if (next != null) {
      widget.controller.updatePageAnnotations(page.id, next);
    }
  }

  Future<void> _openBookSplitDialog(PageItem page) async {
    setState(() => _modalDepth++);
    final res = await showDialog<BookSplitResult>(
      context: context,
      builder: (_) => BookSplitDialog(
        page: page,
        sourceBytesFuture: widget.controller.readSourceBytes(page),
        onDetectGutter: () => widget.controller.detectBookGutter(page),
      ),
    );
    if (mounted) setState(() => _modalDepth--);
    if (res != null) {
      await widget.controller.splitDoublePage(
        page,
        res.splitX,
        keepOriginal: res.keepOriginal,
      );
    }
  }

  Future<void> _openOcrSheet() async {
    setState(() => _modalDepth++);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => OcrResultSheet(controller: widget.controller),
    );
    if (mounted) setState(() => _modalDepth--);
  }

  Future<void> _openDocumentLibrary() async {
    setState(() => _modalDepth++);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => DocumentLibrarySheet(controller: widget.controller),
    );
    if (mounted) setState(() => _modalDepth--);
  }

  Future<void> _openIdCardComposer() async {
    await _pushModalRoute<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IdCardComposerScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _openBurstCamera() async {
    final shots = await _pushModalRoute<List<PickedImageInput>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const BurstCameraScreen(),
      ),
    );
    if (shots != null && shots.isNotEmpty) {
      await widget.controller.importPickedImages(shots);
    }
  }

  void _cycleThemeMode() {
    final current = widget.controller.preferences.themeMode;
    final next = switch (current) {
      'system' => 'light',
      'light' => 'dark',
      _ => 'system',
    };
    unawaited(
      widget.controller.updatePreferences(
        widget.controller.preferences.copyWith(themeMode: next),
      ),
    );
  }

  void _toggleAutoDetectOnImport() {
    final cur = widget.controller.preferences.autoDetectOnImport;
    unawaited(
      widget.controller.updatePreferences(
        widget.controller.preferences.copyWith(autoDetectOnImport: !cur),
      ),
    );
    _showSnack(
      ToastMessage(
        !cur ? '已开启导入自动裁边' : '已关闭导入自动裁边',
        ToastKind.info,
      ),
    );
  }

  Future<void> _openMobileSheet(_InspectorTab tab) async {
    final navIndex = switch (tab) {
      _InspectorTab.style => 1,
      _InspectorTab.params => 2,
      _InspectorTab.export => 3,
    };
    setState(() {
      _activeMobileTool = navIndex;
      _modalDepth++;
    });

    final meta = switch (tab) {
      _InspectorTab.style => ('扫描风格', '四档风格 + 六种预设，选中立即生效'),
      _InspectorTab.params => ('参数调整', '拖动滑杆，预览会实时更新'),
      _InspectorTab.export => ('导出扫描件', '支持 PDF / 水印 / OCR 双层检索 / 批量导出'),
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) {
        final pal = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final page = widget.controller.currentPage;
              if (page == null) return const SizedBox.shrink();
              final maxH =
                  MediaQuery.sizeOf(context).height * (tab == _InspectorTab.export ? 0.85 : 0.78);
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  meta.$1,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: pal.ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  meta.$2,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: pal.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    if (widget.controller.isBusy)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: pal.accentBg,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.controller.busyLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: pal.accentText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                        child: _buildInspectorBody(tab, page),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (mounted) {
      setState(() {
        _activeMobileTool = null;
        _modalDepth--;
      });
    }
  }

  Widget _buildInspectorBody(_InspectorTab tab, PageItem page) {
    final ocrPages = widget.controller.pages.where((p) => p.ocr != null && p.ocr!.lines.isNotEmpty).length;
    switch (tab) {
      case _InspectorTab.style:
        return StyleSheetContent(
          options: page.options,
          onPatch: (patch) => widget.controller.applyOptions(patch, immediate: true),
          customPresets: widget.controller.customPresets,
          onSaveCustomPreset: widget.controller.saveCurrentAsPreset,
          onDeleteCustomPreset: widget.controller.deleteCustomPreset,
        );
      case _InspectorTab.params:
        return ParamsSheetContent(
          options: page.options,
          pageCount: widget.controller.pages.length,
          canUndo: widget.controller.canUndoBatch,
          canUndoStep: widget.controller.canUndo,
          canRedoStep: widget.controller.canRedo,
          onUndoStep: widget.controller.undo,
          onRedoStep: widget.controller.redo,
          onChange: widget.controller.applyOptions,
          onApplyAll: widget.controller.applyOptionsToAll,
          onUndo: widget.controller.undoApplyAll,
          onAutoCropAll: widget.controller.autoDetectAllCorners,
          onReset: widget.controller.resetOptions,
        );
      case _InspectorTab.export:
        return ExportSheetContent(
          pageCount: widget.controller.pages.length,
          currentIndex: widget.controller.currentIndex,
          busy: widget.controller.isExporting,
          documentTitle: widget.controller.currentDocument.title,
          ocrReadyPages: ocrPages,
          onExportPdf: (pdfOpts, allPages, dest, {customFileName}) =>
              widget.controller.exportPdf(
            pdfOptions: pdfOpts,
            allPages: allPages,
            destination: dest,
            customFileName: customFileName,
          ),
          onExportImage: (dest, {customFileName, watermarkText, watermarkOpacity = 0.2, quality = 0.92}) =>
              widget.controller.exportCurrentImage(
            destination: dest,
            customFileName: customFileName,
            watermarkText: watermarkText,
            watermarkOpacity: watermarkOpacity,
            quality: quality,
          ),
          onExportAllImages: (dest, {customFileName, watermarkText, watermarkOpacity = 0.2, quality = 0.92, saveToFolder = false}) =>
              widget.controller.exportAllImagesZip(
            destination: dest,
            customFileName: customFileName,
            watermarkText: watermarkText,
            watermarkOpacity: watermarkOpacity,
            quality: quality,
            saveToFolder: saveToFolder,
          ),
        );
    }
  }

  Future<void> _openPageActions(PageItem page, int index) async {
    final total = widget.controller.pages.length;
    setState(() => _modalDepth++);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheetCtx) {
        final pal = AppColors.of(sheetCtx);
        final maxH = MediaQuery.sizeOf(sheetCtx).height * 0.85;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '页面操作',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: pal.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '第 ${index + 1} 页 · ${page.name}',
                          style: TextStyle(fontSize: 13, color: pal.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.rotate_right_rounded),
                    title: const Text('旋转 90°'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      widget.controller.rotatePage(page);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.draw_outlined),
                    title: const Text('擦除打码与电子签名'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _openAnnotateOverlay(page);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.text_snippet_outlined),
                    title: const Text('离线 OCR 识别文字'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _openOcrSheet();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.vertical_split_rounded),
                    title: const Text('对开书籍拆分两页'),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _openBookSplitDialog(page);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.chevron_left_rounded),
                    title: const Text('移前'),
                    enabled: index > 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: index > 0
                        ? () {
                            Navigator.of(sheetCtx).pop();
                            widget.controller.movePage(page, -1);
                          }
                        : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.chevron_right_rounded),
                    title: const Text('移后'),
                    enabled: index < total - 1,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: index < total - 1
                        ? () {
                            Navigator.of(sheetCtx).pop();
                            widget.controller.movePage(page, 1);
                          }
                        : null,
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: widget.controller.isExporting ? pal.inkMuted : pal.danger,
                    ),
                    title: Text(
                      '删除这一页',
                      style: TextStyle(
                        color: widget.controller.isExporting ? pal.inkMuted : pal.danger,
                      ),
                    ),
                    enabled: !widget.controller.isExporting,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onTap: widget.controller.isExporting
                        ? null
                        : () {
                            Navigator.of(sheetCtx).pop();
                            widget.controller.removePage(page);
                          },
                  ),
                ],
              ),
            ),
          ),
        ),
        );
      },
    );
    if (mounted) setState(() => _modalDepth--);
  }

  Widget _buildEmptyState() {
    final pal = AppColors.of(context);
    if (!widget.controller.hydrated) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                '正在加载本地扫描库…',
                style: TextStyle(fontSize: 13, color: pal.inkMuted),
              ),
            ],
          ),
        ),
      );
    }
    final supportsCamera = widget.controller.supportsCamera;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const EmptyDocumentIllustration(size: 200),
              const SizedBox(height: 10),
              Text(
                '把纸变成扫描件',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: pal.ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS
                    ? '拍照、从相册选图或导入 PDF，自动校正四角、去阴影、留红印章，生成双层可搜索 PDF。全部本地完成，不上传。'
                    : '拍照、拖拽图片或导入 PDF，自动校正四角、去阴影、留红印章，生成双层可搜索 PDF。全部本地完成，不上传。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: pal.inkSecondary,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  if (supportsCamera) ...[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.controller.takePhoto,
                        icon: const Icon(Icons.photo_camera_outlined, size: 20),
                        label: const Text('拍照'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: widget.controller.pickFromGallery,
                        icon: const Icon(Icons.photo_library_outlined, size: 20),
                        label: const Text('从相册选'),
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.controller.pickFromGallery,
                        icon: const Icon(Icons.photo_library_outlined, size: 20),
                        label: const Text('选择图片'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => widget.controller.loadDemoPages(),
                        icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                        label: const Text('示例文档'),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (supportsCamera)
                    ActionChip(
                      avatar: const Icon(Icons.burst_mode_outlined, size: 17),
                      label: const Text('连续连拍'),
                      onPressed: _openBurstCamera,
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.picture_as_pdf_outlined, size: 17),
                    label: const Text('导入 PDF 漂白'),
                    onPressed: widget.controller.pickAndImportPdfs,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.credit_card_outlined, size: 17),
                    label: const Text('证件拼版'),
                    onPressed: _openIdCardComposer,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.content_paste_go_rounded, size: 17),
                    label: const Text('粘贴剪贴板'),
                    onPressed: widget.controller.pasteFromClipboard,
                  ),
                  if (supportsCamera)
                    ActionChip(
                      avatar: const Icon(Icons.auto_awesome_outlined, size: 17),
                      label: const Text('加载示例文档'),
                      onPressed: () => widget.controller.loadDemoPages(),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              const Divider(),
              const SizedBox(height: 14),
              const Wrap(
                spacing: 18,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _PointChip('离线可用'),
                  _PointChip('本地 OCR'),
                  _PointChip('多文档库'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer(PageItem page) {
    final pal = AppColors.of(context);
    final preview = widget.controller.currentRender;
    final error = widget.controller.currentError;
    final showOriginal = _comparingOriginal && _compareSourceBytes != null;

    return Container(
      color: pal.previewBg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showOriginal)
            InteractiveViewer(
              transformationController: _zoomController,
              minScale: 1.0,
              maxScale: 4.5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      _compareSourceBytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            )
          else if (preview != null)
            GestureDetector(
              onDoubleTap: _toggleDoubleTapZoom,
              child: InteractiveViewer(
                transformationController: _zoomController,
                minScale: 1.0,
                maxScale: 4.5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(
                        preview.bytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else if (error == null)
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        '正在生成预览…',
                        style: TextStyle(fontSize: 13, color: pal.inkMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 顶部信息栏：页码 + 状态标签 + 快捷操作
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 340;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            height: narrow ? 28 : 30,
                            padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 10),
                            decoration: BoxDecoration(
                              color: AppColors.ink.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.controller.state.formatPageCounter(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: narrow ? 11.5 : 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (showOriginal)
                            Container(
                              height: narrow ? 28 : 30,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: AppColors.warn,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.compare_rounded, size: 14, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text(
                                    '原图对比中',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (page.options.corners != null)
                            InkWell(
                              onTap: widget.controller.isBusy
                                  ? null
                                  : () => _openCornersOverlay(page),
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                height: narrow ? 28 : 30,
                                padding: EdgeInsets.symmetric(horizontal: narrow ? 7 : 8),
                                decoration: BoxDecoration(
                                  color: pal.surface.withValues(alpha: 0.94),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: pal.outline),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.crop_free_rounded,
                                      size: 13,
                                      color: pal.accentText,
                                    ),
                                    if (!narrow) ...[
                                      const SizedBox(width: 3),
                                      Text(
                                        '已校正',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: pal.accentText,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: pal.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!narrow) ...[
                            IconButton(
                              tooltip: '撤销 (Ctrl+Z)',
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  widget.controller.canUndo ? widget.controller.undo : null,
                              icon: const Icon(Icons.undo_rounded, size: 18),
                            ),
                            IconButton(
                              tooltip: '擦除与签名批注',
                              visualDensity: VisualDensity.compact,
                              onPressed: widget.controller.isBusy
                                  ? null
                                  : () => _openAnnotateOverlay(page),
                              icon: const Icon(Icons.draw_outlined, size: 18),
                            ),
                            IconButton(
                              tooltip: '离线 OCR 识字',
                              visualDensity: VisualDensity.compact,
                              onPressed: widget.controller.isBusy ? null : _openOcrSheet,
                              icon: const Icon(Icons.text_snippet_outlined, size: 18),
                            ),
                          ],
                          IconButton(
                            tooltip: '旋转 90° (R)',
                            visualDensity: VisualDensity.compact,
                            style: narrow
                                ? IconButton.styleFrom(
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    minimumSize: const Size(32, 32),
                                    padding: const EdgeInsets.all(6),
                                  )
                                : null,
                            onPressed: () => widget.controller.rotatePage(page),
                            icon: Icon(Icons.rotate_right_rounded, size: narrow ? 17 : 19),
                          ),
                          IconButton(
                            tooltip: '页面操作',
                            visualDensity: VisualDensity.compact,
                            style: narrow
                                ? IconButton.styleFrom(
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    minimumSize: const Size(32, 32),
                                    padding: const EdgeInsets.all(6),
                                  )
                                : null,
                            onPressed: () => _openPageActions(
                              page,
                              widget.controller.currentIndex,
                            ),
                            icon: Icon(Icons.more_horiz_rounded, size: narrow ? 17 : 19),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // 按住对比原图浮动按钮（右下角）
          if (preview != null && error == null)
            Positioned(
              right: 14,
              bottom: 14,
              child: Listener(
                onPointerDown: (_) => unawaited(_setCompareOriginal(true)),
                onPointerUp: (_) => unawaited(_setCompareOriginal(false)),
                onPointerCancel: (_) => unawaited(_setCompareOriginal(false)),
                child: Material(
                  color: _comparingOriginal
                      ? AppColors.warn
                      : pal.surface.withValues(alpha: 0.92),
                  elevation: 2,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _comparingOriginal ? AppColors.warn : pal.outline,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.compare_rounded,
                          size: 16,
                          color: _comparingOriginal ? Colors.white : pal.inkSecondary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '按住对比原图',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _comparingOriginal ? Colors.white : pal.inkSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          if (error == null)
            Positioned(
              left: 12,
              right: 140,
              bottom: 14,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '双指或双击缩放 · 长按缩略图可拖动排序',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),

          if (error != null)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Card(
                  elevation: 3,
                  color: pal.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 30,
                          color: pal.warn,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: pal.inkSecondary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: widget.controller.retryCurrentRender,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          ProcessingBanner(
            visible: widget.controller.isBusy,
            label: widget.controller.busyLabel,
          ),
        ],
      ),
    );
  }

  Widget _buildWideInspector(PageItem page) {
    final pal = AppColors.of(context);
    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border(left: BorderSide(color: pal.outline)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.controller.isBusy
                            ? null
                            : () => _openCornersOverlay(page),
                        icon: const Icon(Icons.crop_free_rounded, size: 18),
                        label: const Text('四角透视校正'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: '擦除打码 / 电子签名',
                      onPressed: widget.controller.isBusy
                          ? null
                          : () => _openAnnotateOverlay(page),
                      icon: const Icon(Icons.draw_outlined, size: 19),
                    ),
                    const SizedBox(width: 4),
                    IconButton.outlined(
                      tooltip: '离线 OCR 识字',
                      onPressed: widget.controller.isBusy ? null : _openOcrSheet,
                      icon: const Icon(Icons.text_snippet_outlined, size: 19),
                    ),
                    const SizedBox(width: 4),
                    IconButton.outlined(
                      tooltip: '对开书页拆分',
                      onPressed: widget.controller.isBusy
                          ? null
                          : () => _openBookSplitDialog(page),
                      icon: const Icon(Icons.vertical_split_rounded, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SegmentedButton<_InspectorTab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _InspectorTab.style, label: Text('风格')),
                    ButtonSegment(value: _InspectorTab.params, label: Text('参数')),
                    ButtonSegment(value: _InspectorTab.export, label: Text('导出')),
                  ],
                  selected: <_InspectorTab>{_desktopTab},
                  onSelectionChanged: (s) =>
                      setState(() => _desktopTab = s.first),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildInspectorBody(_desktopTab, page),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final hasPages = widget.controller.hasPages;
        final page = widget.controller.currentPage;
        final isWide = MediaQuery.sizeOf(context).width >= 840;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: isDark
              ? SystemUiOverlayStyle.light
              : const SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness: Brightness.dark,
                  statusBarBrightness: Brightness.light,
                ),
          child: Focus(
          focusNode: _shortcutFocus,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: DropTarget(
            enable: _modalDepth == 0,
            onDragEntered: (_) => setState(() => _draggingOver = true),
            onDragExited: (_) => setState(() => _draggingOver = false),
            onDragDone: (details) {
              setState(() => _draggingOver = false);
              final paths = details.files
                  .map((f) => f.path)
                  .where((p) => p.isNotEmpty)
                  .toList(growable: false);
              if (paths.isNotEmpty) {
                unawaited(widget.controller.importDroppedPaths(paths));
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Scaffold(
                  body: Column(
                    children: [
                      TopBar(
                        hasPages: hasPages,
                        supportsCamera: widget.controller.supportsCamera,
                        busy: widget.controller.isBusy || !widget.controller.hydrated,
                        documentTitle: widget.controller.currentDocument.title,
                        themeMode: widget.controller.preferences.themeMode,
                        autoDetectOnImport:
                            widget.controller.preferences.autoDetectOnImport,
                        onTakePhoto: widget.controller.takePhoto,
                        onBurstCamera: _openBurstCamera,
                        onPickGallery: widget.controller.pickFromGallery,
                        onImportPdf: widget.controller.pickAndImportPdfs,
                        onPasteClipboard: widget.controller.pasteFromClipboard,
                        onOpenLibrary: _openDocumentLibrary,
                        onOpenIdComposer: _openIdCardComposer,
                        onCycleThemeMode: _cycleThemeMode,
                        onToggleAutoDetect: _toggleAutoDetectOnImport,
                        onLoadDemo: () => widget.controller.loadDemoPages(),
                      ),
                      Expanded(
                        child: !hasPages || page == null
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  _buildEmptyState(),
                                  ProcessingBanner(
                                    visible: widget.controller.isBusy,
                                    label: widget.controller.busyLabel,
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Expanded(child: _buildViewer(page)),
                                        PageStrip(
                                          pages: widget.controller.pages,
                                          currentIndex: widget.controller.currentIndex,
                                          thumbnailOf: widget.controller.thumbnailOf,
                                          onSelect: (idx) {
                                            _resetZoom();
                                            widget.controller.selectPage(idx);
                                          },
                                          onOpenActions: _openPageActions,
                                          onReorder: widget.controller.reorderPage,
                                          onAdd: widget.controller.pickFromGallery,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isWide) _buildWideInspector(page),
                                ],
                              ),
                      ),
                    ],
                  ),
                  bottomNavigationBar: !isWide && hasPages && page != null
                      ? NavigationBar(
                          selectedIndex: _activeMobileTool ?? 0,
                          indicatorColor: _activeMobileTool == null
                              ? Colors.transparent
                              : Theme.of(context).colorScheme.primaryContainer,
                          onDestinationSelected: (index) {
                            if (widget.controller.isBusy) return;
                            switch (index) {
                              case 0:
                                _openCornersOverlay(page);
                              case 1:
                                _openMobileSheet(_InspectorTab.style);
                              case 2:
                                _openMobileSheet(_InspectorTab.params);
                              case 3:
                                _openMobileSheet(_InspectorTab.export);
                            }
                          },
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.crop_free_rounded),
                              label: '四角',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.auto_awesome_outlined),
                              label: '风格',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.tune_rounded),
                              label: '参数',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.picture_as_pdf_outlined, color: AppColors.seed),
                              label: '导出',
                            ),
                          ],
                        )
                      : null,
                ),
                if (_draggingOver)
                  IgnorePointer(
                    child: Container(
                      color: AppColors.seed.withValues(alpha: 0.14),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                          decoration: BoxDecoration(
                            color: pal.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.seed, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 16),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.file_download_outlined,
                                size: 42,
                                color: AppColors.seed,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '松手导入图片或 PDF',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: pal.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }
}

class _PointChip extends StatelessWidget {
  const _PointChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_rounded, size: 15, color: pal.success),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: pal.inkMuted),
        ),
      ],
    );
  }
}
