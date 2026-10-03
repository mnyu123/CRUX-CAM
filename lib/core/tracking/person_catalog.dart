import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';

/// 모델의 반환 순서는 인물 번호가 아닙니다. 가까운 시점의 위치·크기로 번호를 연결합니다.
/// 두 후보가 비슷하면 번호 연결을 보류하고, 오래 가려지면 새 번호를 부여합니다.
class PersonCatalog {
  List<PoseFrame> assign(List<PoseFrame> frames) {
    var nextId =
        frames.fold<int>(
          0,
          (n, f) => f.personIds.fold<int>(n, (v, id) => math.max(v, id ?? 0)),
        ) +
        1;
    final active = <int, ({PoseBody body, int time, double vx, double vy})>{};
    final output = <PoseFrame>[];
    for (final frame in frames) {
      active.removeWhere((_, value) => frame.timeMs - value.time > 2000);
      final ids = List<int?>.filled(frame.bodies.length, null);
      final claimed = <int>{};
      // 추가 영역 분석 후에도 이미 붙인 번호를 그대로 보존합니다.
      for (var i = 0; i < frame.personIds.length; i++) {
        final id = frame.personIds[i];
        if (id != null) {
          ids[i] = id;
          claimed.add(id);
        }
      }
      final matches = <({int index, int id, double cost})>[];
      for (var i = 0; i < frame.bodies.length; i++) {
        final body = frame.bodies[i];
        if (!body.usable || ids[i] != null) continue;
        for (final entry in active.entries) {
          if (claimed.contains(entry.key)) continue;
          final last = entry.value;
          final dt = math.max(0.001, (frame.timeMs - last.time) / 1000);
          final c = body.center;
          final p = last.body.center;
          final distance = math.sqrt(
            math.pow(c.x - p.x - last.vx * math.min(dt, .5), 2) +
                math.pow(c.y - p.y - last.vy * math.min(dt, .5), 2),
          );
          final gate = math.min(
            .3,
            math.max(.07, last.body.span * .45) + dt * .08,
          );
          final scale = body.span / last.body.span;
          if (distance <= gate && scale >= .55 && scale <= 1.8) {
            matches.add((
              index: i,
              id: entry.key,
              cost: distance / gate + math.log(scale).abs() * .25,
            ));
          }
        }
      }
      // 양쪽에서 가장 가까운 후보이고 차이가 충분할 때만 일대일로 연결합니다.
      matches.sort((a, b) => a.cost.compareTo(b.cost));
      for (final match in matches) {
        if (ids[match.index] != null || claimed.contains(match.id)) continue;
        final byBody = matches.where((m) => m.index == match.index).toList();
        final byId = matches.where((m) => m.id == match.id).toList();
        if (byBody.first != match ||
            byId.first != match ||
            (byBody.length > 1 && byBody[1].cost - match.cost < .22) ||
            (byId.length > 1 && byId[1].cost - match.cost < .22)) {
          continue;
        }
        ids[match.index] = match.id;
        claimed.add(match.id);
      }
      for (var i = 0; i < frame.bodies.length; i++) {
        final body = frame.bodies[i];
        if (!body.usable) continue;
        // 잠시 헷갈린 후보에 새 번호를 주면 기존 사람이 매번 다른 번호가 됩니다.
        // 이 시점은 번호 없이 남기고, 다음 시점에 다시 명확해졌을 때 연결합니다.
        if (ids[i] == null && matches.any((m) => m.index == i)) continue;
        final id = ids[i] ??= nextId++;
        final last = active[id];
        final dt = last == null
            ? 1.0
            : math.max(.001, (frame.timeMs - last.time) / 1000);
        active[id] = (
          body: body,
          time: frame.timeMs,
          vx: last == null
              ? 0
              : ((body.center.x - last.body.center.x) / dt).clamp(-.5, .5),
          vy: last == null
              ? 0
              : ((body.center.y - last.body.center.y) / dt).clamp(-.5, .5),
        );
      }
      output.add(
        PoseFrame(
          timeMs: frame.timeMs,
          bodies: frame.bodies,
          inferenceMs: frame.inferenceMs,
          preview: frame.preview,
          personIds: List.unmodifiable(ids),
        ),
      );
    }
    return List.unmodifiable(output);
  }

  /// 같은 사람을 중복 추가하지 않도록 몸통 위치와 인식 영역의 겹침을 함께 확인합니다.
  List<PoseFrame> merge(List<PoseFrame> original, List<PoseFrame> additional) {
    if (original.length != additional.length) {
      throw const FormatException('추가 분석의 프레임 시간이 일치하지 않습니다.');
    }
    return assign(
      List.generate(original.length, (i) {
        final base = original[i];
        final extra = additional[i];
        if (base.timeMs != extra.timeMs) {
          throw const FormatException('추가 분석의 프레임 시간이 일치하지 않습니다.');
        }
        final bodies = [...base.bodies];
        final ids = List<int?>.generate(
          bodies.length,
          (j) => base.personIdAt(j),
        );
        for (final body in extra.bodies.where((b) => b.usable)) {
          if (bodies.any((b) => _duplicate(b, body))) continue;
          bodies.add(body);
          ids.add(null);
        }
        return PoseFrame(
          timeMs: base.timeMs,
          bodies: List.unmodifiable(bodies),
          inferenceMs: base.inferenceMs + extra.inferenceMs,
          preview: base.preview,
          personIds: ids,
        );
      }),
    );
  }

  bool _duplicate(PoseBody a, PoseBody b) {
    if (!a.usable || !b.usable) return false;
    final distance = math.sqrt(
      math.pow(a.center.x - b.center.x, 2) +
          math.pow(a.center.y - b.center.y, 2),
    );
    final x = a.bounds;
    final y = b.bounds;
    final intersection =
        math.max(0.0, math.min(x.right, y.right) - math.max(x.left, y.left)) *
        math.max(0.0, math.min(x.bottom, y.bottom) - math.max(x.top, y.top));
    final union =
        (x.right - x.left) * (x.bottom - x.top) +
        (y.right - y.left) * (y.bottom - y.top) -
        intersection;
    return distance < math.min(a.span, b.span) * .2 &&
        union > 0 &&
        intersection / union > .4;
  }
}
