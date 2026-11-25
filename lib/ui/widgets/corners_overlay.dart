import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/detect.dart';
import '../../engine/options.dart';
import '../../state/page_models.dart';
import '../theme.dart';

class CornersOverlay extends StatefulWidget {
  const CornersOverlay({
    super.key,
    required this.page,
    required this.sourceBytesFuture,
    required this.onCancel,
    required this.onApply,
    required this.onAutoDetect,
    required this.onToast,
  });

  final PageItem page;
  final Future<Uint8List> sourceBytesFuture;
  final VoidCallback onCancel;
  final void Function(List<CornerPoint> corners) onApply;
  final Future<DetectCornersResult> Function() onAutoDetect;
  final void Function(String message, {bool warn, bool error}) onToast;

  @override
  State<CornersOverlay> createState() => _CornersOverlayState();
}

class _CornersOverlayState extends State<CornersOverlay> {
  late List<Offset> _points;
  bool _detecting = false;
  int _editEpoch = 0;
  int _activeIndex = -1;
  ui.Image? _decodedUiImage;
  Uint8List? _sourceBytes;
  String? _loadError;

  static const double _handleHitSize = 48.0;
  static const double _edgePad = 28.0;

  @override
  void initState() {
    super.initState();
    final initial = widget.page.options.corners ?? fullCorners;
    _points = initial
        .map((p) => Offset(p.x.clamp(0.0, 1.0), p.y.clamp(0.0, 1.0)))
        .toList();
    _loadSource();
  }

  @override
  void dispose() {
    _decodedUiImage?.dispose();
    super.dispose();
  }

  Future<void> _loadSource() async {
    try {
      final bytes = await widget.sourceBytesFuture;
      if (!mounted) return;
      _sourceBytes = bytes;
      setState(() {});
      // 解码一份 ui.Image 给拖动放大镜用（失败不影响底图显示）
      ui.Codec? codec;
      ui.FrameInfo? frame;
      try {
        codec = await ui.instantiateImageCodec(bytes, targetWidth: 1200);
        frame = await codec.getNextFrame();
        if (mounted) {
          final img = frame.image;
          frame = null;
          setState(() => _decodedUiImage = img);
        }
      } catch (_) {
        // Ignore loupe decode failure; main preview uses Image.memory.
      } finally {
        frame?.image.dispose();
        codec?.dispose();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadError = '原图读取失败，请重试');
      }
    }
  }

  double _quadArea(List<Offset> pts) {
    var area = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % 4];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    return area.abs() / 2.0;
  }

  Future<void> _handleAutoDetect() async {
    if (_detecting) return;
    final startEpoch = _editEpoch;
    setState(() => _detecting = true);
    try {
      final result = await widget.onAutoDetect();
      if (!mounted || _editEpoch != startEpoch) return;
      if (result.corners.length != 4) {
        widget.onToast('没能识别出纸张边缘，请手动调整', error: true);
        return;
      }
      setState(() {
        _points = result.corners
            .map((c) => Offset(c.x.clamp(0.0, 1.0), c.y.clamp(0.0, 1.0)))
            .toList();
      });
      final conf = (result.confidence * 100).round();
      if (conf < 40) {
        widget.onToast('识别结果不太确定，请检查四个角', warn: true);
      } else {
        widget.onToast('已自动识别纸张边缘');
      }
    } catch (err) {
      if (mounted && _editEpoch == startEpoch) {
        widget.onToast(
          err is StateError ? err.message : '自动检测失败，请手动调整',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _handleReset() {
    setState(() {
      _editEpoch++;
      _points = fullCorners.map((p) => Offset(p.x, p.y)).toList();
    });
    widget.onToast('已恢复整幅画面');
  }

  void _handleApply() {
    if (_quadArea(_points) < 0.02) {
      widget.onToast('选区太小，请把四个角拉开一些', warn: true);
      return;
    }
    final candidate = _points
        .map((p) => CornerPoint(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0)))
        .toList(growable: false);
    if (!isValidConvexQuad(candidate, minArea: 0.02)) {
      widget.onToast('选区不能交叉或内凹，请重新调整四个角', warn: true);
      return;
    }
    widget.onApply(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
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
                  onPressed: widget.onCancel,
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
                        '四角校正',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEEF3FF),
                        ),
                      ),
                      Text(
                        '拖动圆点贴合纸张四个边角',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0x94E9EEFB),
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: _handleApply,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 44),
                  ),
                  child: const Text('应用'),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stageW = math.max(80.0, constraints.maxWidth - _edgePad * 2);
                final stageH = math.max(80.0, constraints.maxHeight - _edgePad * 2);
                final srcW = math.max(1, widget.page.sourceW).toDouble();
                final srcH = math.max(1, widget.page.sourceH).toDouble();
                final scale = math.min(stageW / srcW, stageH / srcH);
                final imgW = srcW * scale;
                final imgH = srcH * scale;
                final imgLeft = _edgePad + (stageW - imgW) / 2.0;
                final imgTop = _edgePad + (stageH - imgH) / 2.0;
                final imageRect = Rect.fromLTWH(imgLeft, imgTop, imgW, imgH);

                final screenPts = _points
                    .map(
                      (p) => Offset(
                        imageRect.left + p.dx * imageRect.width,
                        imageRect.top + p.dy * imageRect.height,
                      ),
                    )
                    .toList(growable: false);

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_loadError != null)
                      Center(
                        child: Text(
                          _loadError!,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      )
                    else if (_sourceBytes != null)
                      Positioned.fromRect(
                        rect: imageRect,
                        child: Image.memory(
                          _sourceBytes!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      )
                    else
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _CornersScrimPainter(
                          points: screenPts,
                          activeIndex: _activeIndex,
                        ),
                      ),
                    ),
                    for (var i = 0; i < 4; i++)
                      Positioned(
                        left: screenPts[i].dx - _handleHitSize / 2,
                        top: screenPts[i].dy - _handleHitSize / 2,
                        width: _handleHitSize,
                        height: _handleHitSize,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => setState(() {
                            _editEpoch++;
                            _activeIndex = i;
                          }),
                          onPanUpdate: (details) {
                            setState(() {
                              _editEpoch++;
                              final nx = (_points[i].dx + details.delta.dx / imageRect.width)
                                  .clamp(0.0, 1.0);
                              final ny = (_points[i].dy + details.delta.dy / imageRect.height)
                                  .clamp(0.0, 1.0);
                              _points[i] = Offset(nx, ny);
                            });
                          },
                          onPanEnd: (_) => setState(() => _activeIndex = -1),
                          onPanCancel: () => setState(() => _activeIndex = -1),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              width: _activeIndex == i ? 28 : 22,
                              height: _activeIndex == i ? 28 : 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _activeIndex == i
                                    ? const Color(0x8C60A5FA)
                                    : Colors.white.withValues(alpha: 0.2),
                                border: Border.all(
                                  color: _activeIndex == i
                                      ? const Color(0xFFBFDBFE)
                                      : Colors.white,
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.seed.withValues(alpha: 0.65),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 拖动时的局部放大镜（放在对侧角落，防止手指遮挡）
                    if (_activeIndex >= 0 && _decodedUiImage != null)
                      Positioned(
                        top: 14,
                        left: _points[_activeIndex].dx < 0.5 ? null : 14,
                        right: _points[_activeIndex].dx < 0.5 ? 14 : null,
                        child: IgnorePointer(
                          child: Container(
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2.5),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black54,
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: CustomPaint(
                              painter: _LoupePainter(
                                image: _decodedUiImage!,
                                normalizedPoint: _points[_activeIndex],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(14, 10, 14, bottomPad + 14),
            decoration: BoxDecoration(
              color: const Color(0xEB0B1220),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _detecting ? null : _handleAutoDetect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      minimumSize: const Size(0, 48),
                    ),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 19),
                    label: Text(_detecting ? '识别中…' : '自动检测'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _handleReset,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      minimumSize: const Size(0, 48),
                    ),
                    icon: const Icon(Icons.restart_alt_rounded, size: 19),
                    label: const Text('重置'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }
}

class _CornersScrimPainter extends CustomPainter {
  const _CornersScrimPainter({
    required this.points,
    required this.activeIndex,
  });

  final List<Offset> points;
  final int activeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final quadPath = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    final outer = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(quadPath, Offset.zero);

    canvas.drawPath(
      outer,
      Paint()..color = const Color(0x8F070C18),
    );

    // 透视三分网格辅助线
    final gridPaint = Paint()
      ..color = const Color(0x5593C5FD)
      ..strokeWidth = 1;
    for (final t in const [1 / 3, 2 / 3]) {
      final top = Offset.lerp(points[0], points[1], t)!;
      final bot = Offset.lerp(points[3], points[2], t)!;
      canvas.drawLine(top, bot, gridPaint);

      final left = Offset.lerp(points[0], points[3], t)!;
      final right = Offset.lerp(points[1], points[2], t)!;
      canvas.drawLine(left, right, gridPaint);
    }

    canvas.drawPath(
      quadPath,
      Paint()
        ..color = const Color(0xFF93C5FD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
  }

  @override
  bool shouldRepaint(covariant _CornersScrimPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.activeIndex != activeIndex;
}

class _LoupePainter extends CustomPainter {
  const _LoupePainter({
    required this.image,
    required this.normalizedPoint,
  });

  final ui.Image image;
  final Offset normalizedPoint;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.darkStage);
    final cx = normalizedPoint.dx * image.width;
    final cy = normalizedPoint.dy * image.height;
    final sampleHalf = math.min(image.width, image.height) * 0.08;
    final src = Rect.fromLTWH(
      cx - sampleHalf,
      cy - sampleHalf,
      sampleHalf * 2,
      sampleHalf * 2,
    );
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final crossPaint = Paint()
      ..color = const Color(0xFF60A5FA)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      crossPaint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      crossPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LoupePainter oldDelegate) =>
      oldDelegate.normalizedPoint != normalizedPoint || oldDelegate.image != image;
}
