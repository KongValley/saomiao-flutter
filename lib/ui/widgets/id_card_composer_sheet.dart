import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../engine/options.dart';
import '../../engine/pdf.dart';
import '../../io/app_storage.dart';
import '../../io/file_export.dart';
import '../../io/image_acquisition.dart';
import '../../io/pixel_io.dart';
import '../../jobs/render_jobs.dart';
import '../../state/page_models.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';
import 'corners_overlay.dart';

class _CardSlot {
  _CardSlot({
    required this.name,
    required this.bytes,
    required this.width,
    required this.height,
    required this.options,
  });

  final String name;
  final Uint8List bytes;
  final int width;
  final int height;
  ScanOptions options;
}

class IdCardComposerScreen extends StatefulWidget {
  const IdCardComposerScreen({
    super.key,
    required this.controller,
  });

  final ScannerController controller;

  @override
  State<IdCardComposerScreen> createState() => _IdCardComposerScreenState();
}

class _IdCardComposerScreenState extends State<IdCardComposerScreen> {
  final ImageAcquisition _acq = ImageAcquisition();
  final RenderJobs _jobs = RenderJobs(storage: MemoryAppStorage());
  final TextEditingController _watermarkCtrl =
      TextEditingController(text: '仅供办理业务使用，复印无效');

  IdCardTemplate _template = IdCardTemplate.idCard;
  ScanMode _mode = ScanMode.color;
  bool _enableWatermark = false;
  _CardSlot? _front;
  _CardSlot? _back;
  Uint8List? _composedBytes;
  bool _busy = false;
  String _busyText = '';

  @override
  void dispose() {
    _watermarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickSlot(bool isFront, {required bool useCamera}) async {
    try {
      PickedImageEntry? entry;
      if (useCamera) {
        entry = await _acq.takePhotoEntry();
      } else {
        final entries = await _acq.pickFromGalleryEntries(limit: 1);
        if (entries.isNotEmpty) entry = entries.first;
      }
      if (entry == null) return;
      final bytes = await entry.readAsBytes();
      final size = await probeImageSize(bytes);
      if (size == null) return;
      await _assignSlot(isFront, entry.name, bytes, size.width, size.height);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$err')),
      );
    }
  }

  Future<void> _pickFromExistingPage(bool isFront) async {
    final pages = widget.controller.pages;
    if (pages.isEmpty) return;
    final selected = await showDialog<PageItem>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从当前文档选页'),
        content: SizedBox(
          width: 340,
          height: 280,
          child: ListView.builder(
            itemCount: pages.length,
            itemBuilder: (_, idx) {
              final p = pages[idx];
              final thumb = widget.controller.thumbnailOf(p.id);
              return ListTile(
                leading: thumb != null
                    ? Image.memory(thumb, width: 40, height: 52, fit: BoxFit.cover)
                    : const Icon(Icons.description_outlined),
                title: Text('第 ${idx + 1} 页 · ${p.name}', maxLines: 1),
                onTap: () => Navigator.of(ctx).pop(p),
              );
            },
          ),
        ),
      ),
    );
    if (selected == null) return;
    final bytes = await widget.controller.readSourceBytes(selected);
    await _assignSlot(
      isFront,
      selected.name,
      bytes,
      selected.sourceW,
      selected.sourceH,
      baseOptions: selected.options,
    );
  }

  Future<void> _assignSlot(
    bool isFront,
    String name,
    Uint8List bytes,
    int w,
    int h, {
    ScanOptions? baseOptions,
  }) async {
    var opts = baseOptions ??
        ScanOptions(
          mode: _mode,
          shadow: _mode == ScanMode.color ? 12 : 58,
          contrast: 54,
        );
    // 自动检测卡证四角
    if (opts.corners == null) {
      try {
        final tempStorage = MemoryAppStorage();
        final uri = await tempStorage.saveSourceBytes(bytes, 'slot', name);
        final tempPage = createPage(
          id: 'slot',
          name: name,
          sourceUri: uri,
          sourceW: w,
          sourceH: h,
        );
        final detected = await RenderJobs(storage: tempStorage).detectCornersTask(tempPage);
        if (detected.confidence >= 0.35) {
          opts = opts.copyWith(corners: detected.corners);
        }
      } catch (_) {}
    }

    final slot = _CardSlot(
      name: name,
      bytes: bytes,
      width: w,
      height: h,
      options: opts.copyWith(mode: _mode),
    );
    setState(() {
      if (isFront) {
        _front = slot;
      } else {
        _back = slot;
      }
      _composedBytes = null;
    });
    if (_front != null && _back != null) {
      await _generatePreview();
    }
  }

  Future<void> _editSlotCorners(bool isFront) async {
    final slot = isFront ? _front : _back;
    if (slot == null) return;
    final tempStorage = MemoryAppStorage();
    final uri = await tempStorage.saveSourceBytes(slot.bytes, 'slot_edit', slot.name);
    final tempPage = createPage(
      id: 'slot_edit',
      name: slot.name,
      sourceUri: uri,
      sourceW: slot.width,
      sourceH: slot.height,
      options: slot.options,
    );
    final tempJobs = RenderJobs(storage: tempStorage);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeCtx) => CornersOverlay(
          page: tempPage,
          sourceBytesFuture: Future.value(slot.bytes),
          onCancel: () => Navigator.of(routeCtx).pop(),
          onApply: (corners) {
            Navigator.of(routeCtx).pop();
            setState(() {
              slot.options = slot.options.copyWith(corners: corners);
              _composedBytes = null;
            });
            if (_front != null && _back != null) _generatePreview();
          },
          onAutoDetect: () => tempJobs.detectCornersTask(tempPage),
          onToast: (msg, {warn = false, error = false}) {},
        ),
      ),
    );
  }

  Future<void> _generatePreview() async {
    if (_front == null || _back == null || _busy) return;
    setState(() {
      _busy = true;
      _busyText = '正在合成 A4 拼版…';
    });
    try {
      final bytes = await _jobs.composeIdCardTask(
        frontBytes: _front!.bytes,
        frontOptions: _front!.options.copyWith(mode: _mode),
        backBytes: _back!.bytes,
        backOptions: _back!.options.copyWith(mode: _mode),
        template: _template,
        watermarkText: _enableWatermark ? _watermarkCtrl.text.trim() : null,
      );
      if (mounted) setState(() => _composedBytes = bytes);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('拼版生成失败：$err')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportDirectPdf() async {
    if (_composedBytes == null) await _generatePreview();
    if (_composedBytes == null) return;
    setState(() {
      _busy = true;
      _busyText = '正在导出拼版 PDF…';
    });
    try {
      final pdfBytes = buildPdf(
        <PdfPageInput>[PdfPageInput(jpegBytes: _composedBytes!)],
        PdfOptions(title: _template.label, marginMm: 0),
      );
      final feedback = await const FileExporter().deliver(
        storage: createAppStorage(),
        bytes: pdfBytes,
        fileName: '${_template.label}_${pdfTimestamp()}.pdf',
        mimeType: 'application/pdf',
        destination: ExportDestination.save,
      );
      if (mounted && feedback.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(feedback)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final supportsCamera = widget.controller.supportsCamera;

    return Scaffold(
      appBar: AppBar(
        title: const Text('证件 / 双面拼版'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '排版模板',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.inkMuted),
          ),
          const SizedBox(height: 8),
          SegmentedButton<IdCardTemplate>(
            showSelectedIcon: false,
            segments: IdCardTemplate.values
                .map((t) => ButtonSegment(value: t, label: Text(t.label)))
                .toList(growable: false),
            selected: <IdCardTemplate>{_template},
            onSelectionChanged: (s) {
              setState(() => _template = s.first);
              if (_front != null && _back != null) _generatePreview();
            },
          ),
          const SizedBox(height: 6),
          Text(_template.desc, style: TextStyle(fontSize: 12, color: pal.inkMuted)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildSlotCard(
                  title: _template == IdCardTemplate.twoUp ? '上半页' : '正面（人像面）',
                  slot: _front,
                  isFront: true,
                  supportsCamera: supportsCamera,
                  pal: pal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSlotCard(
                  title: _template == IdCardTemplate.twoUp ? '下半页' : '反面（国徽面）',
                  slot: _back,
                  isFront: false,
                  supportsCamera: supportsCamera,
                  pal: pal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '画面风格',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.inkMuted),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ScanMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ScanMode.color, label: Text('彩色原貌')),
              ButtonSegment(value: ScanMode.gray, label: Text('灰度')),
              ButtonSegment(value: ScanMode.bw, label: Text('黑白')),
            ],
            selected: <ScanMode>{_mode},
            onSelectionChanged: (s) {
              setState(() => _mode = s.first);
              if (_front != null && _back != null) _generatePreview();
            },
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('添加防盗用斜向水印'),
                    subtitle: const Text('保护证件信息，防止被挪作他用'),
                    value: _enableWatermark,
                    onChanged: (v) {
                      setState(() => _enableWatermark = v);
                      if (_front != null && _back != null) _generatePreview();
                    },
                  ),
                  if (_enableWatermark) ...[
                    TextField(
                      controller: _watermarkCtrl,
                      decoration: const InputDecoration(
                        labelText: '水印文字',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        if (_front != null && _back != null) _generatePreview();
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final preset in const [
                          '仅供办理业务使用，复印无效',
                          '仅限实名认证使用',
                          '仅用于银行开户使用',
                        ])
                          ActionChip(
                            label: Text(preset, style: const TextStyle(fontSize: 12)),
                            onPressed: () {
                              _watermarkCtrl.text = preset;
                              if (_front != null && _back != null) _generatePreview();
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(_busyText, style: TextStyle(color: pal.inkSecondary)),
                ],
              ),
            )
          else if (_composedBytes != null) ...[
            Text(
              'A4 拼版预览',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.inkMuted),
            ),
            const SizedBox(height: 8),
            Container(
              height: 360,
              decoration: BoxDecoration(
                color: pal.previewBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: pal.outline),
              ),
              padding: const EdgeInsets.all(12),
              child: Image.memory(_composedBytes!, fit: BoxFit.contain),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: pal.surface,
            border: Border(top: BorderSide(color: pal.outline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _front == null || _back == null || _busy
                      ? null
                      : () async {
                          final nav = Navigator.of(context);
                          if (_composedBytes == null) await _generatePreview();
                          if (_composedBytes == null || !mounted) return;
                          await widget.controller.importComposedCardPage(
                            jpegBytes: _composedBytes!,
                            name: '${_template.label}.jpg',
                          );
                          if (mounted) nav.pop();
                        },
                  icon: const Icon(Icons.add_to_photos_outlined, size: 19),
                  label: const Text('加入当前文档'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _front == null || _back == null || _busy
                      ? null
                      : _exportDirectPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 19),
                  label: const Text('直接保存 PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlotCard({
    required String title,
    required _CardSlot? slot,
    required bool isFront,
    required bool supportsCamera,
    required AppThemePalette pal,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pal.ink),
            ),
            const SizedBox(height: 8),
            Container(
              height: 110,
              decoration: BoxDecoration(
                color: pal.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: slot != null
                  ? RotatedBox(
                      quarterTurns: (slot.options.rotate ~/ 90) % 4,
                      child: Image.memory(slot.bytes, fit: BoxFit.cover),
                    )
                  : Center(
                      child: Icon(Icons.credit_card_outlined, size: 32, color: pal.inkMuted),
                    ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                if (supportsCamera)
                  IconButton.filledTonal(
                    tooltip: '拍照',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _pickSlot(isFront, useCamera: true),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  ),
                IconButton.filledTonal(
                  tooltip: '相册/文件',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pickSlot(isFront, useCamera: false),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                ),
                if (widget.controller.hasPages)
                  IconButton.filledTonal(
                    tooltip: '从文档选页',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _pickFromExistingPage(isFront),
                    icon: const Icon(Icons.collections_bookmark_outlined, size: 18),
                  ),
                if (slot != null) ...[
                  IconButton(
                    tooltip: '四角校正',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _editSlotCorners(isFront),
                    icon: const Icon(Icons.crop_free_rounded, size: 18),
                  ),
                  IconButton(
                    tooltip: '旋转 90°',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        slot.options = slot.options.copyWith(
                          rotate: (slot.options.rotate + 90) % 360,
                        );
                        _composedBytes = null;
                      });
                      if (_front != null && _back != null) _generatePreview();
                    },
                    icon: const Icon(Icons.rotate_right_rounded, size: 18),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
