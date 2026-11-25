import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../theme.dart';

class SignatureResult {
  const SignatureResult({
    required this.name,
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  final String name;
  final Uint8List pngBytes;
  final int width;
  final int height;
}

class _InkStroke {
  _InkStroke({
    required this.color,
    required this.width,
    required this.points,
  });

  final Color color;
  final double width;
  final List<Offset> points;
}

class SignaturePadDialog extends StatefulWidget {
  const SignaturePadDialog({super.key});

  @override
  State<SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends State<SignaturePadDialog> {
  final TextEditingController _nameController = TextEditingController(text: '我的签名');
  final List<_InkStroke> _strokes = <_InkStroke>[];
  _InkStroke? _current;
  Color _inkColor = const Color(0xFF111827);
  double _strokeWidth = 4.5;
  bool _saving = false;

  static const List<({String label, Color color})> _colors = [
    (label: '纯黑', color: Color(0xFF111827)),
    (label: '钢笔蓝', color: Color(0xFF1D4ED8)),
    (label: '朱砂红', color: Color(0xFFDC2626)),
  ];

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _startStroke(Offset pos) {
    setState(() {
      _current = _InkStroke(
        color: _inkColor,
        width: _strokeWidth,
        points: <Offset>[pos],
      );
      _strokes.add(_current!);
    });
  }

  void _appendPoint(Offset pos) {
    if (_current == null) return;
    setState(() {
      _current!.points.add(pos);
    });
  }

  void _endStroke() {
    _current = null;
  }

  Future<void> _save(Size canvasSize) async {
    if (_strokes.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      const double scale = 2.0;
      final outW = math.max(100, (canvasSize.width * scale).round());
      final outH = math.max(60, (canvasSize.height * scale).round());

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      );
      canvas.scale(scale, scale);

      var minX = double.infinity;
      var minY = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;

      for (final stroke in _strokes) {
        final paint = Paint()
          ..color = stroke.color
          ..strokeWidth = stroke.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;

        for (final p in stroke.points) {
          minX = math.min(minX, p.dx - stroke.width);
          minY = math.min(minY, p.dy - stroke.width);
          maxX = math.max(maxX, p.dx + stroke.width);
          maxY = math.max(maxY, p.dy + stroke.width);
        }

        if (stroke.points.length == 1) {
          canvas.drawCircle(
            stroke.points.first,
            stroke.width * 0.5,
            Paint()..color = stroke.color,
          );
        } else {
          final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
          for (var i = 1; i < stroke.points.length - 1; i++) {
            final p0 = stroke.points[i];
            final p1 = stroke.points[i + 1];
            path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
          }
          path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
          canvas.drawPath(path, paint);
        }
      }

      final pic = recorder.endRecording();
      final fullImg = await pic.toImage(outW, outH);
      pic.dispose();
      final byteData = await fullImg.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      fullImg.dispose();
      if (byteData == null) return;

      final fullRgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final srcImg = img.Image.fromBytes(
        width: outW,
        height: outH,
        bytes: fullRgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );

      final cropX = (minX * scale - 12).floor().clamp(0, outW - 2);
      final cropY = (minY * scale - 12).floor().clamp(0, outH - 2);
      final cropR = (maxX * scale + 12).ceil().clamp(cropX + 2, outW);
      final cropB = (maxY * scale + 12).ceil().clamp(cropY + 2, outH);
      final cropped = img.copyCrop(
        srcImg,
        x: cropX,
        y: cropY,
        width: cropR - cropX,
        height: cropB - cropY,
      );
      final pngBytes = img.encodePng(cropped);
      if (!mounted) return;
      Navigator.of(context).pop(
        SignatureResult(
          name: _nameController.text.trim().isEmpty ? '我的签名' : _nameController.text.trim(),
          pngBytes: Uint8List.fromList(pngBytes),
          width: cropped.width,
          height: cropped.height,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = AppColors.of(context);
    Size latestCanvasSize = const Size(420, 220);

    return Dialog(
      backgroundColor: pal.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '手写电子签名',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: pal.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '签名名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final c in _colors) ...[
                    ChoiceChip(
                      label: Text(c.label),
                      selected: _inkColor == c.color,
                      avatar: CircleAvatar(backgroundColor: c.color, radius: 7),
                      onSelected: (_) => setState(() => _inkColor = c.color),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Spacer(),
                  IconButton(
                    tooltip: '撤销上一笔',
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() => _strokes.removeLast()),
                    icon: const Icon(Icons.undo_rounded),
                  ),
                  IconButton(
                    tooltip: '重写',
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() => _strokes.clear()),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('笔锋粗细', style: TextStyle(fontSize: 13, color: pal.inkSecondary)),
                  Expanded(
                    child: Slider(
                      value: _strokeWidth,
                      min: 2.0,
                      max: 9.0,
                      divisions: 14,
                      onChanged: (v) => setState(() => _strokeWidth = v),
                    ),
                  ),
                ],
              ),
              Container(
                height: 210,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: pal.outline, width: 1.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    latestCanvasSize = constraints.biggest;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (d) => _startStroke(d.localPosition),
                      onPanUpdate: (d) => _appendPoint(d.localPosition),
                      onPanEnd: (_) => _endStroke(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_strokes.isEmpty)
                            const Center(
                              child: Text(
                                '在此区域书写签名（透明底 PNG，可反复使用）',
                                style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                              ),
                            ),
                          CustomPaint(
                            painter: _SignaturePadPainter(_strokes),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
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
                    child: FilledButton(
                      onPressed: _strokes.isEmpty || _saving
                          ? null
                          : () => _save(latestCanvasSize),
                      child: Text(_saving ? '保存中…' : '保存签名'),
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

class _SignaturePadPainter extends CustomPainter {
  const _SignaturePadPainter(this.strokes);

  final List<_InkStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first,
          stroke.width * 0.5,
          Paint()..color = stroke.color,
        );
        continue;
      }
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length - 1; i++) {
        final p0 = stroke.points[i];
        final p1 = stroke.points[i + 1];
        path.quadraticBezierTo(p0.dx, p0.dy, (p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      }
      path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePadPainter oldDelegate) => true;
}
