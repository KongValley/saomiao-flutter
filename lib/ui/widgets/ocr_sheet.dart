import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/file_export.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';

class OcrResultSheet extends StatefulWidget {
  const OcrResultSheet({
    super.key,
    required this.controller,
  });

  final ScannerController controller;

  @override
  State<OcrResultSheet> createState() => _OcrResultSheetState();
}

class _OcrResultSheetState extends State<OcrResultSheet> {
  late final TextEditingController _textController;
  String? _boundPageId;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    _syncFromPage();
    final page = widget.controller.currentPage;
    if (page != null && page.ocr == null && !widget.controller.isBusy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recognizeCurrent();
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _syncFromPage() {
    final page = widget.controller.currentPage;
    if (page == null) return;
    if (_boundPageId != page.id) {
      _boundPageId = page.id;
      _textController.text = page.ocr?.text ?? '';
    }
  }

  Future<void> _recognizeCurrent() async {
    final page = widget.controller.currentPage;
    if (page == null) return;
    final res = await widget.controller.recognizePageOcr(page);
    if (mounted && res != null) {
      _textController.text = res.text;
      if (res.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未识别到清晰文字，可尝试调高对比度后重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final page = widget.controller.currentPage;
        if (page == null) return const SizedBox.shrink();
        _syncFromPage();
        final busy = widget.controller.isBusy;
        final linesCount = page.ocr?.lines.length ?? 0;

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本地离线 OCR 识字',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: pal.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '识别后自动写入双层可搜索 PDF（共 $linesCount 行定位框）',
                          style: TextStyle(fontSize: 13, color: pal.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.controller.busyLabel,
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
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 160, maxHeight: 280),
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  minLines: 7,
                  onChanged: (val) => widget.controller.updatePageOcrText(page.id, val),
                  decoration: InputDecoration(
                    hintText: '点击下方「识别当前页」开始离线提取文字（可手动修改纠错）',
                    filled: true,
                    fillColor: pal.surfaceLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: pal.outline),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : _recognizeCurrent,
                    icon: const Icon(Icons.document_scanner_outlined, size: 18),
                    label: const Text('识别当前页'),
                  ),
                  if (widget.controller.pages.length >= 2)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : widget.controller.recognizeAllPagesOcr,
                      icon: const Icon(Icons.auto_stories_outlined, size: 18),
                      label: Text('识别全部 (${widget.controller.pages.length})'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _textController.text.trim().isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: _textController.text.trim()),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制全部识别文字')),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('复制'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || _textController.text.trim().isEmpty
                        ? null
                        : () => widget.controller.exportOcrText(
                              allPages: widget.controller.pages.length > 1,
                              destination: ExportDestination.save,
                            ),
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: const Text('保存 TXT'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
