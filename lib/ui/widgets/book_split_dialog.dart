import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../state/page_models.dart';
import '../theme.dart';

class BookSplitResult {
  const BookSplitResult({
    required this.splitX,
    required this.keepOriginal,
  });

  final double splitX;
  final bool keepOriginal;
}

class BookSplitDialog extends StatefulWidget {
  const BookSplitDialog({
    super.key,
    required this.page,
    required this.sourceBytesFuture,
    required this.onDetectGutter,
  });

  final PageItem page;
  final Future<Uint8List> sourceBytesFuture;
  final Future<double> Function() onDetectGutter;

  @override
  State<BookSplitDialog> createState() => _BookSplitDialogState();
}

class _BookSplitDialogState extends State<BookSplitDialog> {
  double _splitX = 0.5;
  bool _keepOriginal = false;
  bool _detecting = false;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  Future<void> _initLoad() async {
    try {
      final bytes = await widget.sourceBytesFuture;
      if (mounted) setState(() => _bytes = bytes);
      await _autoGutter();
    } catch (_) {}
  }

  Future<void> _autoGutter() async {
    if (_detecting) return;
    setState(() => _detecting = true);
    try {
      final x = await widget.onDetectGutter();
      if (mounted) setState(() => _splitX = x.clamp(0.2, 0.8));
    } catch (_) {
      // keep 0.5
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    final rotTurns = (widget.page.options.rotate ~/ 90) % 4;
    final rotatedSwap = rotTurns.isOdd;
    final srcW = (rotatedSwap ? widget.page.sourceH : widget.page.sourceW).toDouble();
    final srcH = (rotatedSwap ? widget.page.sourceW : widget.page.sourceH).toDouble();

    return Dialog(
      backgroundColor: pal.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(18),
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
                          '对开书籍拆页',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: pal.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '左右拖动分界线，将对开页拆分为左页与右页两张扫描件',
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
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.darkStage,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _bytes == null
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final scale = math.min(
                              (constraints.maxWidth - 24) / math.max(1, srcW),
                              (constraints.maxHeight - 24) / math.max(1, srcH),
                            );
                            final drawW = srcW * scale;
                            final drawH = srcH * scale;
                            final left = (constraints.maxWidth - drawW) / 2;
                            final top = (constraints.maxHeight - drawH) / 2;
                            final lineX = left + drawW * _splitX;

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragUpdate: (d) {
                                final next = ((d.localPosition.dx - left) / drawW)
                                    .clamp(0.20, 0.80);
                                setState(() => _splitX = next);
                              },
                              onTapDown: (d) {
                                final next = ((d.localPosition.dx - left) / drawW)
                                    .clamp(0.20, 0.80);
                                setState(() => _splitX = next);
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Positioned(
                                    left: left,
                                    top: top,
                                    width: drawW,
                                    height: drawH,
                                    child: RotatedBox(
                                      quarterTurns: rotTurns,
                                      child: Image.memory(
                                        _bytes!,
                                        fit: BoxFit.fill,
                                        gaplessPlayback: true,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: lineX - 1.5,
                                    top: top,
                                    width: 3,
                                    height: drawH,
                                    child: Container(color: const Color(0xFF60A5FA)),
                                  ),
                                  Positioned(
                                    left: math.max(8, lineX - 16),
                                    top: top + drawH / 2 - 16,
                                    child: Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: AppColors.seed,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                      ),
                                      child: const Icon(
                                        Icons.drag_indicator_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: left + 10,
                                    top: top + 10,
                                    child: _PageTag('左页 ${(_splitX * 100).round()}%'),
                                  ),
                                  Positioned(
                                    right: left + 10,
                                    top: top + 10,
                                    child: _PageTag('右页 ${((1 - _splitX) * 100).round()}%'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : _autoGutter,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(_detecting ? '定位中…' : '自动定位中缝'),
                  ),
                  const Spacer(),
                  Text('保留原双页', style: TextStyle(fontSize: 13, color: pal.inkSecondary)),
                  Switch(
                    value: _keepOriginal,
                    onChanged: (v) => setState(() => _keepOriginal = v),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(
                        BookSplitResult(splitX: _splitX, keepOriginal: _keepOriginal),
                      ),
                      icon: const Icon(Icons.vertical_split_rounded, size: 19),
                      label: const Text('拆分为两页'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageTag extends StatelessWidget {
  const _PageTag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
