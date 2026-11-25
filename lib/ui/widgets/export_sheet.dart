import 'package:flutter/material.dart';

import '../../engine/pdf.dart';
import '../../io/file_export.dart';
import '../../state/page_models.dart';
import '../theme.dart';

class ExportSheetContent extends StatefulWidget {
  const ExportSheetContent({
    super.key,
    required this.pageCount,
    required this.currentIndex,
    required this.busy,
    required this.onExportPdf,
    required this.onExportImage,
    this.documentTitle = '扫描件',
    this.ocrReadyPages = 0,
    this.onExportAllImages,
  });

  final int pageCount;
  final int currentIndex;
  final bool busy;
  final String documentTitle;
  final int ocrReadyPages;
  final void Function(
    PdfOptions pdfOptions,
    bool allPages,
    ExportDestination destination, {
    String? customFileName,
  }) onExportPdf;
  final void Function(
    ExportDestination destination, {
    String? customFileName,
    String? watermarkText,
    double watermarkOpacity,
    double quality,
  }) onExportImage;
  final void Function(
    ExportDestination destination, {
    String? customFileName,
    String? watermarkText,
    double watermarkOpacity,
    double quality,
    bool saveToFolder,
  })? onExportAllImages;

  @override
  State<ExportSheetContent> createState() => _ExportSheetContentState();
}

class _ExportSheetContentState extends State<ExportSheetContent> {
  bool _allPages = true;
  ExportDestination _destination = ExportDestination.share;
  PdfOptions _pdfOptions = kDefaultPdfOptions;
  late final TextEditingController _nameController;
  final TextEditingController _watermarkController =
      TextEditingController(text: '仅供办理业务使用');
  bool _enableWatermark = false;

  static const Map<PdfPageSize, String> _paperLabels = {
    PdfPageSize.a4: 'A4',
    PdfPageSize.letter: 'Letter',
    PdfPageSize.auto: '自动纸张',
  };

  static const Map<PdfOrientation, String> _orientLabels = {
    PdfOrientation.auto: '自动方向',
    PdfOrientation.portrait: '纵向',
    PdfOrientation.landscape: '横向',
  };

  static const List<({String label, double quality})> _qualityPresets = [
    (label: '高清', quality: 0.92),
    (label: '均衡', quality: 0.76),
    (label: '小体积', quality: 0.56),
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.documentTitle.trim().isNotEmpty ? widget.documentTitle.trim() : '扫描件',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _watermarkController.dispose();
    super.dispose();
  }

  String _estimateSizeLabel() {
    final pages = _allPages ? widget.pageCount : 1;
    final perPageKb = _pdfOptions.jpegQuality >= 0.88
        ? 420
        : (_pdfOptions.jpegQuality >= 0.70 ? 220 : 115);
    final totalKb = pages * perPageKb;
    if (totalKb >= 1024) {
      return '约 ${(totalKb / 1024).toStringAsFixed(1)} MB';
    }
    return '约 $totalKb KB';
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final scopeText =
        _allPages ? '全部 ${widget.pageCount} 页' : '第 ${widget.currentIndex + 1} 页';
    final margin = _pdfOptions.marginMm.round();
    final summary =
        '$scopeText · ${_paperLabels[_pdfOptions.pageSize]} · ${_orientLabels[_pdfOptions.orientation]} · 边距 ${margin}mm · ${_estimateSizeLabel()}';
    final effectiveWatermark =
        _enableWatermark && _watermarkController.text.trim().isNotEmpty
            ? _watermarkController.text.trim()
            : null;
    final effectiveTitle = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : widget.documentTitle;

    final effectivePdfOptions = _pdfOptions.copyWith(
      title: effectiveTitle,
      watermarkText: effectiveWatermark,
      clearWatermark: effectiveWatermark == null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('文件名称 / PDF 标题'),
        const SizedBox(height: 8),
        TextField(
          controller: _nameController,
          enabled: !widget.busy,
          decoration: InputDecoration(
            hintText: '输入导出文件名前缀',
            isDense: true,
            filled: true,
            fillColor: pal.surfaceLow,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: pal.outline),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('导出范围'),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment<bool>(
              value: true,
              label: Text('全部页 (${widget.pageCount})'),
            ),
            const ButtonSegment<bool>(
              value: false,
              label: Text('当前页'),
            ),
          ],
          selected: <bool>{_allPages},
          onSelectionChanged: widget.busy
              ? null
              : (s) => setState(() => _allPages = s.first),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('清晰度与体积'),
        const SizedBox(height: 8),
        SegmentedButton<double>(
          showSelectedIcon: false,
          segments: _qualityPresets
              .map((q) => ButtonSegment<double>(value: q.quality, label: Text(q.label)))
              .toList(growable: false),
          selected: <double>{_pdfOptions.jpegQuality},
          onSelectionChanged: widget.busy
              ? null
              : (s) => setState(
                    () => _pdfOptions = _pdfOptions.copyWith(jpegQuality: s.first),
                  ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('纸张大小'),
        const SizedBox(height: 8),
        SegmentedButton<PdfPageSize>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: PdfPageSize.a4, label: Text('A4')),
            ButtonSegment(value: PdfPageSize.letter, label: Text('Letter')),
            ButtonSegment(value: PdfPageSize.auto, label: Text('自动')),
          ],
          selected: <PdfPageSize>{_pdfOptions.pageSize},
          onSelectionChanged: widget.busy
              ? null
              : (s) => setState(
                    () => _pdfOptions = _pdfOptions.copyWith(pageSize: s.first),
                  ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('页面方向'),
        const SizedBox(height: 8),
        SegmentedButton<PdfOrientation>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: PdfOrientation.auto, label: Text('自动')),
            ButtonSegment(value: PdfOrientation.portrait, label: Text('纵向')),
            ButtonSegment(value: PdfOrientation.landscape, label: Text('横向')),
          ],
          selected: <PdfOrientation>{_pdfOptions.orientation},
          onSelectionChanged: widget.busy
              ? null
              : (s) => setState(
                    () => _pdfOptions = _pdfOptions.copyWith(orientation: s.first),
                  ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const _SectionTitle('页边距'),
            Text(
              '${margin}mm',
              style: TextStyle(
                fontSize: 14,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: pal.inkSecondary,
              ),
            ),
          ],
        ),
        Slider(
          value: _pdfOptions.marginMm.clamp(0, 40),
          min: 0,
          max: 40,
          divisions: 40,
          onChanged: widget.busy
              ? null
              : (v) => setState(
                    () => _pdfOptions = _pdfOptions.copyWith(
                      marginMm: v.roundToDouble(),
                    ),
                  ),
        ),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('显示页脚页码', style: TextStyle(fontSize: 14)),
                value: _pdfOptions.showPageNumbers,
                onChanged: widget.busy
                    ? null
                    : (v) => setState(
                          () => _pdfOptions = _pdfOptions.copyWith(showPageNumbers: v),
                        ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('写入双层可搜索 OCR 文字', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  widget.ocrReadyPages > 0
                      ? '已有 ${widget.ocrReadyPages} 页完成识字，导出可划词检索'
                      : '当前暂无识字页（可在识字面板生成）',
                  style: TextStyle(fontSize: 12, color: pal.inkMuted),
                ),
                value: _pdfOptions.embedOcrText,
                onChanged: widget.busy
                    ? null
                    : (v) => setState(
                          () => _pdfOptions = _pdfOptions.copyWith(embedOcrText: v),
                        ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('添加防盗用斜向水印', style: TextStyle(fontSize: 14)),
                value: _enableWatermark,
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _enableWatermark = v),
              ),
              if (_enableWatermark)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      TextField(
                        controller: _watermarkController,
                        enabled: !widget.busy,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '水印文本',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            '透明度',
                            style: TextStyle(fontSize: 12, color: pal.inkMuted),
                          ),
                          Expanded(
                            child: Slider(
                              value: _pdfOptions.watermarkOpacity.clamp(0.08, 0.50),
                              min: 0.08,
                              max: 0.50,
                              onChanged: widget.busy
                                  ? null
                                  : (v) => setState(
                                        () => _pdfOptions =
                                            _pdfOptions.copyWith(watermarkOpacity: v),
                                      ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Text(
              summary,
              style: TextStyle(fontSize: 13, color: pal.inkSecondary),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle('导出方式'),
        const SizedBox(height: 8),
        SegmentedButton<ExportDestination>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ExportDestination.share, label: Text('分享')),
            ButtonSegment(value: ExportDestination.save, label: Text('保存到文件')),
          ],
          selected: <ExportDestination>{_destination},
          onSelectionChanged: widget.busy
              ? null
              : (s) => setState(() => _destination = s.first),
        ),
        const SizedBox(height: 12),
        Text(
          '全部在设备本地生成，不上传任何图片。',
          style: TextStyle(fontSize: 13, color: pal.inkMuted),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: widget.busy
              ? null
              : () => widget.onExportPdf(
                    effectivePdfOptions,
                    _allPages,
                    _destination,
                    customFileName: effectiveTitle,
                  ),
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
          label: Text(
            widget.busy
                ? '正在生成…'
                : (_destination == ExportDestination.save ? '保存 PDF' : '导出 PDF'),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: widget.busy
              ? null
              : () => widget.onExportImage(
                    _destination,
                    customFileName: effectiveTitle,
                    watermarkText: effectiveWatermark,
                    watermarkOpacity: _pdfOptions.watermarkOpacity,
                    quality: _pdfOptions.jpegQuality,
                  ),
          icon: const Icon(Icons.image_outlined, size: 20),
          label: Text(
            _destination == ExportDestination.save ? '保存当前页图片' : '导出当前页图片',
          ),
        ),
        if (widget.onExportAllImages != null && widget.pageCount > 1) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.busy
                ? null
                : () => widget.onExportAllImages!(
                      _destination,
                      customFileName: effectiveTitle,
                      watermarkText: effectiveWatermark,
                      watermarkOpacity: _pdfOptions.watermarkOpacity,
                      quality: _pdfOptions.jpegQuality,
                      saveToFolder: false,
                    ),
            icon: const Icon(Icons.folder_zip_outlined, size: 20),
            label: Text(
              _destination == ExportDestination.save
                  ? '保存全部页图片（ZIP）'
                  : '打包分享全部页图片（ZIP）',
            ),
          ),
          if (_destination == ExportDestination.save) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.busy
                  ? null
                  : () => widget.onExportAllImages!(
                        _destination,
                        customFileName: effectiveTitle,
                        watermarkText: effectiveWatermark,
                        watermarkOpacity: _pdfOptions.watermarkOpacity,
                        quality: _pdfOptions.jpegQuality,
                        saveToFolder: true,
                      ),
              icon: const Icon(Icons.drive_file_move_outlined, size: 20),
              label: const Text('逐张保存到指定文件夹'),
            ),
          ],
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: pal.inkMuted,
      ),
    );
  }
}
