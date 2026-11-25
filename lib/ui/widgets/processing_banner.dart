import 'package:flutter/material.dart';

import '../theme.dart';

class ProcessingBanner extends StatelessWidget {
  const ProcessingBanner({
    super.key,
    required this.visible,
    required this.label,
  });

  final bool visible;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final pal = AppColors.of(context);
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Align(
        alignment: Alignment.topRight,
        child: IgnorePointer(
          child: Material(
            color: pal.surface,
            elevation: 4,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: pal.outline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: pal.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyDocumentIllustration extends StatelessWidget {
  const EmptyDocumentIllustration({super.key, this.size = 200});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * 0.82),
      painter: _EmptyDocPainter(),
    );
  }
}

class _EmptyDocPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 240.0;
    canvas.save();
    canvas.scale(s, s);

    // 纸张卡片
    final docRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(60, 26, 120, 142),
      const Radius.circular(12),
    );
    canvas.drawRRect(docRect, Paint()..color = Colors.white);
    canvas.drawRRect(
      docRect,
      Paint()
        ..color = const Color(0xFFDBE4F3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 模拟文本行
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(76, 46, 52, 7), const Radius.circular(3.5)),
      Paint()..color = const Color(0xFFC9D7EE),
    );
    const widths = [86.0, 78.0, 88.0, 66.0, 82.0, 58.0];
    final linePaint = Paint()..color = const Color(0xFFE2EAF7);
    for (var i = 0; i < widths.length; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(76, 62.0 + i * 14, widths[i], 5),
          const Radius.circular(2.5),
        ),
        linePaint,
      );
    }

    // 蓝色四角框线
    final bracketPaint = Paint()
      ..color = AppColors.seed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;

    void corner(Path p) => canvas.drawPath(p, bracketPaint);
    corner(Path()
      ..moveTo(60, 40)
      ..lineTo(60, 34)
      ..arcToPoint(const Offset(68, 26), radius: const Radius.circular(8))
      ..lineTo(74, 26));
    corner(Path()
      ..moveTo(180, 40)
      ..lineTo(180, 34)
      ..arcToPoint(const Offset(172, 26), radius: const Radius.circular(8), clockwise: false)
      ..lineTo(166, 26));
    corner(Path()
      ..moveTo(60, 154)
      ..lineTo(60, 160)
      ..arcToPoint(const Offset(68, 168), radius: const Radius.circular(8), clockwise: false)
      ..lineTo(74, 168));
    corner(Path()
      ..moveTo(180, 154)
      ..lineTo(180, 160)
      ..arcToPoint(const Offset(172, 168), radius: const Radius.circular(8))
      ..lineTo(166, 168));

    // 右侧小圆徽标
    canvas.drawCircle(const Offset(197, 59), 13, Paint()..color = const Color(0xFFEDF3FF));
    final arrow = Paint()
      ..color = AppColors.seed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(const Offset(197, 52), const Offset(197, 66), arrow);
    canvas.drawPath(
      Path()
        ..moveTo(192.6, 61.6)
        ..lineTo(197, 66)
        ..lineTo(201.4, 61.6),
      arrow,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
