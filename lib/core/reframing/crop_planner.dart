import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';
import '../../features/crop/models/crop_models.dart';

class CropPlanner {
  /// 이 시간 이하로 놓친 구간은 앞뒤 위치를 이어서 화면이 멈췄다 튀지 않게 합니다.
  static const bridgeMs = 3000;

  /// 더 긴 구간은 마지막 위치를 유지하다가, 다시 찾기 직전 이 시간 동안 새 위치로 옮겨 갑니다.
  static const approachMs = 1000;

  static const _windowMs = 550;
  static const _maxPanPerSecond = 1.65;
  static const _zoomInPerSecond = .65;
  static const _zoomOutPerSecond = 1.15;

  CropTimeline plan(AnalysisResult result, CropOptions options) {
    if (result.session.width <= 0 ||
        result.session.height <= 0 ||
        result.frames.isEmpty ||
        result.tracked.length != result.frames.length ||
        result.trackedCount == 0 ||
        !options.zoom.isFinite ||
        options.zoom < 1 ||
        options.zoom > 2.5 ||
        !options.offsetX.isFinite ||
        !options.offsetY.isFinite ||
        options.offsetX.abs() > .5 ||
        options.offsetY.abs() > .5) {
      throw const FormatException('추적할 사람을 먼저 선택해주세요.');
    }
    final sourceAspect = result.session.width / result.session.height;
    final relativeAspect =
        (options.ratio.aspect ?? sourceAspect) / sourceAspect;
    final maximumHeight = math.min(1.0, 1.0 / relativeAspect).toDouble();
    CropRect around(double x, double y, double height) {
      final h = height
          .clamp(math.min(.12, maximumHeight), maximumHeight)
          .toDouble();
      final w = h * relativeAspect;
      return CropRect(
        (x - w / 2).clamp(0.0, math.max(0.0, 1 - w)),
        (y - h / 2).clamp(0.0, math.max(0.0, 1 - h)),
        w,
        h,
      );
    }

    CropRect blend(CropRect a, CropRect b, double t) {
      // 처음과 끝을 천천히 움직여 이어 붙인 구간의 시작·끝에서 화면이 덜컹이지 않게 합니다.
      final eased = t * t * (3 - 2 * t);
      return around(
        a.centerX + (b.centerX - a.centerX) * eased,
        a.centerY + (b.centerY - a.centerY) * eased,
        a.height + (b.height - a.height) * eased,
      );
    }

    // 1) 실제로 찾은 프레임의 목표 영역을 먼저 계산합니다.
    final tracked = result.tracked;
    final desired = List<CropRect?>.filled(tracked.length, null);
    for (var i = 0; i < tracked.length; i++) {
      final body = tracked[i].corrected ?? tracked[i].raw;
      if (tracked[i].status != TrackStatus.tracked ||
          body == null ||
          !body.usable) {
        continue;
      }
      final bounds = body.bounds;
      final left = bounds.left.clamp(0.0, 1.0),
          right = bounds.right.clamp(0.0, 1.0);
      final top = bounds.top.clamp(0.0, 1.0),
          bottom = bounds.bottom.clamp(0.0, 1.0);
      // 신뢰할 수 있는 관절 범위에 여유를 두어 작은 좌표 변화로 손발이 잘리는 것을 줄입니다.
      final height =
          math.max(
            math.max(.18, bottom - top) * 1.4,
            math.max(.12, right - left) * 1.4 / relativeAspect,
          ) /
          options.zoom;
      final boundsX = (left + right) / 2, boundsY = (top + bottom) / 2;
      final raw = tracked[i].raw;
      final torso = raw != null && raw.usable ? raw.center : body.center;
      // 많이 확대하면 손발보다 몸통 쪽을 더 중심에 두어 팔을 뻗을 때 초점이 덜 흔들리게 합니다.
      final torsoWeight = options.smooth ? (options.zoom - 1) * .5 : 0.0;
      desired[i] = around(
        boundsX +
            (torso.x.clamp(0.0, 1.0) - boundsX) * torsoWeight +
            options.offsetX,
        boundsY +
            (torso.y.clamp(0.0, 1.0) - boundsY) * torsoWeight +
            options.offsetY,
        height,
      );
    }
    if (options.smooth) _removeSpikes(desired, tracked);
    final known = [
      for (var i = 0; i < desired.length; i++)
        if (desired[i] != null) i,
    ];
    if (known.isEmpty) throw const FormatException('추적할 사람을 먼저 선택해주세요.');

    // 2) 놓친 프레임은 앞뒤로 찾은 위치를 보고 목표 영역을 채웁니다.
    // 분석은 영상 전체를 미리 끝낸 상태라 다음에 다시 찾는 위치도 알고 있습니다.
    final wide = around(.5, .5, maximumHeight);
    final targets = <({CropRect rect, CropStatus status})>[];
    var next = 0;
    for (var i = 0; i < tracked.length; i++) {
      while (next < known.length && known[next] < i) {
        next++;
      }
      if (desired[i] != null) {
        targets.add((rect: desired[i]!, status: CropStatus.following));
        continue;
      }
      final time = tracked[i].timeMs;
      final before = next > 0 ? known[next - 1] : null;
      final after = next < known.length ? known[next] : null;
      if (after == null) {
        // 마지막으로 놓친 뒤에는 어디로 갔는지 알 수 없으므로 마지막 영역을 유지합니다.
        targets.add((rect: desired[before!]!, status: CropStatus.held));
        continue;
      }
      final end = tracked[after].timeMs;
      final from = before == null ? wide : desired[before]!;
      // 처음부터 놓친 경우에는 영상 시작부터 처음 찾을 때까지를 구간 길이로 봅니다.
      final start = tracked[before ?? 0].timeMs;
      if (end - start <= bridgeMs) {
        // 짧게 놓친 구간: 앞뒤 위치를 시간 비율로 이어 줍니다.
        // 처음부터 놓친 경우에는 곧 찾을 위치를 미리 보여 줍니다.
        targets.add((
          rect: before == null
              ? desired[after]!
              : blend(from, desired[after]!, (time - start) / (end - start)),
          status: CropStatus.bridged,
        ));
      } else if (end - time <= approachMs) {
        // 오래 놓친 구간: 다시 찾기 직전에만 새 위치로 천천히 이동합니다.
        targets.add((
          rect: blend(from, desired[after]!, 1 - (end - time) / approachMs),
          status: CropStatus.bridged,
        ));
      } else {
        targets.add((
          rect: from,
          status: before == null ? CropStatus.waiting : CropStatus.held,
        ));
      }
    }

    // 3) 앞뒤의 목표를 함께 보아 방향이 바뀌는 구간에서도 뒤늦게 쫓아가지 않게 합니다.
    final path = targets.map((target) => target.rect).toList();
    final averaged = options.smooth
        ? _smoothTargets(path, tracked, around)
        : path;
    var previous = averaged.first;
    final frames = <CropFrame>[];
    for (var i = 0; i < targets.length; i++) {
      final desiredRect = averaged[i];
      final time = tracked[i].timeMs;
      if (options.smooth && i > 0) {
        if (targets[i].status != CropStatus.held &&
            targets[i].status != CropStatus.waiting) {
          final dt = math.max(0.0, (time - tracked[i - 1].timeMs) / 1000);
          // 확대율은 비율로 제한합니다. 같은 픽셀 변화도 작은 크롭에서는 더 크게 느껴집니다.
          final zoom = math
              .log(desiredRect.height / previous.height)
              .clamp(-_zoomInPerSecond * dt, _zoomOutPerSecond * dt);
          final candidate = around(
            desiredRect.centerX,
            desiredRect.centerY,
            previous.height * math.exp(zoom),
          );
          // 경계에 걸려 크롭 중심이 밀리는 이동까지 포함해, 잘린 화면 크기 기준으로 제한합니다.
          final movement = _distance(previous, candidate);
          previous = movement > _maxPanPerSecond * dt
              ? previous.interpolate(
                  candidate,
                  _maxPanPerSecond * dt / movement,
                )
              : candidate;
        }
      } else {
        previous = desiredRect;
      }
      frames.add(
        CropFrame(timeMs: time, rect: previous, status: targets[i].status),
      );
    }
    return CropTimeline(
      width: result.session.width,
      height: result.session.height,
      durationMs: result.session.durationMs,
      personId: result.selectedPersonId,
      engine: result.engine.id,
      options: options,
      frames: List.unmodifiable(frames),
    );
  }

  double _distance(CropRect a, CropRect b) {
    final dx = (a.centerX - b.centerX) / math.min(a.width, b.width);
    final dy = (a.centerY - b.centerY) / math.min(a.height, b.height);
    return math.sqrt(dx * dx + dy * dy);
  }

  void _removeSpikes(List<CropRect?> path, List<TrackedFrame> frames) {
    final original = List<CropRect?>.of(path);
    for (var i = 1; i < path.length - 1; i++) {
      final before = original[i - 1], at = original[i], after = original[i + 1];
      if (before == null || at == null || after == null) continue;
      final left = frames[i].timeMs - frames[i - 1].timeMs;
      final right = frames[i + 1].timeMs - frames[i].timeMs;
      if (left <= 0 || right <= 0 || left > _windowMs || right > _windowMs) {
        continue;
      }
      final expected = before.interpolate(after, left / (left + right));
      // 양옆이 같은 위치·크기인데 한 번만 벗어나면 짧은 오인식으로 보고 이어 줍니다.
      // 여러 프레임에서 계속 이동하거나 다시 찾은 구간은 이 규칙으로 지우지 않습니다.
      if (_distance(before, after) < .18 &&
          math.log(after.height / before.height).abs() < .15 &&
          (_distance(expected, at) > .28 ||
              math.log(at.height / expected.height).abs() > .22)) {
        path[i] = expected;
      }
    }
  }

  List<CropRect> _smoothTargets(
    List<CropRect> path,
    List<TrackedFrame> frames,
    CropRect Function(double, double, double) around,
  ) {
    final relativeAspect = path.first.width / path.first.height;
    return List.generate(path.length, (i) {
      final time = frames[i].timeMs;
      var mean = path[i];
      var total = 1.0;
      var start = i, end = i;
      for (final direction in [-1, 1]) {
        for (var j = i + direction; j >= 0 && j < path.length; j += direction) {
          final elapsed = (frames[j].timeMs - time).abs();
          if (elapsed >= _windowMs) break;
          if (j < start) start = j;
          if (j > end) end = j;
          // 가까운 시점에 더 큰 비중을 둡니다. 같은 비율의 영역끼리 섞어 경계와 비율을 지킵니다.
          final weight = 1 - elapsed / _windowMs;
          total += weight;
          mean = mean.interpolate(path[j], weight / total);
        }
      }
      // 빠른 이동을 화면이 다 따라잡기 어렵다면 잠깐 여유를 넓혀 사람을 놓칠 가능성을 줄입니다.
      // 앞쪽 위치도 미리 보므로 실제로 움직이기 시작한 뒤 갑자기 축소하지 않아도 됩니다.
      var height = mean.height;
      for (var j = start; j <= end; j++) {
        final reach = math.max(
          (path[j].centerX - mean.centerX).abs() / relativeAspect,
          (path[j].centerY - mean.centerY).abs(),
        );
        final elapsed = (frames[j].timeMs - time).abs();
        height = math.max(height, 3.4 * reach * (1 - elapsed / _windowMs));
      }
      return around(mean.centerX, mean.centerY, height);
    });
  }
}
