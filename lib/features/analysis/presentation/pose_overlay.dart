import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../models/pose_models.dart';

const poseConnections = <(int, int)>[
  (11, 12),
  (11, 13),
  (13, 15),
  (12, 14),
  (14, 16),
  (11, 23),
  (12, 24),
  (23, 24),
  (23, 25),
  (25, 27),
  (24, 26),
  (26, 28),
  (27, 29),
  (29, 31),
  (28, 30),
  (30, 32),
];

class PoseOverlay extends CustomPainter {
  PoseOverlay({
    required this.bodies,
    required this.target,
    this.showCandidates = true,
  });
  final List<PoseBody> bodies;
  final PoseBody? target;
  final bool showCandidates;

  @override
  void paint(Canvas canvas, Size size) {
    if (showCandidates) {
      for (var i = 0; i < bodies.length; i++) {
        final body = bodies[i];
        if (!body.usable) continue;
        final b = body.bounds;
        final rect = Rect.fromLTRB(
          b.left * size.width,
          b.top * size.height,
          b.right * size.width,
          b.bottom * size.height,
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.white70
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        final label = TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: const TextStyle(
              color: Colors.black,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final offset = Offset(
          rect.left.clamp(0, math.max(0, size.width - 20)),
          rect.top.clamp(0, math.max(0, size.height - 22)),
        );
        canvas.drawRect(
          offset & const Size(20, 22),
          Paint()..color = Colors.white,
        );
        label.paint(canvas, offset + const Offset(5, 2));
      }
    }
    final body = target;
    if (body == null) return;
    final paint = Paint()
      ..color = const Color(0xffb7dc8f)
      ..strokeWidth = 2.5;
    Offset at(PosePoint p) => Offset(p.x * size.width, p.y * size.height);
    // 신뢰도가 낮은 관절을 연결하면 엉뚱한 선이 생기므로 양쪽이 보일 때만 그립니다.
    for (final (a, b) in poseConnections) {
      if (body.points[a].reliable && body.points[b].reliable) {
        canvas.drawLine(at(body.points[a]), at(body.points[b]), paint);
      }
    }
    for (final p in body.points.where((p) => p.reliable)) {
      canvas.drawCircle(at(p), 3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant PoseOverlay oldDelegate) =>
      bodies != oldDelegate.bodies ||
      target != oldDelegate.target ||
      showCandidates != oldDelegate.showCandidates;
}
