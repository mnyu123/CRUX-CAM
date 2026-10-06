import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';

/// 자세가 바뀌거나 잠시 가려져도 기존 인물 번호를 보관합니다.
/// 위치·몸 크기와 옷 색을 함께 보고, 애매한 경우 번호 연결만 보류합니다.
class PersonCatalog {
  List<PoseFrame> assign(List<PoseFrame> frames, {int firstId = 1}) {
    var nextId = math.max(
      firstId,
      frames.fold<int>(
            0,
            (n, f) => f.personIds.fold<int>(n, (v, id) => math.max(v, id ?? 0)),
          ) +
          1,
    );
    final people = <int, _Identity>{};
    final output = <PoseFrame>[];
    for (var frameIndex = 0; frameIndex < frames.length; frameIndex++) {
      final frame = frames[frameIndex];
      final ids = List<int?>.generate(frame.bodies.length, frame.personIdAt);
      final claimed = ids.whereType<int>().toSet();
      final matches = <({int index, int id, double cost})>[];
      for (var i = 0; i < frame.bodies.length; i++) {
        final body = frame.bodies[i];
        if (!body.usable || ids[i] != null) continue;
        for (final entry in people.entries) {
          if (claimed.contains(entry.key)) continue;
          final identity = entry.value;
          final gap = frame.timeMs - identity.time;
          final dt = math.max(.001, gap / 1000);
          final c = body.center;
          final p = identity.body.center;
          final distance = math.sqrt(
            math.pow(c.x - p.x - identity.vx * math.min(dt, .5), 2) +
                math.pow(c.y - p.y - identity.vy * math.min(dt, .5), 2),
          );
          final color = identity.colorDistance(body.appearance);
          // 계속 가까운 위치에서 움직이는 사람은 자세에 따라 색 표본이 바뀌어도 번호를 유지합니다.
          final continuous =
              gap <= 2000 &&
              distance <=
                  math.min(
                    .14,
                    math.max(.05, identity.body.span * .2) + dt * .1,
                  ) &&
              people.entries.every(
                (other) =>
                    other.key == entry.key ||
                    math.sqrt(
                          math.pow(c.x - other.value.body.center.x, 2) +
                              math.pow(c.y - other.value.body.center.y, 2),
                        ) >
                        distance + .12,
              );
          if (color != null && color > .65 && !continuous) {
            continue;
          }
          final colorEvidence = continuous && color != null
              ? math.min(color, .2)
              : color;
          // 팔다리를 굽히는 자세 변화만으로 새 사람을 만들지 않도록 몸 크기 제한을 완화합니다.
          final scale = body.span / identity.body.span;
          final gate = math.min(
            .45,
            math.max(.12, identity.body.span * .6) + dt * .12,
          );
          final sameColor = color != null && color < .45;
          final onlyPerson =
              people.length == 1 &&
              frame.bodies.where((b) => b.usable).length == 1;
          if (!sameColor &&
              !onlyPerson &&
              (distance > gate || scale < .25 || scale > 4)) {
            continue;
          }
          if (sameColor && gap < 600 && distance > .6) continue;
          matches.add((
            index: i,
            id: entry.key,
            cost: colorEvidence == null
                ? distance / math.max(gate, .01) + math.log(scale).abs() * .08
                : colorEvidence * 1.5 +
                      math.min(distance / math.max(gate, .01), 2) * .25,
          ));
        }
      }
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
        if (ids[i] == null) {
          // 동일 인물인지 애매한 후보에 새 번호를 붙이지 않고 다음 명확한 감지를 기다립니다.
          if (matches.any((m) => m.index == i)) continue;
          if (people.isNotEmpty && !_confirmedNew(frames, frameIndex, body)) {
            continue;
          }
          ids[i] = nextId++;
        }
        final id = ids[i]!;
        final identity = people[id];
        if (identity == null) {
          people[id] = _Identity(body, frame.timeMs);
        } else {
          identity.update(body, frame.timeMs);
        }
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

  bool _confirmedNew(List<PoseFrame> frames, int index, PoseBody body) {
    if (frames.length == 1) return true;
    // 기존 몸과 겹치는 새 후보는 중복 감지일 수 있으므로 사람 수를 늘리지 않습니다.
    if (frames[index].bodies.any(
      (other) =>
          !identical(other, body) &&
          other.usable &&
          (other.center.x - body.center.x).abs() < .12 &&
          (other.center.y - body.center.y).abs() < .12 &&
          _overlap(other, body) > .15,
    )) {
      return false;
    }
    final identity = _Identity(body, frames[index].timeMs);
    // 한 번의 잘못된 감지로 사람 수를 늘리지 않도록 위치와 옷 색을 다른 프레임에서도 확인합니다.
    for (
      var i = math.max(0, index - 2);
      i <= math.min(frames.length - 1, index + 2);
      i++
    ) {
      if (i == index ||
          (frames[i].timeMs - frames[index].timeMs).abs() > 1000) {
        continue;
      }
      if (frames[i].bodies.any(
        (b) =>
            b.usable &&
            (b.center.x - body.center.x).abs() < .12 &&
            (b.center.y - body.center.y).abs() < .12 &&
            (identity.colorDistance(b.appearance) ?? 0) < .5,
      )) {
        return true;
      }
    }
    return false;
  }

  /// 추가 영역의 후보는 별도로 번호를 연결하고 기존 최대 번호 다음에서 시작합니다.
  /// 같은 시점의 중복만 제거하여, 다른 시점의 같은 사람을 임의로 합치지 않습니다.
  List<PoseFrame> merge(List<PoseFrame> original, List<PoseFrame> additional) {
    if (original.length != additional.length) {
      throw const FormatException('추가 분석의 프레임 시간이 일치하지 않습니다.');
    }
    final nextId =
        original.fold<int>(
          0,
          (n, f) => f.personIds.fold<int>(n, (v, id) => math.max(v, id ?? 0)),
        ) +
        1;
    final extra = assign(
      List.generate(original.length, (i) {
        final base = original[i];
        final added = additional[i];
        if (base.timeMs != added.timeMs) {
          throw const FormatException('추가 분석의 프레임 시간이 일치하지 않습니다.');
        }
        return PoseFrame(
          timeMs: added.timeMs,
          inferenceMs: added.inferenceMs,
          bodies: List.unmodifiable(
            added.bodies.where(
              (b) => b.usable && !base.bodies.any((p) => _duplicate(p, b)),
            ),
          ),
        );
      }),
      firstId: nextId,
    );
    return List.unmodifiable(
      List.generate(
        original.length,
        (i) => PoseFrame(
          timeMs: original[i].timeMs,
          inferenceMs: original[i].inferenceMs + additional[i].inferenceMs,
          preview: original[i].preview,
          bodies: List.unmodifiable([
            ...original[i].bodies,
            ...extra[i].bodies,
          ]),
          personIds: List.unmodifiable([
            ...original[i].personIds,
            ...extra[i].personIds,
          ]),
        ),
      ),
    );
  }

  double _overlap(PoseBody a, PoseBody b) {
    final x = a.bounds, y = b.bounds;
    final intersection =
        math.max(0.0, math.min(x.right, y.right) - math.max(x.left, y.left)) *
        math.max(0.0, math.min(x.bottom, y.bottom) - math.max(x.top, y.top));
    final union =
        (x.right - x.left) * (x.bottom - x.top) +
        (y.right - y.left) * (y.bottom - y.top) -
        intersection;
    return union > 0 ? intersection / union : 0;
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

class _Identity {
  _Identity(this.body, this.time)
    : colors = body.appearance,
      firstColors = body.appearance;
  PoseBody body;
  int time;
  double vx = 0, vy = 0;
  List<double>? colors;
  final List<double>? firstColors;
  double? colorDistance(List<double>? value) {
    if (value == null || colors == null) return null;
    double distance(List<double> profile) {
      final sumA = profile.fold<double>(0, (a, b) => a + b);
      final sumB = value.fold<double>(0, (a, b) => a + b);
      var similarity = 0.0;
      for (var i = 0; i < profile.length; i++) {
        similarity += math.sqrt(profile[i] / sumA * value[i] / sumB);
      }
      return math.sqrt(math.max(0, 1 - similarity.clamp(0, 1)));
    }

    return math.min(
      distance(colors!),
      firstColors == null ? 1 : distance(firstColors!),
    );
  }

  void update(PoseBody current, int currentTime) {
    final dt = math.max(.001, (currentTime - time) / 1000);
    vx = ((current.center.x - body.center.x) / dt).clamp(-.5, .5);
    vy = ((current.center.y - body.center.y) / dt).clamp(-.5, .5);
    if (current.appearance != null) {
      colors = colors == null
          ? current.appearance
          : List.generate(
              96,
              (i) => colors![i] * .9 + current.appearance![i] * .1,
            );
    }
    body = current;
    time = currentTime;
  }
}
