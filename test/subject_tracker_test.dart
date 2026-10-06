import 'package:crux_cam/core/tracking/subject_tracker.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pose.dart';

void main() {
  test('모델의 사람 순서가 바뀌어도 선택한 사람을 추적한다', () {
    final a = bodyAt(0.2);
    final b = bodyAt(0.8);
    final moved = bodyAt(0.23);
    final result = SubjectTracker().track(
      [
        poseFrame(0, [a, b]),
        poseFrame(200, [b, moved]),
      ],
      0,
      0,
    );
    expect(result[1].raw, same(moved));
    expect(result[1].corrected!.center.x, lessThan(0.24));
  });

  test('멀리 있는 다른 사람을 연결하지 않고 끊김을 남긴다', () {
    final result = SubjectTracker().track(
      [
        poseFrame(0, [bodyAt(0.2)]),
        poseFrame(200, [bodyAt(0.8)]),
      ],
      0,
      0,
    );
    expect(result[1].status, TrackStatus.lost);
    expect(result[1].corrected, isNull);
  });

  test('두 사람이 비슷한 위치로 교차하면 연결을 보류한다', () {
    final result = SubjectTracker().track(
      [
        poseFrame(0, [bodyAt(0.4)]),
        poseFrame(200, [bodyAt(0.39), bodyAt(0.41)]),
      ],
      0,
      0,
    );
    expect(result[1].status, TrackStatus.ambiguous);
    expect(result[1].raw, isNull);
  });

  test('2초를 넘는 가림 뒤에는 가까운 사람도 자동으로 연결하지 않는다', () {
    final result = SubjectTracker().track(
      [
        poseFrame(0, [bodyAt(0.4)]),
        poseFrame(500, []),
        poseFrame(2200, [bodyAt(0.4)]),
        poseFrame(2400, [bodyAt(0.4)]),
      ],
      0,
      0,
    );
    expect(result.skip(1).every((f) => f.status == TrackStatus.lost), isTrue);
  });

  test('중간 프레임에서 선택하면 앞뒤를 모두 추적한다', () {
    final frames = [
      for (var i = 0; i < 5; i++) poseFrame(i * 200, [bodyAt(0.3 + i * 0.02)]),
    ];
    final result = SubjectTracker().track(frames, 2, 0);
    expect(result.every((f) => f.status == TrackStatus.tracked), isTrue);
  });

  test('보정은 작은 좌표 흔들림을 줄이고 낮은 신뢰도 관절을 숨긴다', () {
    final points = bodyAt(0.31).points.toList();
    points[15] = const PosePoint(0.9, 0.9, 0, 0.1);
    final result = SubjectTracker().track(
      [
        poseFrame(0, [bodyAt(0.3)]),
        poseFrame(200, [PoseBody(points)]),
      ],
      0,
      0,
    );
    final frame = result[1];
    expect(frame.corrected!.points[11].x, lessThan(frame.raw!.points[11].x));
    expect(frame.corrected!.points[15].reliable, isFalse);
  });
}
