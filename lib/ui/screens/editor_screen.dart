import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/page_models.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';
import '../widgets/corners_overlay.dart';
import '../widgets/export_sheet.dart';
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

class _EditorScreenState extends State<EditorScreen> {
  final TransformationController _zoomController = TransformationController();
  StreamSubscription<ToastMessage>? _toastSub;
  _InspectorTab _desktopTab = _InspectorTab.style;
  int? _activeMobileTool;
  bool _zoomed2x = false;

  @override
  void initState() {
    super.initState();
    _toastSub = widget.controller.toasts.listen(_showSnack);
    unawaited(widget.controller.init(demoPages: widget.demoPages));
  }

  @override
  void dispose() {
    _toastSub?.cancel();
    _zoomController.dispose();
    super.dispose();
  }

  void _showSnack(ToastMessage toast) {
    if (!mounted) return;
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
        bg = AppColors.ink;
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

  Future<void> _openCornersOverlay(PageItem page) async {
    await Navigator.of(context).push<void>(
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

  Future<void> _openMobileSheet(_InspectorTab tab) async {
    final navIndex = switch (tab) {
      _InspectorTab.style => 1,
      _InspectorTab.params => 2,
      _InspectorTab.export => 3,
    };
    setState(() => _activeMobileTool = navIndex);

    final meta = switch (tab) {
      _InspectorTab.style => ('扫描风格', '三档风格 + 四种预设，选中立即生效'),
      _InspectorTab.params => ('参数调整', '拖动滑杆，预览会实时更新'),
      _InspectorTab.export => ('导出扫描件', '生成后可直接分享或保存到文件'),
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) {
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final page = widget.controller.currentPage;
            if (page == null) return const SizedBox.shrink();
            final maxH = MediaQuery.sizeOf(context).height * (tab == _InspectorTab.export ? 0.86 : 0.78);
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
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                meta.$2,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.inkMuted,
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
                          color: const Color(0xFFEDF3FF),
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
                            Text(
                              widget.controller.busyLabel,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1D4ED8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        4,
                        20,
                        20 + MediaQuery.paddingOf(context).bottom,
                      ),
                      child: _buildInspectorBody(tab, page),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (mounted) {
      setState(() => _activeMobileTool = null);
    }
  }

  Widget _buildInspectorBody(_InspectorTab tab, PageItem page) {
    switch (tab) {
      case _InspectorTab.style:
        return StyleSheetContent(
          options: page.options,
          onPatch: (patch) => widget.controller.applyOptions(patch, immediate: true),
        );
      case _InspectorTab.params:
        return ParamsSheetContent(
          options: page.options,
          pageCount: widget.controller.pages.length,
          canUndo: widget.controller.canUndoBatch,
          onChange: widget.controller.applyOptions,
          onApplyAll: widget.controller.applyOptionsToAll,
          onUndo: widget.controller.undoApplyAll,
          onReset: widget.controller.resetOptions,
        );
      case _InspectorTab.export:
        return ExportSheetContent(
          pageCount: widget.controller.pages.length,
          currentIndex: widget.controller.currentIndex,
          busy: widget.controller.isExporting,
          onExportPdf: (pdfOpts, allPages, dest) => widget.controller.exportPdf(
            pdfOptions: pdfOpts,
            allPages: allPages,
            destination: dest,
          ),
          onExportImage: (dest) => widget.controller.exportCurrentImage(
            destination: dest,
          ),
        );
    }
  }

  Future<void> _openPageActions(PageItem page, int index) async {
    final total = widget.controller.pages.length;
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '页面操作',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '第 ${index + 1} 页 · ${page.name}',
                        style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
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
                  leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                  title: const Text('删除这一页', style: TextStyle(color: AppColors.danger)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    widget.controller.removePage(page);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final supportsCamera = widget.controller.supportsCamera;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const EmptyDocumentIllustration(size: 210),
              const SizedBox(height: 10),
              const Text(
                '把纸变成扫描件',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '拍照或从相册选图，自动校正四角、去阴影、转黑白，最后导出多页 PDF。全部在设备本地完成，图片不会上传。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: AppColors.inkSecondary,
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
              if (supportsCamera) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => widget.controller.loadDemoPages(),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                  label: const Text('加载示例文档体验'),
                ),
              ],
              const SizedBox(height: 18),
              const Divider(),
              const SizedBox(height: 14),
              const Wrap(
                spacing: 18,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _PointChip('离线可用'),
                  _PointChip('本地处理'),
                  _PointChip('多页 PDF'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer(PageItem page) {
    final preview = widget.controller.currentRender;
    final error = widget.controller.currentError;

    return Container(
      color: AppColors.previewBg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (preview != null)
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
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text(
                    '正在生成预览…',
                    style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),

          // 顶部信息栏：页码 + 已校正标签 + 快捷操作
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Row(
              children: [
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.ink.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    widget.controller.state.formatPageCounter(),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (page.options.corners != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.outline),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.crop_free_rounded,
                          size: 14,
                          color: Color(0xFF1D4ED8),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '已校正',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1D4ED8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                Material(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(999),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '旋转 90°',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.controller.rotatePage(page),
                        icon: const Icon(Icons.rotate_right_rounded, size: 19),
                      ),
                      IconButton(
                        tooltip: '页面操作',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _openPageActions(
                          page,
                          widget.controller.currentIndex,
                        ),
                        icon: const Icon(Icons.more_horiz_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '双指或双击缩放 · 长按缩略图可拖动排序',
                      style: TextStyle(fontSize: 13, color: Colors.white),
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
                  color: AppColors.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 30,
                          color: AppColors.warn,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.inkSecondary,
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
    return Container(
      width: 390,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.outline)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: widget.controller.isBusy
                      ? null
                      : () => _openCornersOverlay(page),
                  icon: const Icon(Icons.crop_free_rounded, size: 19),
                  label: const Text('四角透视校正'),
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final hasPages = widget.controller.hasPages;
        final page = widget.controller.currentPage;
        final isWide = MediaQuery.sizeOf(context).width >= 840;

        return Scaffold(
          body: Column(
            children: [
              TopBar(
                hasPages: hasPages,
                supportsCamera: widget.controller.supportsCamera,
                busy: widget.controller.isBusy,
                onTakePhoto: widget.controller.takePhoto,
                onPickGallery: widget.controller.pickFromGallery,
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
                                  renderOf: widget.controller.renderOf,
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_rounded, size: 15, color: AppColors.success),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
