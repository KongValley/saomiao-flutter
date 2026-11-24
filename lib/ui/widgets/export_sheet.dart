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
  });

  final int pageCount;
  final int currentIndex;
  final bool busy;
  final void Function(
    PdfOptions pdfOptions,
    bool allPages,
    ExportDestination destination,
  ) onExportPdf;
  final void Function(ExportDestination destination) onExportImage;

  @override
  State<ExportSheetContent> createState() => _ExportSheetContentState();
}

class _ExportSheetContentState extends State<ExportSheetContent> {
  bool _allPages = true;
  ExportDestination _destination = ExportDestination.share;
  PdfOptions _pdfOptions = kDefaultPdfOptions;

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

  @override
  Widget build(BuildContext context) {
    final scopeText =
        _allPages ? '全部 ${widget.pageCount} 页' : '第 ${widget.currentIndex + 1} 页';
    final margin = _pdfOptions.marginMm.round();
    final summary =
        '$scopeText · ${_paperLabels[_pdfOptions.pageSize]} · ${_orientLabels[_pdfOptions.orientation]} · 边距 ${margin}mm';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              style: const TextStyle(
                fontSize: 14,
                fontFeatures: [FontFeature.tabularFigures()],
                color: AppColors.inkSecondary,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Text(
              summary,
              style: const TextStyle(fontSize: 13, color: AppColors.inkSecondary),
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
        const Text(
          '全部在设备本地生成，不上传任何图片。',
          style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: widget.busy
              ? null
              : () => widget.onExportPdf(_pdfOptions, _allPages, _destination),
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
              : () => widget.onExportImage(_destination),
          icon: const Icon(Icons.image_outlined, size: 20),
          label: Text(
            _destination == ExportDestination.save ? '保存当前页图片' : '导出当前页图片',
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.inkMuted,
      ),
    );
  }
}
