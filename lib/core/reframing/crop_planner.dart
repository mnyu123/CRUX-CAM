import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';
import '../../features/crop/models/crop_models.dart';

class CropPlanner {
  /// 이 시간 이하로 놓친 구간은 앞뒤 위치를 이어서 화면이 멈췄다 튀지 않게 합니다.
  static const bridgeMs = 3000;

  /// 더 긴 구간은 마지막 위치를 유지하다가, 다시 찾기 직전 이 시간 동안 새 위치로 옮겨 갑니다.
  static const approachMs = 1000;

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
      desired[i] = around(
        (left + right) / 2 + options.offsetX,
        (top + bottom) / 2 + options.offsetY,
        height,
      );
    }
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

    // 3) 목표 영역을 시간 순서대로 부드럽게 따라갑니다.
    var previous = targets.first.rect;
    int? lastTime;
    final frames = <CropFrame>[];
    for (var i = 0; i < targets.length; i++) {
      final desiredRect = targets[i].rect;
      final time = tracked[i].timeMs;
      if (options.smooth && lastTime != null) {
        final dt = math.max(.001, (time - lastTime) / 1000);
        final movement =
            math.sqrt(
              math.pow(desiredRect.centerX - previous.centerX, 2) +
                  math.pow(desiredRect.centerY - previous.centerY, 2),
            ) /
            dt;
        // 빠른 움직임에는 더 빨리 따라가고, 확대는 천천히·축소는 빠르게 적용합니다.
        final pan = 1 - math.exp(-dt * (5 + movement * 15));
        final scale =
            1 - math.exp(-dt * (desiredRect.height > previous.height ? 12 : 3));
        final moved = around(
          previous.centerX + (desiredRect.centerX - previous.centerX) * pan,
          previous.centerY + (desiredRect.centerY - previous.centerY) * pan,
          previous.height + (desiredRect.height - previous.height) * scale,
        );
        // 위치가 그대로면 이전 영역을 그대로 써서 멈춘 구간이 정확히 같은 화면이 되게 합니다.
        previous = _same(moved, previous) ? previous : moved;
      } else {
        previous = desiredRect;
      }
      lastTime = time;
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

  bool _same(CropRect a, CropRect b) =>
      (a.left - b.left).abs() < 1e-9 &&
      (a.top - b.top).abs() < 1e-9 &&
      (a.width - b.width).abs() < 1e-9 &&
      (a.height - b.height).abs() < 1e-9;
}
