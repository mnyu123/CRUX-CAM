import 'package:flutter/material.dart';

import '../models/crop_models.dart';

/// 영상 픽셀을 다시 인코딩하지 않고 원본의 표시 위치와 크기만 바꿔 미리봅니다.
class CropViewport extends StatelessWidget {
  const CropViewport({
    super.key,
    required this.rect,
    required this.sourceAspect,
    required this.child,
  });
  final CropRect rect;
  final double sourceAspect;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth / rect.width;
      final height = width / sourceAspect;
      return ClipRect(
        child: Stack(
          children: [
            Positioned(
              left: -rect.left * width,
              top: -rect.top * height,
              width: width,
              height: height,
              child: child,
            ),
          ],
        ),
      );
    },
  );
}

class CropOverlay extends CustomPainter {
  const CropOverlay(this.rect);
  final CropRect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final crop = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(crop);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: .4));
    canvas.drawRect(
      crop,
      Paint()
        ..color = const Color(0xffb7dc8f)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CropOverlay oldDelegate) =>
      rect != oldDelegate.rect;
}
