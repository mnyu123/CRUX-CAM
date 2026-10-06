import 'package:crux_cam/core/tracking/person_catalog.dart';
import 'package:crux_cam/features/analysis/models/pose_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pose.dart';

void main() {
  test('두 사람의 모델 반환 순서가 바뀌어도 번호를 유지한다', () {
    final frames = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.25), bodyAt(.75)]),
      poseFrame(200, [bodyAt(.74), bodyAt(.26)]),
      poseFrame(400, [bodyAt(.27), bodyAt(.73)]),
    ]);
    expect(frames.map((f) => f.personIds), [
      [1, 2],
      [2, 1],
      [1, 2],
    ]);
  });
  test('가까운 두 사람을 구분할 수 없으면 번호를 억지로 이어 붙이지 않는다', () {
    final frames = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.45), bodyAt(.55)]),
      poseFrame(200, [bodyAt(.49), bodyAt(.51)]),
      poseFrame(400, [bodyAt(.43), bodyAt(.57)]),
    ]);
    expect(frames[1].personIds, [null, null]);
    expect(frames.last.personIds, [1, 2]);
  });
  test('자세 변화와 10초 누락 뒤에도 같은 사람 번호를 유지한다', () {
    final frames = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.3)]),
      poseFrame(200, []),
      poseFrame(400, [bodyAt(.31)]),
      poseFrame(10400, [bodyAt(.75, y: .2)]),
    ]);
    expect(frames[2].personIds, [1]);
    expect(frames.last.personIds, [1]);
  });
  test('추가 영역의 다른 사람은 새 번호로 추가하고 기존 번호와 좌표는 보존한다', () {
    final base = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.25)]),
      poseFrame(200, [bodyAt(.26)]),
    ]);
    final merged = PersonCatalog().merge(base, [
      poseFrame(0, [bodyAt(.75)]),
      poseFrame(200, [bodyAt(.74)]),
    ]);
    expect(merged.map((f) => f.personIds), [
      [1, 2],
      [1, 2],
    ]);
    expect(merged.first.bodies.first, same(base.first.bodies.first));
    expect(merged.first.inferenceMs, 20);
  });
  test('같은 사람의 중복 분석은 후보를 늘리지 않는다', () {
    final base = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.25)]),
    ]);
    final merged = PersonCatalog().merge(base, [
      poseFrame(0, [bodyAt(.255)]),
    ]);
    expect(merged.first.bodies, hasLength(1));
    expect(merged.first.personIds, [1]);
  });
  test('옷 색이 다른 새 사람이 나타나면 새 번호를 주고 원래 사람은 기존 번호로 돌아온다', () {
    PoseBody colored(double x, int bin) => PoseBody(
      bodyAt(x).points,
      appearance: List.generate(96, (i) => i == bin ? 1.0 : 0.0),
    );
    final frames = PersonCatalog().assign([
      poseFrame(0, [colored(.3, 0)]),
      poseFrame(200, [colored(.3, 0)]),
      poseFrame(10000, [colored(.3, 80)]),
      poseFrame(10200, [colored(.3, 80)]),
      poseFrame(11000, [colored(.7, 0)]),
    ]);
    expect(frames.map((f) => f.personIds), [
      [1],
      [1],
      [2],
      [2],
      [1],
    ]);
  });
  test('연속 동작에서 자세 때문에 몸통 색 표본이 바뀌어도 같은 번호를 유지한다', () {
    PoseBody colored(double x, int bin) => PoseBody(
      bodyAt(x).points,
      appearance: List.generate(96, (i) => i == bin ? 1.0 : 0.0),
    );
    final frames = PersonCatalog().assign([
      poseFrame(0, [colored(.3, 0)]),
      poseFrame(200, [colored(.31, 0)]),
      poseFrame(400, [colored(.32, 80)]),
      poseFrame(600, [colored(.33, 80)]),
    ]);
    expect(frames.every((f) => f.personIds.single == 1), isTrue);
  });
  test('짧은 누락 뒤 예측 위치에 돌아온 사람은 색 표본이 바뀌어도 같은 번호를 유지한다', () {
    PoseBody colored(double y, int bin) => PoseBody(
      bodyAt(.3, y: y).points,
      appearance: List.generate(96, (i) => i == bin ? 1.0 : 0.0),
    );
    final frames = PersonCatalog().assign([
      poseFrame(0, [colored(.3, 0)]),
      poseFrame(200, [colored(.34, 0)]),
      poseFrame(400, []),
      poseFrame(600, []),
      poseFrame(800, []),
      poseFrame(1200, [colored(.44, 80)]),
    ]);
    expect(frames.last.personIds, [1]);
  });
  test('새 인물의 일회성 오감지는 번호 카운트를 늘리지 않는다', () {
    final frames = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.25)]),
      poseFrame(200, [bodyAt(.25), bodyAt(.8)]),
      poseFrame(400, [bodyAt(.25)]),
    ]);
    expect(frames[1].personIds, [1, null]);
  });
  test('추가 영역은 기존 사람이 없는 다른 시점에서도 별도 새 번호를 유지한다', () {
    final base = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.3)]),
      poseFrame(200, []),
    ]);
    final merged = PersonCatalog().merge(base, [
      poseFrame(0, []),
      poseFrame(200, [bodyAt(.3)]),
    ]);
    expect(merged.last.personIds, [2]);
  });
  test('화면 밖이나 너무 작은 분석 영역은 거부한다', () {
    expect(() => PoseRegion(-.1, 0, .5, 1), throwsFormatException);
    expect(() => PoseRegion(.5, 0, .51, 1), throwsFormatException);
    expect(() => PoseRegion(0, double.nan, .5, 1), throwsFormatException);
  });
}
