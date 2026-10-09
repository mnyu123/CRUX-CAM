import 'dart:async';
import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';
import 'person_catalog.dart';

/// 한 사람을 놓친 한 프레임에서 다시 찾아볼 위치입니다.
class GapRequest {
  const GapRequest({
    required this.frameIndex,
    required this.timeMs,
    required this.personId,
    required this.region,
    required this.center,
    required this.span,
    required this.tolerance,
    required this.colors,
  });
  final int frameIndex;
  final int timeMs;
  final int personId;

  /// 모델에 넣을 확대 영역입니다.
  final PoseRegion region;

  /// 앞뒤로 찾은 위치로 예상한 몸통 중심과 몸 크기입니다.
  final ({double x, double y}) center;
  final double span;

  /// 예상 위치에서 얼마나 벗어나도 같은 사람으로 볼지 정합니다. 찾은 시점에서 멀수록 커집니다.
  final double tolerance;

  /// 앞뒤로 찾은 같은 사람의 옷 색 분포입니다.
  final List<List<double>> colors;
}

/// 모델이 사람을 놓친 프레임을 앞뒤 위치로 예상하고, 그 주변만 확대해 다시 찾은 결과를 붙입니다.
///
/// 클라이머가 벽을 보고 등진 자세이거나 화면에서 작게 보이면 전체 화면 분석에서 자주 놓칩니다.
/// 같은 장면을 확대하면 다시 찾는 경우가 많지만, 다른 사람을 잘못 잡으면 안 되므로
/// 예상 위치·몸 크기·옷 색이 모두 맞는 결과만 같은 번호로 받아들입니다.
class GapFiller {
  /// 앞뒤로 찾은 시점 사이가 이보다 짧으면 두 위치를 이어서 예상합니다.
  static const bridgeMs = 4000;

  /// 한쪽 위치만 쓸 수 있을 때 이 시간 안의 프레임만 다시 찾습니다.
  static const edgeMs = 1500;

  /// 한두 번만 나온 잘못된 감지는 다시 찾지 않습니다.
  static const minFrames = 3;

  List<GapRequest> plan(
    List<PoseFrame> frames, {
    required int width,
    required int height,
    int firstPersonId = 1,
    int limit = 1000,
    Set<(int, int)> skip = const {},
  }) {
    if (width <= 0 || height <= 0) return const [];
    final known = <int, Map<int, PoseBody>>{};
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      for (var j = 0; j < frame.bodies.length; j++) {
        final id = frame.personIdAt(j);
        if (id == null || id < firstPersonId || !frame.bodies[j].usable) {
          continue;
        }
        (known[id] ??= {})[i] = frame.bodies[j];
      }
    }
    final requests = <GapRequest>[];
    for (final entry in known.entries) {
      if (entry.value.length < minFrames) continue;
      final indices = entry.value.keys.toList()..sort();
      var next = 0;
      for (var i = 0; i < frames.length; i++) {
        while (next < indices.length && indices[next] < i) {
          next++;
        }
        if (next < indices.length && indices[next] == i) continue;
        // 이미 한 번 다시 찾아본 프레임과 사람 조합은 반복하지 않습니다.
        if (skip.contains((i, entry.key))) continue;
        final before = next > 0 ? indices[next - 1] : null;
        final after = next < indices.length ? indices[next] : null;
        final time = frames[i].timeMs;
        final a = before == null ? null : entry.value[before]!;
        final b = after == null ? null : entry.value[after]!;
        final ta = before == null ? null : frames[before].timeMs;
        final tb = after == null ? null : frames[after].timeMs;
        _Guess? guess;
        if (a != null && b != null && tb! - ta! <= bridgeMs) {
          guess = _Guess.between(a, b, (time - ta) / (tb - ta));
        } else if (a != null && time - ta! <= edgeMs) {
          // 직전 이동 방향으로 조금 옮겨 예상합니다. 한쪽 정보뿐이라 이동량은 절반만 반영합니다.
          final earlier = next > 1 ? indices[next - 2] : null;
          guess = _Guess.of(a).moved(
            _velocity(
              entry.value[earlier],
              earlier == null ? null : frames[earlier].timeMs,
              a,
              ta,
            ),
            (time - ta) / 1000,
          );
        } else if (b != null && tb! - time <= edgeMs) {
          final later = next + 1 < indices.length ? indices[next + 1] : null;
          guess = _Guess.of(b).moved(
            _velocity(
              entry.value[later],
              later == null ? null : frames[later].timeMs,
              b,
              tb,
            ),
            (time - tb) / 1000,
          );
        }
        if (guess == null) continue;
        final nearest = math.min(
          ta == null ? 1 << 30 : time - ta,
          tb == null ? 1 << 30 : tb - time,
        );
        final tolerance = math.min(.25, .04 + .12 * nearest / 1000);
        // 예상 위치에 이미 다른 후보가 있으면 모델이 놓친 것이 아니라
        // 번호 연결을 보류했거나 다른 사람과 겹친 장면입니다. 이때는 새로 붙이지 않습니다.
        final frame = frames[i];
        final crowded = frame.bodies.any((body) {
          if (!body.usable) return false;
          final c = body.center;
          return math.sqrt(
                math.pow(c.x - guess!.center.x, 2) +
                    math.pow(c.y - guess.center.y, 2),
              ) <
              guess.span * .5 + tolerance;
        });
        if (crowded) continue;
        requests.add(
          GapRequest(
            frameIndex: i,
            timeMs: time,
            personId: entry.key,
            region: _region(guess, tolerance, width, height),
            center: guess.center,
            span: guess.span,
            tolerance: tolerance,
            colors: [?a?.appearance, ?b?.appearance],
          ),
        );
      }
    }
    // 영상 앞에서부터 차례로 읽어야 디코더 이동이 짧습니다.
    requests.sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    return requests.length > limit ? requests.sublist(0, limit) : requests;
  }

  /// 놓친 프레임을 여러 차례에 걸쳐 다시 찾습니다.
  ///
  /// 한 번 다시 찾는 데 성공하면 그 프레임이 새 기준점이 되어, 다음 차례에는 그 뒤(또는 앞)
  /// 구간까지 이어서 찾아봅니다. 그래서 끊긴 뒤 오래 못 찾던 클라이머도 조금씩 따라갈 수 있습니다.
  /// [find]가 실패하면 그때까지 붙인 결과만 돌려주어 기본 분석 결과를 잃지 않게 합니다.
  Future<List<PoseFrame>> fill(
    List<PoseFrame> frames, {
    required int width,
    required int height,
    required Future<List<PoseBody>> Function(GapRequest request) find,
    int firstPersonId = 1,
    int? limit,
    void Function(int done)? onProgress,
    bool Function()? active,
  }) async {
    // 긴 영상에서도 보충 시간이 끝없이 늘지 않도록 시도 횟수를 제한합니다.
    final budget = limit ?? math.min(1000, math.max(100, frames.length ~/ 2));
    final working = [...frames];
    final attempted = <(int, int)>{};
    var done = 0;
    while (done < budget) {
      final requests = plan(
        working,
        width: width,
        height: height,
        firstPersonId: firstPersonId,
        limit: budget - done,
        skip: attempted,
      );
      if (requests.isEmpty) break;
      var added = false;
      for (final request in requests) {
        if (active != null && !active()) return frames;
        attempted.add((request.frameIndex, request.personId));
        final List<PoseBody> found;
        try {
          found = await find(request);
        } catch (error) {
          // 지원하지 않는 빌드이거나 기기에서 실패하면 보충만 멈춥니다.
          return List.unmodifiable(working);
        }
        done++;
        onProgress?.call(done);
        if (active != null && !active()) return frames;
        final updated = accept(working[request.frameIndex], request, found);
        if (updated != null) {
          working[request.frameIndex] = updated;
          added = true;
        }
      }
      // 이번 차례에 새로 찾은 프레임이 없으면 더 이어 갈 기준점도 없습니다.
      if (!added) break;
    }
    return List.unmodifiable(working);
  }

  /// 다시 찾은 후보 중 같은 사람으로 볼 수 있는 하나를 골라 프레임에 붙입니다.
  /// 맞는 후보가 없으면 null을 돌려주며, 원래 프레임은 바꾸지 않습니다.
  PoseFrame? accept(PoseFrame frame, GapRequest request, List<PoseBody> found) {
    if (frame.personIds.contains(request.personId)) return null;
    PoseBody? best;
    var bestCost = double.infinity;
    final reach = request.span * .5 + request.tolerance;
    for (final body in found) {
      if (!body.usable) continue;
      final c = body.center;
      final distance = math.sqrt(
        math.pow(c.x - request.center.x, 2) +
            math.pow(c.y - request.center.y, 2),
      );
      final scale = body.span / request.span;
      if (distance > reach || scale < .5 || scale > 2) continue;
      if (request.colors.isNotEmpty && body.appearance != null) {
        final color = request.colors
            .map((profile) => appearanceDistance(profile, body.appearance))
            .whereType<double>()
            .fold<double?>(null, (v, d) => v == null ? d : math.min(v, d));
        if (color != null && color > .6) continue;
      }
      // 같은 프레임의 다른 사람과 겹치는 결과는 누구인지 확신할 수 없어 버립니다.
      if (frame.bodies.any((other) => other.overlaps(body))) continue;
      final cost =
          distance / reach + math.log(scale).abs() * .25 - body.confidence * .1;
      if (cost < bestCost) {
        bestCost = cost;
        best = body;
      }
    }
    if (best == null) return null;
    return PoseFrame(
      timeMs: frame.timeMs,
      inferenceMs: frame.inferenceMs,
      preview: frame.preview,
      bodies: List.unmodifiable([...frame.bodies, best]),
      // 번호 목록이 몸 목록보다 짧을 수 있어 길이를 맞춘 뒤 새 번호를 붙입니다.
      personIds: List.unmodifiable([
        ...List.generate(frame.bodies.length, frame.personIdAt),
        request.personId,
      ]),
    );
  }

  /// 두 시점의 몸통 이동 속도(초당 화면 비율)입니다. 너무 떨어진 시점은 쓰지 않습니다.
  ({double x, double y}) _velocity(
    PoseBody? other,
    int? otherTime,
    PoseBody body,
    int time,
  ) {
    if (other == null || otherTime == null) return (x: 0, y: 0);
    final dt = (time - otherTime) / 1000;
    if (dt.abs() < .001 || dt.abs() > 1) return (x: 0, y: 0);
    double limit(double v) => v.clamp(-.3, .3).toDouble();
    return (
      x: limit((body.center.x - other.center.x) / dt),
      y: limit((body.center.y - other.center.y) / dt),
    );
  }

  PoseRegion _region(_Guess guess, double tolerance, int width, int height) {
    // 픽셀 기준 정사각형으로 잘라야 모델 입력에서 몸이 찌그러지지 않습니다.
    // 영역이 넓으면 확대 효과가 사라져 작은 사람을 다시 놓칩니다.
    // 그래서 위치 오차는 채택 기준에서 넉넉히 보고, 영역은 몸 크기의 약 1.6배로 제한합니다.
    final shortSide = math.min(width, height).toDouble();
    final side =
        (math.max(guess.boxWidth * width, guess.boxHeight * height) * 1.6 +
                tolerance * shortSide)
            .clamp(shortSide * .3, shortSide * .65);
    final halfX = math.min(.5, side / width / 2);
    final halfY = math.min(.5, side / height / 2);
    final x = guess.boxCenter.x.clamp(halfX, 1 - halfX);
    final y = guess.boxCenter.y.clamp(halfY, 1 - halfY);
    return PoseRegion(
      (x - halfX).clamp(0.0, 1.0),
      (y - halfY).clamp(0.0, 1.0),
      (x + halfX).clamp(0.0, 1.0),
      (y + halfY).clamp(0.0, 1.0),
    );
  }
}

class _Guess {
  _Guess(this.center, this.boxCenter, this.boxWidth, this.boxHeight, this.span);

  factory _Guess.of(PoseBody body) => _Guess.between(body, body, 0);

  factory _Guess.between(PoseBody a, PoseBody b, double t) {
    double mix(double x, double y) => x + (y - x) * t;
    final ab = a.bounds, bb = b.bounds;
    return _Guess(
      (x: mix(a.center.x, b.center.x), y: mix(a.center.y, b.center.y)),
      (
        x: mix((ab.left + ab.right) / 2, (bb.left + bb.right) / 2),
        y: mix((ab.top + ab.bottom) / 2, (bb.top + bb.bottom) / 2),
      ),
      mix(ab.right - ab.left, bb.right - bb.left),
      mix(ab.bottom - ab.top, bb.bottom - bb.top),
      mix(a.span, b.span),
    );
  }

  final ({double x, double y}) center;
  final ({double x, double y}) boxCenter;
  final double boxWidth, boxHeight, span;

  /// 속도와 경과 시간(초, 앞쪽이면 음수)으로 예상 위치를 옮깁니다.
  _Guess moved(({double x, double y}) velocity, double seconds) {
    final dx = velocity.x * seconds * .5, dy = velocity.y * seconds * .5;
    return _Guess(
      (x: center.x + dx, y: center.y + dy),
      (x: boxCenter.x + dx, y: boxCenter.y + dy),
      boxWidth,
      boxHeight,
      span,
    );
  }
}
