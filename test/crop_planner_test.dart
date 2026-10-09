import 'package:crux_cam/core/reframing/crop_planner.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:crux_cam/features/crop/models/crop_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pose.dart';

AnalysisResult analysis(
  List<PoseBody?> bodies, {
  int width = 720,
  int height = 1280,
}) => AnalysisResult(
  session: PoseSession(
    id: 'crop-test',
    width: width,
    height: height,
    durationMs: bodies.length * 200,
    storageDirectory: '/unused',
  ),
  engine: PoseEngine.mediaPipeFull,
  intervalMs: 200,
  elapsedMs: 0,
  selectedPersonId: 1,
  frames: List.generate(
    bodies.length,
    (i) => poseFrame(i * 200, bodies[i] == null ? [] : [bodies[i]!]),
  ),
  tracked: List.generate(
    bodies.length,
    (i) => TrackedFrame(
      timeMs: i * 200,
      status: bodies[i] == null ? TrackStatus.lost : TrackStatus.tracked,
      raw: bodies[i],
      corrected: bodies[i],
    ),
  ),
);

void main() {
  test('3:4는 세로이며 위치 보정이 전체 경로에 적용되고 영상 밖으로 나가지 않는다', () {
    expect(CropRatio.threeFour.aspect, .75);
    final source = analysis([bodyAt(.4), bodyAt(.5)]);
    final base = CropPlanner().plan(
      source,
      const CropOptions(zoom: 2, smooth: false),
    );
    final shifted = CropPlanner().plan(
      source,
      const CropOptions(zoom: 2, smooth: false, offsetX: .1, offsetY: -.1),
    );
    for (var i = 0; i < base.frames.length; i++) {
      expect(
        shifted.frames[i].rect.centerX,
        closeTo(base.frames[i].rect.centerX + .1, .0001),
      );
      expect(
        shifted.frames[i].rect.centerY,
        closeTo(base.frames[i].rect.centerY - .1, .0001),
      );
    }
    final edge = CropPlanner().plan(
      source,
      const CropOptions(zoom: 2, offsetX: .5, offsetY: .5),
    );
    expect(
      edge.frames.last.rect.left + edge.frames.last.rect.width,
      lessThanOrEqualTo(1.000001),
    );
    expect(
      edge.frames.last.rect.top + edge.frames.last.rect.height,
      lessThanOrEqualTo(1.000001),
    );
  });
  test('모든 비율과 화면 가장자리의 사람에서도 크롭 영역이 영상 안에 유지된다', () {
    for (final size in [(720, 1280), (1280, 720)]) {
      for (final ratio in CropRatio.values) {
        final timeline = CropPlanner().plan(
          analysis(
            [bodyAt(.02, y: .02), bodyAt(.98, y: .98)],
            width: size.$1,
            height: size.$2,
          ),
          CropOptions(ratio: ratio),
        );
        for (final frame in timeline.frames) {
          final rect = frame.rect;
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.left + rect.width, lessThanOrEqualTo(1.000001));
          expect(rect.top + rect.height, lessThanOrEqualTo(1.000001));
          expect(
            rect.width / rect.height * timeline.sourceAspect,
            closeTo(timeline.outputAspect, .000001),
          );
        }
      }
    }
  });
  test('짧게 놓친 구간은 앞뒤 위치를 이어 화면이 멈췄다 튀지 않는다', () {
    final timeline = CropPlanner().plan(
      analysis([bodyAt(.3), null, null, bodyAt(.6)]),
      const CropOptions(smooth: false),
    );
    expect(timeline.frames[1].status, CropStatus.bridged);
    expect(timeline.frames[2].status, CropStatus.bridged);
    final xs = timeline.frames.map((f) => f.rect.centerX).toList();
    // 놓친 두 프레임도 앞뒤 사이에서 한 방향으로 이동합니다.
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    expect(xs[2], lessThan(xs[3]));
    // 프레임 사이 시간도 같은 경로를 따라 이어집니다.
    expect(timeline.at(300).rect.centerX, closeTo((xs[1] + xs[2]) / 2, 1e-6));
    for (final frame in timeline.frames) {
      expect(
        frame.rect.width / frame.rect.height * timeline.sourceAspect,
        closeTo(timeline.outputAspect, 1e-6),
      );
    }
  });
  test('오래 놓친 구간은 유지하다가 다시 찾기 직전에만 이동하고, 마지막 뒤에는 유지한다', () {
    // 0초에 찾고 4.2초 동안 놓친 뒤 다시 찾고, 이후 다시 놓칩니다.
    final timeline = CropPlanner().plan(
      analysis([bodyAt(.3), ...List.filled(20, null), bodyAt(.6), null, null]),
      const CropOptions(smooth: false),
    );
    final first = timeline.frames.first.rect;
    expect(timeline.frames[5].status, CropStatus.held);
    expect(timeline.frames[5].rect.centerX, closeTo(first.centerX, 1e-9));
    // 다시 찾기 1초 전(16번째 프레임)까지는 그대로입니다.
    expect(timeline.frames[16].rect.centerX, closeTo(first.centerX, 1e-9));
    expect(timeline.frames[17].status, CropStatus.bridged);
    expect(timeline.frames[17].rect.centerX, greaterThan(first.centerX));
    expect(
      timeline.frames[20].rect.centerX,
      lessThan(timeline.frames[21].rect.centerX),
    );
    // 마지막으로 찾은 뒤에는 어디로 갔는지 모르므로 그 영역을 유지합니다.
    expect(timeline.frames.last.status, CropStatus.held);
    expect(
      timeline.frames.last.rect.centerX,
      closeTo(timeline.frames[21].rect.centerX, 1e-9),
    );
    expect(timeline.at(99999).rect, same(timeline.frames.last.rect));
  });
  test('처음 잠깐 놓치면 곧 찾을 위치를, 오래 못 찾으면 넓은 영역을 보여준다', () {
    final short = CropPlanner().plan(
      analysis([null, bodyAt(.3), bodyAt(.5)]),
      const CropOptions(smooth: false),
    );
    expect(short.frames.first.status, CropStatus.bridged);
    expect(
      short.frames.first.rect.centerX,
      closeTo(short.frames[1].rect.centerX, 1e-9),
    );
    final long = CropPlanner().plan(
      analysis([...List.filled(20, null), bodyAt(.3)]),
      const CropOptions(smooth: false),
    );
    expect(long.frames.first.status, CropStatus.waiting);
    expect(long.at(-200).status, CropStatus.waiting);
    expect(
      long.frames.first.rect.height,
      greaterThan(long.frames.last.rect.height),
    );
    expect(long.frames[19].status, CropStatus.bridged);
  });
  test('부드러운 이동을 켜도 놓친 구간에서 다음 위치로 계속 이동한다', () {
    final timeline = CropPlanner().plan(
      analysis([bodyAt(.3), bodyAt(.3), null, null, null, bodyAt(.6)]),
      const CropOptions(),
    );
    final xs = timeline.frames.map((f) => f.rect.centerX).toList();
    for (var i = 2; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]));
    }
  });
  test('확대하면 영역이 좁아지고 부드러운 이동은 직접 따라가기보다 변화를 줄인다', () {
    final result = analysis([bodyAt(.3), bodyAt(.6)]);
    final normal = CropPlanner().plan(result, const CropOptions(smooth: false));
    final zoomed = CropPlanner().plan(
      result,
      const CropOptions(zoom: 2, smooth: false),
    );
    final smooth = CropPlanner().plan(result, const CropOptions());
    expect(
      zoomed.frames.first.rect.width,
      lessThan(normal.frames.first.rect.width),
    );
    expect(
      smooth.frames.last.rect.centerX,
      lessThan(normal.frames.last.rect.centerX),
    );
  });
  test('대상 미선택과 잘못된 확대 값은 크롭하지 않는다', () {
    expect(
      () => CropPlanner().plan(analysis([null]), const CropOptions()),
      throwsFormatException,
    );
    expect(
      () => CropPlanner().plan(
        analysis([bodyAt(.3)]),
        const CropOptions(zoom: 0),
      ),
      throwsFormatException,
    );
    expect(
      () => CropPlanner().plan(
        analysis([bodyAt(.3)]),
        const CropOptions(zoom: double.nan),
      ),
      throwsFormatException,
    );
  });
}
