import 'package:crux_cam/core/tracking/gap_filler.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pose.dart';

/// 옷 색 분포를 한 칸에 몰아 둔 몸입니다. 칸이 다르면 다른 옷 색입니다.
PoseBody coloredAt(double x, {double y = .5, int color = 0, double size = 1}) {
  final base = bodyAt(x, y: y);
  return PoseBody([
    for (final p in base.points)
      PosePoint(x + (p.x - x) * size, y + (p.y - y) * size, p.z, p.confidence),
  ], appearance: List.generate(96, (i) => i == color ? 1.0 : 0.0));
}

PoseFrame numbered(int time, List<(PoseBody, int?)> bodies) => PoseFrame(
  timeMs: time,
  inferenceMs: 10,
  bodies: [for (final b in bodies) b.$1],
  personIds: [for (final b in bodies) b.$2],
);

void main() {
  final filler = GapFiller();

  test('앞뒤로 찾은 위치 사이의 놓친 프레임만 예상 위치 주변으로 다시 찾는다', () {
    final frames = [
      numbered(0, [(coloredAt(.3), 1)]),
      numbered(200, [(coloredAt(.32), 1)]),
      numbered(400, [(coloredAt(.34), 1)]),
      numbered(600, []),
      numbered(800, []),
      numbered(1000, [(coloredAt(.4), 1)]),
    ];
    final requests = filler.plan(frames, width: 720, height: 960);
    expect(requests.map((r) => r.frameIndex), [3, 4]);
    final first = requests.first;
    expect(first.personId, 1);
    expect(first.center.x, greaterThan(.34));
    expect(first.center.x, lessThan(.4));
    expect(first.colors, hasLength(2));
    for (final r in requests) {
      final region = r.region;
      expect(region.left, lessThanOrEqualTo(r.center.x));
      expect(region.right, greaterThanOrEqualTo(r.center.x));
      expect(region.top, lessThanOrEqualTo(r.center.y));
      expect(region.bottom, greaterThanOrEqualTo(r.center.y));
      expect(region.left, greaterThanOrEqualTo(0));
      expect(region.bottom, lessThanOrEqualTo(1));
      // 픽셀 기준 정사각형이라 몸이 찌그러지지 않습니다.
      expect(
        (region.right - region.left) * 720,
        closeTo((region.bottom - region.top) * 960, 1),
      );
    }
  });

  test('한두 번만 나온 후보, 오래 놓친 구간의 가운데, 다른 후보가 있는 자리는 다시 찾지 않는다', () {
    final rare = filler.plan(
      [
        numbered(0, [(coloredAt(.3), 1)]),
        numbered(200, [(coloredAt(.3), 1)]),
        numbered(400, []),
      ],
      width: 720,
      height: 960,
    );
    expect(rare, isEmpty);

    // 0~0.4초에 찾고 6초 동안 놓친 뒤 다시 찾습니다. 양 끝 1.5초 안쪽만 요청합니다.
    final long = filler.plan(
      [
        for (var i = 0; i < 3; i++) numbered(i * 200, [(coloredAt(.3), 1)]),
        for (var i = 3; i < 33; i++) numbered(i * 200, []),
        numbered(33 * 200, [(coloredAt(.3), 1)]),
      ],
      width: 720,
      height: 960,
    );
    final times = long.map((r) => r.timeMs).toList();
    expect(times, contains(600));
    expect(times, contains(1800));
    expect(times, isNot(contains(3400)));
    expect(times, contains(6400));

    // 예상 위치에 번호 없는 후보가 이미 있으면 번호 보류 상황이므로 건드리지 않습니다.
    final crowded = filler.plan(
      [
        for (var i = 0; i < 3; i++) numbered(i * 200, [(coloredAt(.3), 1)]),
        numbered(600, [(coloredAt(.31), null)]),
        numbered(800, [(coloredAt(.3), 1)]),
      ],
      width: 720,
      height: 960,
    );
    expect(crowded, isEmpty);
  });

  test('추가 영역 분석에서는 새 번호의 사람만 다시 찾는다', () {
    final frames = [
      numbered(0, [(coloredAt(.3), 1), (coloredAt(.7, color: 5), 2)]),
      numbered(200, [(coloredAt(.3), 1), (coloredAt(.7, color: 5), 2)]),
      numbered(400, []),
      numbered(600, [(coloredAt(.3), 1), (coloredAt(.7, color: 5), 2)]),
    ];
    final requests = filler.plan(
      frames,
      width: 720,
      height: 960,
      firstPersonId: 2,
    );
    expect(requests.map((r) => r.personId), [2]);
  });

  test('예상 위치·몸 크기·옷 색이 맞는 결과만 같은 번호로 붙인다', () {
    final frames = [
      numbered(0, [(coloredAt(.3), 1)]),
      numbered(200, [(coloredAt(.3), 1)]),
      numbered(400, [(coloredAt(.3), 1)]),
      numbered(600, [(coloredAt(.8, color: 9), null)]),
      numbered(800, [(coloredAt(.3), 1)]),
    ];
    final request = filler.plan(frames, width: 720, height: 960).single;
    final frame = frames[3];
    // 멀리 있는 사람, 몸 크기가 너무 다른 결과, 옷 색이 다른 결과는 버립니다.
    expect(filler.accept(frame, request, [coloredAt(.6)]), isNull);
    expect(filler.accept(frame, request, [coloredAt(.3, size: 3)]), isNull);
    expect(filler.accept(frame, request, [coloredAt(.3, color: 40)]), isNull);
    // 같은 프레임의 다른 사람과 겹치는 결과도 누구인지 확신할 수 없어 버립니다.
    expect(
      filler.accept(numbered(600, [(coloredAt(.35, color: 9), 2)]), request, [
        coloredAt(.34),
      ]),
      isNull,
    );
    final accepted = filler.accept(frame, request, [
      coloredAt(.6),
      coloredAt(.31),
    ])!;
    expect(accepted.bodies, hasLength(2));
    expect(accepted.personIds, [null, 1]);
    expect(accepted.bodies.last.center.x, closeTo(.31, .001));
    // 이미 같은 번호가 붙은 프레임에는 다시 붙이지 않습니다.
    expect(filler.accept(accepted, request, [coloredAt(.3)]), isNull);
  });

  test('다시 찾은 프레임을 기준점으로 삼아 오래 놓친 구간도 이어서 찾는다', () async {
    // 0.4초까지 찾은 뒤 4초 동안 놓친 클라이머가 천천히 오른쪽으로 이동합니다.
    final frames = [
      for (var i = 0; i < 3; i++) numbered(i * 200, [(coloredAt(.3), 1)]),
      for (var i = 3; i < 23; i++) numbered(i * 200, []),
    ];
    final asked = <int>[];
    final filled = await filler.fill(
      frames,
      width: 720,
      height: 960,
      find: (r) async {
        asked.add(r.frameIndex);
        return [coloredAt(.3 + (r.frameIndex - 2) * .01)];
      },
    );
    // 처음에는 1.5초 범위만 요청하지만, 찾은 위치를 기준으로 끝까지 이어집니다.
    expect(filled.every((f) => f.personIds.contains(1)), isTrue);
    expect(asked.toSet(), hasLength(20));
    expect(filled.last.bodies.single.center.x, closeTo(.5, .001));

    // 아무것도 찾지 못하면 첫 차례 범위만 확인하고 멈춥니다.
    final none = <int>[];
    final unchanged = await filler.fill(
      frames,
      width: 720,
      height: 960,
      find: (r) async {
        none.add(r.frameIndex);
        return const [];
      },
    );
    expect(none, [3, 4, 5, 6, 7, 8, 9]);
    expect(unchanged.skip(3).every((f) => f.bodies.isEmpty), isTrue);

    // 다른 옷 색의 사람이 같은 자리에 있어도 이어 붙이지 않습니다.
    final other = await filler.fill(
      frames,
      width: 720,
      height: 960,
      find: (r) async => [coloredAt(.3, color: 40)],
    );
    expect(other.skip(3).every((f) => f.bodies.isEmpty), isTrue);

    // 기기에서 실패하면 그때까지 찾은 결과만 남깁니다.
    var count = 0;
    final partial = await filler.fill(
      frames,
      width: 720,
      height: 960,
      find: (r) async {
        if (++count > 2) throw StateError('기기 오류');
        return [coloredAt(.3)];
      },
    );
    expect(partial.where((f) => f.personIds.contains(1)), hasLength(5));
  });
  test('보조 모델 결과는 기본 결과와 겹치지 않을 때만 후보로 더한다', () {
    List<List<double>> pose(double x) => coloredAt(x).toJson();
    final frame = PoseFrame.fromMap({
      'timeMs': 0,
      'inferenceMs': 1.0,
      'poses': [pose(.3)],
      'assistPoses': [pose(.32)],
    });
    expect(frame.bodies, hasLength(1));
    final added = PoseFrame.fromMap({
      'timeMs': 0,
      'inferenceMs': 1.0,
      'poses': [pose(.3)],
      'assistPoses': [pose(.7)],
      'assistAppearances': [List.filled(96, 1.0)],
    });
    expect(added.bodies, hasLength(2));
    expect(added.bodies.last.appearance, isNotNull);
    final onlyAssist = PoseFrame.fromMap({
      'timeMs': 0,
      'inferenceMs': 1.0,
      'poses': [],
      'assistPoses': [pose(.5)],
    });
    expect(onlyAssist.bodies, hasLength(1));
  });
}
