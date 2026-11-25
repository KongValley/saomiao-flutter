import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../engine/options.dart';
import '../../state/page_models.dart';
import '../../state/scanner_controller.dart';
import '../theme.dart';
import 'signature_pad_dialog.dart';

class AnnotateOverlay extends StatefulWidget {
  const AnnotateOverlay({
    super.key,
    required this.page,
    required this.baseImageFuture,
    required this.controller,
  });

  final PageItem page;
  final Future<({Uint8List bytes, int width, int height})> baseImageFuture;
  final ScannerController controller;

  @override
  State<AnnotateOverlay> createState() => _AnnotateOverlayState();
}

enum _ToolMode {
  eraseWhite('涂白擦除', Icons.cleaning_services_outlined, StrokeKind.eraseWhite),
  redactBlack('黑笔打码', Icons.edit_off_outlined, StrokeKind.redactBlack),
  highlightYellow('黄荧光笔', Icons.highlight_outlined, StrokeKind.highlightYellow),
  highlightRed('红批注笔', Icons.brush_outlined, StrokeKind.highlightRed),
  highlightBlue('蓝批注笔', Icons.draw_outlined, StrokeKind.highlightBlue),
  signature('电子签名', Icons.gesture_rounded, null);

  const _ToolMode(this.label, this.icon, this.strokeKind);
  final String label;
  final IconData icon;
  final StrokeKind? strokeKind;
}

class _AnnotateOverlayState extends State<AnnotateOverlay> {
  _ToolMode _tool = _ToolMode.eraseWhite;
  double _strokeWidth = 0.025;
  late List<AnnotationStroke> _strokes;
  late List<SignaturePlacement> _signatures;
  List<CornerPoint>? _activePoints;
  int _selectedSigIndex = -1;

  Uint8List? _baseBytes;
  int _baseW = 1;
  int _baseH = 1;
  String? _loadError;
  final Map<String, Uint8List> _sigBytes = <String, Uint8List>{};

  @override
  void initState() {
    super.initState();
    _strokes = List<AnnotationStroke>.of(widget.page.annotations.strokes);
    _signatures = List<SignaturePlacement>.of(widget.page.annotations.signatures);
    _loadBase();
    _loadUsedSignatures();
  }

  Future<void> _loadBase() async {
    try {
      final res = await widget.baseImageFuture;
      if (!mounted) return;
      setState(() {
        _baseBytes = res.bytes;
        _baseW = math.max(1, res.width);
        _baseH = math.max(1, res.height);
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '画面加载失败，请重试');
    }
  }

  Future<void> _loadUsedSignatures() async {
    for (final pl in _signatures) {
      if (_sigBytes.containsKey(pl.signatureId)) continue;
      final bytes = await widget.controller.readSignatureBytes(pl.signatureId);
      if (bytes != null && mounted) {
        setState(() => _sigBytes[pl.signatureId] = bytes);
      }
    }
  }

  Future<void> _pickOrCreateSignature() async {
    final pal = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheetCtx) {
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final sigs = widget.controller.signatures;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择或手写电子签名',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: pal.ink,
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () async {
                            final res = await showDialog<SignatureResult>(
                              context: sheetCtx,
                              builder: (_) => const SignaturePadDialog(),
                            );
                            if (res == null || !mounted) return;
                            final saved = await widget.controller.saveNewSignature(
                              name: res.name,
                              pngBytes: res.pngBytes,
                              width: res.width,
                              height: res.height,
                            );
                            _sigBytes[saved.id] = res.pngBytes;
                            if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                            _addSignaturePlacement(saved);
                          },
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('手写新签名'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (sigs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          '暂无保存的签名，点击右上角「手写新签名」即可创建',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: pal.inkMuted),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: sigs.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, idx) {
                            final sig = sigs[idx];
                            return FutureBuilder<Uint8List?>(
                              future: widget.controller.readSignatureBytes(sig.id),
                              builder: (context, snap) {
                                return ListTile(
                                  tileColor: pal.surfaceLow,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: pal.outline),
                                  ),
                                  leading: Container(
                                    width: 72,
                                    height: 40,
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: snap.data != null
                                        ? Image.memory(snap.data!, fit: BoxFit.contain)
                                        : const SizedBox.shrink(),
                                  ),
                                  title: Text(sig.name),
                                  trailing: IconButton(
                                    tooltip: '删除签名',
                                    icon: Icon(Icons.delete_outline, color: pal.danger),
                                    onPressed: () =>
                                        widget.controller.deleteSignature(sig.id),
                                  ),
                                  onTap: () {
                                    if (snap.data != null) {
                                      _sigBytes[sig.id] = snap.data!;
                                    }
                                    Navigator.of(sheetCtx).pop();
                                    _addSignaturePlacement(sig);
                                  },
                                );
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _addSignaturePlacement(SavedSignature sig) {
    setState(() {
      _tool = _ToolMode.signature;
      _signatures.add(
        SignaturePlacement(
          signatureId: sig.id,
          cx: 0.72,
          cy: 0.78,
          widthRatio: 0.28,
          aspectRatio: sig.aspectRatio,
        ),
      );
      _selectedSigIndex = _signatures.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: AppColors.darkStage,
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(14, topPad + 10, 14, 10),
            decoration: BoxDecoration(
              color: const Color(0xEB0B1220),
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    minimumSize: const Size(64, 44),
                  ),
                  child: const Text('取消'),
                ),
                const Expanded(
                  child: Column(
                    children: [
                      Text(
                        '擦除打码与电子签名',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEEF3FF),
                        ),
                      ),
                      Text(
                        '非破坏性叠加，可随时修改或清除',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Color(0x94E9EEFB)),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    final next = PageAnnotations(
                      strokes: List<AnnotationStroke>.unmodifiable(_strokes),
                      signatures: List<SignaturePlacement>.unmodifiable(_signatures),
                    );
                    Navigator.of(context).pop(next);
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                  child: const Text('应用'),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const pad = 20.0;
                final stageW = math.max(80.0, constraints.maxWidth - pad * 2);
                final stageH = math.max(80.0, constraints.maxHeight - pad * 2);
                final scale = math.min(stageW / _baseW, stageH / _baseH);
                final imgW = _baseW * scale;
                final imgH = _baseH * scale;
                final imgLeft = pad + (stageW - imgW) / 2.0;
                final imgTop = pad + (stageH - imgH) / 2.0;
                final imageRect = Rect.fromLTWH(imgLeft, imgTop, imgW, imgH);

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_loadError != null)
                      Center(
                        child: Text(
                          _loadError!,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      )
                    else if (_baseBytes == null)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                    else
                      Positioned.fromRect(
                        rect: imageRect,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _selectedSigIndex = -1),
                          onPanStart: _tool.strokeKind == null
                              ? null
                              : (d) {
                                  final nx = (d.localPosition.dx / imgW).clamp(0.0, 1.0);
                                  final ny = (d.localPosition.dy / imgH).clamp(0.0, 1.0);
                                  setState(() {
                                    _selectedSigIndex = -1;
                                    _activePoints = <CornerPoint>[CornerPoint(nx, ny)];
                                  });
                                },
                          onPanUpdate: _tool.strokeKind == null
                              ? null
                              : (d) {
                                  if (_activePoints == null) return;
                                  final nx = (d.localPosition.dx / imgW).clamp(0.0, 1.0);
                                  final ny = (d.localPosition.dy / imgH).clamp(0.0, 1.0);
                                  setState(() {
                                    _activePoints!.add(CornerPoint(nx, ny));
                                  });
                                },
                          onPanEnd: _tool.strokeKind == null
                              ? null
                              : (_) {
                                  if (_activePoints != null && _activePoints!.isNotEmpty) {
                                    setState(() {
                                      _strokes.add(
                                        AnnotationStroke(
                                          kind: _tool.strokeKind!,
                                          width: _strokeWidth,
                                          points: List<CornerPoint>.unmodifiable(_activePoints!),
                                        ),
                                      );
                                      _activePoints = null;
                                    });
                                  }
                                },
                          child: Stack(
                            fit: StackFit.expand,
                            clipBehavior: Clip.none,
                            children: [
                              Image.memory(
                                _baseBytes!,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _AnnotateStrokesPainter(
                                    strokes: _strokes,
                                    activeKind: _tool.strokeKind,
                                    activeWidth: _strokeWidth,
                                    activePoints: _activePoints,
                                  ),
                                ),
                              ),
                              for (var i = 0; i < _signatures.length; i++)
                                _buildSignatureSticker(i, imgW, imgH),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPad + 12),
            decoration: BoxDecoration(
              color: const Color(0xEB0B1220),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_tool.strokeKind != null)
                  Row(
                    children: [
                      const Text(
                        '粗细',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Expanded(
                        child: Slider(
                          value: _strokeWidth,
                          min: 0.008,
                          max: 0.075,
                          onChanged: (v) => setState(() => _strokeWidth = v),
                        ),
                      ),
                      IconButton(
                        tooltip: '撤销上一笔',
                        onPressed: _strokes.isEmpty
                            ? null
                            : () => setState(() => _strokes.removeLast()),
                        icon: const Icon(Icons.undo_rounded, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: '清空全部批注',
                        onPressed: _strokes.isEmpty && _signatures.isEmpty
                            ? null
                            : () => setState(() {
                                  _strokes.clear();
                                  _signatures.clear();
                                  _selectedSigIndex = -1;
                                }),
                        icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white70),
                      ),
                    ],
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final mode in _ToolMode.values) ...[
                        ChoiceChip(
                          avatar: Icon(
                            mode.icon,
                            size: 16,
                            color: _tool == mode ? Colors.white : Colors.white70,
                          ),
                          label: Text(
                            mode.label,
                            style: TextStyle(
                              color: _tool == mode ? Colors.white : Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          selected: _tool == mode,
                          selectedColor: AppColors.seed,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                          onSelected: (_) {
                            setState(() => _tool = mode);
                            if (mode == _ToolMode.signature) {
                              _pickOrCreateSignature();
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignatureSticker(int index, double imgW, double imgH) {
    final pl = _signatures[index];
    final selected = _selectedSigIndex == index;
    final boxW = math.max(24.0, pl.widthRatio * imgW);
    final boxH = math.max(16.0, boxW * pl.aspectRatio);
    final left = pl.cx * imgW - boxW / 2;
    final top = pl.cy * imgH - boxH / 2;
    final png = _sigBytes[pl.signatureId];

    return Positioned(
      left: left,
      top: top,
      width: boxW,
      height: boxH,
      child: GestureDetector(
        onTap: () => setState(() => _selectedSigIndex = index),
        onPanUpdate: (d) {
          setState(() {
            _selectedSigIndex = index;
            _signatures[index] = pl.copyWith(
              cx: pl.cx + d.delta.dx / imgW,
              cy: pl.cy + d.delta.dy / imgH,
            );
          });
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: selected
                  ? BoxDecoration(
                      border: Border.all(color: AppColors.seed, width: 1.5),
                      color: AppColors.seed.withValues(alpha: 0.06),
                    )
                  : null,
              child: png != null
                  ? Image.memory(png, fit: BoxFit.contain)
                  : const Center(
                      child: Icon(Icons.gesture_rounded, color: AppColors.seed),
                    ),
            ),
            if (selected)
              Positioned(
                top: -12,
                right: -12,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _signatures.removeAt(index);
                    _selectedSigIndex = -1;
                  }),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            if (selected)
              Positioned(
                bottom: -12,
                right: -12,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      _signatures[index] = pl.copyWith(
                        widthRatio: pl.widthRatio + d.delta.dx / imgW,
                      );
                    });
                  },
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: AppColors.seed,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.open_in_full_rounded, size: 13, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AnnotateStrokesPainter extends CustomPainter {
  const _AnnotateStrokesPainter({
    required this.strokes,
    required this.activeKind,
    required this.activeWidth,
    required this.activePoints,
  });

  final List<AnnotationStroke> strokes;
  final StrokeKind? activeKind;
  final double activeWidth;
  final List<CornerPoint>? activePoints;

  Color _colorFor(StrokeKind kind) {
    switch (kind) {
      case StrokeKind.eraseWhite:
        return Colors.white;
      case StrokeKind.redactBlack:
        return const Color(0xFF101828);
      case StrokeKind.highlightYellow:
        return const Color(0x6BFDE047);
      case StrokeKind.highlightRed:
        return const Color(0x5CEF4444);
      case StrokeKind.highlightBlue:
        return const Color(0x573B82F6);
    }
  }

  void _paintOne(Canvas canvas, Size size, StrokeKind kind, double normWidth, List<CornerPoint> pts) {
    if (pts.isEmpty) return;
    final shortEdge = math.min(size.width, size.height);
    final strokeW = math.max(3.0, normWidth * shortEdge);
    final color = _colorFor(kind);
    if (pts.length == 1) {
      canvas.drawCircle(
        Offset(pts.first.x * size.width, pts.first.y * size.height),
        strokeW * 0.5,
        Paint()..color = color,
      );
      return;
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(pts.first.x * size.width, pts.first.y * size.height);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].x * size.width, pts[i].y * size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _paintOne(canvas, size, s.kind, s.width, s.points);
    }
    if (activeKind != null && activePoints != null) {
      _paintOne(canvas, size, activeKind!, activeWidth, activePoints!);
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotateStrokesPainter oldDelegate) => true;
}
