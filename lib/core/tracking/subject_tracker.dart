import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';

/// 선택한 사람의 위치와 몸의 크기를 기준으로 연결합니다.
/// 확신하기 어려운 교차나 긴 가림에서는 다른 사람으로 옮겨 가지 않고 끊김을 남깁니다.
class SubjectTracker {
  List<TrackedFrame> track(List<PoseFrame> frames, int anchor, int bodyIndex) {
    final selected = frames[anchor].bodies[bodyIndex];
    if (!selected.usable) throw const FormatException('몸통이 보이는 사람을 선택해주세요.');
    final output = List<TrackedFrame>.generate(
      frames.length,
      (i) => TrackedFrame(timeMs: frames[i].timeMs, status: TrackStatus.lost),
    );
    output[anchor] = TrackedFrame(
      timeMs: frames[anchor].timeMs,
      status: TrackStatus.tracked,
      raw: selected,
      corrected: selected,
    );
    // 중간 시점에서 사람을 선택해도 앞뒤를 따로 추적하여 영상 전체를 분석합니다.
    _walk(frames, output, anchor, selected, 1);
    _walk(frames, output, anchor, selected, -1);
    return List.unmodifiable(output);
  }

  void _walk(
    List<PoseFrame> frames,
    List<TrackedFrame> output,
    int anchor,
    PoseBody selected,
    int direction,
  ) {
    var last = selected;
    var lastTime = frames[anchor].timeMs;
    var corrected = selected;
    var vx = 0.0;
    var vy = 0.0;
    for (
      var i = anchor + direction;
      i >= 0 && i < frames.length;
      i += direction
    ) {
      final frame = frames[i];
      final gap = (frame.timeMs - lastTime).abs();
      // 오래 가려진 뒤의 재등장은 좌표만으로 동일 인물임을 보장할 수 없습니다.
      // 2초를 넘으면 자동 연결을 중단하고 사용자가 해당 시점에서 다시 선택합니다.
      if (gap > 2000) continue;
      final dt = math.max(gap / 1000, 0.001);
      final center = last.center;
      final predictedX = center.x + vx * math.min(dt, 0.5);
      final predictedY = center.y + vy * math.min(dt, 0.5);
      final gate = math.min(0.3, math.max(0.07, last.span * 0.45) + dt * 0.08);
      final matches = <({PoseBody body, double cost})>[];
      for (final body in frame.bodies.where((b) => b.usable)) {
        final c = body.center;
        final distance = math.sqrt(
          math.pow(c.x - predictedX, 2) + math.pow(c.y - predictedY, 2),
        );
        final scale = (body.span / last.span).abs();
        if (distance > gate || scale < 0.55 || scale > 1.8) continue;
        matches.add((
          body: body,
          cost: distance / gate + (math.log(scale)).abs() * 0.25,
        ));
      }
      matches.sort((a, b) => a.cost.compareTo(b.cost));
      if (matches.isEmpty) continue;
      if (matches.length > 1 && matches[1].cost - matches[0].cost < 0.22) {
        output[i] = TrackedFrame(
          timeMs: frame.timeMs,
          status: TrackStatus.ambiguous,
        );
        continue;
      }
      final current = matches.first.body;
      final c = current.center;
      vx = ((c.x - center.x) / dt).clamp(-0.5, 0.5);
      vy = ((c.y - center.y) / dt).clamp(-0.5, 0.5);
      corrected = _smooth(corrected, current, dt, gap > 600);
      output[i] = TrackedFrame(
        timeMs: frame.timeMs,
        status: TrackStatus.tracked,
        raw: current,
        corrected: corrected,
      );
      last = current;
      lastTime = frame.timeMs;
    }
  }

  PoseBody _smooth(PoseBody previous, PoseBody current, double dt, bool reset) {
    // 동작이 빠를수록 현재 좌표를 더 반영하여 과도한 보정으로 늦게 따라가지 않게 합니다.
    // 신뢰도가 낮은 관절은 숨기며, 이전 좌표를 확실한 결과처럼 계속 남기지 않습니다.
    return PoseBody(
      List.generate(33, (i) {
        final p = previous.points[i];
        final c = current.points[i];
        if (reset || !c.reliable || !p.reliable) return c;
        final speed =
            math.sqrt(math.pow(c.x - p.x, 2) + math.pow(c.y - p.y, 2)) / dt;
        final alpha = (1 - math.exp(-dt * (5 + 25 * speed))).clamp(0.2, 1.0);
        return PosePoint(
          p.x + (c.x - p.x) * alpha,
          p.y + (c.y - p.y) * alpha,
          c.z,
          c.confidence,
        );
      }),
    );
  }
}
