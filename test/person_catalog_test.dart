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
  test('짧은 누락은 연결하고 2초가 넘는 가림은 새 번호를 부여한다', () {
    final frames = PersonCatalog().assign([
      poseFrame(0, [bodyAt(.3)]),
      poseFrame(200, []),
      poseFrame(400, [bodyAt(.31)]),
      poseFrame(2600, [bodyAt(.31)]),
    ]);
    expect(frames[2].personIds, [1]);
    expect(frames.last.personIds, [2]);
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
  test('화면 밖이나 너무 작은 분석 영역은 거부한다', () {
    expect(() => PoseRegion(-.1, 0, .5, 1), throwsFormatException);
    expect(() => PoseRegion(.5, 0, .51, 1), throwsFormatException);
    expect(() => PoseRegion(0, double.nan, .5, 1), throwsFormatException);
  });
}
