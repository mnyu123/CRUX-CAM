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
  test('놓친 구간은 마지막 영역을 유지하고 다른 사람에게 이동하지 않는다', () {
    final timeline = CropPlanner().plan(
      analysis([bodyAt(.3), null, null, bodyAt(.4)]),
      const CropOptions(),
    );
    expect(timeline.frames[1].status, CropStatus.held);
    expect(timeline.frames[1].rect, same(timeline.frames.first.rect));
    expect(timeline.at(500).rect, same(timeline.frames.first.rect));
  });
  test('대상 감지 전에는 넓게 표시하고 시간 보간은 같은 비율을 유지한다', () {
    final timeline = CropPlanner().plan(
      analysis([null, bodyAt(.3), bodyAt(.5)]),
      const CropOptions(smooth: false),
    );
    expect(timeline.frames.first.status, CropStatus.waiting);
    final middle = timeline.at(300).rect;
    expect(
      middle.centerX,
      closeTo(
        (timeline.frames[1].rect.centerX + timeline.frames[2].rect.centerX) / 2,
        .000001,
      ),
    );
    expect(
      middle.width / middle.height * timeline.sourceAspect,
      closeTo(timeline.outputAspect, .000001),
    );
    expect(timeline.at(-200).status, CropStatus.waiting);
    expect(timeline.at(99999).rect, same(timeline.frames.last.rect));
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
