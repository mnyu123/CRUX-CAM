import 'dart:math' as math;

import '../../features/analysis/models/pose_models.dart';
import '../../features/crop/models/crop_models.dart';

class CropPlanner {
  CropTimeline plan(AnalysisResult result, CropOptions options) {
    if (result.session.width <= 0 ||
        result.session.height <= 0 ||
        result.frames.isEmpty ||
        result.tracked.length != result.frames.length ||
        result.trackedCount == 0 ||
        !options.zoom.isFinite ||
        options.zoom < 1 ||
        options.zoom > 2.5) {
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

    var previous = around(.5, .5, maximumHeight);
    var hasTarget = false;
    int? lastTime;
    final frames = <CropFrame>[];
    for (final tracked in result.tracked) {
      final body = tracked.corrected ?? tracked.raw;
      if (tracked.status != TrackStatus.tracked ||
          body == null ||
          !body.usable) {
        frames.add(
          CropFrame(
            timeMs: tracked.timeMs,
            rect: previous,
            status: hasTarget ? CropStatus.held : CropStatus.waiting,
          ),
        );
        lastTime = tracked.timeMs;
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
      final desired = around((left + right) / 2, (top + bottom) / 2, height);
      if (options.smooth && hasTarget) {
        final dt = math.max(
          .001,
          (tracked.timeMs - (lastTime ?? tracked.timeMs)) / 1000,
        );
        final movement =
            math.sqrt(
              math.pow(desired.centerX - previous.centerX, 2) +
                  math.pow(desired.centerY - previous.centerY, 2),
            ) /
            dt;
        // 빠른 움직임에는 더 빨리 따라가고, 확대는 천천히·축소는 빠르게 적용합니다.
        final pan = 1 - math.exp(-dt * (5 + movement * 15));
        final scale =
            1 - math.exp(-dt * (desired.height > previous.height ? 12 : 3));
        previous = around(
          previous.centerX + (desired.centerX - previous.centerX) * pan,
          previous.centerY + (desired.centerY - previous.centerY) * pan,
          previous.height + (desired.height - previous.height) * scale,
        );
      } else {
        previous = desired;
      }
      hasTarget = true;
      lastTime = tracked.timeMs;
      frames.add(
        CropFrame(
          timeMs: tracked.timeMs,
          rect: previous,
          status: CropStatus.following,
        ),
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
}
